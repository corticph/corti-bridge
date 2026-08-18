#!/bin/sh
# Pure-function tests for translate.mjs. Zero dependencies, hermetic, offline —
# translateRequest never touches the network, so no credentials are needed.
#
# Run: sh test/translate.sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

node --input-type=module -e '
import { translateRequest, translateError, promptTooLong, applyIntercepts } from "'"$REPO"'/translate.mjs";

let failed = 0;
const check = (name, got, want) => {
  if (got === want) console.log(`ok   ${name}`);
  else { console.log(`FAIL ${name} (expected ${want}, got ${got})`); failed++; }
};

const effort = async (model, thinking) =>
  (await translateRequest({ model, max_tokens: 16, thinking, messages: [{ role: "user", content: "hi" }] }))
    .request.reasoning_effort;

const ENABLED = (n) => ({ type: "enabled", budget_tokens: n });

// Effort is budget-derived and model-independent.
for (const m of ["corti-s1", "corti-s1-mini", "corti-s1-ultra-beta", "corti-s1-ultra-instant-beta"]) {
  check(`${m}: adaptive is medium`, await effort(m, { type: "adaptive" }), "medium");
  check(`${m}: mid budget is medium`, await effort(m, ENABLED(8000)), "medium");
  check(`${m}: low budget is low`, await effort(m, ENABLED(1000)), "low");
  check(`${m}: high budget is high`, await effort(m, ENABLED(32000)), "high");
}

// Model name mapping: claude-* model names should map to configured Corti models via env vars.
process.env.ANTHROPIC_DEFAULT_OPUS_MODEL = "corti-s1";
process.env.ANTHROPIC_DEFAULT_SONNET_MODEL = "corti-s1-instant";
process.env.ANTHROPIC_DEFAULT_HAIKU_MODEL = "corti-s1-mini-instant";
const mappedOpus = (await translateRequest({ model: "claude-opus-5", max_tokens: 16, messages: [{ role: "user", content: "hi" }] })).request.model;
const mappedSonnet = (await translateRequest({ model: "claude-sonnet-4-20250514", max_tokens: 16, messages: [{ role: "user", content: "hi" }] })).request.model;
const mappedHaiku = (await translateRequest({ model: "claude-haiku-4-20250514", max_tokens: 16, messages: [{ role: "user", content: "hi" }] })).request.model;
const unmapped = (await translateRequest({ model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }] })).request.model;
check("model mapping: claude-opus-5 → corti-s1", mappedOpus, "corti-s1");
check("model mapping: claude-sonnet-* → corti-s1-instant", mappedSonnet, "corti-s1-instant");
check("model mapping: claude-haiku-* → corti-s1-mini-instant", mappedHaiku, "corti-s1-mini-instant");
check("model mapping: corti-s1 unchanged", unmapped, "corti-s1");

// applyIntercepts is the shared function called by both gateway modes. Test it directly
// to verify it works without translateRequest\x27s translation layer.
const interceptBody = { model: "claude-opus-5", max_tokens: 16, messages: [{ role: "user", content: "hi" }] };
const interceptDiags = await applyIntercepts(interceptBody);
check("applyIntercepts: maps model in-place", interceptBody.model, "corti-s1");
check("applyIntercepts: returns diagnostics", interceptDiags.length > 0, true);

// WebSearch server-side tool should be converted to a function tool, not stripped.
const wsTools = (await translateRequest({
  model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }],
  tools: [{ type: "web_search_20250305", name: "web_search", max_uses: 5 }],
})).request.tools;
check("websearch: converted to function tool", wsTools?.length === 1 && wsTools[0]?.function?.name === "WebSearch", true);

// consult_advisor: tool def injected when CORTI_ADVISOR_TOOL is set, in both gateway modes.
process.env.CORTI_ADVISOR_TOOL = "1";
const advBody = { model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }] };
await applyIntercepts(advBody);
check("advisor: tool def injected", advBody.tools?.some((t) => t.name === "consult_advisor"), true);
check("advisor: schema has focus", advBody.tools?.find((t) => t.name === "consult_advisor")?.input_schema?.properties?.focus?.type, "string");
// The openai translate path filters tools to input_schema + string name; ours has both, so it survives.
const advTools = (await translateRequest({
  model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }],
})).request.tools;
check("advisor: survives openai filter", advTools?.some((t) => t.function?.name === "consult_advisor"), true);

// Guard: not injected when the env var is unset.
delete process.env.CORTI_ADVISOR_TOOL;
const advBody2 = { model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }], tools: [] };
await applyIntercepts(advBody2);
check("advisor: not injected when unset", advBody2.tools.length, 0);

// Result rewrite with a stubbed runAdvisor — hermetic, no child_process spawn. Mirrors the
// shape Claude Code produces: an error tool_result ("Unknown tool: ...", is_error:true) that
// it round-trips in the next request; the intercept overwrites both content AND is_error.
process.env.CORTI_ADVISOR_TOOL = "1";
const stub = async (focus) => `stub advice for: ${focus}`;
const advBody3 = {
  model: "corti-s1", max_tokens: 16,
  messages: [
    { role: "assistant", content: [{ type: "tool_use", id: "tu_adv1", name: "consult_advisor", input: { focus: "the plan" } }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "tu_adv1", content: "Unknown tool: consult_advisor", is_error: true }] },
  ],
};
await applyIntercepts(advBody3, { runAdvisor: stub });
const advResult = advBody3.messages[1].content[0];
check("advisor: result rewritten", advResult.content, "Advisor feedback:\n\nstub advice for: the plan");
check("advisor: is_error cleared", advResult.is_error, false);

// Idempotency: don\x27t inject twice if the tool is already present.
const advBody4 = { model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }], tools: [{ name: "consult_advisor", input_schema: { type: "object" } }] };
await applyIntercepts(advBody4);
check("advisor: no duplicate injection", advBody4.tools.filter((t) => t.name === "consult_advisor").length, 1);
delete process.env.CORTI_ADVISOR_TOOL;

// Claude Code parses the digit pair out of our message to size compaction; when the match
// fails it tells the user the conversation cannot be compacted at all.
const CC_OVERFLOW_RE = /prompt is too long[^0-9]*(\d+)\s*tokens?\s*>\s*(\d+)/i;
const overflow = (message) =>
  translateError({ status: 400, bodyText: JSON.stringify({ error: { message } }) }).envelope.error.message;

// The apostrophe is \x27 because this whole program is one single-quoted shell string
// and a literal one would end it.
const vllm =
  "This model\x27s maximum context length is 524288 tokens. However, you requested 1 output tokens" +
  " and your prompt contains at least 524288 input tokens, for a total of at least 524289 tokens.";
const parsed = CC_OVERFLOW_RE.exec(overflow(vllm));
check("overflow: vLLM 0.27 wording yields a digit pair", parsed !== null, true);
check("overflow: actual token count survives", parsed?.[1], "524288");
check("overflow: limit survives", parsed?.[2], "524288");

// Older wording must keep working — legacy wording still parses.
const legacy = "maximum context length is 262144 tokens, however request has 300000 input tokens";
check("overflow: legacy wording still parses", CC_OVERFLOW_RE.test(overflow(legacy)), true);

// The gateway backstop is near-unreachable, so nothing else would catch a regression here — hence the digit assertions.
const local = CC_OVERFLOW_RE.exec(promptTooLong(600000, 524288, "proxy estimate"));
check("overflow: local guard message parses", local !== null, true);
check("overflow: local guard reports the estimate", local?.[1], "600000");
check("overflow: local guard reports the window", local?.[2], "524288");

console.log("");
if (failed === 0) { console.log("all checks passed"); process.exit(0); }
console.log(`${failed} check(s) failed`);
process.exit(1);
'
