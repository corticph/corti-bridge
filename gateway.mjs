#!/usr/bin/env node

import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import zlib from "node:zlib";
import {
  TranslateRejection,
  applyIntercepts,
  createStreamTranslator,
  estimateTokens,
  promptTooLong,
  runAdvisor,
  translateCompletion,
  translateError,
  translateModels,
  translateNetworkError,
  translateRequest,
} from "./translate.mjs";
import {
  RETRY_MAX_ATTEMPTS,
  isRetryableNetworkError,
  isRetryableStatus,
  retryDelayMs,
} from "./lib/retry.mjs";

const HOST = process.env.CORTI_HOST ?? "127.0.0.1";
const PORT = Number(process.env.CORTI_PORT ?? 4192);
const BEARER = process.env.CORTI_BEARER;
const BASE_URL = process.env.CORTI_BASE_URL;
// What a request carrying no mode prefix resolves to. Normally openai; a wrapper predating
// path dispatch sets CORTI_UPSTREAM_MODE and cannot add a prefix, so its bare requests have
// to keep meaning pass-through. Read once at boot — mode is otherwise per request.
const BARE_PATH_IS_ANTHROPIC = process.env.CORTI_UPSTREAM_MODE === "anthropic";
const REASONING_MODE = ["thinking", "text", "drop"].includes(process.env.CORTI_REASONING_MODE)
  ? process.env.CORTI_REASONING_MODE
  : "thinking";

if (!BEARER) {
  console.error("CORTI_BEARER is required");
  process.exit(1);
}

if (!BASE_URL) {
  console.error("CORTI_BASE_URL is required");
  process.exit(1);
}

const BASE_URL_PATTERN = /^https:\/\/ai\.[a-z0-9-]+\.corti\.app\/v1$/;
if (!BASE_URL_PATTERN.test(BASE_URL)) {
  console.error(
    `CORTI_BASE_URL "${BASE_URL}" doesn't look like a Corti API URL (expected https://ai.<env>.corti.app/v1)`,
  );
  process.exit(1);
}

const UPSTREAM_OPENAI = BASE_URL;
const UPSTREAM_ANTHROPIC = BASE_URL.replace(/\/v1$/, "/anthropic");
// Claude Code preserves a path prefix in ANTHROPIC_BASE_URL, so the wrapper selects a mode by
// pointing a session at "$GATEWAY" or "$GATEWAY/anthropic".
const ANTHROPIC_PREFIX = "/anthropic";

// Probe-locked constants
const PING_INTERVAL_MS = 15_000;
const STREAM_IDLE_MS = 120_000;
// Silence before response headers means upstream never answered at all — a far stronger
// death signal than a mid-generation pause, so it gets its own, shorter fuse. Set
// CORTI_HEADERS_TIMEOUT_MS=0 to fall back to STREAM_IDLE_MS; raise it if upstream
// buffers whole non-SSE replies to streaming requests and generation runs long.
const _headersTimeout = Number(process.env.CORTI_HEADERS_TIMEOUT_MS);
const HEADERS_TIMEOUT_MS = !Number.isFinite(_headersTimeout)
  ? 60_000
  : _headersTimeout > 0
    ? _headersTimeout
    : STREAM_IDLE_MS;
const NONSTREAM_TIMEOUT_MS = 600_000;
const SHUTDOWN_GRACE_MS = 5_000;
// Upstream's own 400 is authoritative for whichever model is called; this just bounds the backstop.
const CONTEXT_WINDOW = 524_288;
// estimateTokens undercounts real usage, so this trips only on absurd bodies.
const OVERFLOW_TOKEN_ESTIMATE = 524_288;
const BYTE_CAP_BYTES = 8_000_000;
const MEMORY_BREAKER_BYTES = 64_000_000;

const DEBUG = isTruthy(process.env.CORTI_DEBUG);
const _debugMaxBody = Number(process.env.CORTI_DEBUG_MAX_BODY);
// 0 stays 0 (the "unlimited" sentinel); NaN (a non-numeric env value) falls back to the default.
const DEBUG_MAX_BODY = Number.isFinite(_debugMaxBody) ? _debugMaxBody : 2097152;
const LOG_FILE = DEBUG ? openDebugLog() : null;

const agent = new https.Agent({ keepAlive: true, keepAliveMsecs: 30000, maxSockets: 32 });

let requestId = 0;

// Closers for responses still streaming. Shutdown ends each one with a terminal frame
// instead of letting the socket reset, so the client sees a decodable error.
const inFlight = new Set();
let shuttingDown = false;

// Splits the mode prefix off a URL. Anchored on purpose: "/v1/anthropic/messages" and
// "/anthropicabc/x" are openai paths, not pass-through ones.
function splitPath(url) {
  const reqPath = (url ?? "").split("?")[0];
  if (reqPath === ANTHROPIC_PREFIX || reqPath.startsWith(`${ANTHROPIC_PREFIX}/`))
    return { anthropic: true, path: reqPath.slice(ANTHROPIC_PREFIX.length) || "/" };
  return { anthropic: BARE_PATH_IS_ANTHROPIC, path: reqPath };
}

// The wrapper stamps the mode it asked for onto the auth token, which the gateway otherwise
// discards. Headers are untouched by URL resolution, so a stamp that disagrees with the path
// means the prefix was lost in transit — the one failure that would otherwise be silent,
// serving pass-through traffic through the translator.
function modeMarker(req) {
  const auth = req.headers.authorization ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : (req.headers["x-api-key"] ?? "");
  if (token.endsWith("-anthropic")) return "anthropic";
  if (token.endsWith("-openai")) return "openai";
  return null;
}

// The advisor child is spawned through this same gateway; without a guard it would re-inject
// consult_advisor into its own request and recurse. The wrapper stamps a -noadvisor- marker
// on the child's token (local-gateway-noadvisor-<mode>) — placed before the mode suffix so
// modeMarker still matches the trailing -openai/-anthropic. Match the marker anywhere in the
// token, since it now sits before the mode suffix rather than at the tail.
function wantsNoAdvisor(req) {
  const auth = req.headers.authorization ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : (req.headers["x-api-key"] ?? "");
  return typeof token === "string" && token.includes("-noadvisor-");
}

let warnedUnmarked = false;

const server = http.createServer((req, res) => {
  if (req.method === "OPTIONS") return cors(res);

  // Unprefixed on purpose: the wrapper curls it before it knows which mode a session wants.
  if (req.url === "/health") return send(res, 200, healthPayload());

  const { anthropic, path: reqPath } = splitPath(req.url);

  const marker = modeMarker(req);
  if (marker === "anthropic" && !anthropic)
    return send(res, 400, {
      type: "error",
      error: {
        type: "invalid_request_error",
        message:
          `pass-through was requested but the "${ANTHROPIC_PREFIX}" path prefix did not arrive — ` +
          `the client dropped it from ANTHROPIC_BASE_URL. Re-run ./setup.sh; if that does not ` +
          `help, the client changed how it joins a base URL to a request path.`,
      },
    });
  if (marker === null && !warnedUnmarked) {
    warnedUnmarked = true;
    // Hand-curling and pre-dispatch wrappers land here. The path is authoritative for them.
    console.log("corti-proxy: request without a mode marker — routing by path alone");
  }

  // Claude Code probes this against the base URL before its first request. Answering locally
  // keeps both modes identical; pass-through would otherwise forward it upstream.
  if (req.method === "HEAD" && reqPath === "/api/hello") return void res.writeHead(200).end();

  if (anthropic) return void handlePassthrough(req, res, reqPath).catch(proxyFailure(res));
  return handleOpenAI(req, res, reqPath);
});

function healthPayload() {
  return {
    status: "healthy",
    gatewayVersion: 2,
    // A pre-dispatch wrapper compares this against the mode it wants, so it has to describe
    // bare-path behaviour rather than naming a process-wide mode that no longer exists.
    mode: BARE_PATH_IS_ANTHROPIC ? "anthropic" : "openai",
    upstream: BASE_URL,
    debug: LOG_FILE ?? false,
  };
}

// CC streams can be long-lived; don't let Node's request timeout kill them.
server.requestTimeout = 0;
server.listen(PORT, HOST, () => {
  console.log(
    `corti-proxy on http://${HOST}:${PORT} (openai: /, anthropic: ${ANTHROPIC_PREFIX}, reasoning: ${REASONING_MODE})`,
  );
  if (LOG_FILE) console.log(`corti-proxy debug log: ${LOG_FILE}`);
});

// Without this, SIGTERM is the OS default: the process dies instantly and every open stream
// resets mid-frame, which the client surfaces as ECONNRESET rather than an API error.
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`corti-proxy: ${signal} — shutting down`);

  // server.close() only stops the listener; it resolves once every socket is gone, and an
  // idle keep-alive client would hold it open indefinitely.
  server.close(() => process.exit(0));
  server.closeIdleConnections();

  for (const closer of inFlight) {
    try {
      closer();
    } catch {
      // a closer racing its own socket teardown must not block the rest
    }
  }

  // Backstop: a wedged socket, or the outbound pool's ref'd sockets, would otherwise
  // keep the process alive past the point of usefulness.
  setTimeout(() => {
    server.closeAllConnections();
    agent.destroy();
    process.exit(0);
  }, SHUTDOWN_GRACE_MS).unref();
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

/* ================================================================== */
/* anthropic mode: thin pass-through                                     */
/* ================================================================== */

async function handlePassthrough(req, res, reqPath) {
  const id = ++requestId;
  const isCountTokens = reqPath.startsWith("/v1/messages/count_tokens");
  const target = isCountTokens ? null : new URL(`${UPSTREAM_ANTHROPIC}${reqPath}`);

  let body = await rawBody(req);
  const started = Date.now();

  if (!isCountTokens && req.method === "POST" && reqPath === "/v1/messages") {
    try {
      const parsed = JSON.parse(body.toString());
      await applyIntercepts(parsed, { skipAdvisor: wantsNoAdvisor(req) });
      body = Buffer.from(JSON.stringify(parsed));
    } catch {
      // JSON parse failed — forward original body; upstream will reject
    }
  }

  logRequest(id, req, target, body);

  if (isCountTokens) {
    const counted = countTokens(body);
    logResponse({
      id,
      started,
      status: counted.status,
      body: JSON.stringify(counted.payload),
      note: "handled locally",
    });
    return send(res, counted.status, counted.payload);
  }

  const proxyReq = https.request(
    target,
    {
      agent,
      method: req.method,
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${BEARER}`,
        "anthropic-version": req.headers["anthropic-version"] ?? "2023-06-01",
        "content-length": body.length,
        ...(req.headers["anthropic-beta"] && { "anthropic-beta": req.headers["anthropic-beta"] }),
      },
    },
    (upstream) => {
      console.log(`${req.method} ${reqPath} ${upstream.statusCode}`);
      res.writeHead(upstream.statusCode ?? 502, upstream.headers);
      if (LOG_FILE) teeResponse(id, started, upstream, res);
      upstream.pipe(res);
    },
  );

  proxyReq.on("error", (err) => {
    console.error(err.message);
    logResponse({ id, started, status: null, body: "", note: `upstream request error: ${err.message}` });
    if (!res.headersSent)
      send(res, 502, { type: "error", error: { type: "api_error", message: err.message } });
  });

  // Passthrough carries Corti's raw wire bytes, so there is no Anthropic frame we could
  // honestly synthesise here — ending the response is the truthful signal.
  const closer = () => {
    if (!res.writableEnded) res.end();
  };
  inFlight.add(closer);
  res.on("close", () => inFlight.delete(closer));

  req.on("close", () => {
    if (!res.writableEnded) proxyReq.destroy();
  });

  proxyReq.end(body);
}

/* ================================================================== */
/* openai mode: translating gateway                                    */
/* ================================================================== */

function handleOpenAI(req, res, reqPath) {
  return rawBody(req)
    .then((body) => {
      if (req.method === "POST" && reqPath === "/v1/messages") return handleMessages(req, res, body);
      if (req.method === "POST" && reqPath === "/v1/messages/count_tokens") {
        const counted = countTokens(body);
        return send(res, counted.status, counted.payload);
      }
      if (req.method === "GET" && reqPath === "/v1/models") return handleModels(res);
      if (req.method === "POST" && reqPath === "/api/event_logging/batch") return send(res, 200, {});
      return send(res, 404, {
        type: "error",
        error: { type: "not_found_error", message: `unknown route: ${req.method} ${reqPath}` },
      });
    })
    .catch(proxyFailure(res));
}

// Neither upstream offers token counting — the OpenAI API has no such endpoint and Corti's
// /anthropic 404s on it — so both routes answer locally from the same estimate.
function countTokens(body) {
  try {
    return { status: 200, payload: { input_tokens: estimateTokens(JSON.parse(body.toString())) } };
  } catch {
    return {
      status: 400,
      payload: {
        type: "error",
        error: { type: "invalid_request_error", message: "request body is not valid JSON" },
      },
    };
  }
}

function handleModels(res) {
  const proxyReq = https.request(
    new URL(`${UPSTREAM_OPENAI}/models`),
    { agent, method: "GET", headers: { authorization: `Bearer ${BEARER}` } },
    (upstream) => {
      const chunks = [];
      upstream.on("data", (c) => chunks.push(c));
      upstream.on("end", () => {
        const text = Buffer.concat(chunks).toString();
        if (upstream.statusCode !== 200) {
          const mapped = translateError({
            status: upstream.statusCode,
            headers: upstream.headers,
            bodyText: text,
          });
          return send(res, mapped.status, mapped.envelope, mapped.headers);
        }
        try {
          return send(res, 200, translateModels(JSON.parse(text)));
        } catch {
          return send(res, 502, {
            type: "error",
            error: { type: "api_error", message: "upstream /models returned unparseable body" },
          });
        }
      });
    },
  );
  proxyReq.on("error", (err) => {
    const mapped = translateNetworkError(err);
    if (!res.headersSent) send(res, mapped.status, mapped.envelope);
  });
  proxyReq.end();
}

async function handleMessages(req, res, body) {
  const id = ++requestId;
  const started = Date.now();
  const url = `${UPSTREAM_OPENAI}/chat/completions`;
  const diagnostics = [];

  // all mutable request state up front: fail()/finalize() may run at any point after this
  let clientGone = false;
  let finalized = false;
  let proxyReq = null;
  let upstreamRes = null;
  let headersSentToClient = false;
  let lastActivity = Date.now();
  let translator = null;
  let interval = null;
  let absolute = null;
  let loggedResponse = false;
  let attempt = 0;
  let retryTimer = null;
  let drainPending = false;
  let shutdownCloser = null;
  let upstreamStatus = null;
  let emittedTruncated = false;
  let emittedSize = 0;
  let upstreamSize = 0;
  const emittedFrames = [];
  const upstreamChunks = [];

  logRequest(id, req, url, body);

  const finalize = (note) => {
    if (finalized) return;
    finalized = true;
    if (interval) clearInterval(interval);
    if (absolute) clearTimeout(absolute);
    if (retryTimer) clearTimeout(retryTimer);
    if (shutdownCloser) inFlight.delete(shutdownCloser);
    if (proxyReq && !proxyReq.destroyed) proxyReq.destroy();
    if (LOG_FILE && note) {
      if (translator && !loggedResponse)
        logUpstreamResponse(id, upstreamStatus ?? null, cap(Buffer.concat(upstreamChunks))[0]);
      if (!loggedResponse)
        logResponse({
          id,
          started,
          status: res.statusCode ?? null,
          body: emittedFrames.length ? Buffer.concat(emittedFrames) : "",
          note,
          diagnostics,
          truncated: emittedTruncated,
        });
    }
  };

  const fail = (mapped, note) => {
    // PRE_STREAM envelope; only valid while the client response is still unwritten
    if (res.headersSent || clientGone) return finalize(note);
    loggedResponse = true;
    logResponse({ id, started, status: mapped.status, body: JSON.stringify(mapped.envelope), note, diagnostics });
    send(res, mapped.status, mapped.envelope, mapped.headers);
    finalize(note);
  };

  // A retry is only safe while the client response is still unwritten: once SSE frames
  // are out, a second attempt would replay a partial turn.
  const canRetry = () =>
    !finalized && !clientGone && !headersSentToClient && !res.headersSent && attempt < RETRY_MAX_ATTEMPTS;

  const scheduleRetry = (n, reason, delay) => {
    diagnostics.push(`attempt ${n} failed (${reason}); retried after ${delay}ms`);
    // Drop the abandoned attempt's socket rather than returning it to the pool, and
    // deafen it first: a late 'error' from the destroy would otherwise reach fail()
    // and surface as a client error while the retry is still pending.
    const dead = proxyReq;
    if (dead && !dead.destroyed) {
      dead.removeAllListeners("error");
      dead.on("error", () => {});
      dead.destroy();
    }
    retryTimer = setTimeout(() => {
      retryTimer = null;
      if (finalized || clientGone) return;
      sendUpstream();
    }, delay);
  };

  req.on("close", () => {
    if (!res.writableEnded) {
      clientGone = true;
      finalize("client-abort");
    }
  });

  /* ---- local body checks (before any upstream contact) ---- */

  let anthropicBody;
  try {
    anthropicBody = JSON.parse(body.toString());
  } catch {
    return fail(
      {
        status: 400,
        envelope: {
          type: "error",
          error: { type: "invalid_request_error", message: "request body is not valid JSON" },
        },
      },
      "bad-json",
    );
  }

  if (body.length > MEMORY_BREAKER_BYTES)
    return fail(
      {
        status: 413,
        envelope: {
          type: "error",
          error: { type: "request_too_large", message: "request body exceeds local proxy cap (64 MB)" },
        },
      },
      "body-cap",
    );

  const est = estimateTokens(anthropicBody);
  if (est > OVERFLOW_TOKEN_ESTIMATE)
    return fail(
      {
        status: 400,
        envelope: {
          type: "error",
          error: {
            type: "invalid_request_error",
            message: promptTooLong(est, CONTEXT_WINDOW, "proxy estimate"),
          },
        },
      },
      "local-overflow",
    );

  if (body.length > BYTE_CAP_BYTES)
    return fail(
      {
        status: 413,
        envelope: {
          type: "error",
          error: {
            type: "request_too_large",
            message: "request body exceeds the largest size measured to reach inference (8 MB); remove or shrink large images",
          },
        },
      },
      "byte-cap",
    );

  /* ---- request translation ---- */

  let translated;
  try {
    const out = await translateRequest(anthropicBody, { skipAdvisor: wantsNoAdvisor(req) });
    translated = out.request;
    diagnostics.push(...out.dropped.map((d) => `dropped: ${d}`));
  } catch (err) {
    if (err instanceof TranslateRejection)
      return fail({ status: err.status, envelope: err.envelope }, "translation-rejected");
    throw err;
  }

  const ctx = {
    msgId: `msg_${crypto.randomUUID().replace(/-/g, "").slice(0, 24)}`,
    requestedModel: anthropicBody.model,
    reasoningMode: REASONING_MODE,
    estimatedInput: est,
    onDiagnostic: (m) => diagnostics.push(m),
  };

  // Hold-and-continue advisor: when the turn ends on a consult_advisor tool_use, the translator
  // fires this hook instead of terminating. We emit a synthetic server_tool_use + advisor_tool_result
  // inline (the shape the harness renders as "Advising…"), run the advisor, then make a second
  // upstream call with the consult_advisor tool_use + a real client tool_result appended so the
  // model reads the advice and actually answers the user. The gateway owns the terminal events.
  let advisorHandled = false;
  ctx.onAdvisorToolUse = async ({ id, focus }) => {
    if (advisorHandled || finalized || clientGone) return;
    advisorHandled = true;
    diagnostics.push(`advisor hold-and-continue: id=${id} focus="${String(focus).slice(0, 60)}"`);

    // 1. Emit the synthetic server-tool advisor blocks inline (rendered by the harness, not
    //    round-tripped to Corti — the continuation call below carries the client-tool shape).
    const srvIdx = translator ? translator.nextBlockIndex : 0;
    const resIdx = srvIdx + 1;
    writeEvent("content_block_start", {
      type: "content_block_start", index: srvIdx,
      content_block: { type: "server_tool_use", id, name: "advisor", input: {} },
    });
    writeEvent("content_block_stop", { type: "content_block_stop", index: srvIdx });

    // 2. Run the advisor. Non-blocking UI: "Advising" shows while this runs.
    let advisorText = "Advisor feedback: (no response)";
    try {
      const out = await runAdvisor(focus);
      if (out) advisorText = `Advisor feedback:\n\n${out}`;
    } catch (err) {
      diagnostics.push(`advisor spawn failed: ${err?.message ?? err}`);
    }

    if (finalized || clientGone) return;
    writeEvent("content_block_start", {
      type: "content_block_start", index: resIdx,
      content_block: {
        type: "advisor_tool_result", tool_use_id: id,
        content: { type: "advisor_result", text: advisorText, stop_reason: "end_turn" },
      },
    });
    writeEvent("content_block_stop", { type: "content_block_stop", index: resIdx });

    // 3. Continuation: a second, non-streaming upstream call. The history gains the model's
    //    consult_advisor tool_use + a client tool_result holding the advice, so the model reads
    //    the result and answers. We translate that response and stream it back as content blocks
    //    under the SAME message (the harness sees one continuous turn).
    try {
      await continueAfterAdvisor(id, focus, advisorText);
    } catch (err) {
      diagnostics.push(`advisor continuation failed: ${err?.message ?? err}`);
      if (!finalized && !res.writableEnded) {
        writeEvent("message_delta", {
          type: "message_delta",
          delta: { stop_reason: "end_turn", stop_sequence: null },
          usage: { input_tokens: est, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
        });
        writeEvent("message_stop", { type: "message_stop" });
        res.end();
        finalize("advisor-continuation-failed");
      }
    }
  };

  // The second upstream call: appends the consult_advisor tool_use + tool_result to the original
  // request and asks the model to continue. Non-streaming for simplicity (the first turn already
  // streamed; this is the advisor-aware continuation).
  const continueAfterAdvisor = (toolUseId, focus, advisorText) => {
    return new Promise((resolve, reject) => {
      // Build the continuation body: original messages + a new user turn carrying the tool_result.
      const contMessages = [...(anthropicBody.messages || [])];
      contMessages.push({
        role: "assistant",
        content: [{ type: "tool_use", id: toolUseId, name: "consult_advisor", input: { focus } }],
      });
      contMessages.push({
        role: "user",
        content: [{ type: "tool_result", tool_use_id: toolUseId, content: advisorText, is_error: false }],
      });
      const contAnthropic = { ...anthropicBody, messages: contMessages, stream: false };
      // skipAdvisor: the continuation already carries the consult_advisor tool_use +
      // tool_result we synthesized; re-running interceptConsultAdvisor would match that
      // tool_result and spawn runAdvisor a second time. The continuation is ours, not a
      // fresh client request, so the advisor intercept must not touch it.
      translateRequest(contAnthropic, { skipAdvisor: true })
        .then((out) => {
          const contTranslated = out.request;
          diagnostics.push(...out.dropped.map((d) => `continuation dropped: ${d}`));
          const body = Buffer.from(JSON.stringify(contTranslated));
          const req = https.request(url, {
            agent, method: "POST",
            headers: { "content-type": "application/json", authorization: `Bearer ${BEARER}`, "content-length": body.length },
          }, (up) => {
            const chunks = [];
            up.on("data", (c) => chunks.push(c));
            up.on("end", () => {
              if (finalized || clientGone) return resolve();
              try {
                const msg = translateCompletion(JSON.parse(Buffer.concat(chunks).toString()), ctx);
                // Stream the continuation content as more content_block events under this message.
                let idx = translator ? translator.nextBlockIndex : resIdx + 1;
                for (const block of msg.content) {
                  const skeleton =
                    block.type === "tool_use" ? { ...block, input: {} } :
                    block.type === "thinking" ? { type: "thinking", thinking: "", signature: "" } :
                    { type: "text", text: "" };
                  writeEvent("content_block_start", { type: "content_block_start", index: idx, content_block: skeleton });
                  if (block.type === "text")
                    writeEvent("content_block_delta", { type: "content_block_delta", index: idx, delta: { type: "text_delta", text: block.text } });
                  else if (block.type === "thinking") {
                    writeEvent("content_block_delta", { type: "content_block_delta", index: idx, delta: { type: "thinking_delta", thinking: block.thinking } });
                    writeEvent("content_block_delta", { type: "content_block_delta", index: idx, delta: { type: "signature_delta", signature: block.signature } });
                  } else if (block.type === "tool_use")
                    writeEvent("content_block_delta", { type: "content_block_delta", index: idx, delta: { type: "input_json_delta", partial_json: JSON.stringify(block.input) } });
                  writeEvent("content_block_stop", { type: "content_block_stop", index: idx });
                  idx++;
                }
                writeEvent("message_delta", {
                  type: "message_delta",
                  delta: { stop_reason: msg.stop_reason ?? "end_turn", stop_sequence: msg.stop_sequence ?? null },
                  usage: msg.usage,
                });
                writeEvent("message_stop", { type: "message_stop" });
                res.end();
                finalize("advisor-continuation");
                resolve();
              } catch (e) {
                reject(e);
              }
            });
            up.on("error", reject);
          });
          req.on("error", reject);
          req.end(body);
        })
        .catch(reject);
    });
  };

  const upstreamBody = Buffer.from(JSON.stringify(translated));
  logUpstreamRequest(id, url, upstreamBody);

  /* ---- response plumbing ---- */

  const collectEmitted = (buf) => {
    if (!LOG_FILE) return;
    if (DEBUG_MAX_BODY > 0 && emittedSize + buf.length > DEBUG_MAX_BODY) {
      const room = DEBUG_MAX_BODY - emittedSize;
      if (room > 0) emittedFrames.push(buf.subarray(0, room));
      emittedSize = DEBUG_MAX_BODY;
      emittedTruncated = true;
      return;
    }
    emittedFrames.push(buf);
    emittedSize += buf.length;
  };

  const writeEvent = (event, data) => {
    if (clientGone || res.writableEnded) return false;
    const buf = Buffer.from(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    collectEmitted(buf);
    const ok = res.write(buf);
    if (!ok && upstreamRes) {
      upstreamRes.pause();
      // One listener per backpressure episode, not per failed write: repeated writes
      // before a drain otherwise stack listeners for the life of the stream.
      if (!drainPending) {
        drainPending = true;
        res.once("drain", () => {
          drainPending = false;
          if (upstreamRes) upstreamRes.resume();
        });
      }
    }
    return ok;
  };

  const writePing = () => {
    if (clientGone || res.writableEnded) return;
    // While the translator handed the turn to the advisor hook, the stream is idle by
    // design (runAdvisor is spawning). Pings here render as a thinking-spinner line that
    // displaces the "Advising" indicator, so suppress them for the duration of the handoff.
    if (translator?.advisorHandoff) return;
    const buf = Buffer.from(`event: ping\ndata: {"type":"ping"}\n\n`);
    collectEmitted(buf);
    res.write(buf);
  };

  // Registered here, not with the other state: it closes over writeEvent, which is
  // initialised just above — registering earlier would leave a TDZ window where a
  // signal arriving mid-setup throws instead of shutting down cleanly.
  shutdownCloser = () => {
    if (finalized) return;
    if (!headersSentToClient)
      return fail(
        {
          status: 529,
          envelope: { type: "error", error: { type: "overloaded_error", message: "gateway shutting down" } },
        },
        "shutdown",
      );
    writeEvent("error", {
      type: "error",
      error: { type: "api_error", message: "gateway shutting down" },
    });
    res.end();
    finalize("shutdown");
  };
  inFlight.add(shutdownCloser);

  const deadlineCheck = () => {
    const silence = Date.now() - lastActivity;
    const limit = headersSentToClient ? STREAM_IDLE_MS : HEADERS_TIMEOUT_MS;
    if (silence >= limit) {
      if (headersSentToClient) {
        if (!finalized) {
          writeEvent("error", {
            type: "error",
            error: { type: "timeout_error", message: "upstream stalled" },
          });
          res.end();
          finalize("watchdog-timeout");
        }
      } else if (!finalized) {
        fail(
          {
            status: 504,
            envelope: {
              type: "error",
              error: { type: "timeout_error", message: "upstream timed out waiting for response headers" },
            },
          },
          "watchdog-timeout",
        );
      }
      return;
    }
    if (silence >= PING_INTERVAL_MS && headersSentToClient) writePing();
  };

  // One attempt. Re-invoked by scheduleRetry() while the client response is still
  // unwritten, so a retried request looks to Claude Code like one slow request.
  const sendUpstream = () => {
    const myAttempt = ++attempt;
    upstreamStatus = null;
    lastActivity = Date.now();

    proxyReq = https.request(
      url,
      {
        // Retries bypass the pool: a keep-alive socket pinned to an unhealthy backend
        // would just hand back the same instant 5xx.
        agent: myAttempt === 1 ? agent : false,
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${BEARER}`,
          "content-length": upstreamBody.length,
        },
      },
      (upstreamRaw) => {
        if (myAttempt !== attempt || finalized || clientGone) return void upstreamRaw.resume();
        lastActivity = Date.now();
        upstreamStatus = upstreamRaw.statusCode;

        if (upstreamRaw.statusCode >= 400) {
          // PRE_STREAM error path: drain body first, then envelope; bytes stay capped at 8KB
          const chunks = [];
          let size = 0;
          upstreamRaw.on("data", (c) => {
            if (size < 8192) {
              const slice = c.subarray(0, Math.min(c.length, 8192 - size));
              chunks.push(slice);
              size += slice.length;
            }
          });
          upstreamRaw.on("end", () => {
            if (myAttempt !== attempt || finalized || clientGone) return;
            const text = Buffer.concat(chunks).toString();
            const status = upstreamRaw.statusCode;
            console.log(`POST /v1/messages ${status}${myAttempt > 1 ? ` (attempt ${myAttempt})` : ""}`);
            // The only place upstream headers reach the log: what fail() records is the
            // envelope sent to the client, which drops server/retry-after/x-request-id.
            logUpstreamResponse(id, status, Buffer.from(text), upstreamRaw.headers);
            if (isRetryableStatus(status) && canRetry())
              return scheduleRetry(
                myAttempt,
                `HTTP ${status}`,
                retryDelayMs(myAttempt, upstreamRaw.headers["retry-after"]),
              );
            fail(
              translateError({
                status,
                headers: upstreamRaw.headers,
                bodyText: text,
                requestedModel: anthropicBody.model,
              }),
              "upstream-error",
            );
          });
          return;
        }

        const wantsStream = translated.stream === true;
        const contentType = String(upstreamRaw.headers["content-type"] ?? "");
        const isSse = contentType.includes("text/event-stream");

        upstreamRes = upstreamRaw;
        if (upstreamRaw.headers["content-encoding"] === "gzip") {
          const gunzip = zlib.createGunzip();
          upstreamRaw.pipe(gunzip);
          upstreamRes = gunzip;
          upstreamRaw.on("error", (err) => gunzip.destroy(err));
        }

        if (!wantsStream) {
          const chunks = [];
          upstreamRes.on("data", (c) => {
            chunks.push(c);
            lastActivity = Date.now();
          });
          upstreamRes.on("end", () => {
            const raw = Buffer.concat(chunks);
            logUpstreamResponse(id, upstreamStatus, cap(raw)[0]);
            try {
              const msg = translateCompletion(JSON.parse(raw.toString()), ctx);
              loggedResponse = true;
              logResponse({
                id,
                started,
                status: 200,
                body: JSON.stringify(msg),
                note: "completed",
                diagnostics,
              });
              send(res, 200, msg);
            } catch {
              loggedResponse = false;
              fail(
                {
                  status: 502,
                  envelope: {
                    type: "error",
                    error: { type: "api_error", message: "upstream returned unparseable completion" },
                  },
                },
                "parse-fail",
              );
              return;
            }
            finalize(null);
          });
          upstreamRes.on("error", (err) => fail(translateNetworkError(err), "upstream-error"));
          return;
        }

        if (!isSse) {
          // stream requested but upstream answered JSON: synthesize a one-shot SSE turn
          const chunks = [];
          upstreamRes.on("data", (c) => {
            chunks.push(c);
            lastActivity = Date.now();
          });
          upstreamRes.on("end", () => {
            const raw = Buffer.concat(chunks);
            let msg;
            try {
              msg = translateCompletion(JSON.parse(raw.toString()), ctx);
            } catch {
              fail(
                {
                  status: 502,
                  envelope: {
                    type: "error",
                    error: {
                      type: "api_error",
                      message: "upstream returned unparseable non-SSE body to streaming request",
                    },
                  },
                },
                "parse-fail",
              );
              return;
            }
            headersSentToClient = true;
            res.writeHead(200, {
              "content-type": "text/event-stream; charset=utf-8",
              "cache-control": "no-cache",
              connection: "keep-alive",
              "x-accel-buffering": "no",
            });
            res.flushHeaders();
            logUpstreamResponse(id, upstreamStatus, cap(raw)[0]);
            writeEvent("message_start", {
              type: "message_start",
              message: {
                ...msg,
                content: [],
                stop_reason: null,
                stop_sequence: null,
                usage: {
                  input_tokens: est,
                  output_tokens: 1,
                  cache_creation_input_tokens: 0,
                  cache_read_input_tokens: 0,
                },
              },
            });
            msg.content.forEach((block, i) => {
              const skeleton =
                block.type === "tool_use"
                  ? { ...block, input: {} }
                  : block.type === "thinking"
                    ? { type: "thinking", thinking: "", signature: "" }
                    : { type: "text", text: "" };
              writeEvent("content_block_start", { type: "content_block_start", index: i, content_block: skeleton });
              if (block.type === "text")
                writeEvent("content_block_delta", { type: "content_block_delta", index: i, delta: { type: "text_delta", text: block.text } });
              else if (block.type === "thinking") {
                writeEvent("content_block_delta", { type: "content_block_delta", index: i, delta: { type: "thinking_delta", thinking: block.thinking } });
                writeEvent("content_block_delta", { type: "content_block_delta", index: i, delta: { type: "signature_delta", signature: block.signature } });
              } else if (block.type === "tool_use")
                writeEvent("content_block_delta", { type: "content_block_delta", index: i, delta: { type: "input_json_delta", partial_json: JSON.stringify(block.input) } });
              writeEvent("content_block_stop", { type: "content_block_stop", index: i });
            });
            writeEvent("message_delta", {
              type: "message_delta",
              delta: { stop_reason: msg.stop_reason, stop_sequence: msg.stop_sequence ?? null },
              usage: msg.usage,
            });
            writeEvent("message_stop", { type: "message_stop" });
            res.end();
            finalize("completed");
          });
          upstreamRes.on("error", (err) => fail(translateNetworkError(err), "upstream-error"));
          return;
        }

        // streaming SSE path
        headersSentToClient = true;
        res.writeHead(200, {
          "content-type": "text/event-stream; charset=utf-8",
          "cache-control": "no-cache",
          connection: "keep-alive",
          "x-accel-buffering": "no",
        });
        res.flushHeaders();

        translator = createStreamTranslator(ctx, writeEvent);
        let buffer = "";
        let sawDone = false;

        const terminalNote = () =>
          emittedFrames.some((f) => f.includes("event: error")) ? "upstream-error" : "completed";

        const processEventBlock = (block) => {
          const dataLines = block
            .split(/\r?\n/)
            .filter((l) => l.startsWith("data:"))
            .map((l) => l.slice(5).trimStart());
          if (!dataLines.length) return;
          const payload = dataLines.join("\n");
          if (payload.trim() === "[DONE]") {
            sawDone = true;
            translator.done();
            // When the translator handed the turn to the advisor hook, the hook owns the rest
            // of the stream (async: it runs the advisor + continuation). Do not finalize here.
            if (translator.advisorHandoff) return;
            res.end();
            finalize("completed");
            return;
          }
          try {
            translator.feed(JSON.parse(payload));
          } catch {
            diagnostics.push(`unparseable upstream data line skipped (${payload.slice(0, 120)})`);
          }
          if (!finalized && translator.terminated && !sawDone) {
            res.end();
            finalize(terminalNote());
          }
        };

        const streamError = () => {
          if (finalized) return;
          // mid-stream socket failure (possibly over gunzip): never close open
          // blocks — truncated tool args must not look complete
          if (!translator.terminated)
            writeEvent("error", {
              type: "error",
              error: { type: "api_error", message: "upstream connection closed mid-stream" },
            });
          res.end();
          finalize("upstream-error");
        };

        upstreamRes.on("data", (chunk) => {
          lastActivity = Date.now();
          if (LOG_FILE && (DEBUG_MAX_BODY <= 0 || upstreamSize < DEBUG_MAX_BODY)) {
            upstreamChunks.push(chunk);
            upstreamSize += chunk.length;
          }
          buffer += chunk.toString();
          const parts = buffer.split(/\r?\n\r?\n/);
          buffer = parts.pop();
          for (const part of parts) {
            if (finalized) break;
            processEventBlock(part);
          }
        });

        upstreamRes.on("end", () => {
          if (finalized) return;
          if (buffer.trim()) processEventBlock(buffer);
          if (finalized) return;
          if (!sawDone) {
            translator.done();
            diagnostics.push("upstream ended without [DONE]");
            if (translator.advisorHandoff) return; // hook owns the rest (async)
            res.end();
            finalize(terminalNote());
          }
        });

        upstreamRes.on("error", streamError);
        upstreamRaw.on("error", streamError);
      },
    );

    proxyReq.on("error", (err) => {
      if (myAttempt !== attempt || finalized || clientGone) return;
      if (!headersSentToClient) {
        if (isRetryableNetworkError(err) && canRetry())
          return scheduleRetry(
            myAttempt,
            err?.cause?.code ?? err?.code ?? err.message,
            retryDelayMs(myAttempt),
          );
        return fail(translateNetworkError(err), "upstream-error");
      }
      writeEvent("error", {
        type: "error",
        error: { type: "api_error", message: "upstream connection error" },
      });
      res.end();
      finalize("upstream-error");
    });

    proxyReq.end(upstreamBody);
  };

  if (translated.stream === true) {
    interval = setInterval(deadlineCheck, 1_000);
  } else {
    absolute = setTimeout(() => {
      if (finalized) return;
      fail(
        {
          status: 504,
          envelope: { type: "error", error: { type: "timeout_error", message: "upstream timed out" } },
        },
        "watchdog-timeout",
      );
    }, NONSTREAM_TIMEOUT_MS);
  }

  sendUpstream();
}

/* ================================================================== */
/* shared helpers                                                      */
/* ================================================================== */

function rawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function send(res, status, data, extraHeaders) {
  res.writeHead(status, { "content-type": "application/json", ...(extraHeaders ?? {}) });
  res.end(JSON.stringify(data));
}

// Both handlers are async. An unhandled rejection terminates the process on Node 22, so an
// error in one mode would take down every in-flight session in the other.
function proxyFailure(res) {
  return (err) => {
    console.error(err);
    if (!res.headersSent)
      send(res, 500, { type: "error", error: { type: "api_error", message: "proxy failure" } });
  };
}

function cors(res) {
  res.writeHead(204, {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "*",
    "access-control-allow-methods": "POST, GET, OPTIONS",
  });
  res.end();
}

/* ---------- debug logging ---------- */

function isTruthy(value) {
  return value != null && !["", "0", "false", "no", "off"].includes(value.toLowerCase());
}

function openDebugLog() {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  for (const dir of [debugDir(), path.join(os.tmpdir(), "corti-claude-proxy")]) {
    const file = path.join(dir, `gateway-${stamp}.log`);
    try {
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      fs.appendFileSync(
        file,
        [
          `=== corti-claude-proxy debug log ===`,
          `started:  ${new Date().toISOString()}`,
          `pid:      ${process.pid}`,
          `upstream (openai):    ${UPSTREAM_OPENAI}`,
          `upstream (anthropic): ${UPSTREAM_ANTHROPIC}`,
          `body cap: ${DEBUG_MAX_BODY > 0 ? `${DEBUG_MAX_BODY} bytes` : "unlimited"}`,
          "",
          "",
        ].join("\n"),
        { mode: 0o600 },
      );
      return file;
    } catch (err) {
      console.error(`corti-proxy: cannot write debug log to ${dir}: ${err.message}`);
    }
  }
  return null;
}

function debugDir() {
  if (process.env.CORTI_DEBUG_DIR) return process.env.CORTI_DEBUG_DIR;
  if (process.platform === "darwin")
    return path.join(os.homedir(), "Library", "Logs", "corti-claude-proxy");
  const state = process.env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state");
  return path.join(state, "corti-claude-proxy");
}

// One entry per write: concurrent requests would otherwise interleave mid-entry.
function writeEntry(lines) {
  if (!LOG_FILE) return;
  try {
    fs.appendFileSync(LOG_FILE, `${lines.join("\n")}\n\n`, { mode: 0o600 });
  } catch (err) {
    console.error(`corti-proxy: debug log write failed: ${err.message}`);
  }
}

function logRequest(id, req, target, body) {
  if (!LOG_FILE) return;
  writeEntry([
    `=== #${id} REQUEST ${new Date().toISOString()} ===`,
    `${req.method} ${req.url}${target ? ` -> ${target}` : " (handled locally)"}`,
    `headers: ${JSON.stringify(redact(req.headers))}`,
    ...formatBody(...cap(body)),
  ]);
}

function logUpstreamRequest(id, url, body) {
  if (!LOG_FILE) return;
  writeEntry([
    `=== #${id} UPSTREAM-REQUEST ${new Date().toISOString()} ===`,
    `POST ${url}`,
    ...formatBody(...cap(body)),
  ]);
}

function logUpstreamResponse(id, status, body, headers) {
  if (!LOG_FILE) return;
  writeEntry([
    `=== #${id} UPSTREAM-RESPONSE ${new Date().toISOString()} ===`,
    `status: ${status ?? "none"}`,
    ...(headers ? [`headers: ${JSON.stringify(redact(headers))}`] : []),
    ...formatBody(...cap(body)),
  ]);
}

function logResponse({ id, started, status, headers, body, note, diagnostics, truncated }) {
  if (!LOG_FILE) return;
  writeEntry([
    `=== #${id} RESPONSE ${new Date().toISOString()} (${Date.now() - started}ms) ===`,
    `status: ${status ?? "none"}${note ? ` — ${note}` : ""}`,
    ...(headers ? [`headers: ${JSON.stringify(redact(headers))}`] : []),
    ...formatBody(body, truncated),
    ...(diagnostics?.length ? [`diagnostics:`, ...diagnostics.map((d) => `  - ${d}`)] : []),
  ]);
}

function teeResponse(id, started, upstream, res) {
  const chunks = [];
  let size = 0;
  let truncated = false;
  let logged = false;

  upstream.on("data", (chunk) => {
    if (DEBUG_MAX_BODY > 0) {
      const room = DEBUG_MAX_BODY - size;
      if (room <= 0) return void (truncated = true);
      if (chunk.length > room) {
        chunks.push(chunk.subarray(0, room));
        size = DEBUG_MAX_BODY;
        truncated = true;
        return;
      }
    }
    chunks.push(chunk);
    size += chunk.length;
  });

  const finish = (note) => {
    if (logged) return;
    logged = true;
    logResponse({
      id,
      started,
      status: upstream.statusCode,
      headers: upstream.headers,
      body: Buffer.concat(chunks),
      note,
      truncated,
    });
  };

  upstream.on("end", () => finish());
  upstream.on("error", (err) => finish(`stream error: ${err.message}`));
  upstream.on("close", () => finish("upstream closed before end"));
  // A client aborting mid-stream only ever surfaces here: the upstream stalls on backpressure,
  // and req's 'close' never fires once its body was read.
  res.on("close", () => finish("client disconnected mid-response"));
}

function redact(headers) {
  const out = {};
  for (const [key, value] of Object.entries(headers)) {
    out[key] = /^(authorization|x-api-key|cookie|set-cookie)$/i.test(key)
      ? "<redacted>"
      : value;
  }
  return out;
}

function cap(body) {
  if (DEBUG_MAX_BODY > 0 && body.length > DEBUG_MAX_BODY)
    return [body.subarray(0, DEBUG_MAX_BODY), true];
  return [body, false];
}

function formatBody(body, truncated) {
  const text = Buffer.isBuffer(body) ? body.toString() : String(body ?? "");
  if (!text) return ["body: <empty>"];
  let pretty = text;
  try {
    pretty = JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    // SSE streams and error pages aren't JSON — log them verbatim
  }
  return [`body:${truncated ? ` (truncated at ${DEBUG_MAX_BODY} bytes)` : ""}`, pretty];
}
