/**
 * Harness-authored text in an Anthropic request: `body.system`, `role: "system"` messages (where
 * Claude Code puts its environment block and announcements) and `mid_conv_system` blocks. Anything a
 * user or tool wrote is excluded, so quoted prose cannot pose as the harness.
 */
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

/** Every harness-authored text of a request, in order: the system prompt first, then the messages. */
export function harnessTexts(body) {
  const out = [...systemTextsOf(body?.system, true)];
  for (const m of Array.isArray(body?.messages) ? body.messages : [])
    out.push(...systemTextsOf(m?.content, m?.role === "system"));
  return out;
}

/**
 * The executor's working directory from its environment block ("Primary working directory: …"),
 * or undefined. The first occurrence is the session's own; later environment updates append
 * "(was …)" and track a cd, which the advisor has no use for.
 */
export function executorCwd(body) {
  for (const t of harnessTexts(body)) {
    const m = t.match(/Primary working directory: ([^\n]+)/);
    if (m) return m[1].replace(/\s+\(was [^)]*\)\s*$/, "").trim() || undefined;
  }
  return undefined;
}
