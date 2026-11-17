/**
 * Client-side tool search (Claude Code ToolSearch) through the openai translator.
 *
 * The harness keeps rarely used tools "deferred": it announces their names in a message, and
 * ToolSearch answers with `tool_reference` pointers while appending the found tools to
 * `body.tools` with `defer_loading: true`. Anthropic's server expands each pointer into the
 * tool's definition inline; Corti does not, so the translator has to.
 */

/** The function line ToolSearch's own description promises, one per matched tool. */
function functionLine(tool) {
  return `<function>${JSON.stringify({
    description: typeof tool.description === "string" ? tool.description : "",
    name: tool.name,
    parameters: tool.input_schema ?? { type: "object" },
  })}</function>`;
}

/**
 * Text for a tool_result's `tool_reference` blocks, or "" when there are none. A pure function
 * of the request's own tools, so a past result renders byte-identically on every turn and after
 * a gateway restart.
 */
export function renderToolReferences(content, toolsByName) {
  if (!Array.isArray(content)) return "";
  const lines = [];
  for (const b of content) {
    if (b?.type !== "tool_reference" || typeof b.tool_name !== "string") continue;
    const tool = toolsByName?.get(b.tool_name);
    lines.push(tool ? functionLine(tool) : `<function>${JSON.stringify({ name: b.tool_name })}</function>`);
  }
  return lines.length ? `<functions>\n${lines.join("\n")}\n</functions>` : "";
}

/** Name → tool definition for the request's own tools. */
export function toolsByName(tools) {
  const map = new Map();
  for (const t of Array.isArray(tools) ? tools : []) if (t && typeof t.name === "string" && !map.has(t.name)) map.set(t.name, t);
  return map;
}
