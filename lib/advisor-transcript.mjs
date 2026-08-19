// advisor-transcript.mjs — render an executor request into a single text payload for the
// advisor's stdin. Mirrors the official advisor tool's "server supplies context" behaviour:
// the executor signals *timing only* (empty tool input); the harness forwards the full
// conversation so the advisor can catch tool results the executor misread. See
// .context/.../reference/advisor-tool-official.md §3.2 for the template this follows.
//
// Order is load-bearing: system prompt and tools first (stable, cacheable prefix), transcript
// last (grows each call). A budget line closes the payload so the advisor shapes its answer
// to the per-call cap.

const DEFAULT_MAX_TOOL_RESULT_CHARS = 6000; // head/tail-truncate tool results larger than this
const DEFAULT_MAX_TOOL_BUDGET_TOKENS = 2048; // official "recommended starting point" cap

// Block lists for content arrays — same shape translate.mjs uses (string or array of blocks).
function blocksOf(content) {
  if (typeof content === "string") return content ? [{ type: "text", text: content }] : [];
  return Array.isArray(content) ? content : [];
}

// Extract text from a tool_result block's content (string, or array of text blocks).
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

// Extract the system prompt from body.system (string, or array of text blocks).
function systemPromptText(system) {
  if (typeof system === "string") return system;
  if (Array.isArray(system)) {
    return system
      .filter((b) => b && b.type === "text" && typeof b.text === "string")
      .map((b) => b.text)
      .join("\n\n");
  }
  return "";
}

// Format a tool definition as one line: "name — description".
function toolLine(tool) {
  if (!tool || typeof tool !== "object") return null;
  const name = tool.name || tool.function?.name;
  if (!name) return null;
  const desc = (tool.description || tool.function?.description || "").trim();
  return desc ? `${name} — ${desc}` : name;
}

// Head/tail-truncate a long string from the middle, keeping a clear elision marker. The
// official note: "Advisors reason badly about elided middles unless you mark them."
function truncateMiddle(text, maxChars) {
  if (typeof text !== "string" || text.length <= maxChars) return text;
  const keep = Math.floor((maxChars - 60) / 2); // 60 chars reserved for the marker
  const head = text.slice(0, keep);
  const tail = text.slice(text.length - keep);
  const elidedChars = text.length - head.length - tail.length;
  return `${head}\n\n[... ~${elidedChars} chars elided ...]\n\n${tail}`;
}

// Serialize a single message's content blocks into transcript lines.
function serializeContentBlocks(blocks, maxToolResultChars, elided) {
  const lines = [];
  for (const b of blocks) {
    if (!b || typeof b !== "object") continue;
    switch (b.type) {
      case "text":
        if (typeof b.text === "string" && b.text) lines.push(b.text);
        break;
      case "thinking":
        // Official: thinking blocks are dropped — only the conclusion reaches the executor,
        // and thinking would dominate the injected result's token cost. Mark it, don't dump it.
        lines.push("[thinking omitted]");
        break;
      case "tool_use": {
        const input = b.input;
        let inputStr;
        try {
          inputStr = input == null ? "" : JSON.stringify(input);
        } catch {
          inputStr = String(input ?? "");
        }
        lines.push(`→ calls ${b.name || "tool"}(${inputStr})`);
        break;
      }
      case "tool_result": {
        const raw = toolResultText(b);
        if (b.is_error) lines.push(`← ERROR result: ${truncateMiddle(raw, maxToolResultChars)}`);
        else lines.push(`← result: ${truncateMiddle(raw, maxToolResultChars)}`);
        if (raw.length > maxToolResultChars) elided.count++;
        break;
      }
      default:
        // server_tool_use / web_search_tool_result / image / document / etc. — surface a label
        // so the advisor knows something was there without dumping opaque wire shapes.
        if (b.type) lines.push(`[${b.type}]`);
        break;
    }
  }
  return lines;
}

// Render the executor's request into the advisor's stdin payload.
// Returns { text, elidedCount } — elidedCount feeds a gateway diagnostic.
export function serializeAdvisorInput(body, opts = {}) {
  if (!body || typeof body !== "object") return { text: "", elidedCount: 0 };

  const maxToolResultChars =
    Number(opts.maxToolResultChars) || DEFAULT_MAX_TOOL_RESULT_CHARS;
  const maxTokens =
    Number(opts.maxTokens ?? process.env.CORTI_ADVISOR_MAX_TOKENS) || DEFAULT_MAX_TOOL_BUDGET_TOKENS;

  const elided = { count: 0 };
  const parts = [];

  // 1. Executor system prompt (stable prefix).
  const sys = systemPromptText(body.system);
  if (sys) {
    parts.push("<executor_system_prompt>");
    parts.push(sys);
    parts.push("</executor_system_prompt>");
    parts.push("");
  }

  // 2. Available tools — names + descriptions only. Omit consult_advisor itself so the advisor
  //    never sees a tool it could call (the recursion guard's "don't let the advisor see its
  //    own past advice as the executor's reasoning" concern).
  if (Array.isArray(body.tools) && body.tools.length) {
    const toolLines = body.tools
      .map((t) => (t && (t.name === "consult_advisor" || t.function?.name === "consult_advisor") ? null : toolLine(t)))
      .filter(Boolean);
    if (toolLines.length) {
      parts.push("<available_tools>");
      parts.push(toolLines.join("\n"));
      parts.push("</available_tools>");
      parts.push("");
    }
  }

  // 3. Transcript — the growing suffix. Serialize each message by role.
  const messages = Array.isArray(body.messages) ? body.messages : [];
  if (messages.length) {
    parts.push("<transcript>");
    for (const msg of messages) {
      if (!msg || typeof msg !== "object" || !msg.role) continue;
      const blocks = blocksOf(msg.content);
      if (!blocks.length && typeof msg.content === "string" && msg.content) {
        parts.push(`[${msg.role}] ${msg.content}`);
        continue;
      }
      const lines = serializeContentBlocks(blocks, maxToolResultChars, elided);
      if (!lines.length) continue;
      parts.push(`[${msg.role}]`);
      parts.push(lines.join("\n"));
      parts.push("");
    }
    parts.push("</transcript>");
    parts.push("");
  }

  // 4. Budget line — after the transcript (the official template puts it last so it isn't lost).
  //    The advisor sees its remaining-token budget and shapes the answer to fit.
  parts.push(
    `Your remaining output budget for this response is approximately ${maxTokens} tokens. ` +
      `Give the executor your guidance now.`
  );

  return { text: parts.join("\n"), elidedCount: elided.count };
}
