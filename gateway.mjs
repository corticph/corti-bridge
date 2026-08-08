#!/usr/bin/env node

import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import os from "node:os";
import path from "node:path";

const HOST = process.env.CORTI_HOST ?? "127.0.0.1";
const PORT = Number(process.env.CORTI_PORT ?? 4000);
const BEARER = process.env.CORTI_BEARER;
const BASE_URL = process.env.CORTI_BASE_URL;

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

const UPSTREAM = BASE_URL.replace(/\/v1$/, "/anthropic");

const DEBUG = isTruthy(process.env.CORTI_DEBUG);
const DEBUG_MAX_BODY = Number(process.env.CORTI_DEBUG_MAX_BODY ?? 65536);
const LOG_FILE = DEBUG ? openDebugLog() : null;

let requestId = 0;

http
  .createServer(async (req, res) => {
    if (req.method === "OPTIONS") return cors(res);

    if (req.url === "/health")
      return send(res, 200, { status: "healthy", debug: LOG_FILE ?? false });

    const id = ++requestId;
    const reqPath = (req.url ?? "").split("?")[0];
    const isCountTokens = reqPath.startsWith("/v1/messages/count_tokens");
    const target = isCountTokens ? null : new URL(`${UPSTREAM}${reqPath}`);

    // Single read: the stream is consumed, so a second rawBody() would never settle.
    const body = await rawBody(req);
    const started = Date.now();
    logRequest(id, req, reqPath, target, body);

    if (isCountTokens) {
      const result = { input_tokens: estimateTokens(JSON.parse(body.toString())) };
      logResponse(id, started, 200, null, JSON.stringify(result));
      return send(res, 200, result);
    }

    const proxyReq = https.request(
      target,
      {
        method: req.method,
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${BEARER}`,
          "anthropic-version": req.headers["anthropic-version"] ?? "2023-06-01",
          "content-length": body.length,
          ...(req.headers["anthropic-beta"] && {
            "anthropic-beta": req.headers["anthropic-beta"],
          }),
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
      logResponse(id, started, null, null, "", `upstream request error: ${err.message}`);
      if (!res.headersSent)
        send(res, 502, {
          type: "error",
          error: { type: "api_error", message: err.message },
        });
    });

    req.on("close", () => {
      if (!res.writableEnded) proxyReq.destroy();
    });

    proxyReq.end(body);
  })
  .listen(PORT, HOST, () => {
    console.log(`corti-proxy on http://${HOST}:${PORT}`);
    if (LOG_FILE) console.log(`corti-proxy debug log: ${LOG_FILE}`);
  });

function rawBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
  });
}

function send(res, status, data) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(data));
}

function cors(res) {
  res.writeHead(204, {
    "access-control-allow-origin": "*",
    "access-control-allow-headers": "*",
    "access-control-allow-methods": "POST, GET, OPTIONS",
  });
  res.end();
}

function estimateTokens({ system, messages }) {
  let chars = 0;
  const add = (s) => { if (typeof s === "string") chars += s.length; };
  if (system) {
    if (typeof system === "string") add(system);
    else if (Array.isArray(system)) system.forEach((b) => add(b.text));
  }
  for (const msg of messages ?? []) {
    if (typeof msg.content === "string") add(msg.content);
    else if (Array.isArray(msg.content)) msg.content.forEach((b) => add(b.text));
  }
  return Math.max(1, Math.floor(chars / 4));
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
          `upstream: ${UPSTREAM}`,
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

function logRequest(id, req, reqPath, target, body) {
  if (!LOG_FILE) return;
  writeEntry([
    `=== #${id} REQUEST ${new Date().toISOString()} ===`,
    `${req.method} ${req.url}${target ? ` -> ${target}` : " (handled locally)"}`,
    `headers: ${JSON.stringify(redact(req.headers))}`,
    ...formatBody(...cap(body)),
  ]);
}

function logResponse(id, started, status, headers, body, note, truncated) {
  if (!LOG_FILE) return;
  writeEntry([
    `=== #${id} RESPONSE ${new Date().toISOString()} (${Date.now() - started}ms) ===`,
    `status: ${status ?? "none"}${note ? ` — ${note}` : ""}`,
    ...(headers ? [`headers: ${JSON.stringify(redact(headers))}`] : []),
    ...formatBody(body, truncated),
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
    const body = Buffer.concat(chunks);
    logResponse(id, started, upstream.statusCode, upstream.headers, body, note, truncated);
  };

  upstream.on("end", () => finish());
  upstream.on("error", (err) => finish(`stream error: ${err.message}`));
  upstream.on("close", () => finish("upstream closed before end"));
  // A client aborting mid-stream (Esc in Claude Code) only ever surfaces here: the upstream
  // stream just stalls on backpressure, and req's 'close' never fires once its body was read.
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
