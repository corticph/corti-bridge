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
 * Text for a tool_result's `tool_reference` blocks, or "" when there are none. Rendered from the
 * request's own tools. `memo` (name → line, per session) pins each tool's first rendering, so a
 * past result keeps its bytes when the harness later drops or edits the tool (an MCP disconnect);
 * without it, the rendering still matches across turns while the tool is unchanged.
 */
export function renderToolReferences(content, toolsByName, memo) {
  if (!Array.isArray(content)) return "";
  const lines = [];
  for (const b of content) {
    if (b?.type !== "tool_reference" || typeof b.tool_name !== "string") continue;
    let line = memo?.get(b.tool_name);
    if (!line) {
      const tool = toolsByName?.get(b.tool_name);
      line = tool ? functionLine(tool) : `<function>${JSON.stringify({ name: b.tool_name })}</function>`;
      if (tool) memo?.set(b.tool_name, line);
    }
    lines.push(line);
  }
  return lines.length ? `<functions>\n${lines.join("\n")}\n</functions>` : "";
}

/** Name → tool definition for the request's own tools. */
export function toolsByName(tools) {
  const map = new Map();
  for (const t of Array.isArray(tools) ? tools : []) if (t && typeof t.name === "string" && !map.has(t.name)) map.set(t.name, t);
  return map;
}

const ANNOUNCE_HEADER = "to load tool schemas before calling them:";
// Sent deferred from the first request so tool search stays on; never to be called.
const PLACEHOLDER_NAME = "DeferredToolPlaceholder";
const NAME_LINE = /^[A-Za-z0-9_.:-]+$/;

/** A fixed definition, so loading the real tool later never changes the upstream tools array. */
export const DEFERRED_STUB_DESCRIPTION =
  "Deferred tool. Load it with ToolSearch before you call it: its full definition appears in the ToolSearch result.";

export function deferredStub(name) {
  return { name, description: DEFERRED_STUB_DESCRIPTION, input_schema: { type: "object" } };
}

/** Harness-authored text only: user and assistant prose must not be able to declare tools. */
function systemTextsOf(content, wholeMessageIsSystem) {
  if (typeof content === "string") return wholeMessageIsSystem ? [content] : [];
  if (!Array.isArray(content)) return [];
  const out = [];
  for (const b of content) {
    if (wholeMessageIsSystem && b?.type === "text" && typeof b.text === "string") out.push(b.text);
    else if (b?.type === "mid_conv_system")
      for (const t of b.content ?? []) if (t?.type === "text" && typeof t.text === "string") out.push(t.text);
  }
  return out;
}

/**
 * Every deferred tool name the harness announced, in order of first appearance, or null when
 * there is no announcement. Only harness-authored text counts: `body.system`, `role: "system"`
 * messages (where Claude Code puts it) and `mid_conv_system` blocks. Removal notices are ignored:
 * dropping a name would change the upstream tools array, and the harness itself rejects a call to
 * a tool it no longer has. Compaction does not shrink the list, because the harness re-announces.
 */
export function announcedDeferredNames(body) {
  const names = [];
  const scan = (text) => {
    for (let at = text.indexOf(ANNOUNCE_HEADER); at >= 0; at = text.indexOf(ANNOUNCE_HEADER, at + 1)) {
      // Names follow one per line after the header line, up to the first line that is not a name.
      for (const raw of text.slice(at + ANNOUNCE_HEADER.length).split("\n").slice(1)) {
        const line = raw.trim();
        if (!NAME_LINE.test(line)) break;
        if (!names.includes(line)) names.push(line);
      }
    }
  };
  for (const t of systemTextsOf(body?.system, true)) scan(t);
  for (const m of Array.isArray(body?.messages) ? body.messages : []) for (const t of systemTextsOf(m?.content, m?.role === "system")) scan(t);
  return names.length ? names : null;
}

function referencedNames(messages) {
  const names = [];
  for (const m of Array.isArray(messages) ? messages : []) {
    if (!Array.isArray(m?.content)) continue;
    for (const b of m.content) {
      if (b?.type !== "tool_result" || !Array.isArray(b.content)) continue;
      for (const c of b.content)
        if (c?.type === "tool_reference" && typeof c.tool_name === "string" && !names.includes(c.tool_name))
          names.push(c.tool_name);
    }
  }
  return names;
}

/**
 * How deferred tools go upstream, or null when the request has none.
 *
 * Corti renders `tools` at the front of the prompt, so appending each loaded tool there re-bills
 * the whole prompt. Instead every announced deferred name goes upstream as a fixed stub from the
 * first request: the array then changes only when the harness announces a new tool. A real
 * definition reaches the model inline, through the rendered tool_reference. The name must still
 * be declared, because the glm47 parser drops (or grammar-constrains to a declared name) any call
 * to a name that is not.
 *
 * - `{ stubbed: true, names, schemas }`: `schemas` maps each loaded stub to its real input_schema,
 *   for typing the call's arguments back with `coerceStubInput`.
 * - `{ stubbed: false }`: deferred tools but no announcement to name them; the caller forwards
 *   them as real tools, as before.
 */
export function planDeferredTools(body) {
  const tools = Array.isArray(body?.tools) ? body.tools : [];
  const deferred = tools.filter((t) => t && t.defer_loading === true && typeof t.name === "string");
  if (!deferred.length) return null;
  const announced = announcedDeferredNames(body);
  if (!announced) return { stubbed: false };
  // A name that is already a real tool would be declared twice upstream.
  const real = new Set(tools.filter((t) => t && t.defer_loading !== true).map((t) => t?.name));
  const names = announced.filter((n) => !real.has(n));
  // A deferred tool no announcement named still has to be callable: loaded ones first, in load
  // order, then any other the harness sent. Undeclared, glm47 would drop or reroute its calls.
  for (const n of referencedNames(body.messages))
    if (!names.includes(n) && deferred.some((t) => t.name === n)) names.push(n);
  for (const t of deferred) if (!names.includes(t.name) && t.name !== PLACEHOLDER_NAME) names.push(t.name);
  const schemas = new Map();
  for (const t of deferred) if (names.includes(t.name) && t.input_schema) schemas.set(t.name, t.input_schema);
  return { stubbed: true, names, schemas };
}

function allowedTypes(prop) {
  if (!prop || typeof prop !== "object") return null;
  const types = new Set();
  const add = (t) => {
    if (typeof t === "string") types.add(t);
    else if (Array.isArray(t)) t.forEach(add);
  };
  add(prop.type);
  for (const k of ["anyOf", "oneOf"]) if (Array.isArray(prop[k])) for (const s of prop[k]) add(s?.type);
  if (Array.isArray(prop.enum)) for (const v of prop.enum) types.add(v === null ? "null" : typeof v);
  return types.size ? types : null;
}

/**
 * Types a stub call's arguments back from the real schema. The glm47 parser types a top-level
 * argument only from the declared schema, and a stub declares none, so every value arrives as a
 * string: a non-string property holds JSON text. A value that does not parse into an allowed type
 * stays as it is, for the harness's own input validation to report.
 */
export function coerceStubInput(input, schema) {
  const props = schema?.properties;
  if (!input || typeof input !== "object" || Array.isArray(input) || !props || typeof props !== "object") return input;
  let out = input;
  for (const [k, v] of Object.entries(input)) {
    if (typeof v !== "string") continue;
    const types = allowedTypes(props[k]);
    if (!types || types.has("string")) continue;
    let parsed;
    try {
      parsed = JSON.parse(v);
    } catch {
      continue;
    }
    const kind = parsed === null ? "null" : Array.isArray(parsed) ? "array" : typeof parsed;
    const fits = types.has(kind) || (kind === "number" && types.has("integer") && Number.isInteger(parsed));
    if (!fits) continue;
    if (out === input) out = { ...input };
    out[k] = parsed;
  }
  return out;
}
