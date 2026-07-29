#!/usr/bin/env node

import http from "node:http";
import https from "node:https";

const HOST = process.env.HOST ?? "127.0.0.1";
const PORT = Number(process.env.PORT ?? 4000);
const BEARER = process.env.CORTI_BEARER;
const UPSTREAM = "https://ai.eu.corti.app/anthropic";

if (!BEARER) {
  console.error("CORTI_BEARER is required");
  process.exit(1);
}

http
  .createServer(async (req, res) => {
    if (req.method === "OPTIONS") return cors(res);

    if (req.url === "/health") return send(res, 200, { status: "healthy" });

    if (req.url?.startsWith("/v1/messages/count_tokens")) {
      const body = await jsonBody(req);
      return send(res, 200, { input_tokens: estimateTokens(body) });
    }

    if (BEARER) {
      const key = bearerOf(req.headers) ?? req.headers["x-api-key"];
      if (key !== BEARER)
        return send(res, 401, {
          type: "error",
          error: { type: "authentication_error", message: "invalid API key" },
        });
    }

    const body = await rawBody(req);
    const path = (req.url ?? "").split("?")[0];
    const target = new URL(`${UPSTREAM}${path}`);

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
        console.log(`${req.method} ${path} ${upstream.statusCode}`);
        res.writeHead(upstream.statusCode ?? 502, upstream.headers);
        upstream.pipe(res);
      },
    );

    proxyReq.on("error", (err) => {
      console.error(err.message);
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
  .listen(PORT, HOST, () => console.log(`corti-proxy on http://${HOST}:${PORT}`));

function rawBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
  });
}

async function jsonBody(req) {
  return JSON.parse((await rawBody(req)).toString());
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

function bearerOf(h) {
  const a = h.authorization;
  return a?.startsWith("Bearer ") ? a.slice(7) : undefined;
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
