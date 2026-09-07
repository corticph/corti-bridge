#!/bin/sh
# Pure-function tests for translate.mjs. Zero dependencies, hermetic, offline —
# translateRequest never touches the network, so no credentials are needed.
#
# Run: sh test/translate.sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

node --input-type=module -e '
import { translateRequest, translateError, promptTooLong, applyIntercepts, createStreamTranslator, advisorContinuationErrorCode, translateCompletion, _resetAdvisorProcessed } from "'"$REPO"'/translate.mjs";
import { serializeAdvisorInput } from "'"$REPO"'/lib/advisor-transcript.mjs";

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

// --- advisor (consult_advisor) ------------------------------------------------
// Gating (translate.mjs:advisorWanted): one knob, CORTI_ADVISOR=auto|on|off.
//   auto (unset) → openai ON, anthropic OFF (the mode defaults)
//   on           → ON in both modes
//   off          → OFF in both modes
//   unrecognized → warn once, fall to auto
// skipAdvisor (the -noadvisor- recursion guard) is authoritative and wins over
// everything. CORTI_ADVISOR_TOOL is REMOVED from the code — the one clean-slate
// delete below clears any inherited value; it is never set again in this file.
// mode is threaded via opts (applyIntercepts/translateRequest spread opts → ctx.mode).
delete process.env.CORTI_ADVISOR;
delete process.env.CORTI_ADVISOR_TOOL;

// Block A — tool def injected. openai mode default-on (no env var needed).
const advBody = { model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }], system: "You are a coding agent." };
await applyIntercepts(advBody, { mode: "openai" });
check("advisor (openai): tool def injected", advBody.tools?.some((t) => t.name === "consult_advisor"), true);
// Empty input_schema: the executor signals timing only — the harness forwards the transcript.
// additionalProperties:false matters (models want to fill in a "question" field).
const advSchema = advBody.tools?.find((t) => t.name === "consult_advisor")?.input_schema;
check("advisor (openai): schema is empty (additionalProperties:false)",
  JSON.stringify(advSchema) === JSON.stringify({ type: "object", properties: {}, additionalProperties: false }), true);
// The executor-side timing block is prepended to body.system (idempotent, original preserved).
check("advisor (openai): executor timing prompt prepended", String(advBody.system).startsWith("You have access to an `advisor` tool"), true);
check("advisor (openai): original system preserved after timing block", String(advBody.system).includes("You are a coding agent."), true);
// The openai translate path filters tools to input_schema + string name; ours has both, so it survives.
const advTools = (await translateRequest({
  model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }],
}, { mode: "openai" })).request.tools;
check("advisor (openai): survives openai filter", advTools?.some((t) => t.function?.name === "consult_advisor"), true);

// Block B — opt-out: CORTI_ADVISOR=off turns the advisor off even in openai (default-on) mode.
process.env.CORTI_ADVISOR = "off";
const advBody2 = { model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }], tools: [], system: "agent" };
await applyIntercepts(advBody2, { mode: "openai" });
check("advisor (openai+off): not injected when off", advBody2.tools.length, 0);
// Timing prompt is NOT prepended when the advisor is off (system untouched).
check("advisor (openai+off): no timing prompt when off", advBody2.system === "agent", true);
delete process.env.CORTI_ADVISOR;

// Block C — transcript serializer (lib/advisor-transcript.mjs): the heart of the official
// alignment. The advisor receives the full serialized context, not the executor focus string.
// Advisor-ON path: pass mode:"openai" explicitly.
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
await applyIntercepts(advBody3, { runAdvisor: stub, mode: "openai" });
const advResult = advBody3.messages[4].content[0];
check("advisor (openai): result rewritten as <advisor_guidance>", advResult.content, "<advisor_guidance>\nstub advice\n</advisor_guidance>");
check("advisor (openai): is_error cleared", advResult.is_error, false);

// Failure path: when runAdvisor returns { ok:false, code }, the tool_result carries the
// failure (not a fake success), so the executor sees advice was unavailable and continues.
// Maps to the official advisor_tool_result_error error_code (e.g. execution_time_exceeded).
const failStub = async () => ({ ok: false, code: "execution_time_exceeded" });
const failBody = {
  model: "corti-s1", max_tokens: 16, system: "agent",
  messages: [
    { role: "user", content: "Fix the bug" },
    { role: "assistant", content: [{ type: "tool_use", id: "tu_f1", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "tu_f1", content: "Unknown tool: consult_advisor", is_error: true }] },
  ],
};
await applyIntercepts(failBody, { runAdvisor: failStub, mode: "openai" });
const failResult = failBody.messages[2].content[0];
check("advisor (openai): failure carries unavailable guidance, not fake advice",
  failResult.content, "<advisor_guidance>\nadvisor unavailable (execution_time_exceeded)\n</advisor_guidance>");
check("advisor (openai): failure is_error cleared (request does not fail)", failResult.is_error, false);
// The stub received the serialized transcript, not a focus string.
const ser = stubInput[0] || "";
check("advisor (openai): stub receives serialized transcript (has executor_system_prompt)", ser.includes("<executor_system_prompt>"), true);
check("advisor (openai): stub receives serialized transcript (has transcript block)", ser.includes("<transcript>"), true);
check("advisor (openai): stub receives serialized transcript (has budget line)", ser.includes("remaining output budget"), true);
// The advisor tool itself is omitted from the forwarded <available_tools> block (recursion
// guard: the advisor must not see a tool it could call). It still appears in the transcript
// as the executor tool_use call, so scope the check to the tools block.
const toolsBlock = (ser.match(/<available_tools>([\s\S]*?)<\/available_tools>/) || [])[1] || "";
check("advisor (openai): consult_advisor omitted from forwarded tool list", toolsBlock.includes("consult_advisor"), false);
// run_bash IS forwarded (the advisor needs to see the executor available tools).
check("advisor (openai): run_bash forwarded in tool list", ser.includes("run_bash"), true);
// Thinking blocks are dropped (official: only the conclusion reaches the executor).
check("advisor (openai): thinking omitted in transcript", ser.includes("[thinking omitted]"), true);
// Order: system prompt before transcript (stable prefix first).
check("advisor (openai): system prompt precedes transcript", ser.indexOf("<executor_system_prompt>") < ser.indexOf("<transcript>"), true);
// The executor real tool result (the bug) reaches the advisor — the whole point.
check("advisor (openai): executor tool result forwarded", ser.includes("x.foo()"), true);

// Block D — truncation: large tool results are head/tail-truncated with an elision marker.
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
await applyIntercepts(truncBody, { runAdvisor: async (t) => { truncCap.push(t); return "x"; }, mode: "openai" });
check("advisor (openai): large tool result truncated with elision marker", (truncCap[0] || "").includes("chars elided"), true);

// Block E — budget line uses CORTI_ADVISOR_MAX_TOKENS when set.
process.env.CORTI_ADVISOR_MAX_TOKENS = "768";
const budgetCap = [];
await applyIntercepts({
  model: "corti-s1", max_tokens: 16,
  messages: [
    { role: "assistant", content: [{ type: "tool_use", id: "bm1", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "bm1", content: "Unknown tool", is_error: true }] },
  ],
}, { runAdvisor: async (t) => { budgetCap.push(t); return "x"; }, mode: "openai" });
check("advisor (openai): budget line honors CORTI_ADVISOR_MAX_TOKENS", (budgetCap[0] || "").includes("approximately 768 tokens"), true);
delete process.env.CORTI_ADVISOR_MAX_TOKENS;

// Block F — idempotency: don\x27t inject twice if the tool is already present, and don\x27t re-prepend
// the timing block if it\x27s already there. Advisor-ON path (mode:"openai") so the guard actually runs.
const advBody4 = { model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }], tools: [{ name: "consult_advisor", input_schema: { type: "object" } }], system: "You have access to an `advisor` tool backed by a stronger reviewer model.\n\nOriginal system." };
await applyIntercepts(advBody4, { mode: "openai" });
check("advisor (openai): no duplicate injection", advBody4.tools.filter((t) => t.name === "consult_advisor").length, 1);
check("advisor (openai): no duplicate timing prompt", (String(advBody4.system).match(/You have access to an `advisor` tool/g) || []).length, 1);

// Block G — continuation (continueAfterAdvisor) carries a consult_advisor tool_use + an
// already-populated tool_result. Without skipAdvisor, interceptConsultAdvisor matches that
// tool_result and re-spawns runAdvisor. skipAdvisor:true must suppress both the injection and
// the spawn. Mirrors the continuation body shape (assistant tool_use with EMPTY input + user
// tool_result) that the gateway builds in continueAfterAdvisor. Advisor-ON via mode:"openai".
let stubCalls = 0;
const countingStub = async (text) => { stubCalls++; return `stub advice`; };
const continuationBody = {
  model: "corti-s1", max_tokens: 16,
  messages: [
    { role: "user", content: "should I ship this?" },
    { role: "assistant", content: [{ type: "tool_use", id: "tu_adv1", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "tu_adv1", content: "<advisor_guidance>\nalready synthesized\n</advisor_guidance>", is_error: false }] },
  ],
};
// Without skipAdvisor: the intercept re-spawns the advisor (regression guard — proves the
// fix is the skipAdvisor thread, not a broader no-op).
const leakBody = JSON.parse(JSON.stringify(continuationBody));
stubCalls = 0;
await applyIntercepts(leakBody, { runAdvisor: countingStub, mode: "openai" });
check("advisor continuation: re-injects WITHOUT skipAdvisor (regression guard)", stubCalls, 1);
// With skipAdvisor: no spawn, no injection, result preserved as-is. skipAdvisor wins over the
// openai default-on (no CORTI_ADVISOR needed — skipAdvisor is checked first in advisorWanted).
const skipBody = JSON.parse(JSON.stringify(continuationBody));
stubCalls = 0;
await applyIntercepts(skipBody, { runAdvisor: countingStub, skipAdvisor: true, mode: "openai" });
check("advisor continuation: no re-spawn WITH skipAdvisor", stubCalls, 0);
check("advisor continuation: result preserved with skipAdvisor", skipBody.messages[2].content[0].content, "<advisor_guidance>\nalready synthesized\n</advisor_guidance>");
check("advisor continuation: no tool injected with skipAdvisor", Boolean(skipBody.tools?.some((t) => t?.name === "consult_advisor")), false);

// Block G2 — C1: the advisor continuation upstream status maps to an advisor_tool_result_error
// code, never parsed as a completion. The continuation cannot retry (advice SSE already written,
// invariant #3), so a non-2xx must surface as an error result; the harness renders the decline
// line and the executor continues without advice. A live incident saw 5xx on the continuation
// swallowed as a blank text block, silently ending the turn.
check("C1: 2xx is success (null)", advisorContinuationErrorCode(200), null);
check("C1: 429 too_many_requests", advisorContinuationErrorCode(429), "too_many_requests");
check("C1: 503 overloaded", advisorContinuationErrorCode(503), "overloaded");
check("C1: 529 overloaded", advisorContinuationErrorCode(529), "overloaded");
check("C1: 500 unavailable", advisorContinuationErrorCode(500), "unavailable");
check("C1: 502 unavailable", advisorContinuationErrorCode(502), "unavailable");
check("C1: 504 unavailable", advisorContinuationErrorCode(504), "unavailable");
check("C1: 400 unavailable", advisorContinuationErrorCode(400), "unavailable");

// Block G3 — A1: a consult_advisor tool_result the harness re-sends on a later turn must NOT
// re-spawn the advisor. The bug is cross-turn: the harness re-sends the raw "Unknown tool" error
// each turn, and a request-scoped set cannot remember across requests, so the dedup cache is
// per-session (advisorProcessed), shared across the two calls below. Two-call form is required:
// a single call legitimately processes all N prior consults (N spawns), so stubCalls<=1 is wrong.
_resetAdvisorProcessed();
let a1Calls = 0;
const a1Stub = async () => { a1Calls++; return `advice ${a1Calls}`; };
const a1Body = {
  model: "corti-s1", max_tokens: 16, system: "agent",
  messages: [
    { role: "user", content: "go" },
    { role: "assistant", content: [{ type: "tool_use", id: "a1_1", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "a1_1", content: "Unknown tool: consult_advisor", is_error: true }] },
    { role: "assistant", content: [{ type: "tool_use", id: "a1_2", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "a1_2", content: "Unknown tool: consult_advisor", is_error: true }] },
    { role: "assistant", content: [{ type: "tool_use", id: "a1_3", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "a1_3", content: "Unknown tool: consult_advisor", is_error: true }] },
  ],
};
const a1Cache = new Map();
a1Calls = 0;
await applyIntercepts(JSON.parse(JSON.stringify(a1Body)), { runAdvisor: a1Stub, advisorProcessed: a1Cache, mode: "openai" });
check("A1: first turn spawns once per prior consult (3)", a1Calls, 3);
check("A1: first turn caches all 3 ids", a1Cache.size, 3);
a1Calls = 0;
const a1Body2 = JSON.parse(JSON.stringify(a1Body));
await applyIntercepts(a1Body2, { runAdvisor: a1Stub, advisorProcessed: a1Cache, mode: "openai" });
check("A1: second turn re-spawns 0 (cross-turn dedup)", a1Calls, 0);
check("A1: second turn rewrites from cache (guidance present)", a1Body2.messages[2].content[0].content.startsWith("<advisor_guidance>"), true);
check("A1: second turn clears is_error", a1Body2.messages[2].content[0].is_error, false);
// Isolation: a different session (no shared cache) re-runs for ids it has not seen. The module
// map keys by parentSessionId; an unseen session gets a fresh map and spawns normally.
_resetAdvisorProcessed();
a1Calls = 0;
await applyIntercepts(JSON.parse(JSON.stringify(a1Body)), { runAdvisor: a1Stub, parentSessionId: "sess-other", mode: "openai" });
check("A1: a different session is not blocked by another", a1Calls, 3);
// No session id: dedup must be OFF — a missing x-claude-code-session-id has no safe cross-request
// key, so each call gets a throwaway map and re-spawns (no shared "__untracked__" bucket).
_resetAdvisorProcessed();
a1Calls = 0;
await applyIntercepts(JSON.parse(JSON.stringify(a1Body)), { runAdvisor: a1Stub, mode: "openai" });
check("A1: no session id still spawns (3)", a1Calls, 3);
a1Calls = 0;
await applyIntercepts(JSON.parse(JSON.stringify(a1Body)), { runAdvisor: a1Stub, mode: "openai" });
check("A1: no session id re-spawns on replay (no cross-request cache)", a1Calls, 3);

// Block H — C6: prior-turn advisor advice round-trips into history instead of being dropped.
// advisor_tool_result is NOT in SERVER_BLOCK_TYPES (only server_tool_use is); before the fix it
// fell through to the drop branch. Now it renders as <advisor_guidance> text the model keeps.
// Build a body whose assistant history carries an advisor_tool_result and translate it; the
// advice must land in the assistant message text, not in the dropped diagnostics.
const histBody = {
  model: "corti-s1", max_tokens: 16, system: "agent",
  messages: [
    { role: "user", content: "Fix the bug" },
    { role: "assistant", content: [
      { type: "text", text: "Let me consult the advisor." },
      { type: "server_tool_use", id: "srv1", name: "advisor", input: {} },
      { type: "advisor_tool_result", tool_use_id: "srv1", content: { type: "advisor_result", text: "Use a channel-based pattern; drain in-flight work on shutdown.", stop_reason: "end_turn" } },
      { type: "text", text: "Here is the implementation." },
    ]},
    { role: "user", content: "Now add a max-in-flight limit." },
  ],
};
const histOut = await translateRequest(histBody, { mode: "openai" });
const histAssist = histOut.request.messages.find((m) => m.role === "assistant" && typeof m.content === "string" && m.content.includes("implementation"));
check("advisor C6: prior advice kept in assistant history (not dropped)",
  histAssist?.content?.includes("Use a channel-based pattern"), true);
check("advisor C6: prior advice wrapped in <advisor_guidance> tag",
  histAssist?.content?.includes("<advisor_guidance>"), true);
check("advisor C6: advisor_tool_result not in dropped diagnostics",
  histOut.dropped.some((d) => /advisor_tool_result \(assistant history\)/.test(d)), false);
// The paired server_tool_use is still dropped (the executor doesn\x27t need the call shape).
check("advisor C6: server_tool_use still dropped from history",
  histOut.dropped.some((d) => /server_tool_use \(assistant history\)/.test(d)), true);

// Block H2 — C6: a prior advisor_tool_result_error also round-trips (as an unavailable note).
const histErrBody = {
  model: "corti-s1", max_tokens: 16, system: "agent",
  messages: [
    { role: "user", content: "Fix the bug" },
    { role: "assistant", content: [
      { type: "advisor_tool_result", tool_use_id: "srv2", content: { type: "advisor_tool_result_error", error_code: "overloaded" } },
    ]},
    { role: "user", content: "Retry?" },
  ],
};
const histErrOut = await translateRequest(histErrBody, { mode: "openai" });
const histErrAssist = histErrOut.request.messages.find((m) => m.role === "assistant");
check("advisor C6: error advice kept as unavailable note", histErrAssist?.content?.includes("advisor unavailable (overloaded)"), true);

// Block H3 — C6 advisor-side: the advisor\x27s OWN serializer (lib/advisor-transcript.mjs) must
// surface prior advisor_tool_result advice in the transcript it sends to the advisor child.
// Before the fix the block hit the default case and emitted only "[advisor_tool_result]",
// so the advisor couldn\x27t see what it said last turn — breaking its reconcile guidance.
const advSerBody = {
  model: "corti-s1", max_tokens: 16, system: "agent",
  messages: [
    { role: "user", content: "Fix the bug" },
    { role: "assistant", content: [
      { type: "server_tool_use", id: "srv3", name: "advisor", input: {} },
      { type: "advisor_tool_result", tool_use_id: "srv3", content: { type: "advisor_result", text: "Drain in-flight work on shutdown before closing the channel.", stop_reason: "end_turn" } },
    ]},
    { role: "assistant", content: [{ type: "tool_use", id: "tu_adv3", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "tu_adv3", content: "Unknown tool", is_error: true }] },
  ],
};
const advSerText = serializeAdvisorInput(advSerBody).text;
check("advisor C6 advisor-side: prior advice surfaced in transcript (not just a label)",
  advSerText.includes("Drain in-flight work on shutdown"), true);
check("advisor C6 advisor-side: prior advice marked as advisor guidance line",
  advSerText.includes("advisor guidance:"), true);
// A prior error also surfaces as a note (the advisor can see the prior consult failed).
const advSerErrBody = {
  model: "corti-s1", max_tokens: 16, system: "agent",
  messages: [
    { role: "assistant", content: [{ type: "advisor_tool_result", tool_use_id: "srv4", content: { type: "advisor_tool_result_error", error_code: "overloaded" } }] },
    { role: "assistant", content: [{ type: "tool_use", id: "tu_adv4", name: "consult_advisor", input: {} }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "tu_adv4", content: "Unknown tool", is_error: true }] },
  ],
};
const advSerErrText = serializeAdvisorInput(advSerErrBody).text;
check("advisor C6 advisor-side: prior error surfaces as unavailable note",
  advSerErrText.includes("advisor unavailable (overloaded)"), true);

// Block I — C2: advisorEffort overrides reasoning_effort (the advisor child reasons at high,
// not the medium adaptive maps to). The gateway passes advisorEffort for the advisor child.
const noThink = await translateRequest({ model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }] }, { advisorEffort: "high" });
check("advisor C2: advisorEffort=high overrides even with no thinking block", noThink.request.reasoning_effort, "high");
const adaptiveMed = await translateRequest({ model: "corti-s1", max_tokens: 16, thinking: { type: "adaptive" }, messages: [{ role: "user", content: "hi" }] }, { advisorEffort: "high" });
check("advisor C2: advisorEffort=high overrides adaptive→medium", adaptiveMed.request.reasoning_effort, "high");
const budgetLow = await translateRequest({ model: "corti-s1", max_tokens: 16, thinking: { type: "enabled", budget_tokens: 1024 }, messages: [{ role: "user", content: "hi" }] }, { advisorEffort: "high" });
check("advisor C2: advisorEffort=high overrides low budget mapping", budgetLow.request.reasoning_effort, "high");
// Without advisorEffort, the thinking mapping is untouched (regression guard).
const noOverride = await translateRequest({ model: "corti-s1", max_tokens: 16, thinking: { type: "adaptive" }, messages: [{ role: "user", content: "hi" }] });
check("advisor C2: no advisorEffort leaves adaptive→medium untouched", noOverride.request.reasoning_effort, "medium");
// CORTI_ADVISOR_EFFORT overrides the default — read at call time by the gateway (not tested here
// at the translate level, which only honors the explicit opt).

// --- gating matrix ------------------------------------------------------------
// Full truth table for advisorWanted(mode, skipAdvisor) × CORTI_ADVISOR. Each case clears
// CORTI_ADVISOR before and after so cases are order-independent. The advisor body has no
// consult_advisor tool_use, so injection is the only observable: tools.some(name match).
// applyIntercepts mutates the body in place and returns diagnostics, so run it on a fresh
// body and read tools off the body, not the return value.
const gateBody = () => ({ model: "corti-s1", max_tokens: 16, messages: [{ role: "user", content: "hi" }] });
const injected = (b) => Boolean(b.tools?.some((t) => t?.name === "consult_advisor"));
const runGate = async (opts) => { const b = gateBody(); await applyIntercepts(b, opts); return b; };

// auto (unset) + openai → ON
delete process.env.CORTI_ADVISOR;
check("gate: auto + openai → ON", injected(await runGate({ mode: "openai" })), true);
delete process.env.CORTI_ADVISOR;
// auto (unset) + anthropic → OFF
check("gate: auto + anthropic → OFF", injected(await runGate({ mode: "anthropic" })), false);
delete process.env.CORTI_ADVISOR;

// on + openai → ON
process.env.CORTI_ADVISOR = "on";
check("gate: on + openai → ON", injected(await runGate({ mode: "openai" })), true);
delete process.env.CORTI_ADVISOR;
// on + anthropic → ON
process.env.CORTI_ADVISOR = "on";
check("gate: on + anthropic → ON", injected(await runGate({ mode: "anthropic" })), true);
delete process.env.CORTI_ADVISOR;

// off + openai → OFF
process.env.CORTI_ADVISOR = "off";
check("gate: off + openai → OFF", injected(await runGate({ mode: "openai" })), false);
delete process.env.CORTI_ADVISOR;
// off + anthropic → OFF
process.env.CORTI_ADVISOR = "off";
check("gate: off + anthropic → OFF", injected(await runGate({ mode: "anthropic" })), false);
delete process.env.CORTI_ADVISOR;

// Case-insensitive and whitespace-tolerant: OFF (uppercase) and padded ON parse as off/on,
// not as unrecognized values that silently fall back to the mode default.
process.env.CORTI_ADVISOR = "OFF";
check("gate: OFF (uppercase) + openai → OFF", injected(await runGate({ mode: "openai" })), false);
delete process.env.CORTI_ADVISOR;
process.env.CORTI_ADVISOR = " ON ";
check("gate: padded ON + anthropic → ON", injected(await runGate({ mode: "anthropic" })), true);
delete process.env.CORTI_ADVISOR;

// skipAdvisor:true → OFF in both modes (wins over on, and over the openai default-on).
process.env.CORTI_ADVISOR = "on";
check("gate: skipAdvisor wins over on (openai)", injected(await runGate({ skipAdvisor: true, mode: "openai" })), false);
delete process.env.CORTI_ADVISOR;
check("gate: skipAdvisor wins over default-on (openai)", injected(await runGate({ skipAdvisor: true, mode: "openai" })), false);
process.env.CORTI_ADVISOR = "on";
check("gate: skipAdvisor wins over on (anthropic)", injected(await runGate({ skipAdvisor: true, mode: "anthropic" })), false);
delete process.env.CORTI_ADVISOR;

// Unrecognized value (not auto/on/off) → warns once, falls to auto. Two openai calls with the
// bad value: both inject (auto → openai ON), but the warning fires exactly once. Capture
// console.error via a spy so we can assert both the message and the once-only guard.
process.env.CORTI_ADVISOR = "maybe";
const errSpy = [];
const origErr = console.error;
console.error = (...a) => { errSpy.push(a.join(" ")); };
try {
  await runGate({ mode: "openai" });
  await runGate({ mode: "openai" });
} finally {
  console.error = origErr;
}
check("gate: unrecognized + openai → ON (falls to auto)", injected(await runGate({ mode: "openai" })), true);
delete process.env.CORTI_ADVISOR;
check("gate: unrecognized value warns once", errSpy.filter((m) => m.includes("unrecognized CORTI_ADVISOR")).length, 1);
// (warnedAdvisorVar is process-scoped; it stays true for the rest of this run — that\x27s fine,
// it\x27s the once-per-process guard being exercised. No further assertions depend on it firing.)

// undefined mode + no vars → OFF (legacy bare-call behavior: mode === undefined ≠ "openai").
delete process.env.CORTI_ADVISOR;
check("gate: undefined mode + no vars → OFF", injected(await runGate()), false);
delete process.env.CORTI_ADVISOR;

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

// --- A1: mid-conversation role:system stays out of the system prefix ------------
// A harness-injected reminder as a top-level role:system in body.messages must land as
// user content in the stream, NOT folded into messages[0] (the cached system prefix).
const a1top = (await translateRequest({
  model: "corti-s1", max_tokens: 16, system: "base system prompt",
  messages: [
    { role: "user", content: "hi" },
    { role: "system", content: "The task tools haven\x27t been used recently." },
    { role: "user", content: "bye" },
  ],
})).request;
check("A1 top: messages[0] is system", a1top.messages[0]?.role === "system", true);
check("A1 top: prefix is body.system only", a1top.messages[0]?.content === "base system prompt", true);
const a1relocated = a1top.messages.find((m) => m.role === "user" && /task tools haven/.test(m.content));
check("A1 top: reminder relocated to a user message", !!a1relocated, true);

// A mid_conv_system block inside a user message must likewise stay in the user content,
// not get promoted into the system prefix.
const a1mc = (await translateRequest({
  model: "corti-s1", max_tokens: 16, system: "base system prompt",
  messages: [{
    role: "user",
    content: [
      { type: "mid_conv_system", content: [{ type: "text", text: "mid conv reminder" }] },
      { type: "text", text: "actual user text" },
    ],
  }],
})).request;
check("A1 mid_conv: prefix is body.system only", a1mc.messages[0]?.content === "base system prompt", true);
const a1mcuser = a1mc.messages.find((m) => m.role === "user" && /mid conv reminder/.test(m.content));
check("A1 mid_conv: reminder stays in user content", !!a1mcuser, true);

// --- A2: message_start seeds the prompt estimate; message_delta carries the real value ---
// The live per-agent counter reads the message_start value off each streamed event; the
// estimate is its only growth signal. message_delta overrides it for the statusline.
const a2events = [];
const a2ctx = { msgId: "msg_test", requestedModel: "corti-s1", reasoningMode: "drop", estimatedInput: 12345 };
const a2tx = createStreamTranslator(a2ctx, (ev, data) => a2events.push({ ev, data }));
a2tx.feed({ choices: [{ delta: { content: "pong" } }] });
a2tx.done();
const a2start = a2events.find((e) => e.ev === "message_start");
check("A2: message_start seeds the estimate", a2start?.data?.message?.usage?.input_tokens, 12345);
const a2delta = a2events.find((e) => e.ev === "message_delta");
check("A2: message_delta follows message_start", !!a2delta, true);
check("A2: message_delta input_tokens is non-zero (no double-count)", a2delta?.data?.usage?.input_tokens > 0, true);

// --- A2b: anthropicUsage floors input_tokens at 1 on a fully-cached turn (no double-count) ---
const a2bevents = [];
const a2bctx = { msgId: "msg_test2", requestedModel: "corti-s1", reasoningMode: "drop", estimatedInput: 50000 };
const a2btx = createStreamTranslator(a2bctx, (ev, data) => a2bevents.push({ ev, data }));
a2btx.feed({ choices: [{ delta: { content: "x" } }] });
// Fully cached: prompt_tokens == cached_tokens, created_cache_tokens 0 -> remainder 0.
a2btx.feed({ usage: { prompt_tokens: 50000, completion_tokens: 7, prompt_tokens_details: { cached_tokens: 50000, created_cache_tokens: 0 } } });
a2btx.done();
const a2bdelta = a2bevents.find((e) => e.ev === "message_delta");
check("A2b: fully-cached turn input_tokens floored at 1 (not 0)", a2bdelta?.data?.usage?.input_tokens, 1);
check("A2b: fully-cached turn cache_read preserved", a2bdelta?.data?.usage?.cache_read_input_tokens, 50000);

// --- D1: translateCompletion generates a fallback tool_use id when upstream omits it. The
// streaming path already does (translate.mjs:1301); the non-streaming path used call.id directly,
// so a missing id left id:undefined and the harness could not pair the tool_result -> broken loop.
const d1ctx = { msgId: "msg_d1", requestedModel: "corti-s1", reasoningMode: "drop" };
const d1msg = translateCompletion({
  choices: [{ index: 0, message: { role: "assistant", content: null, tool_calls: [{ index: 0, function: { name: "run_bash", arguments: "{}" } }] }, finish_reason: "tool_calls" }],
  usage: { prompt_tokens: 1, completion_tokens: 1 },
}, d1ctx);
check("D1: missing tool_call id gets a fallback", typeof d1msg.content[0].id === "string" && d1msg.content[0].id.startsWith("chatcmpl-tool-local-"), true);
// A present id is preserved verbatim (no fallback clobber).
const d1pres = translateCompletion({
  choices: [{ index: 0, message: { role: "assistant", content: null, tool_calls: [{ id: "call_abc", function: { name: "run_bash", arguments: "{}" } }] }, finish_reason: "tool_calls" }],
  usage: { prompt_tokens: 1, completion_tokens: 1 },
}, d1ctx);
check("D1: present tool_call id preserved", d1pres.content[0].id, "call_abc");

console.log("");
if (failed === 0) { console.log("all checks passed"); process.exit(0); }
console.log(`${failed} check(s) failed`);
process.exit(1);
'
