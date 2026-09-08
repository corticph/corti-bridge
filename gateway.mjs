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
  advisorContinuationErrorCode,
  applyIntercepts,
  createStreamTranslator,
  estimateTokens,
  promptTooLong,
  recordAdvisorGuidance,
  restoreAdvisorGuidance,
  runAdvisor,
  translateCompletion,
  translateError,
  translateModels,
  translateNetworkError,
  translateRequest,
} from "./translate.mjs";
import { serializeAdvisorInput } from "./lib/advisor-transcript.mjs";
import { calibrationKey, calibratedEstimate, recordPromptTokens } from "./lib/prompt-estimate.mjs";
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
// The advisor continuation is bounded by what is left of NONSTREAM_TIMEOUT_MS after the advisor
// phase, not by a fresh full budget: a ceiling measured from the continuation's own start expires
// long after the client has stopped listening, so the graceful failure note would land nowhere.
// GRACE leaves room to write that note; MIN keeps a slow advisor from starving the continuation.
// MIN can outlast the client's own patience after a near-ceiling consult — that case is bounded
// by client-disconnect detection (req 'close' -> clientGone -> finalize), and letting a late
// continuation try beats failing it instantly with a note nobody is left to read.
const CONTINUATION_GRACE_MS = 10_000;
const CONTINUATION_MIN_MS = 60_000;
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
// Per-session debug logs: each session's traffic lands in its own file under LOG_DIR,
// keyed on x-claude-code-session-id (advisors override to their parent's id via
// x-corti-advisor-for). sessionFiles caches the path per session key for the gateway's life.
const LOG_DIR = DEBUG ? debugDir() : null;
const sessionFiles = new Map();
if (LOG_DIR) fs.mkdirSync(LOG_DIR, { recursive: true, mode: 0o700 });

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
    // Opaque fingerprint of the source this process booted from, handed over by the wrapper at
    // launch. The gateway never computes it: one side owns the algorithm, so the two can't drift.
    // The wrapper re-fingerprints the clone on each launch and restarts us when it stops matching,
    // which is what makes a `git pull` take effect instead of silently serving the old build.
    buildId: process.env.CORTI_BUILD_ID || null,
    // A pre-dispatch wrapper compares this against the mode it wants, so it has to describe
    // bare-path behaviour rather than naming a process-wide mode that no longer exists.
    mode: BARE_PATH_IS_ANTHROPIC ? "anthropic" : "openai",
    upstream: BASE_URL,
    debug: LOG_DIR ?? false,
  };
}

// CC streams can be long-lived; don't let Node's request timeout kill them.
server.requestTimeout = 0;
server.listen(PORT, HOST, () => {
  console.log(
    `corti-proxy on http://${HOST}:${PORT} (openai: /, anthropic: ${ANTHROPIC_PREFIX}, reasoning: ${REASONING_MODE})`,
  );
  if (LOG_DIR) console.log(`corti-proxy debug log dir: ${LOG_DIR}`);
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
  const sessionFile = DEBUG ? sessionLogFile(req) : null;
  const isCountTokens = reqPath.startsWith("/v1/messages/count_tokens");
  const target = isCountTokens ? null : new URL(`${UPSTREAM_ANTHROPIC}${reqPath}`);

  let body = await rawBody(req);
  const started = Date.now();

  if (!isCountTokens && req.method === "POST" && reqPath === "/v1/messages") {
    try {
      const parsed = JSON.parse(body.toString());
      await applyIntercepts(parsed, {
        skipAdvisor: wantsNoAdvisor(req),
        mode: "anthropic",
        parentSessionId: req.headers["x-claude-code-session-id"],
      });
      body = Buffer.from(JSON.stringify(parsed));
    } catch {
      // JSON parse failed — forward original body; upstream will reject
    }
  }

  logRequest(id, sessionFile, req, target, body);

  if (isCountTokens) {
    const counted = countTokens(body);
    logResponse({
      id,
      sessionFile,
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
      teeResponse(id, sessionFile, started, upstream, res);
      upstream.pipe(res);
    },
  );

  proxyReq.on("error", (err) => {
    console.error(err.message);
    logResponse({ id, sessionFile, started, status: null, body: "", note: `upstream request error: ${err.message}` });
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
  const sessionFile = DEBUG ? sessionLogFile(req) : null;
  const parentSessionId = req.headers["x-claude-code-session-id"];
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
  let lastPing = 0;
  let translator = null;
  // The continuation's own stream translator, once it starts streaming. endContinuationFailure
  // reads it to place its note after whatever the continuation already emitted; assigned once,
  // never reassigned, so the index it reports is always the live one.
  let contTranslator = null;
  // Next free block index for a continuation that emitted without a translator (the non-SSE
  // one-shot path). Keeps the note's placement keyed to what was actually emitted rather than to
  // which branch produced it.
  let contNextIndex = 0;
  // True while an advisor continuation (the 2nd upstream call after hold-and-continue) is in
  // flight. Like the advisor phase itself it can legitimately run for minutes, so the 120s
  // stream-idle watchdog must stay its hand — the continuation's own deadline is the ceiling.
  let continuationActive = false;
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

  logRequest(id, sessionFile, req, url, body);

  const finalize = (note) => {
    if (finalized) return;
    finalized = true;
    if (interval) clearInterval(interval);
    if (absolute) clearTimeout(absolute);
    if (retryTimer) clearTimeout(retryTimer);
    if (shutdownCloser) inFlight.delete(shutdownCloser);
    if (proxyReq && !proxyReq.destroyed) proxyReq.destroy();
    if (sessionFile && note) {
      if (translator && !loggedResponse)
        logUpstreamResponse(id, sessionFile, upstreamStatus ?? null, cap(Buffer.concat(upstreamChunks))[0]);
      if (!loggedResponse)
        logResponse({
          id,
          sessionFile,
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
    logResponse({ id, sessionFile, started, status: mapped.status, body: JSON.stringify(mapped.envelope), note, diagnostics });
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

  // The advisor child (wantsNoAdvisor) reasons at high effort by default — the official advisor
  // default — rather than the medium that adaptive thinking maps to. CORTI_ADVISOR_EFFORT
  // overrides (e.g. "medium" to keep consults cheap). Read at call time so a change takes effect
  // on the next consult without a gateway restart.
  const noAdvisor = wantsNoAdvisor(req);
  const advisorEffort = noAdvisor
    ? (process.env.CORTI_ADVISOR_EFFORT || "high")
    : undefined;
  let translated;
  try {
    const out = await translateRequest(anthropicBody, { skipAdvisor: noAdvisor, mode: "openai", advisorEffort, parentSessionId });
    translated = out.request;
    diagnostics.push(...out.dropped.map((d) => `dropped: ${d}`));
  } catch (err) {
    if (err instanceof TranslateRejection)
      return fail({ status: err.status, envelope: err.envelope }, "translation-rejected");
    throw err;
  }

  // The overflow guard above deliberately stays on the raw estimate; this is only what the client
  // is told the prompt cost, and it has to survive becoming a turn's final usage when the turn dies
  // before upstream reports anything real.
  const calKey = calibrationKey(parentSessionId, anthropicBody.model);
  const estimatedInput = calibratedEstimate(calKey, est);

  const ctx = {
    msgId: `msg_${crypto.randomUUID().replace(/-/g, "").slice(0, 24)}`,
    requestedModel: anthropicBody.model,
    reasoningMode: REASONING_MODE,
    estimatedInput,
    onDiagnostic: (m) => diagnostics.push(m),
    // Fires wherever translate.mjs sees upstream's own prompt_tokens, streaming or not. Paired
    // with the raw estimate for this same body, so the ratio compares like with like.
    onPromptTokens: (n) => recordPromptTokens(calKey, est, n),
  };

  // Hold-and-continue advisor: when the turn ends on a consult_advisor tool_use, the translator
  // fires this hook instead of terminating. We emit a synthetic server_tool_use + advisor_tool_result
  // inline (the shape the harness renders as "Advising…"), run the advisor, then make a second
  // upstream call with the consult_advisor tool_use + a real client tool_result appended so the
  // model reads the advice and actually answers the user. The gateway owns the terminal events.
  // Only wire the hook when the intercept actually offered the tool: a toolless side call was
  // never given the advisor, so it must not be able to hold a turn open for one either.
  const advisorOffered = anthropicBody.tools?.some((t) => t?.name === "consult_advisor");
  let advisorHandled = false;
  const onAdvisorToolUse = async ({ id }) => {
    if (advisorHandled || finalized || clientGone) return;
    advisorHandled = true;
    // Captured while it is still the newest block: the sentence the model would otherwise read
    // next turn as an unkept promise, and the anchor the advice is re-inserted against.
    const preCallText = translator?.lastText ?? "";
    // Serialize the executor's full request (system + tools + transcript + budget line) for the
    // advisor. The tool input is empty — the executor signals timing only; the harness forwards
    // context automatically, per the official advisor tool design.
    // Restored history: shown the excised version, the advisor confirms the executor's false
    // "I never called it" rather than correcting it.
    const { text: advisorInput, elidedCount } = serializeAdvisorInput(
      { ...anthropicBody, messages: restoreAdvisorGuidance(parentSessionId, anthropicBody.messages) },
      { maxTokens: Number(process.env.CORTI_ADVISOR_MAX_TOKENS) || 2048 },
    );
    const elidedStr = elidedCount ? ` elided=${elidedCount}` : "";
    diagnostics.push(`advisor hold-and-continue: id=${id} transcript=${advisorInput.length} chars${elidedStr}`);

    // 1. Emit the synthetic server-tool advisor blocks inline (rendered by the harness, not
    //    round-tripped to Corti — the continuation call below carries the client-tool shape).
    const srvIdx = translator ? translator.nextBlockIndex : 0;
    const resIdx = srvIdx + 1;
    writeEvent("content_block_start", {
      type: "content_block_start", index: srvIdx,
      content_block: { type: "server_tool_use", id, name: "advisor", input: {} },
    });
    writeEvent("content_block_stop", { type: "content_block_stop", index: srvIdx });

    /** Advisor succeeded but the continuation (proxy's own 2nd call) failed: a proxy-internal
     *  event, not an advisor failure. A text note ends the turn — no second advisor_tool_result
     *  (spec: one per call).
     *
     *  The note carries the advice verbatim. The harness does not replay server_tool_use /
     *  advisor_tool_result blocks into the next request's history, so the advisor's text exists
     *  only in the UI: a note pointing at "the advice above" points at nothing, and the model
     *  answers the next turn from a context where the consult left no trace at all. */
    const endContinuationFailure = (reason, tag) => {
      // contTranslator.terminated: the continuation already closed the turn (e.g. a socket error
      // arriving after [DONE]); a second message_delta/message_stop would be malformed.
      if (finalized || res.writableEnded || contTranslator?.terminated) return;
      diagnostics.push(`advisor continuation failed: ${reason}`);
      const note = advisorResult?.ok
        ? `[advisor consulted, but the follow-up response failed (${reason}). The guidance is repeated here because it is not retained in the conversation history otherwise.]\n\n<advisor_guidance>\n${advisorResult.text}\n</advisor_guidance>`
        : `[advisor consulted, but no advice was returned (${advisorResult?.code ?? "unavailable"}) and the follow-up response also failed (${reason}). Proceed without advice.]`;
      // Whatever the continuation already streamed stays intact: close its open block and take
      // the next free index. The captured resIdx is only correct before the continuation emits.
      contTranslator?.closeOpen();
      const idx = contTranslator ? contTranslator.nextBlockIndex : Math.max(resIdx + 1, contNextIndex);
      writeEvent("content_block_start", { type: "content_block_start", index: idx, content_block: { type: "text", text: "" } });
      writeEvent("content_block_delta", { type: "content_block_delta", index: idx, delta: { type: "text_delta", text: note } });
      writeEvent("content_block_stop", { type: "content_block_stop", index: idx });
      writeEvent("message_delta", {
        type: "message_delta",
        delta: { stop_reason: "end_turn", stop_sequence: null },
        usage: { input_tokens: estimatedInput, output_tokens: 1, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 },
      });
      writeEvent("message_stop", { type: "message_stop" });
      res.end();
      finalize(tag);
    };

    // 2. Run the advisor on the serialized transcript. Non-blocking UI: "Advising" shows while this runs.
    // runAdvisor returns {ok:true,text} or {ok:false,code} (official advisor_tool_result_error
    // error_code: execution_time_exceeded | unavailable | overloaded | too_many_requests |
    // prompt_too_long | model_not_found). On failure the harness renders "Advisor declined to
    // advise" and the executor continues without advice — never a fake success string.
    let advisorResult;
    try {
      const out = await runAdvisor(advisorInput, { parentSessionId });
      // Bare string = injected test stub; treat as success for backward compat.
      advisorResult = typeof out === "string" ? { ok: true, text: out } : out;
      if (!advisorResult) advisorResult = { ok: false, code: "unavailable" };
    } catch (err) {
      diagnostics.push(`advisor spawn failed: ${err?.message ?? err}`);
      advisorResult = { ok: false, code: "unavailable" };
    }

    if (finalized || clientGone) return;
    // The result block the client sees: success (advisor_result) or error (advisor_tool_result_error).
    // The error variant lets the harness render the expected "Advisor declined to advise on this
    // request" line instead of a success with an empty/no-response string. The success text is the
    // RAW advisor output (the official advisor_result carries the advisor's text verbatim, no prefix).
    const resultContent = advisorResult.ok
      ? { type: "advisor_result", text: advisorResult.text, stop_reason: "end_turn" }
      : { type: "advisor_tool_result_error", error_code: advisorResult.code };
    writeEvent("content_block_start", {
      type: "content_block_start", index: resIdx,
      content_block: { type: "advisor_tool_result", tool_use_id: id, content: resultContent },
    });
    writeEvent("content_block_stop", { type: "content_block_stop", index: resIdx });
    diagnostics.push(
      advisorResult.ok
        ? `advisor ok: ${advisorResult.text.length} chars`
        : `advisor failed: ${advisorResult.code}${advisorResult.detail ? ` — ${advisorResult.detail}` : ""}`,
    );

    // 3. Continuation: a second, non-streaming upstream call. The history gains the model's
    //    consult_advisor tool_use + a client tool_result holding the advice (or the failure note),
    //    so the model reads the result and answers. We translate that response and stream it back
    //    as content blocks under the SAME message (the harness sees one continuous turn).
    //    On failure the tool_result carries an unavailable note so the executor knows advice was
    //    unavailable and proceeds without it (the official "continues without further advice").
    //    Model-facing text wraps the advice in <advisor_guidance> — a distinct channel the
    //    executor treats as first-class advice, not ordinary tool output (reconstruction §3.3).
    const continuationText = advisorResult.ok
      ? `<advisor_guidance>\n${advisorResult.text}\n</advisor_guidance>`
      : `<advisor_guidance>\nadvisor unavailable (${advisorResult.code})\n</advisor_guidance>`;
    // The advisor child is done; the continuation is a normal upstream request. Release the
    // handoff (the advisor phase is over) but assert continuationActive so the 120s stream-idle
    // watchdog stays suppressed — the continuation can legitimately run for minutes (the model
    // reads the advice and answers), and a 120s silence kill would drop a live generation. The
    // continuation's own req.setTimeout is the real ceiling. Reset the silence clock so any
    // watchdog that does apply measures from the continuation's start, not the advisor run.
    translator?.releaseAdvisor?.();
    continuationActive = true;
    lastActivity = Date.now();
    try {
      await continueAfterAdvisor(id, continuationText, resIdx);
      // The harness drops the consult from history; anchor the advice on a block that survives
      // beside it — what preceded the call, else the first block the continuation emitted.
      if (advisorResult.ok) {
        const first = contTranslator?.firstBlock;
        const anchor = preCallText ? { text: preCallText }
          : first?.type === "text" ? { text: first.text, before: true }
          : first?.type === "tool" ? { toolUseId: first.id, before: true }
          : null;
        if (anchor) recordAdvisorGuidance(parentSessionId, anchor, advisorResult.text);
      }
      // Reached only once the continuation's upstream turn is complete and every frame is
      // written. Ending the turn here rather than inside the stream handler keeps settlement on
      // the critical path: a continuation that never settles can no longer finalize silently.
      if (!res.writableEnded) res.end();
      finalize("advisor-continuation");
    } catch (err) {
      endContinuationFailure(err?.message ?? String(err), err?.contTag ?? "advisor-continuation-failed");
      // endContinuationFailure declines when the turn is already closed. Finalize regardless, or
      // a request whose note could not be written waits for the watchdog and is logged under it.
      if (!finalized) {
        if (!res.writableEnded) res.end();
        finalize(err?.contTag ?? "advisor-continuation-failed");
      }
    } finally {
      continuationActive = false;
    }
  };
  if (advisorOffered) ctx.onAdvisorToolUse = onAdvisorToolUse;

  /**
   * Second upstream call: appends the consult_advisor tool_use + tool_result and asks the model
   * to continue. Streaming, like the first call, so Corti emits bytes as it generates rather than
   * buffering the whole answer (its buffered endpoint 500'd on large sessions).
   *
   * Resolves once the upstream turn is complete and every client frame is written; rejects with a
   * `contTag`-carrying error otherwise. It never ends the client response itself — the caller
   * does, so settlement sits on the critical path instead of being a side effect nobody awaits.
   */
  const continueAfterAdvisor = (toolUseId, advisorText, resIdx) => {
    // Emit a translated completion (a non-SSE upstream response) as a one-shot SSE turn that
    // resumes after the synthetic advisor blocks. Reused by the drain path for JSON upstreams.
    const emitContinuationCompletion = (msg) => {
      let idx = resIdx + 1;
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
        contNextIndex = idx;
      }
      writeEvent("message_delta", {
        type: "message_delta",
        delta: { stop_reason: msg.stop_reason ?? "end_turn", stop_sequence: msg.stop_sequence ?? null },
        usage: msg.usage,
      });
      writeEvent("message_stop", { type: "message_stop" });
    };
    return new Promise((resolve, reject) => {
      let settled = false;
      let deadline = null;
      // Every exit runs through here, so the promise settles exactly once on every path —
      // including the ones that used to rely on an 'end' event the socket teardown had already
      // cancelled, which left the whole handleMessages frame suspended for the process's life.
      const settle = (err) => {
        if (settled) return;
        settled = true;
        if (err) return reject(err);
        // Logged before the caller finalizes, so it lands in the RESPONSE entry's diagnostics.
        diagnostics.push("advisor continuation settled: upstream turn complete");
        resolve();
      };
      const settleFailed = (reason, tag) => settle(Object.assign(Error(reason), { contTag: tag }));

      const contMessages = [...(anthropicBody.messages || [])];
      contMessages.push({
        role: "assistant",
        content: [{ type: "tool_use", id: toolUseId, name: "consult_advisor", input: {} }],
      });
      contMessages.push({
        role: "user",
        content: [{ type: "tool_result", tool_use_id: toolUseId, content: advisorText, is_error: false }],
      });
      // The first translateRequest mutated anthropicBody.tools to include consult_advisor; the
      // spread carries that by reference. Strip it so the model can't call consult_advisor from
      // the continuation — onAdvisorToolUse is unset there, so a nested consult would emit a real
      // tool_use the harness has no implementation for (an "Unknown tool" error, no answer).
      const contTools = Array.isArray(anthropicBody.tools)
        ? anthropicBody.tools.filter((t) => t && t.name !== "consult_advisor")
        : anthropicBody.tools;
      const contAnthropic = { ...anthropicBody, tools: contTools, messages: contMessages, stream: true };
      // skipAdvisor: re-running interceptConsultAdvisor would match the tool_result we just
      // synthesized and spawn runAdvisor a second time. The continuation is ours, not a fresh
      // client request, so the advisor intercept must not touch it.
      // parentSessionId only re-inserts *prior* consults, so the continuation reads the history
      // the first call did; this turn's own consult is not recorded until the continuation settles.
      translateRequest(contAnthropic, { skipAdvisor: true, parentSessionId })
        .then((out) => {
          const contTranslated = out.request;
          diagnostics.push(...out.dropped.map((d) => `continuation dropped: ${d}`));
          const body = Buffer.from(JSON.stringify(contTranslated));
          logUpstreamRequest(id, sessionFile, url, body);
          const req = https.request(url, {
            agent, method: "POST",
            headers: { "content-type": "application/json", authorization: `Bearer ${BEARER}`, "content-length": body.length },
          }, (up) => {
            if (finalized || clientGone) {
              up.destroy();
              return settle();
            }
            lastActivity = Date.now();

            let logged = false;
            let logSize = 0;
            const logChunks = [];
            const logContResponse = () => {
              if (logged || !sessionFile) return;
              logged = true;
              logUpstreamResponse(id, sessionFile, up.statusCode, cap(Buffer.concat(logChunks))[0], up.headers, "continuation");
            };
            const collect = (chunk) => {
              if (!sessionFile) return;
              if (DEBUG_MAX_BODY > 0 && logSize >= DEBUG_MAX_BODY) return;
              logSize += chunk.length;
              logChunks.push(chunk);
            };

            // A non-2xx can't be retried (the advice SSE is already written, invariant #3) and must
            // not be parsed as a completion (a blank block silently ends the turn). Drain it briefly
            // so the error body reaches the debug log — that body is what a 500 investigation needs —
            // but never let a hung drain hold the failure note hostage.
            const errCode = advisorContinuationErrorCode(up.statusCode);
            if (errCode) {
              const fail = () => settleFailed(`upstream ${up.statusCode}: ${errCode}`, "advisor-continuation-upstream-error");
              if (!sessionFile) {
                up.resume();
                return fail();
              }
              const failNow = () => { logContResponse(); fail(); };
              const drainCap = setTimeout(failNow, 3_000);
              up.on("data", collect);
              up.on("end", () => { clearTimeout(drainCap); failNow(); });
              up.on("error", () => { clearTimeout(drainCap); failNow(); });
              return;
            }

            // Non-SSE: drain the JSON body and synthesize a one-shot SSE turn, same as the main
            // !isSse path, so a JSON-upstream continuation still round-trips correctly.
            if (!String(up.headers["content-type"] ?? "").includes("text/event-stream")) {
              const chunks = [];
              up.on("data", (c) => { chunks.push(c); collect(c); lastActivity = Date.now(); });
              up.on("end", () => {
                logContResponse();
                if (finalized || clientGone) return settle();
                try {
                  emitContinuationCompletion(
                    // onPromptTokens dropped: the continuation's prompt carries the advisor's
                    // answer on top of the body `est` was measured from, so the pair would not
                    // compare like with like.
                    translateCompletion(JSON.parse(Buffer.concat(chunks).toString()), { ...ctx, onPromptTokens: undefined }),
                  );
                  proxyReq = null; // response is complete; don't let finalize() tear down a reusable socket
                  settle();
                } catch (e) {
                  settle(e);
                }
              });
              up.on("error", (e) => { logContResponse(); settle(e); });
              return;
            }

            // Streaming SSE: a fresh translator seeded at resIdx + 1. message_start is suppressed
            // (the harness already saw one for this turn — two would be malformed); onAdvisorToolUse
            // is unset so done() emits the terminal message_stop instead of re-handing the turn
            // to a now-defunct advisor hook.
            const contCtx = { ...ctx, messageStarted: true, onAdvisorToolUse: undefined, onPromptTokens: undefined };
            contTranslator = createStreamTranslator(contCtx, writeEvent, resIdx + 1);
            // Point backpressure at the continuation's stream: writeEvent pauses/resumes
            // `upstreamRes` when res.write() returns false, and upstreamRes still holds the
            // first call's finished response — without this a slow client gets unbounded
            // buffering from a continuation that never pauses.
            upstreamRes = up;
            let buffer = "";
            let sawDone = false;

            // The upstream turn is over and every frame is written. Log here rather than on the
            // socket's 'end': the trailing terminator can arrive after the client response is
            // already closed, which would file the entry after this request's RESPONSE entry (or
            // lose it entirely). Drop proxyReq too — finalize() destroys it, and tearing down a
            // socket whose response is already complete is what cancelled the 'end' event this
            // path used to wait on.
            const upstreamTurnDone = () => {
              logContResponse();
              proxyReq = null;
              settle();
            };
            const processEventBlock = (block) => {
              const dataLines = block
                .split(/\r?\n/)
                .filter((l) => l.startsWith("data:"))
                .map((l) => l.slice(5).trimStart());
              if (!dataLines.length) return;
              const payload = dataLines.join("\n");
              if (payload.trim() === "[DONE]") {
                sawDone = true;
                contTranslator.done();
                return upstreamTurnDone();
              }
              let parsed;
              try {
                parsed = JSON.parse(payload);
              } catch {
                diagnostics.push(`unparseable continuation data line skipped (${payload.slice(0, 120)})`);
                return;
              }
              // Intercept an upstream error frame before the translator sees it. feed() would
              // terminate the turn with a bare `error` event and no terminal frame, and this path
              // would then settle as a success — stranding the advice exactly like the stall this
              // whole fix removes. Failing here routes it to the note, which carries the advice.
              if (parsed?.error && typeof parsed.error === "object") {
                const detail = parsed.error.message ?? parsed.error.code ?? "unknown";
                return settleFailed(`upstream error frame: ${detail}`, "advisor-continuation-upstream-error");
              }
              contTranslator.feed(parsed);
              // Defensive: any other route to a terminated translator has emitted its own
              // terminal event, so nothing more can be written under this message.
              if (contTranslator.terminated) upstreamTurnDone();
            };
            up.on("data", (chunk) => {
              collect(chunk);
              if (settled || finalized || clientGone) return;
              lastActivity = Date.now();
              buffer += chunk.toString();
              const parts = buffer.split(/\r?\n\r?\n/);
              buffer = parts.pop();
              for (const part of parts) {
                if (settled) break;
                processEventBlock(part);
              }
            });
            up.on("end", () => {
              logContResponse();
              if (settled || finalized || clientGone) return settle();
              if (buffer.trim()) processEventBlock(buffer);
              if (settled) return;
              if (!sawDone) {
                // Upstream closed cleanly without [DONE]: close the turn on what did arrive
                // rather than reporting a failure the client can't act on.
                contTranslator.done();
                diagnostics.push("continuation ended without [DONE]");
              }
              upstreamTurnDone();
            });
            // 'close' always fires, so no socket teardown can leave the promise unsettled. After
            // the turn is done it is just cleanup; before, it means the connection died mid-turn.
            up.on("close", () => {
              logContResponse();
              if (settled) return;
              if (finalized || clientGone) return settle();
              settleFailed("upstream connection closed mid-continuation", "advisor-continuation-failed");
            });
            up.on("error", (err) => {
              logContResponse();
              if (settled || finalized || clientGone) return settle();
              settleFailed(err?.message ?? String(err), "advisor-continuation-failed");
            });
          });
          proxyReq = req;
          // Absolute, not idle: what bounds this call is the client's own patience, and the advisor
          // phase already spent part of it. An idle timer measured from here would expire long
          // after the client gave up, so a hung continuation would never get the failure note.
          const budget = Math.max(CONTINUATION_MIN_MS, NONSTREAM_TIMEOUT_MS - (Date.now() - started) - CONTINUATION_GRACE_MS);
          deadline = setTimeout(() => {
            // Settle first: destroying the request races the 'close' and 'error' handlers, and
            // first-settle wins — reporting the teardown would shadow the budget reason in the
            // one diagnostic this timer exists to produce. No-op if the turn already settled.
            settleFailed(`continuation exceeded its ${Math.round(budget / 1000)}s budget`, "advisor-continuation-failed");
            // Deliberately also fires after a settled turn: once [DONE] is seen we drop proxyReq
            // so finalize() can't tear the socket down, leaving this the only thing that can
            // reclaim it if upstream never sends the terminating chunk.
            if (!req.destroyed) req.destroy();
          }, budget);
          // Cleared on 'close', not in settle(): the request always closes eventually, and until
          // it does the timer is the socket's only backstop.
          req.on("close", () => { if (deadline) clearTimeout(deadline); });
          req.on("error", (err) => {
            if (settled || finalized || clientGone) return settle();
            settleFailed(err?.message ?? String(err), "advisor-continuation-failed");
          });
          req.end(body);
        })
        .catch((err) => settleFailed(err?.message ?? String(err), "advisor-continuation-failed"));
    });
  };

  const upstreamBody = Buffer.from(JSON.stringify(translated));
  logUpstreamRequest(id, sessionFile, url, upstreamBody);

  /* ---- response plumbing ---- */

  const collectEmitted = (buf) => {
    if (!sessionFile) return;
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
    // PING_INTERVAL_MS is the ping *period*. deadlineCheck ticks every second and a ping does not
    // count as activity, so without this a quiet stream emits one ping per tick — bounded before
    // only by the watchdog kill, which the advisor continuation is now exempt from.
    if (Date.now() - lastPing < PING_INTERVAL_MS) return;
    lastPing = Date.now();
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
    // The advisor handoff owns the turn: runAdvisor is a headless `corti-bridge -p` child that
    // can legitimately run for minutes (see ADVISOR_TIMEOUT_MS). While it owns the turn the SSE
    // stream is idle by design — pings are suppressed (writePing, below) so they don't displace
    // the "Advising" indicator, and the stream-idle watchdog must stay its hand too. Without
    // this guard a consult that exceeds STREAM_IDLE_MS (120s) would fire "upstream stalled"
    // mid-advisor and kill the turn before the advisor finishes. The advisor's own timeout
    // (ADVISOR_TIMEOUT_MS) is the real ceiling here.
    if (translator?.advisorHandoff) return; // hook owns the turn; ADVISOR_TIMEOUT_MS is the ceiling
    // An advisor child (wantsNoAdvisor) is its own handleMessages whose translator never sets
    // advisorHandoff, so the guard above doesn't cover it. The same ADVISOR_TIMEOUT_MS ceiling
    // applies — applied at the child's execFile layer. Exempt the child from this 120s watchdog
    // too, or it kills a slow advisor generation mid-stream ("watchdog-timeout").
    if (noAdvisor) return;
    const silence = Date.now() - lastActivity;
    // The advisor continuation can legitimately go quiet for minutes mid-generation — Corti has
    // stalled well past STREAM_IDLE_MS between tokens — so it is exempt from the kill; its own
    // deadline is the ceiling. Pings still go out: the advisor phase is over, so they no longer
    // displace the "Advising" indicator, and the client needs to see the turn is still alive.
    if (continuationActive) {
      if (silence >= PING_INTERVAL_MS && headersSentToClient) writePing();
      return;
    }
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
            logUpstreamResponse(id, sessionFile, status, Buffer.from(text), upstreamRaw.headers);
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
            logUpstreamResponse(id, sessionFile, upstreamStatus, cap(raw)[0]);
            try {
              const msg = translateCompletion(JSON.parse(raw.toString()), ctx);
              loggedResponse = true;
              logResponse({
                id,
                sessionFile,
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
            logUpstreamResponse(id, sessionFile, upstreamStatus, cap(raw)[0]);
            writeEvent("message_start", {
              type: "message_start",
              message: {
                ...msg,
                content: [],
                stop_reason: null,
                stop_sequence: null,
                usage: {
                  // The live per-agent counter reads this off the streamed event; the estimate is
                  // its only growth signal. anthropicUsage floors input_tokens at 1 so the
                  // statusline merge overwrites this with the real value (no cached-prefix double-count).
                  input_tokens: estimatedInput,
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
          if (sessionFile && (DEBUG_MAX_BODY <= 0 || upstreamSize < DEBUG_MAX_BODY)) {
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

function writeBanner(file) {
  fs.appendFileSync(
    file,
    [
      `=== corti-bridge debug log ===`,
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
}

// Resolves the per-session log file for a request. Advisor children carry
// x-corti-advisor-for (their parent's id) and file under the parent; everything else
// keys on its own x-claude-code-session-id; requests with neither share one untracked file.
// Must be called once per request, synchronously, where req is in scope — the returned path
// is threaded into async closures (finalize/teeResponse) that fire after the handler returns.
function sessionLogFile(req) {
  const advisorFor = req.headers["x-corti-advisor-for"];
  const sessionId = advisorFor || req.headers["x-claude-code-session-id"];
  const key = sessionId || "__untracked__";
  let file = sessionFiles.get(key);
  if (!file) {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const shortId = sessionId ? sessionId.slice(0, 12) : "untracked";
    file = path.join(LOG_DIR, `gateway-session-${shortId}-${stamp}.log`);
    sessionFiles.set(key, file);
    try {
      writeBanner(file);
    } catch (err) {
      console.error(`corti-proxy: cannot write debug log to ${file}: ${err.message}`);
    }
  }
  return file;
}

function debugDir() {
  if (process.env.CORTI_DEBUG_DIR) return process.env.CORTI_DEBUG_DIR;
  if (process.platform === "darwin")
    return path.join(os.homedir(), "Library", "Logs", "corti-bridge");
  const state = process.env.XDG_STATE_HOME ?? path.join(os.homedir(), ".local", "state");
  return path.join(state, "corti-bridge");
}

// One entry per write: concurrent requests would otherwise interleave mid-entry.
function writeEntry(sessionFile, lines) {
  if (!sessionFile) return;
  try {
    fs.appendFileSync(sessionFile, `${lines.join("\n")}\n\n`, { mode: 0o600 });
  } catch (err) {
    console.error(`corti-proxy: debug log write failed: ${err.message}`);
  }
}

function logRequest(id, sessionFile, req, target, body) {
  if (!sessionFile) return;
  const advisorFor = req.headers["x-corti-advisor-for"];
  // Fallback tag when the advisor's parent-id header didn't round-trip (CLI below 2.1.227):
  // still recognizable as an advisor turn, filed under the child's own session.
  const tag = advisorFor
    ? ` [advisor for ${advisorFor.slice(0, 12)}]`
    : wantsNoAdvisor(req)
      ? " [advisor]"
      : "";
  writeEntry(sessionFile, [
    `=== #${id} REQUEST${tag} ${new Date().toISOString()} ===`,
    `${req.method} ${req.url}${target ? ` -> ${target}` : " (handled locally)"}`,
    `headers: ${JSON.stringify(redact(req.headers))}`,
    ...formatBody(...cap(body)),
  ]);
}

function logUpstreamRequest(id, sessionFile, url, body) {
  if (!sessionFile) return;
  writeEntry(sessionFile, [
    `=== #${id} UPSTREAM-REQUEST ${new Date().toISOString()} ===`,
    `POST ${url}`,
    ...formatBody(...cap(body)),
  ]);
}

function logUpstreamResponse(id, sessionFile, status, body, headers, tag) {
  if (!sessionFile) return;
  writeEntry(sessionFile, [
    `=== #${id} UPSTREAM-RESPONSE${tag ? ` [${tag}]` : ""} ${new Date().toISOString()} ===`,
    `status: ${status ?? "none"}`,
    ...(headers ? [`headers: ${JSON.stringify(redact(headers))}`] : []),
    ...formatBody(...cap(body)),
  ]);
}

function logResponse({ id, sessionFile, started, status, headers, body, note, diagnostics, truncated }) {
  if (!sessionFile) return;
  writeEntry(sessionFile, [
    `=== #${id} RESPONSE ${new Date().toISOString()} (${Date.now() - started}ms) ===`,
    `status: ${status ?? "none"}${note ? ` — ${note}` : ""}`,
    ...(headers ? [`headers: ${JSON.stringify(redact(headers))}`] : []),
    ...formatBody(body, truncated),
    ...(diagnostics?.length ? [`diagnostics:`, ...diagnostics.map((d) => `  - ${d}`)] : []),
  ]);
}

function teeResponse(id, sessionFile, started, upstream, res) {
  // With debug off, sessionFile is null and logResponse early-returns — so buffering every chunk
  // and running Buffer.concat is pure waste on every passthrough response. Skip it entirely.
  if (!sessionFile) return;

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
      sessionFile,
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
