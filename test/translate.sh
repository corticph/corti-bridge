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
const advBody = { model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }], system: "You are a coding agent." };
await applyIntercepts(advBody);
check("advisor: tool def injected", advBody.tools?.some((t) => t.name === "consult_advisor"), true);
// Empty input_schema: the executor signals timing only — the harness forwards the transcript.
// additionalProperties:false matters (models want to fill in a "question" field).
const advSchema = advBody.tools?.find((t) => t.name === "consult_advisor")?.input_schema;
check("advisor: schema is empty (additionalProperties:false)",
  JSON.stringify(advSchema) === JSON.stringify({ type: "object", properties: {}, additionalProperties: false }), true);
// The executor-side timing block is prepended to body.system (idempotent, original preserved).
check("advisor: executor timing prompt prepended", String(advBody.system).startsWith("You have access to an `advisor` tool"), true);
check("advisor: original system preserved after timing block", String(advBody.system).includes("You are a coding agent."), true);
// The openai translate path filters tools to input_schema + string name; ours has both, so it survives.
const advTools = (await translateRequest({
  model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }],
})).request.tools;
check("advisor: survives openai filter", advTools?.some((t) => t.function?.name === "consult_advisor"), true);

// Guard: not injected when the env var is unset.
delete process.env.CORTI_ADVISOR_TOOL;
const advBody2 = { model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }], tools: [], system: "agent" };
await applyIntercepts(advBody2);
check("advisor: not injected when unset", advBody2.tools.length, 0);
// Timing prompt is NOT prepended when the advisor is off (system untouched).
check("advisor: no timing prompt when unset", advBody2.system === "agent", true);

// Transcript serializer (lib/advisor-transcript.mjs) — the heart of the official alignment.
// The advisor receives the full serialized context, not the executor focus string.
process.env.CORTI_ADVISOR_TOOL = "1";
const stubInput = []; // captures the serialized payload the stub receives
const stub = async (text) => { stubInput.length = 0; stubInput.push(text); return `stub advice`; };
const advBody3 = {
  model: "corti-s1", max_tokens: 16, system: "You are a coding agent.",
  tools: [{ name: "run_bash", description: "Run a bash command" }],
  messages: [
    { role: "user", content: "Fix the bug in app.js" },
    { role: "assistant", content: [
      { type: "thinking", thinking: "secret", signature: "x" },
      { type: "tool_use", id: "tu_adv1", name: "run_bash", input: { command: "cat app.js" } },
    ]},
    { role: "user", content: [{ type: "tool_result", tool_use_id: "tu_adv1", content: "const x = undefined;\nx.foo();" }] },
    { role: "assistant", content: [{ type: "tool_use", id: "tu_adv2", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "tu_adv2", content: "Unknown tool: consult_advisor", is_error: true }] },
  ],
};
await applyIntercepts(advBody3, { runAdvisor: stub });
const advResult = advBody3.messages[4].content[0];
check("advisor: result rewritten", advResult.content, "Advisor feedback:\n\nstub advice");
check("advisor: is_error cleared", advResult.is_error, false);
// The stub received the serialized transcript, not a focus string.
const ser = stubInput[0] || "";
check("advisor: stub receives serialized transcript (has executor_system_prompt)", ser.includes("<executor_system_prompt>"), true);
check("advisor: stub receives serialized transcript (has transcript block)", ser.includes("<transcript>"), true);
check("advisor: stub receives serialized transcript (has budget line)", ser.includes("remaining output budget"), true);
// The advisor tool itself is omitted from the forwarded <available_tools> block (recursion
// guard: the advisor must not see a tool it could call). It still appears in the transcript
// as the executor tool_use call, so scope the check to the tools block.
const toolsBlock = (ser.match(/<available_tools>([\s\S]*?)<\/available_tools>/) || [])[1] || "";
check("advisor: consult_advisor omitted from forwarded tool list", toolsBlock.includes("consult_advisor"), false);
// run_bash IS forwarded (the advisor needs to see the executor available tools).
check("advisor: run_bash forwarded in tool list", ser.includes("run_bash"), true);
// Thinking blocks are dropped (official: only the conclusion reaches the executor).
check("advisor: thinking omitted in transcript", ser.includes("[thinking omitted]"), true);
// Order: system prompt before transcript (stable prefix first).
check("advisor: system prompt precedes transcript", ser.indexOf("<executor_system_prompt>") < ser.indexOf("<transcript>"), true);
// The executor real tool result (the bug) reaches the advisor — the whole point.
check("advisor: executor tool result forwarded", ser.includes("x.foo()"), true);

// Truncation: large tool results are head/tail-truncated with an elision marker.
const big = "x".repeat(20000);
const truncBody = {
  model: "corti-s1", max_tokens: 16,
  messages: [
    { role: "assistant", content: [{ type: "tool_use", id: "tb1", name: "run_bash", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "tb1", content: big }] },
    { role: "assistant", content: [{ type: "tool_use", id: "tb2", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "tb2", content: "Unknown tool", is_error: true }] },
  ],
};
const truncCap = [];
await applyIntercepts(truncBody, { runAdvisor: async (t) => { truncCap.push(t); return "x"; } });
check("advisor: large tool result truncated with elision marker", (truncCap[0] || "").includes("chars elided"), true);

// Budget line uses CORTI_ADVISOR_MAX_TOKENS when set.
process.env.CORTI_ADVISOR_MAX_TOKENS = "768";
const budgetCap = [];
await applyIntercepts({
  model: "corti-s1", max_tokens: 16,
  messages: [
    { role: "assistant", content: [{ type: "tool_use", id: "bm1", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "bm1", content: "Unknown tool", is_error: true }] },
  ],
}, { runAdvisor: async (t) => { budgetCap.push(t); return "x"; } });
check("advisor: budget line honors CORTI_ADVISOR_MAX_TOKENS", (budgetCap[0] || "").includes("approximately 768 tokens"), true);
delete process.env.CORTI_ADVISOR_MAX_TOKENS;

// Idempotency: don\x27t inject twice if the tool is already present, and don\x27t re-prepend the
// timing block if it\x27s already there.
const advBody4 = { model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }], tools: [{ name: "consult_advisor", input_schema: { type: "object" } }], system: "You have access to an `advisor` tool backed by a stronger reviewer model.\n\nOriginal system." };
await applyIntercepts(advBody4);
check("advisor: no duplicate injection", advBody4.tools.filter((t) => t.name === "consult_advisor").length, 1);
check("advisor: no duplicate timing prompt", (String(advBody4.system).match(/You have access to an `advisor` tool/g) || []).length, 1);

// Fix #2c: the advisor continuation (continueAfterAdvisor) carries a consult_advisor
// tool_use + an already-populated tool_result. Without skipAdvisor, interceptConsultAdvisor
// matches that tool_result and re-spawns runAdvisor. skipAdvisor:true must suppress both
// the injection and the spawn. Mirrors the continuation body shape (assistant tool_use with
// EMPTY input + user tool_result) that the gateway builds in continueAfterAdvisor.
let stubCalls = 0;
const countingStub = async (text) => { stubCalls++; return `stub advice`; };
const continuationBody = {
  model: "corti-s1", max_tokens: 16,
  messages: [
    { role: "user", content: "should I ship this?" },
    { role: "assistant", content: [{ type: "tool_use", id: "tu_adv1", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "tu_adv1", content: "Advisor feedback:\n\nalready synthesized", is_error: false }] },
  ],
};
// Without skipAdvisor: the intercept re-spawns the advisor (regression guard — proves the
// fix is the skipAdvisor thread, not a broader no-op).
const leakBody = JSON.parse(JSON.stringify(continuationBody));
stubCalls = 0;
await applyIntercepts(leakBody, { runAdvisor: countingStub });
check("advisor continuation: re-injects WITHOUT skipAdvisor (regression guard)", stubCalls, 1);
// With skipAdvisor: no spawn, no injection, result preserved as-is.
const skipBody = JSON.parse(JSON.stringify(continuationBody));
stubCalls = 0;
await applyIntercepts(skipBody, { runAdvisor: countingStub, skipAdvisor: true });
check("advisor continuation: no re-spawn WITH skipAdvisor", stubCalls, 0);
check("advisor continuation: result preserved with skipAdvisor", skipBody.messages[2].content[0].content, "Advisor feedback:\n\nalready synthesized");
check("advisor continuation: no tool injected with skipAdvisor", Boolean(skipBody.tools?.some((t) => t?.name === "consult_advisor")), false);
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
