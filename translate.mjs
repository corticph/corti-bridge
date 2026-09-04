// translate.mjs — Anthropic Messages ⇄ OpenAI Chat Completions wire translation.

import https from "node:https";
import path from "node:path";
import fs from "node:fs";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { serializeAdvisorInput } from "./lib/advisor-transcript.mjs";

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
/* advisor: headless corti-bridge backing (consult_advisor intercept)  */
/* ------------------------------------------------------------------ */

// The advisor runs as a headless `corti-bridge -p` session through this same gateway, so it
// inherits the Corti model mapping. The recursion guard has two layers: the env var below
// gates injection on the gateway, and the advisor child is spawned WITHOUT it (so its own
// requests don't re-inject) and with `--tools ""` (so it can't emit a tool_use at all).
const REPO_ROOT = path.dirname(fileURLToPath(import.meta.url));
const ADVISOR_PROMPT_FILE = path.join(REPO_ROOT, "lib", "advisor-prompt.txt");
const ADVISOR_EXECUTOR_PROMPT_FILE = path.join(REPO_ROOT, "lib", "advisor-executor-prompt.txt");
// The advisor is a headless Opus-tier `corti-bridge -p` reasoning over a large serialized
// transcript — a single consult can legitimately take minutes, not seconds. 60s was
// observed timing out in real sessions. 8 minutes is the floor; raise CORTI_ADVISOR_TIMEOUT_MS
// to extend further. The gateway's stream-idle watchdog is suppressed for the advisor
// handoff (see gateway.mjs deadlineCheck / advisorHandoff) so this is the real ceiling.
const ADVISOR_TIMEOUT_MS = Number(process.env.CORTI_ADVISOR_TIMEOUT_MS) || 8 * 60_000;
const ADVISOR_MODEL = process.env.CORTI_ADVISOR_MODEL || "opus";
// Soft per-call output cap, surfaced to the advisor via the serialized transcript's budget
// line. The official advisor tool sets a hard `max_tokens` on the tool def; corti-bridge -p
// exposes no such flag, so this is a soft steer (the advisor shapes to fit) plus the hard
// ADVISOR_TIMEOUT_MS / maxBuffer ceilings. 2048 is the official "recommended starting point."
// Read at call time (not module load) so per-test env changes take effect.
const advisorMaxTokens = () => Number(process.env.CORTI_ADVISOR_MAX_TOKENS) || 2048;

const ADVISOR_TOOL_NAME = "consult_advisor";
const ADVISOR_TOOL_NAMES = new Set([ADVISOR_TOOL_NAME]);
// Empty input_schema: the executor signals *timing only*. Letting it write a query loses
// exactly the detail the advisor is there to catch — the harness forwards the full transcript
// automatically (see serializeAdvisorInput). `additionalProperties: false` matters: models
// want to fill in a "question" field.
const ADVISOR_TOOL_DEF = {
  name: ADVISOR_TOOL_NAME,
  description:
    "Consult a stronger reviewer model. Takes no parameters — your entire conversation " +
    "history is forwarded automatically. Call before committing to an approach, when stuck, " +
    "and before declaring a task complete.",
  input_schema: { type: "object", properties: {}, additionalProperties: false },
};

// Runs the advisor as a headless corti-bridge session. Resolves to a discriminated result:
//   { ok: true,  text }            — the advisor's guidance (plaintext)
//   { ok: false, code }            — a failure, mapped to an official advisor_tool_result_error
//                                    error_code (execution_time_exceeded | unavailable |
//                                    prompt_too_long | overloaded | too_many_requests |
//                                    model_not_found). See reference/advisor-tool-official.md
//                                    §"Error results": the executor sees the error and
//                                    continues without further advice; the request does not fail.
// The child env carries a recursion guard so the child's own requests through the proxy
// don't re-inject the tool: CORTI_ADVISOR_NOINJECT stamps the -noadvisor- token (primary),
// and CORTI_ADVISOR=off is a belt-and-suspenders env backstop (the child's advisorWanted
// sees `off` regardless of its mode). `text` is the serialized executor transcript
// (system + tools + messages + budget line), not a short focus string — the advisor sees the
// full context the executor has, per the official advisor tool's "server supplies context"
// behaviour. A bare string return from an injected test stub is treated as { ok: true, text }
// so tests that return plain advice strings stay unchanged.
export function runAdvisor(text, opts = {}) {
  return new Promise((resolve) => {
    const args = [
      "-p",
      "--model", ADVISOR_MODEL,
      "--output-format", "json",
      "--system-prompt-file", ADVISOR_PROMPT_FILE,
      "--tools", "",
      "--input-format", "text",
    ];
    const env = { ...process.env };
    // The child must not inherit the gateway's debug logging: CORTI_DEBUG makes corti-bridge
    // tee verbose output to stdout/stderr (and write its own gateway-*.log), which inflated
    // the child's stdout past the 4MB maxBuffer and failed the consult with
    // ERR_CHILD_PROCESS_STDIO_MAXBUFFER. The advisor runs silently; the gateway logs its
    // result. Strip CORTI_DEBUG / CORTI_DEBUG_DIR alongside the recursion-guard strip.
    delete env.CORTI_DEBUG;
    delete env.CORTI_DEBUG_DIR;
    // The advisor child runs through the SAME gateway the parent process is serving on, but
    // it must never MANAGE that gateway: the wrapper's debug-mode-mismatch restart (parent
    // started with CORTI_DEBUG=1, this child with it stripped) would otherwise make the child
    // restart-kill its own parent gateway mid-consult ("Server error mid-response"). Tell the
    // wrapper to use the running gateway as-is — no stop, no start, no restart.
    env.CORTI_NO_MANAGE_GATEWAY = "1";
    // Recursion guard: ask the corti-bridge wrapper to stamp the -noadvisor marker on the
    // child's auth token, which the gateway's wantsNoAdvisor() skips injection on. The
    // gateway process env has no ANTHROPIC_AUTH_TOKEN (the wrapper sets it after spawning
    // the gateway), so we can't stamp the suffix here — the wrapper must do it.
    env.CORTI_ADVISOR_NOINJECT = "1";
    // Carry the parent's session id so the wrapper can stamp it as x-corti-advisor-for on the
    // child's request, letting the gateway file the advisor's log entries under the parent.
    const parentSessionId = opts?.parentSessionId;
    if (parentSessionId) env.CORTI_ADVISOR_PARENT_SESSION = parentSessionId;
    // Belt-and-suspenders: even if the -noadvisor- token guard somehow failed, the child's
    // openai-mode advisorWanted("openai", false) sees CORTI_ADVISOR=off → no injection.
    // Primary guard remains CORTI_ADVISOR_NOINJECT (the token stamp → skipAdvisor:true).
    env.CORTI_ADVISOR = "off";
    // maxBuffer bounds the child's combined stdout. The advisor is an Opus-tier model
    // emitting --output-format json (an array of every event); even without inherited debug
    // logging, that stream can exceed a few MB on a long consult. 32MB is generous headroom —
    // the real advice is small (the successful consult returned 624 chars), but the event
    // stream surrounding it is not. The `detail` capture surfaces a maxBuffer failure with its
    // err.code if this is ever too small again.
    const child = execFile("corti-bridge", args, {
      env,
      timeout: ADVISOR_TIMEOUT_MS,
      maxBuffer: 32 * 1024 * 1024,
    }, (err, stdout, stderr) => {
      if (err) {
        // Capture the raw failure so the gateway diagnostic can show WHY, not just that, it
        // failed. execFile sets err.code === "ETIMEDOUT" when the timeout fires; other codes
        // (ENOENT if corti-bridge isn't on PATH, ERR_CHILD_PROCESS_STDIO_MAXBUFFER if stdout
        // or stderr exceeded maxBuffer, a non-zero exit) are non-timeout failures. stderr
        // carries the child's own error text when it exited non-zero — the most useful signal.
        const detail = `code=${err.code || "?"} msg=${String(err.message || "").slice(0, 200)}` +
          (stderr ? ` stderr=${String(stderr).trim().slice(0, 200)}` : "");
        return resolve({
          ok: false,
          code: err.code === "ETIMEDOUT" ? "execution_time_exceeded" : "unavailable",
          detail,
        });
      }
      try {
        // --output-format json emits a JSON array of event objects; the result text is on the
        // element with type === "result". Fall back to result.text, then raw stdout.
        const out = stdout.toString().trim();
        const arr = JSON.parse(out);
        const items = Array.isArray(arr) ? arr : [arr];
        const result = items.find((o) => o && o.type === "result");
        const advice =
          (typeof result?.result === "string" && result.result) ||
          (typeof result?.text === "string" && result.text) ||
          out;
        // Empty advice despite a clean exit: surface the raw stdout so we can see what the
        // child actually emitted (an error envelope, an empty result, etc.).
        return resolve(
          advice
            ? { ok: true, text: advice }
            : { ok: false, code: "unavailable", detail: `empty advice; stdout=${out.slice(0, 200)}` },
        );
      } catch (e) {
        return resolve({ ok: false, code: "unavailable", detail: `unparseable: ${String(e.message || e).slice(0, 200)}; stdout=${String(stdout || "").trim().slice(0, 200)}` });
      }
    });
    child.stdin.on("error", () => {}); // child closed stdin before we wrote
    child.stdin.end(String(text ?? ""));
  });
}

// Default backing used when no runAdvisor is injected via ctx (production). Aliased rather than
// re-declared to avoid a TDZ reference before runAdvisor is initialised.
const defaultRunAdvisor = runAdvisor;

// The executor-side timing + advice-weight block, read once from disk and cached. Prepended to
// the executor's system prompt whenever the advisor tool is injected, so the executor calls at
// the official cadence (before substantive work, before declaring done). From
// lib/advisor-executor-prompt.txt — the official "Suggested system prompt for coding tasks."
let _executorPromptCache;
function advisorExecutorPrompt() {
  if (_executorPromptCache === undefined) {
    try {
      _executorPromptCache = fs.readFileSync(ADVISOR_EXECUTOR_PROMPT_FILE, "utf8").trim();
    } catch {
      _executorPromptCache = "";
    }
  }
  return _executorPromptCache;
}

// Prepend the executor timing block to body.system. Idempotent: skips if the block is already
// present (it carries its own distinctive opening line). Accepts string or array system shapes.
function prependExecutorPrompt(body) {
  const block = advisorExecutorPrompt();
  if (!block) return;
  if (typeof body.system === "string") {
    if (!body.system.includes("You have access to an `advisor` tool")) {
      body.system = `${block}\n\n${body.system}`.trim();
    }
  } else if (Array.isArray(body.system)) {
    const first = body.system.find((b) => b?.type === "text" && typeof b.text === "string");
    if (!first?.text?.includes("You have access to an `advisor` tool")) {
      body.system = [{ type: "text", text: block }, ...body.system];
    }
  } else {
    body.system = [{ type: "text", text: block }];
  }
}

// Extract the advice text from an advisor_tool_result block for history round-tripping (C6).
// The block's content is a discriminated union: {type:"advisor_result", text} (success) or
// {type:"advisor_tool_result_error", error_code} (failure). We previously wrapped the advice in
// a leading "Advisor feedback:\n\n" prefix when emitting it (C7 removed that); here we strip any
// legacy prefix so the tag holds the raw advice. Errors render as a short unavailable note.
function advisorResultText(block) {
  const c = block?.content;
  if (!c || typeof c !== "object") return "";
  if (c.type === "advisor_result" && typeof c.text === "string") {
    return c.text.replace(/^Advisor feedback:\n\n/, "");
  }
  if (c.type === "advisor_tool_result_error") return `advisor unavailable (${c.error_code || "unavailable"})`;
  return "";
}

// Wrap advisor advice for the model-facing channel: a distinct <advisor_guidance> tag so the
// executor treats it as a first-class advice channel rather than ordinary tool output
// (reconstruction §3.3). Used in the continuation tool_result, the anthropic next-turn rewrite,
// and the C6 history round-trip — every place the advice text meets the model.
function advisorGuidanceText(advice) {
  return `<advisor_guidance>\n${advice}\n</advisor_guidance>`;
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

let warnedAdvisorVar = false;

// One knob, mode-aware default. skipAdvisor (the -noadvisor- recursion guard) is
// authoritative and checked FIRST so no env var can override it.
//   CORTI_ADVISOR=auto (unset) → openai ON, anthropic OFF (the mode defaults)
//   CORTI_ADVISOR=on           → ON in both modes
//   CORTI_ADVISOR=off          → OFF in both modes
//   CORTI_ADVISOR_TOOL is REMOVED — CORTI_ADVISOR is the only knob.
// An unrecognized value (not auto/on/off/unset) warns once and falls to auto.
function advisorWanted(mode, skipAdvisor) {
  if (skipAdvisor) return false;
  // Normalize so CORTI_ADVISOR=OFF / " on " etc. behave as written, not as a silent
  // fall to auto. The raw value is preserved for the unrecognized-value warning.
  const raw = process.env.CORTI_ADVISOR;
  const v = raw != null ? raw.trim().toLowerCase() : raw;
  if (v === "off") return false;
  if (v === "on") return true;
  if (v != null && v !== "" && v !== "auto") {
    // Unrecognized value — warn once per process, then fall to auto (mode default).
    if (!warnedAdvisorVar) {
      warnedAdvisorVar = true;
      console.error(`corti-proxy: unrecognized CORTI_ADVISOR=${JSON.stringify(raw)}, using auto (expected auto|on|off)`);
    }
  }
  // "auto" (unset, or unrecognized) → mode default: openai on, anthropic (and undefined) off.
  return mode === "openai";
}

// Injects the consult_advisor tool def and rewrites its tool_result blocks with the advisor's
// output. Gated by CORTI_ADVISOR (auto/on/off): auto is the mode default (openai on, anthropic
// off), on/off force both modes. skipAdvisor (the -noadvisor- recursion guard) is authoritative
// and checked first inside advisorWanted so no env var can override it. The runAdvisor
// dependency is injectable via ctx so tests stay hermetic (no child_process spawn).
async function interceptConsultAdvisor(body, { toolUseMap, runAdvisor, skipAdvisor, mode, parentSessionId } = {}) {
  if (!advisorWanted(mode, skipAdvisor)) return [];
  const diagnostics = [];

  // (a) inject the tool def so the model sees it (idempotent — don't push if present)
  if (Array.isArray(body.tools)) {
    if (!body.tools.some((t) => t && t.name === ADVISOR_TOOL_NAME)) body.tools.push(ADVISOR_TOOL_DEF);
  } else {
    body.tools = [ADVISOR_TOOL_DEF];
  }

  // (a2) prepend the executor timing + advice-weight block to body.system so the executor
  //     calls at the official cadence. Same gate as the tool injection above.
  prependExecutorPrompt(body);

  // (b) rewrite tool_result blocks for consult_advisor calls. Claude Code synthesizes an error
  // tool_result ("Unknown tool: consult_advisor", is_error:true) for the unknown tool and
  // round-trips it in the next request; we overwrite both content AND is_error here.
  //
  // The advisor receives the SERIALIZED TRANSCRIPT of the whole request (system + tools +
  // messages + budget line), not the executor's focus string — this is the official "server
  // supplies context" behaviour. The tool_use input is now empty, so there is no focus to read.
  const call = runAdvisor || defaultRunAdvisor;
  for (const msg of body.messages ?? []) {
    if (msg?.role !== "user" || !Array.isArray(msg.content)) continue;
    for (const b of msg.content) {
      if (b?.type !== "tool_result") continue;
      const toolUse = toolUseMap.get(b.tool_use_id);
      if (!toolUse || !ADVISOR_TOOL_NAMES.has(toolUse.name)) continue;
      const { text, elidedCount } = serializeAdvisorInput(body, { maxTokens: advisorMaxTokens() });
      const out = await call(text, { parentSessionId });
      // A bare string is a test stub (backward compat) — treat as success.
      const res = typeof out === "string" ? { ok: true, text: out } : out;
      if (res?.ok) {
        b.content = advisorGuidanceText(res.text);
        b.is_error = false;
      } else {
        // The advisor failed (timeout / unavailable / etc). The executor sees the failure and
        // continues without advice; the request itself does not fail (official §"Error results").
        b.content = advisorGuidanceText(`advisor unavailable (${res?.code || "unavailable"})`);
        b.is_error = false;
      }
      const elidedStr = elidedCount ? ` elided=${elidedCount}` : "";
      const resStr = res?.ok ? `advisor=${res.text.length} chars` : `advisor_error=${res?.code || "unavailable"}`;
      diagnostics.push(`advisor intercepted: transcript=${text.length} chars${elidedStr} ${resStr}`);
    }
  }
  return diagnostics;
}

const intercepts = [
  interceptModelMapping,
  interceptWebSearch,
  interceptConsultAdvisor,
];

export async function applyIntercepts(body, opts) {
  const ctx = { toolUseMap: buildToolUseMap(body), ...(opts || {}) };
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


export async function translateRequest(body, opts) {
  if (!body || typeof body !== "object")
    reject(400, "invalid_request_error", "request body is not valid JSON");
  if (typeof body.model !== "string" || !body.model)
    reject(400, "invalid_request_error", "Field required: model");
  if (!Array.isArray(body.messages))
    reject(400, "invalid_request_error", "Field required: messages");

  const interceptDiags = await applyIntercepts(body, opts);

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

    // Mid-conversation role:system messages are harness-injected reminders (task-tool nudges,
    // agent-type lists, CLAUDE.md content replays, plan-mode exits). Folding them into sysParts
    // grows the upstream system prefix and breaks Corti's automatic prefix cache every turn.
    // Emit them as user content at their original position instead — the prefix stays byte-stable
    // (cached) and the reminders still reach the model. body.system carries the real base prompt.
    if (msg.role === "system") {
      const texts = [];
      for (const b of blocksOf(msg.content)) {
        if (b.type === "text" && typeof b.text === "string" && b.text) texts.push(b.text);
        else if (b.type === "mid_conv_system") {
          for (const t of b.content ?? []) if (t?.type === "text" && t.text) texts.push(t.text);
        }
      }
      if (texts.length) messages.push({ role: "user", content: texts.join("\n\n") });
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
        } else if (b.type === "advisor_tool_result") {
          // C6: prior-turn advisor advice must round-trip into the model's view, not be dropped.
          // The official doc: "Pass the full assistant content, including advisor_tool_result
          // blocks, back to the API on subsequent turns. Round-trip the result blocks verbatim."
          // We can't replay the server-tool wire shape to an OpenAI upstream, so we surface the
          // advice as text wrapped in a distinct tag — a first-class channel the executor treats
          // as advice rather than ordinary (skeptically-treated) tool output (reconstruction §3.3).
          // server_tool_use (the paired call) is in SERVER_BLOCK_TYPES and dropped above — the
          // executor doesn't need to see the call shape, only the advice it carried.
          const advice = advisorResultText(b);
          if (advice) texts.push(advisorGuidanceText(advice));
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
          for (const t of b.content ?? []) if (t?.type === "text" && t.text)
            userParts.push({ type: "text", text: t.text });
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

  // C2: the advisor child should reason at high (the official default), not the medium that
  // adaptive thinking maps to above. The gateway sets advisorEffort for the advisor child
  // (detected via the -noadvisor- token); it overrides whatever the thinking block produced,
  // including the adaptive→medium mapping. A model that rejects this effort level will 400 at
  // upstream — that surfaces a real capability gap rather than silently reasoning shallow.
  if (opts?.advisorEffort) req.reasoning_effort = opts.advisorEffort;

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
  // Floor at 1: the harness's S2 usage-merge keeps message_start's estimate when the incoming
  // input_tokens is 0, double-counting the cached prefix on the statusline. Non-zero forces it
  // to overwrite with the real remainder.
  return {
    input_tokens: details ? Math.max(1, prompt - cacheRead - cacheCreation) : prompt,
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
  const toolBlocks = new Map(); // upstream tool_calls index -> { blockIndex, closed, name, id, args }
  let pendingStop = null;
  let doneEmitted = false;
  let terminated = false;
  let latestUsage = null;
  let outputChars = 0;
  let advisorToolUse = null; // { id, name, args } when the turn ends on a consult_advisor tool_use

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
          // The live per-agent counter reads this off each streamed event; the estimate is its
          // only growth signal (message_delta's real usage arrives too late). anthropicUsage
          // floors input_tokens at 1 so the statusline merge overwrites this with the real value.
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
        // Suppress the client consult_advisor tool_use from the harness: we replace it with a
        // synthetic server_tool_use + advisor_tool_result inline (see finish()/onAdvisorToolUse),
        // so the harness never dispatches a tool it has no implementation for (no error flash).
        // We still record the block so the hook can read its id; marked closed + blockIndex -1
        // so it is never emitted and occupies no block index.
        if (name === ADVISOR_TOOL_NAME && typeof ctx.onAdvisorToolUse === "function") {
          toolBlocks.set(idx, { blockIndex: -1, closed: true, name, id, args: "" });
        } else {
          openBlock("tool", { type: "tool_use", id, name, input: {} });
          toolBlocks.set(idx, { blockIndex: open.index, closed: false, name, id, args: "" });
        }
      }
    }

    const rec = toolBlocks.get(idx);
    if (!rec || rec.closed) {
      // The suppressed advisor block is closed but we still accumulate its args for
      // completeness — just don't emit them to the harness. (The tool input is empty, so
      // there's nothing to read here in practice; the hook gets the id only.)
      if (rec && rec.name === ADVISOR_TOOL_NAME && typeof ctx.onAdvisorToolUse === "function") {
        const f = entry.function?.arguments;
        if (typeof f === "string") rec.args += f;
      } else if (entry.function?.arguments) {
        ctx.onDiagnostic?.(`tool args for unknown/closed index ${idx}: skipped`);
      }
      return;
    }
    const frag = entry.function?.arguments;
    if (typeof frag === "string" && frag.length) {
      if (open?.index !== rec.blockIndex) {
        // args for a non-open tool block: vLLM emits sequentially; defensive skip
        ctx.onDiagnostic?.(`tool args for non-open block ${rec.blockIndex}: skipped`);
        return;
      }
      rec.args += frag;
      outputChars += frag.length;
      emit("content_block_delta", {
        type: "content_block_delta",
        index: rec.blockIndex,
        delta: { type: "input_json_delta", partial_json: frag },
      });
    }
  };

  const finish = (choice) => {
    pendingStop = anthropicStop(choice);
    closeOpen();
    // Detect a turn ending on a consult_advisor tool_use. The harness would otherwise end the
    // turn and synthesize a "No such tool" error; the gateway uses this to hold the turn open
    // and emit an inline advisor_tool_result instead. Only fires when a hook is registered.
    // The tool input is empty (the executor signals timing only), so we pass just the id;
    // the gateway serializes the full transcript from its own copy of the request body.
    if (pendingStop?.stop_reason === "tool_use" && typeof ctx.onAdvisorToolUse === "function") {
      const adv = [...toolBlocks.values()].reverse().find((t) => t.name === "consult_advisor");
      if (adv) {
        advisorToolUse = { id: adv.id };
      }
    }
  };

  const usageEvent = (usage) => {
    latestUsage = usage;
  };

  const emitDeltaEvent = () => {
    if (doneEmitted) return;
    doneEmitted = true;
    // Hand the turn to the gateway instead of terminating, so it can emit an inline
    // advisor_tool_result and a continuation. The gateway owns the terminal events then.
    if (advisorToolUse && typeof ctx.onAdvisorToolUse === "function") {
      ctx.onAdvisorToolUse(advisorToolUse);
      return;
    }
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
      startMessage();
      closeOpen();
      emitDeltaEvent();
      // When the turn is handed off for an inline advisor result, the gateway owns the rest
      // of the stream — do not emit message_stop or mark terminated.
      if (!advisorToolUse) {
        terminated = true;
        emit("message_stop", { type: "message_stop" });
      }
    },

    get terminated() {
      return terminated;
    },
    get nextBlockIndex() {
      return nextBlockIndex;
    },
    // True when the translator handed the turn to the gateway for an inline advisor result
    // (done() suppressed message_stop). The stream handlers use this to know not to finalize.
    get advisorHandoff() {
      return !!advisorToolUse && !terminated;
    },
    // Release the advisor handoff: the advisor child has finished and the gateway is about to
    // make the continuation upstream call, which is a normal (non-advisor) request that can
    // stall and must be guarded by the stream-idle watchdog. Call this right before the
    // continuation so the watchdog re-arms (deadlineCheck keys on advisorHandoff).
    releaseAdvisor() {
      advisorToolUse = null;
    },
  };
}
