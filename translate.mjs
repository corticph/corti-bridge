// translate.mjs — Anthropic Messages ⇄ OpenAI Chat Completions wire translation.

import https from "node:https";

export const REASONING_SIGNATURE = "Y29ydGktcHJveHk="; // base64 "corti-proxy"

const SERVER_BLOCK_TYPES = new Set([
  "search_result",
  "server_tool_use",
  "web_search_tool_result",
  "web_fetch_tool_result",
  "code_execution_tool_result",
  "bash_code_execution_tool_result",
  "text_editor_code_execution_tool_result",
  "tool_search_tool_result",
  "container_upload",
]);

const WEBSEARCH_TOOL_NAMES = new Set(["web_search", "WebSearch"]);

export class TranslateRejection extends Error {
  constructor(status, envelope) {
    super(envelope.error.message);
    this.status = status;
    this.envelope = envelope;
  }
}

function reject(status, type, message) {
  throw new TranslateRejection(status, {
    type: "error",
    error: { type, message },
  });
}

/* ------------------------------------------------------------------ */
/* model name mapping                                                  */
/* ------------------------------------------------------------------ */

// Subagents can send Claude Code's default claude-* names; map them back to the configured Corti model.
function mapModel(model) {
  if (typeof model !== "string" || !model.startsWith("claude-")) return model;
  if (/opus/i.test(model)) return process.env.ANTHROPIC_DEFAULT_OPUS_MODEL || model;
  if (/sonnet/i.test(model)) return process.env.ANTHROPIC_DEFAULT_SONNET_MODEL || model;
  if (/haiku/i.test(model)) return process.env.ANTHROPIC_DEFAULT_HAIKU_MODEL || model;
  if (/fable/i.test(model)) return process.env.ANTHROPIC_DEFAULT_FABLE_MODEL || model;
  return model;
}

/* ------------------------------------------------------------------ */
/* web search: Tavily API (primary), DuckDuckGo HTML (keyless fallback)*/
/* ------------------------------------------------------------------ */

const searchCache = new Map();
const SEARCH_TTL_MS = 5 * 60 * 1000;
const SEARCH_TIMEOUT_MS = 8_000;
const SEARCH_MAX_RESULTS = 8;

export async function webSearch(query) {
  const cached = searchCache.get(query);
  if (cached && Date.now() - cached.time < SEARCH_TTL_MS) return cached.results;

  let results;
  if (process.env.TAVILY_API_KEY) {
    results = await tavilySearch(query);
    if (!results.length) results = await duckDuckGoSearch(query);
  } else {
    results = await duckDuckGoSearch(query);
  }
  searchCache.set(query, { results, time: Date.now() });
  return results;
}

// Tavily search; depth is fixed at load, the API key is read at call time.
const SEARCH_DEPTH = ["basic", "advanced"].includes(process.env.CORTI_SEARCH_DEPTH)
  ? process.env.CORTI_SEARCH_DEPTH
  : "basic";

async function tavilySearch(query) {
  const body = JSON.stringify({
    query,
    max_results: SEARCH_MAX_RESULTS,
    search_depth: SEARCH_DEPTH,
  });
  return new Promise((resolve) => {
    const req = https.request(
      "https://api.tavily.com/search",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "content-length": Buffer.byteLength(body),
          authorization: `Bearer ${process.env.TAVILY_API_KEY}`,
        },
      },
      (res) => {
        if (res.statusCode !== 200) return resolve([]);
        let data = "";
        res.on("data", (c) => (data += c));
        res.on("end", () => {
          try {
            const json = JSON.parse(data);
            resolve(
              (json.results ?? []).slice(0, SEARCH_MAX_RESULTS).map((r) => ({
                title: r.title ?? "",
                url: r.url ?? "",
                snippet: r.content ?? "",
              })),
            );
          } catch {
            resolve([]);
          }
        });
      },
    );
    req.on("error", () => resolve([]));
    req.setTimeout(SEARCH_TIMEOUT_MS, () => {
      req.destroy();
      resolve([]);
    });
    req.end(body);
  });
}

async function duckDuckGoSearch(query) {
  return new Promise((resolve) => {
    const body = `q=${encodeURIComponent(query)}`;
    const req = https.request(
      "https://html.duckduckgo.com/html/",
      {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded",
          "content-length": Buffer.byteLength(body),
          "User-Agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
          "Accept-Language": "en-US,en;q=0.9",
          Accept: "text/html",
        },
      },
      (res) => {
        if (res.statusCode !== 200) return resolve([]);
        let html = "";
        res.on("data", (c) => (html += c));
        res.on("end", () => resolve(parseDuckDuckGoResults(html)));
      },
    );
    req.on("error", () => resolve([]));
    req.setTimeout(SEARCH_TIMEOUT_MS, () => {
      req.destroy();
      resolve([]);
    });
    req.end(body);
  });
}

// DDG HTML: each result is a <a class="result__a" href="...">title</a> with an
// optional <a class="result__snippet">…</a>. URLs are direct, no redirect unwrap.
function parseDuckDuckGoResults(html) {
  const results = [];
  const blocks = html.split('result results_links results_links_deep').slice(1);
  for (const block of blocks) {
    if (results.length >= SEARCH_MAX_RESULTS) break;
    const a = block.match(/<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/);
    if (!a) continue;
    const url = a[1];
    const title = decodeHtml(a[2]);
    if (!title || !url) continue;
    const snip = block.match(/<a[^>]*class="result__snippet"[^>]*>([\s\S]*?)<\/a>/);
    const snippet = snip ? decodeHtml(snip[1]) : "";
    results.push({ title, url, snippet });
  }
  return results;
}

function decodeHtml(s) {
  return s
    .replace(/<[^>]*>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'")
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&#0183;/g, "·")
    .replace(/&#035;/g, "#")
    .replace(/&#(\d+);/g, (_, n) => {
      const cp = Number(n);
      return cp >= 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : "";
    })
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => {
      const cp = parseInt(n, 16);
      return cp >= 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : "";
    })
    .replace(/\s+/g, " ")
    .trim();
}

function formatSearchResults(query, results) {
  if (!results.length) return null;
  const lines = [`Web search results for: "${query}"`, ""];
  results.forEach((r, i) => {
    lines.push(`[${i + 1}] ${r.title} (${r.url})`);
    if (r.snippet) lines.push(r.snippet);
    lines.push("");
  });
  lines.push(
    'REMINDER: You MUST include the sources above in your response to the user using markdown hyperlinks.',
  );
  return lines.join("\n");
}

/* ------------------------------------------------------------------ */
/* intercept registry — shared by both gateway modes                   */
/* ------------------------------------------------------------------ */

function buildToolUseMap(body) {
  const map = new Map();
  for (const msg of body.messages ?? []) {
    if (msg?.role === "assistant" && Array.isArray(msg.content)) {
      for (const b of msg.content) {
        if (b?.type === "tool_use" && typeof b.id === "string")
          map.set(b.id, { name: b.name, input: b.input });
      }
    }
  }
  return map;
}

async function interceptModelMapping(body) {
  if (typeof body.model !== "string") return [];
  const mapped = mapModel(body.model);
  if (mapped === body.model) return [];
  const orig = body.model;
  body.model = mapped;
  return [`model mapped: ${orig} → ${mapped}`];
}

async function interceptWebSearch(body, { toolUseMap }) {
  const diagnostics = [];
  for (const msg of body.messages ?? []) {
    if (msg?.role !== "user" || !Array.isArray(msg.content)) continue;
    for (const b of msg.content) {
      if (b?.type !== "tool_result") continue;
      const toolUse = toolUseMap.get(b.tool_use_id);
      if (!toolUse || !WEBSEARCH_TOOL_NAMES.has(toolUse.name) || !toolUse.input?.query) continue;
      const results = await webSearch(toolUse.input.query);
      const formatted = formatSearchResults(toolUse.input.query, results);
      if (formatted) {
        b.content = formatted;
        diagnostics.push(`web_search intercepted: "${toolUse.input.query.slice(0, 60)}" → ${results.length} results`);
      }
    }
  }
  return diagnostics;
}

const intercepts = [
  interceptModelMapping,
  interceptWebSearch,
];

export async function applyIntercepts(body) {
  const ctx = { toolUseMap: buildToolUseMap(body) };
  const diagnostics = [];
  for (const fn of intercepts) {
    const diags = await fn(body, ctx);
    if (diags?.length) diagnostics.push(...diags);
  }
  return diagnostics;
}

/* ------------------------------------------------------------------ */
/* request side                                                        */
/* ------------------------------------------------------------------ */

function stripSchemaExtras(value) {
  if (Array.isArray(value)) return value.map(stripSchemaExtras);
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (k === "$schema" || k === "cache_control") continue;
      out[k] = stripSchemaExtras(v);
    }
    return out;
  }
  return value;
}

function blocksOf(content) {
  if (typeof content === "string") return content ? [{ type: "text", text: content }] : [];
  return Array.isArray(content) ? content : [];
}

function toolResultText(block) {
  const c = block.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) {
    return c
      .filter((b) => b && b.type === "text" && typeof b.text === "string")
      .map((b) => b.text)
      .join("\n\n");
  }
  return "";
}

function toolResultImages(block) {
  const c = block.content;
  if (!Array.isArray(c)) return [];
  return c.filter((b) => b && b.type === "image").map((b) => imagePart(b)).filter(Boolean);
}

function imagePart(block) {
  const src = block.source;
  if (!src) return null;
  if (src.type === "base64" && src.media_type && src.data)
    return { type: "image_url", image_url: { url: `data:${src.media_type};base64,${src.data}` } };
  if (src.type === "url" && src.url) return { type: "image_url", image_url: { url: src.url } };
  return null;
}

function documentText(block) {
  const src = block.source;
  const title = block.title ? `[Document: ${block.title}]\n` : "";
  if (src?.type === "text" && typeof src.data === "string") return title + src.data;
  if (src?.type === "content") {
    if (typeof src.content === "string") return title + src.content;
    if (Array.isArray(src.content))
      return (
        title +
        src.content
          .filter((b) => b && b.type === "text")
          .map((b) => b.text)
          .join("\n\n")
      );
  }
  return null;
}


export async function translateRequest(body) {
  if (!body || typeof body !== "object")
    reject(400, "invalid_request_error", "request body is not valid JSON");
  if (typeof body.model !== "string" || !body.model)
    reject(400, "invalid_request_error", "Field required: model");
  if (!Array.isArray(body.messages))
    reject(400, "invalid_request_error", "Field required: messages");

  const interceptDiags = await applyIntercepts(body);

  const dropped = [...interceptDiags];
  const sysParts = [];

  if (typeof body.system === "string") {
    if (body.system) sysParts.push(body.system);
  } else if (Array.isArray(body.system)) {
    for (const b of body.system) {
      if (b && b.type === "text" && typeof b.text === "string") sysParts.push(b.text);
    }
  }

  const messages = [];
  let pendingCalls = [];

  const flushPending = () => {
    for (const id of pendingCalls) {
      messages.push({
        role: "tool",
        tool_call_id: id,
        content: "(tool result unavailable — call was interrupted)",
      });
      dropped.push(`synthesized placeholder result for dangling tool_use ${id}`);
    }
    pendingCalls = [];
  };

  for (const msg of body.messages) {
    if (!msg || typeof msg !== "object") continue;

    if (msg.role === "system") {
      for (const b of blocksOf(msg.content)) {
        if (b.type === "text" && typeof b.text === "string") sysParts.push(b.text);
        else if (b.type === "mid_conv_system") {
          for (const t of b.content ?? []) if (t?.type === "text") sysParts.push(t.text);
        }
      }
      continue;
    }

    if (msg.role === "assistant") {
      const texts = [];
      const calls = [];
      for (const b of blocksOf(msg.content)) {
        if (b.type === "text" && typeof b.text === "string") texts.push(b.text);
        else if (b.type === "tool_use") {
          calls.push({
            id: b.id,
            type: "function",
            function: { name: b.name, arguments: JSON.stringify(b.input ?? {}) },
          });
        } else if (b.type === "thinking" || b.type === "redacted_thinking" || SERVER_BLOCK_TYPES.has(b.type)) {
          dropped.push(`${b.type} (assistant history)`);
        } else if (b.type !== "text") {
          dropped.push(`${b.type} (assistant)`);
        }
      }
      if (!texts.length && !calls.length) {
        dropped.push("empty assistant message");
        continue;
      }
      flushPending();
      const out = { role: "assistant", content: texts.length ? texts.join("\n\n") : "" };
      if (calls.length) out.tool_calls = calls;
      pendingCalls = calls.map((c) => c.id);
      messages.push(out);
      continue;
    }

    if (msg.role === "user") {
      const rawBlocks = blocksOf(msg.content);
      const toolMsgs = [];
      const userParts = [];
      const trailingImages = [];
      const danglingNotes = [];

      for (const b of rawBlocks) {
        if (b.type === "tool_result") {
          let text = toolResultText(b);
          const imgs = toolResultImages(b);

          if (imgs.length) {
            text = `${text}${text ? "\n" : ""}(image content attached below)`;
            trailingImages.push(...imgs);
          }
          if (!text) text = "(empty tool result)";
          if (pendingCalls.includes(b.tool_use_id)) {
            toolMsgs.push({ role: "tool", tool_call_id: b.tool_use_id, content: text });
            pendingCalls = pendingCalls.filter((id) => id !== b.tool_use_id);
          } else {
            danglingNotes.push(`[Tool result for unknown call ${b.tool_use_id}]: ${text}`);
            dropped.push(`dangling tool_result ${b.tool_use_id} demoted to user text`);
          }
        } else if (b.type === "text" && typeof b.text === "string") {
          if (b.text) userParts.push({ type: "text", text: b.text });
        } else if (b.type === "image") {
          const part = imagePart(b);
          if (part) userParts.push(part);
          else dropped.push("unusable image block");
        } else if (b.type === "document") {
          const t = documentText(b);
          if (t != null) userParts.push({ type: "text", text: t });
          else {
            userParts.push({
              type: "text",
              text: "[PDF document omitted: this deployment does not support PDF input]",
            });
            dropped.push("base64 document (placeholder substituted)");
          }
        } else if (SERVER_BLOCK_TYPES.has(b.type)) {
          dropped.push(`${b.type} (user)`);
        } else if (b.type === "mid_conv_system") {
          for (const t of b.content ?? []) if (t?.type === "text") sysParts.push(t.text);
        } else {
          dropped.push(`${b.type} (user)`);
        }
      }

      if (toolMsgs.length) {
        messages.push(...toolMsgs);
      }
      flushPending();

      for (const note of danglingNotes) userParts.push({ type: "text", text: note });
      userParts.push(...trailingImages);

      if (userParts.length) {
        const onlyText = userParts.filter((p) => p.type === "text");
        if (onlyText.length === userParts.length) {
          const joined = onlyText.map((p) => p.text).join("\n\n");
          if (joined) messages.push({ role: "user", content: joined });
        } else {
          messages.push({ role: "user", content: userParts });
        }
      }
      continue;
    }

    dropped.push(`unknown role ${msg.role}`);
  }
  flushPending();

  if (sysParts.length) {
    const joined = sysParts.filter(Boolean).join("\n\n");
    if (joined) messages.unshift({ role: "system", content: joined });
  }

  if (!messages.length || messages.every((m) => m.role === "system" || m.role === "tool"))
    reject(400, "invalid_request_error", "messages array is empty after translation");

  const req = {
    model: body.model,
    messages,
    // 32000 default when max_tokens omitted
    max_tokens: 32000,
  };

  if (body.max_tokens !== undefined) {
    if (typeof body.max_tokens !== "number" || !Number.isInteger(body.max_tokens) || body.max_tokens < 1)
      reject(400, "invalid_request_error", "max_tokens must be a positive integer");
    req.max_tokens = body.max_tokens;
  }

  if (body.stream === true) {
    req.stream = true;
    req.stream_options = { include_usage: true };
  } else {
    req.stream = false;
  }

  if (typeof body.temperature === "number") req.temperature = body.temperature;
  if (typeof body.top_p === "number") req.top_p = body.top_p;

  if (Array.isArray(body.stop_sequences) && body.stop_sequences.length) {
    req.stop = body.stop_sequences.slice(0, 4).filter((s) => typeof s === "string");
    if (body.stop_sequences.length > 4) dropped.push("stop_sequences truncated to first 4");
    if (!req.stop.length) delete req.stop;
  }

  const allTools = Array.isArray(body.tools) ? body.tools : [];
  const tools = allTools.filter(
    (t) => t && typeof t === "object" && t.input_schema && typeof t.name === "string",
  );

  // Convert WebSearch to a function tool so the call is schemaed; the proxy
  // intercepts the tool_result next turn to inject real search results.
  const hasWebSearch = allTools.some(
    (t) =>
      t &&
      typeof t === "object" &&
      (WEBSEARCH_TOOL_NAMES.has(t.name) ||
        (typeof t.type === "string" && t.type.startsWith("web_search"))),
  );
  if (hasWebSearch) {
    tools.push({
      name: "WebSearch",
      description: "Search the web for current information.",
      input_schema: {
        type: "object",
        properties: {
          query: { type: "string", description: "The search query" },
        },
        required: ["query"],
      },
    });
  }

  const droppedTools = allTools.length - tools.length;
  if (droppedTools > 0) dropped.push(`${droppedTools} server tool(s) stripped`);

  if (tools.length) {
    req.tools = tools.map((t) => ({
      type: "function",
      function: {
        name: t.name,
        description: typeof t.description === "string" ? t.description : "",
        parameters: stripSchemaExtras(t.input_schema),
      },
    }));
    const tc = body.tool_choice;
    if (tc && typeof tc === "object") {
      if (tc.type === "auto") req.tool_choice = "auto";
      else if (tc.type === "any") req.tool_choice = "required";
      else if (tc.type === "tool" && typeof tc.name === "string")
        req.tool_choice = { type: "function", function: { name: tc.name } };
      else if (tc.type === "none") req.tool_choice = "none";
      if (tc.type !== "none" && tc.disable_parallel_tool_use === true)
        req.parallel_tool_calls = false;
    }
  }

  const th = body.thinking;
  if (th && typeof th === "object") {
    const budget = th.budget_tokens;
    if (th.type === "enabled") {
      req.reasoning_effort =
        typeof budget === "number" && budget < 4096 ? "low"
        : typeof budget === "number" && budget < 16384 ? "medium"
        : "high";
      if (typeof budget === "number" && budget > 0) req.thinking_token_budget = budget;
    } else if (th.type === "adaptive") {
      req.reasoning_effort = "medium";
    }
  }

  return { request: req, dropped };
}

/* ------------------------------------------------------------------ */
/* count_tokens estimate                                               */
/* ------------------------------------------------------------------ */

export function estimateTokens(body) {
  try {
    let chars = 0;
    let overhead = 0;
    const add = (s) => {
      if (typeof s === "string") chars += s.length;
    };

    if (typeof body?.system === "string") add(body.system);
    else if (Array.isArray(body?.system))
      for (const b of body.system) if (b?.type === "text") add(b.text);

    for (const msg of body?.messages ?? []) {
      overhead += 4;
      if (typeof msg?.content === "string") {
        add(msg.content);
        continue;
      }
      for (const b of Array.isArray(msg?.content) ? msg.content : []) {
        if (!b || typeof b !== "object") continue;
        if (b.type === "text") add(b.text);
        else if (b.type === "image") overhead += 100;
        else if (b.type === "tool_use") {
          add(b.name);
          add(JSON.stringify(b.input ?? {}));
        } else if (b.type === "tool_result") {
          if (typeof b.content === "string") add(b.content);
          else if (Array.isArray(b.content))
            for (const c of b.content) {
              if (c?.type === "text") add(c.text);
              else if (c?.type === "image") overhead += 100;
            }
        } else if (b.type === "thinking" || b.type === "redacted_thinking") {
          // stripped before upstream; not billed
        } else if (b.type === "document") {
          const t = documentText(b);
          if (t != null) add(t);
        }
      }
    }

    for (const t of Array.isArray(body?.tools) ? body.tools : []) {
      if (!t || typeof t !== "object" || !t.input_schema) continue;
      overhead += 16;
      add(t.name);
      add(t.description);
      add(JSON.stringify(t.input_schema));
    }

    return Math.max(1, Math.floor(chars / 4) + overhead);
  } catch {
    return Math.max(1, Math.floor(JSON.stringify(body ?? "").length / 8));
  }
}

/* ------------------------------------------------------------------ */
/* models list                                                         */
/* ------------------------------------------------------------------ */

export function translateModels(openaiList) {
  const data = (Array.isArray(openaiList?.data) ? openaiList.data : [])
    .filter((m) => m && typeof m.id === "string" && !/embedding/i.test(m.id))
    .map((m) => ({
      type: "model",
      id: m.id,
      display_name: m.id,
      created_at:
        typeof m.created === "number" ? new Date(m.created * 1000).toISOString() : undefined,
    }));
  return {
    data,
    has_more: false,
    first_id: data[0]?.id ?? null,
    last_id: data[data.length - 1]?.id ?? null,
  };
}

/* ------------------------------------------------------------------ */
/* error mapping                                                       */
/* ------------------------------------------------------------------ */

// Claude Code regex-parses the "N tokens > M maximum" pair here to size compaction.
export const promptTooLong = (n, max, note) => `prompt is too long: ${n} tokens > ${max} maximum (${note})`;

const OVERFLOW_RE = /max_model_len|maximum context length|context length|too many tokens/i;

function sanitize(detail) {
  return String(detail ?? "")
    .replace(/Bearer\s+\S+/gi, "Bearer <redacted>")
    .slice(0, 300);
}

function envelope(type, message, requestId) {
  const e = { type: "error", error: { type, message } };
  if (requestId) e.request_id = requestId;
  return e;
}

export function translateError({ status, headers = {}, bodyText = "", requestedModel = "" }) {
  const requestId = headers["x-request-id"];
  let detail = sanitize(bodyText);
  let upstreamType;

  try {
    const parsed = JSON.parse(bodyText);
    if (parsed && parsed.error && typeof parsed.error === "object") {
      if (parsed.error.message) detail = sanitize(parsed.error.message);
      upstreamType = parsed.error.type;
    }
  } catch {
    // plain-text gateway errors land here; bodyText is already the detail
  }

  if (status === 400 && OVERFLOW_RE.test(detail)) {
    // Both vLLM wordings must yield a digit pair — without one, Claude Code says the conversation cannot be compacted.
    const max = /max_total_tokens=(\d+)/.exec(detail)?.[1] ?? /maximum context length is (\d+)/.exec(detail)?.[1];
    const n =
      /request has (\d+) input tokens/.exec(detail)?.[1] ??
      /prompt contains at least (\d+) input tokens/.exec(detail)?.[1];
    const message =
      max && n ? promptTooLong(n, max, `upstream: ${detail}`) : `prompt is too long (upstream: ${detail})`;
    return { status: 400, envelope: envelope("invalid_request_error", message, requestId) };
  }

  switch (status) {
    case 400:
      return { status, envelope: envelope("invalid_request_error", `upstream rejected request: ${detail}`, requestId) };
    case 401:
      return { status, envelope: envelope("authentication_error", `upstream authentication failed — check CORTI_BEARER (upstream: ${detail})`, requestId) };
    case 403:
      return { status, envelope: envelope("permission_error", `upstream permission denied (upstream: ${detail})`, requestId) };
    case 404:
      return { status, envelope: envelope("not_found_error", `model: ${requestedModel} (upstream: ${detail})`, requestId) };
    case 413:
      return {
        status: 400,
        envelope: envelope("invalid_request_error", `prompt is too long: request payload exceeds upstream size limit (upstream: ${detail})`, requestId),
      };
    case 429:
      return {
        status,
        headers: headers["retry-after"] ? { "retry-after": headers["retry-after"] } : undefined,
        envelope: envelope("rate_limit_error", `rate limited (upstream: ${detail})`, requestId),
      };
    case 500:
      return { status, envelope: envelope("api_error", `upstream internal error (upstream: ${detail})`, requestId) };
    case 502:
    case 503:
      return { status: 529, envelope: envelope("overloaded_error", `upstream unavailable: ${detail}`, requestId) };
    case 504:
      return { status, envelope: envelope("timeout_error", `upstream timed out (upstream: ${detail})`, requestId) };
    default:
      if (status >= 500)
        return { status: 529, envelope: envelope("overloaded_error", `upstream unavailable: ${detail}`, requestId) };
      return { status: 502, envelope: envelope("api_error", `upstream request failed: ${detail || upstreamType || "unknown"}`, requestId) };
  }
}

export function translateNetworkError(err) {
  const code = err?.cause?.code ?? err?.code;
  if (code === "ECONNREFUSED" || code === "ENOTFOUND" || code === "ECONNRESET")
    return { status: 529, envelope: envelope("overloaded_error", `upstream unreachable: ${code}`) };
  if (code === "ETIMEDOUT" || code === "ESOCKETTIMEDOUT")
    return { status: 504, envelope: envelope("timeout_error", `upstream timed out: ${code}`) };
  return { status: 502, envelope: envelope("api_error", `upstream request failed: ${err?.message ?? "unknown"}`) };
}

/* ------------------------------------------------------------------ */
/* non-streaming response                                              */
/* ------------------------------------------------------------------ */

function anthropicStop(choice) {
  const fr = choice?.finish_reason;
  if (fr === "length") return { stop_reason: "max_tokens", stop_sequence: null };
  if (fr === "tool_calls") return { stop_reason: "tool_use", stop_sequence: null };
  // OpenAI's finish_reason "stop" doesn't identify a matched stop sequence, so map to end_turn.
  return { stop_reason: "end_turn", stop_sequence: null };
}

function anthropicUsage(usage) {
  const details = usage?.prompt_tokens_details;
  const cacheRead = details?.cached_tokens ?? 0;
  const cacheCreation = details?.created_cache_tokens ?? 0;
  const prompt = usage?.prompt_tokens ?? 0;
  return {
    input_tokens: details ? Math.max(0, prompt - cacheRead - cacheCreation) : prompt,
    output_tokens: usage?.completion_tokens ?? 0,
    cache_creation_input_tokens: cacheCreation,
    cache_read_input_tokens: cacheRead,
  };
}

export function translateCompletion(completion, ctx) {
  const choice = completion?.choices?.[0] ?? {};
  const message = choice.message ?? {};
  const reasoning = message.reasoning ?? message.reasoning_content;
  const content = [];

  if (typeof reasoning === "string" && reasoning) {
    if (ctx.reasoningMode === "thinking")
      content.push({ type: "thinking", thinking: reasoning, signature: REASONING_SIGNATURE });
    else if (ctx.reasoningMode === "text")
      content.push({ type: "text", text: reasoning });
  }

  if (typeof message.content === "string" && message.content)
    content.push({ type: "text", text: message.content });

  for (const call of message.tool_calls ?? []) {
    let input = {};
    try {
      input = JSON.parse(call.function?.arguments ?? "{}");
    } catch {
      ctx.onDiagnostic?.(`tool args JSON.parse failed for ${call.function?.name}: using {}`);
    }
    content.push({ type: "tool_use", id: call.id, name: call.function?.name, input });
  }

  if (!content.length) content.push({ type: "text", text: "" });

  return {
    id: ctx.msgId,
    type: "message",
    role: "assistant",
    content,
    model: ctx.requestedModel,
    ...anthropicStop(choice),
    usage: anthropicUsage(completion.usage),
  };
}

/* ------------------------------------------------------------------ */
/* streaming state machine                                             */
/* ------------------------------------------------------------------ */

export function createStreamTranslator(ctx, emit) {
  // emit(eventName, dataObject) -> called for each Anthropic SSE event to send.
  let messageStarted = false;
  let open = null; // { kind: "thinking"|"text"|"tool", index }
  let nextBlockIndex = 0;
  const toolBlocks = new Map(); // upstream tool_calls index -> { blockIndex, closed }
  let pendingStop = null;
  let finishSeen = false;
  let doneEmitted = false;
  let terminated = false;
  let latestUsage = null;
  let outputChars = 0;

  const closeOpen = () => {
    if (!open) return;
    if (open.kind === "thinking")
      emit("content_block_delta", {
        type: "content_block_delta",
        index: open.index,
        delta: { type: "signature_delta", signature: REASONING_SIGNATURE },
      });
    emit("content_block_stop", { type: "content_block_stop", index: open.index });
    if (open.kind === "tool") {
      const rec = [...toolBlocks.values()].find((t) => t.blockIndex === open.index);
      if (rec) rec.closed = true;
    }
    open = null;
  };

  const openBlock = (kind, contentBlock) => {
    closeOpen();
    const index = nextBlockIndex++;
    open = { kind, index };
    emit("content_block_start", { type: "content_block_start", index, content_block: contentBlock });
  };

  const startMessage = () => {
    if (messageStarted) return;
    messageStarted = true;
    emit("message_start", {
      type: "message_start",
      message: {
        id: ctx.msgId,
        type: "message",
        role: "assistant",
        content: [],
        model: ctx.requestedModel,
        stop_reason: null,
        stop_sequence: null,
        usage: {
          input_tokens: ctx.estimatedInput ?? 1,
          output_tokens: 1,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
        },
      },
    });
  };

  const reasoningText = (text) => {
    if (!text) return;
    if (ctx.reasoningMode === "drop") return;
    if (ctx.reasoningMode === "thinking") {
      if (open?.kind !== "thinking")
        openBlock("thinking", { type: "thinking", thinking: "", signature: "" });
      emit("content_block_delta", {
        type: "content_block_delta",
        index: open.index,
        delta: { type: "thinking_delta", thinking: text },
      });
      return;
    }
    textDelta(text); // mode=text: fold reasoning into the text stream
  };

  const textDelta = (text) => {
    if (!text) return;
    if (open?.kind !== "text") openBlock("text", { type: "text", text: "" });
    outputChars += text.length;
    emit("content_block_delta", {
      type: "content_block_delta",
      index: open.index,
      delta: { type: "text_delta", text },
    });
  };

  const toolDelta = (entry) => {
    const idx = entry?.index ?? 0;
    const hasHead = entry.id || entry.function?.name;

    if (hasHead) {
      const existing = toolBlocks.get(idx);
      if (!existing || existing.closed) {
        const id = entry.id || `chatcmpl-tool-local-${Math.random().toString(16).slice(2, 10)}`;
        const name = entry.function?.name ?? "";
        if (!entry.id || !name)
          ctx.onDiagnostic?.(`tool head missing ${!entry.id ? "id" : "name"} at index ${idx}`);
        openBlock("tool", { type: "tool_use", id, name, input: {} });
        toolBlocks.set(idx, { blockIndex: open.index, closed: false });
      }
    }

    const rec = toolBlocks.get(idx);
    if (!rec || rec.closed) {
      if (entry.function?.arguments)
        ctx.onDiagnostic?.(`tool args for unknown/closed index ${idx}: skipped`);
      return;
    }
    const frag = entry.function?.arguments;
    if (typeof frag === "string" && frag.length) {
      if (open?.index !== rec.blockIndex) {
        // args for a non-open tool block: vLLM emits sequentially; defensive skip
        ctx.onDiagnostic?.(`tool args for non-open block ${rec.blockIndex}: skipped`);
        return;
      }
      outputChars += frag.length;
      emit("content_block_delta", {
        type: "content_block_delta",
        index: rec.blockIndex,
        delta: { type: "input_json_delta", partial_json: frag },
      });
    }
  };

  const finish = (choice) => {
    finishSeen = true;
    pendingStop = anthropicStop(choice);
    closeOpen();
  };

  const usageEvent = (usage) => {
    latestUsage = usage;
  };

  const emitDeltaEvent = () => {
    if (doneEmitted) return;
    doneEmitted = true;
    const usage = latestUsage
      ? anthropicUsage(latestUsage)
      : {
          input_tokens: ctx.estimatedInput ?? 1,
          output_tokens: Math.max(1, Math.floor(outputChars / 4)),
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
        };
    emit("message_delta", {
      type: "message_delta",
      delta: pendingStop ?? { stop_reason: "end_turn", stop_sequence: null },
      usage,
    });
  };

  return {
    feed(obj) {
      if (terminated || !obj || typeof obj !== "object") return;

      if (obj.error && typeof obj.error === "object") {
        terminated = true;
        const code = obj.error.code;
        const type =
          code === 429 ? "rate_limit_error"
          : code === 503 || code === 529 || /overload/i.test(String(obj.error.message)) ? "overloaded_error"
          : code === 400 ? "invalid_request_error"
          : "api_error";
        emit("error", {
          type: "error",
          error: { type, message: `upstream stream error: ${sanitize(obj.error.message)}` },
        });
        return;
      }

      const choice = Array.isArray(obj.choices) ? obj.choices[0] : null;

      if (choice) {
        startMessage();
        const delta = choice.delta ?? {};
        // fixed intra-chunk order: reasoning -> content -> tool_calls -> finish_reason
        const reasoning = delta.reasoning ?? delta.reasoning_content;
        if (typeof reasoning === "string") reasoningText(reasoning);
        if (typeof delta.content === "string") textDelta(delta.content);
        if (Array.isArray(delta.tool_calls)) for (const t of delta.tool_calls) toolDelta(t);
        if (choice.finish_reason != null) finish(choice);
      }

      if (obj.usage) usageEvent(obj.usage);
    },

    // [DONE] or upstream end/close: single terminal entry point
    done() {
      if (terminated) return;
      terminated = true;
      startMessage();
      closeOpen();
      emitDeltaEvent();
      emit("message_stop", { type: "message_stop" });
    },

    abort() {
      terminated = true;
    },

    get terminated() {
      return terminated;
    },
    get finishSeen() {
      return finishSeen;
    },
  };
}
