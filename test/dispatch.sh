#!/bin/sh
# Mode-dispatch tests: ONE gateway process serving BOTH upstream modes, selected per request
# by URL path prefix. Zero dependencies beyond node + openssl (skipped without the latter).
#
# The gateway only accepts a real Corti URL, so this runs against a copy with that check
# relaxed to localhost. Never point CORTI_PROXY_DIR at a live clone when running lifecycle
# tests — the pattern-kill fallback matches by clone path.
#
# Run: sh test/dispatch.sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
FAILED=0
STUB_PID=""
GW_PID=""
GW_PORT=4298

cleanup() {
  [ -n "$GW_PID" ] && { kill "$GW_PID" 2>/dev/null || :; wait "$GW_PID" 2>/dev/null || :; }
  [ -n "$STUB_PID" ] && { kill "$STUB_PID" 2>/dev/null || :; wait "$STUB_PID" 2>/dev/null || :; }
  [ -n "${C1_GW_PID:-}" ] && { kill "$C1_GW_PID" 2>/dev/null || :; wait "$C1_GW_PID" 2>/dev/null || :; }
  [ -n "${C1STUB_PID:-}" ] && { kill "$C1STUB_PID" 2>/dev/null || :; wait "$C1STUB_PID" 2>/dev/null || :; }
  [ -n "${C1_OK_GW_PID:-}" ] && { kill "$C1_OK_GW_PID" 2>/dev/null || :; wait "$C1_OK_GW_PID" 2>/dev/null || :; }
  [ -n "${C1OKSTUB_PID:-}" ] && { kill "$C1OKSTUB_PID" 2>/dev/null || :; wait "$C1OKSTUB_PID" 2>/dev/null || :; }
  [ -n "${C1_ABORT_GW_PID:-}" ] && { kill "$C1_ABORT_GW_PID" 2>/dev/null || :; wait "$C1_ABORT_GW_PID" 2>/dev/null || :; }
  [ -n "${C1ABORTSTUB_PID:-}" ] && { kill "$C1ABORTSTUB_PID" 2>/dev/null || :; wait "$C1ABORTSTUB_PID" 2>/dev/null || :; }
  [ -n "${C1_SETTLE_GW_PID:-}" ] && { kill "$C1_SETTLE_GW_PID" 2>/dev/null || :; wait "$C1_SETTLE_GW_PID" 2>/dev/null || :; }
  [ -n "${C1SETTLESTUB_PID:-}" ] && { kill "$C1SETTLESTUB_PID" 2>/dev/null || :; wait "$C1SETTLESTUB_PID" 2>/dev/null || :; }
  [ -n "${C1_ERR_GW_PID:-}" ] && { kill "$C1_ERR_GW_PID" 2>/dev/null || :; wait "$C1_ERR_GW_PID" 2>/dev/null || :; }
  [ -n "${C1ERRSTUB_PID:-}" ] && { kill "$C1ERRSTUB_PID" 2>/dev/null || :; wait "$C1ERRSTUB_PID" 2>/dev/null || :; }
  [ -n "${C1_PT_GW_PID:-}" ] && { kill "$C1_PT_GW_PID" 2>/dev/null || :; wait "$C1_PT_GW_PID" 2>/dev/null || :; }
  [ -n "${C1PTSTUB_PID:-}" ] && { kill "$C1PTSTUB_PID" 2>/dev/null || :; wait "$C1PTSTUB_PID" 2>/dev/null || :; }
  [ -n "${CALSTUB_PID:-}" ] && { kill "$CALSTUB_PID" 2>/dev/null || :; wait "$CALSTUB_PID" 2>/dev/null || :; }
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

check() {
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"
    FAILED=$((FAILED + 1))
  fi
}

# Bounded wait for a gateway's startup banner in its log. A crash at boot never prints the
# banner; without a bound the wait would spin forever and mask the failure as a hang.
wait_banner() {
  _wb_log="$1"; _wb_i=0
  while [ "$_wb_i" -lt 100 ]; do
    grep -q "corti-proxy on" "$_wb_log" 2>/dev/null && return 0
    _wb_i=$((_wb_i + 1)); sleep 0.1
  done
  return 1
}

if ! command -v openssl >/dev/null 2>&1; then
  printf 'skip dispatch tests (openssl not installed)\n'
  exit 0
fi

cd "$SCRATCH"
ln -s "$REPO/translate.mjs" translate.mjs
ln -s "$REPO/lib" lib
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 1 \
  -subj "/CN=127.0.0.1" >/dev/null 2>&1

# Upstream that reports which of its two endpoints was hit, so the assertions can prove
# which mode the gateway actually chose rather than just that it answered.
cat > stub.mjs <<'STUBEOF'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    req.resume();
    req.on("end", () => {
      res.writeHead(200, { "content-type": "application/json" });
      if (req.url.startsWith("/anthropic/"))
        return res.end(JSON.stringify({ id: "m", type: "message", role: "assistant",
          content: [{ type: "text", text: "ANTHROPIC" }], model: "corti-s1",
          stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 } }));
      res.end(JSON.stringify({ id: "c", choices: [{ index: 0,
        message: { role: "assistant", content: "OPENAI" }, finish_reason: "stop" }],
        usage: { prompt_tokens: 1, completion_tokens: 1 } }));
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`PORT=${s.address().port}`));
STUBEOF

sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > gateway.mjs

node stub.mjs > stub.out 2>&1 &
STUB_PID=$!
UP=""
while [ -z "$UP" ]; do UP=$(sed -n 's/^PORT=//p' stub.out); done

CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$UP/v1" \
CORTI_PORT="$GW_PORT" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node gateway.mjs > gw.out 2>&1 &
GW_PID=$!
while ! grep -q "corti-proxy on" gw.out 2>/dev/null; do :; done

G="http://127.0.0.1:$GW_PORT"
BODY='{"model":"corti-s1","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'
post() { curl -s -m 10 -H 'content-type: application/json' -d "$BODY" "$G$1"; }
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'content-type: application/json' -d "$BODY" "$G$1"; }

# A bare path is the translating route; the prefix selects raw pass-through.
check "bare /v1/messages routes to the openai upstream" \
  "$(post /v1/messages | grep -c OPENAI)" "1"
check "/anthropic/v1/messages routes to the anthropic upstream" \
  "$(post /anthropic/v1/messages | grep -c ANTHROPIC)" "1"

# The openai route translates; pass-through must hand back upstream's bytes untouched.
check "openai route emits a translated Anthropic message envelope" \
  "$(post /v1/messages | grep -c '"type":"message"')" "1"
check "pass-through route returns upstream bytes untranslated" \
  "$(post /anthropic/v1/messages | grep -c '"id":"m"')" "1"

# Prefix matching is anchored: these must NOT be treated as pass-through.
check "/v1/anthropic/messages stays on the openai route" "$(code /v1/anthropic/messages)" "404"
check "/anthropicabc/v1/messages stays on the openai route" "$(code /anthropicabc/v1/messages)" "404"

# count_tokens is answered locally on both routes.
check "count_tokens answered locally, bare" \
  "$(post /v1/messages/count_tokens | grep -c input_tokens)" "1"
check "count_tokens answered locally, prefixed" \
  "$(post /anthropic/v1/messages/count_tokens | grep -c input_tokens)" "1"

# /health must stay unprefixed — the wrapper curls it before it knows the session's mode.
check "/health is served unprefixed" \
  "$(curl -s -m 10 "$G/health" | grep -c '"status":"healthy"')" "1"
check "/health reports a gatewayVersion" \
  "$(curl -s -m 10 "$G/health" | grep -c '"gatewayVersion"')" "1"
check "/health reports bare-path mode as openai" \
  "$(curl -s -m 10 "$G/health" | grep -c '"mode":"openai"')" "1"

# The mode marker on the auth token is the only signal that survives URL resolution, so it is
# what catches a client silently dropping the path prefix.
auth() { curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'content-type: application/json' \
  -H "authorization: Bearer $1" -d "$BODY" "$G$2"; }
check "anthropic marker on a bare path is rejected loudly" \
  "$(auth local-gateway-anthropic /v1/messages)" "400"
check "anthropic marker on the prefixed path is fine" \
  "$(auth local-gateway-anthropic /anthropic/v1/messages)" "200"
check "openai marker on a bare path is fine" \
  "$(auth local-gateway-openai /v1/messages)" "200"
check "an unmarked token still routes by path" \
  "$(auth local-gateway /v1/messages)" "200"

# Claude Code probes this against the base URL; both routes answer it locally.
check "HEAD /api/hello answered locally, bare" \
  "$(curl -s -m 10 -I -o /dev/null -w '%{http_code}' "$G/api/hello")" "200"
check "HEAD /api/hello answered locally, prefixed" \
  "$(curl -s -m 10 -I -o /dev/null -w '%{http_code}' "$G/anthropic/api/hello")" "200"

# --- C1 e2e: a continuation non-2xx ends the turn with a text note, not a second
# advisor_tool_result_error and not a blank block. A separate upstream stub returns a
# consult_advisor tool_call on the first (streaming) request — triggering hold-and-continue —
# then 500 on the continuation (the 2nd request, which carries the synthesized tool_result). The
# advisor child is stubbed via CORTI_ADVISOR_STUB so no live headless session is spawned.
cat > advisor-stub.sh <<'ADVSTUB'
#!/bin/sh
cat >/dev/null  # discard the transcript
printf '{"ok":true,"text":"stub advisor advice"}'
ADVSTUB
chmod +x advisor-stub.sh

cat > c1stub.mjs <<'C1STUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      // After translateRequest, the continuation's consult_advisor tool_result becomes an OpenAI
      // tool-role message (role:"tool" + tool_call_id); the literal Anthropic "tool_result" is
      // gone from the translated body. Detect by that shape, not by the Anthropic block name.
      const isContinuation = body.includes('"role":"tool"') && body.includes('"tool_call_id"');
      if (isContinuation) {
        // The continuation call after the advisor succeeded: fail with 500.
        res.writeHead(500, { "content-type": "application/json" });
        return res.end(JSON.stringify({ error: { message: "upstream overloaded" } }));
      }
      // First (streaming) request: end on a consult_advisor tool_call via SSE so the streaming
      // translator's finish() detects it and fires onAdvisorToolUse (hold-and-continue).
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_c1","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n');
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
      res.end('data: [DONE]\n\n');
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`C1PORT=${s.address().port}`));
C1STUB

node c1stub.mjs > c1stub.out 2>&1 &
C1STUB_PID=$!
C1UP=""
while [ -z "$C1UP" ]; do C1UP=$(sed -n 's/^C1PORT=//p' c1stub.out); done

C1_GW_PORT=4299
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > c1gateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1UP/v1" \
CORTI_PORT="$C1_GW_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1gateway.mjs > c1gw.out 2>&1 &
C1_GW_PID=$!
wait_banner c1gw.out || { echo "FAIL C1 gateway did not start" >&2; FAILED=$((FAILED + 1)); }

C1G="http://127.0.0.1:$C1_GW_PORT"
C1BODY='{"model":"corti-s1","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"advise me"}]}'
# `|| true` so a gateway that crashes mid-stream (curl exits non-zero, e.g. 18 partial) yields a
# partial/empty C1RESP and clean FAIL lines, instead of set -e aborting before the checks run.
C1RESP=$(curl -s -m 15 -N -H 'content-type: application/json' -d "$C1BODY" "$C1G/v1/messages" 2>&1 || true)

# set +e: a crashed gateway yields partial/empty C1RESP; the grep -c calls below then exit 1 on
# zero matches, which set -e would turn into a silent abort. We want clean FAIL lines instead.
set +e
check "C1: continuation 500 ends with the text note" \
  "$(printf '%s' "$C1RESP" | grep -c 'the follow-up response failed')" "1"
# The non-2xx note names the upstream status; the thrown/catch path names an error message
# instead. Asserting this proves the stub's 500 path was actually taken, not a parse-error catch.
check "C1: note names upstream 500 (non-2xx path taken)" \
  "$(printf '%s' "$C1RESP" | grep -c 'upstream 500')" "1"
check "C1: no second advisor_tool_result_error after success" \
  "$(printf '%s' "$C1RESP" | grep -c 'advisor_tool_result_error')" "0"
# Twice: once in the advisor_tool_result block the harness renders, and once repeated verbatim
# inside the failure note. The harness does not replay advisor blocks into the next request's
# history, so the note is the only copy that survives into the model's context.
check "C1: failure note repeats the advice verbatim" \
  "$(printf '%s' "$C1RESP" | grep -c 'stub advisor advice')" "2"
check "C1: failure note wraps the advice in advisor_guidance" \
  "$(printf '%s' "$C1RESP" | grep -c 'advisor_guidance')" "1"
# The terminal message_delta carries end_turn; the advisor_result block also carries stop_reason
# end_turn, so assert on the message_delta event specifically (exactly one terminal delta).
C1_ENDTURN=$(printf '%s' "$C1RESP" | grep -A1 'event: message_delta' | grep -c '"stop_reason":"end_turn"')
check "C1: turn ends with end_turn (terminal message_delta)" "$C1_ENDTURN" "1"
set -e

kill "$C1_GW_PID" "$C1STUB_PID" 2>/dev/null || :
wait "$C1_GW_PID" "$C1STUB_PID" 2>/dev/null || :

# --- C1 success path: a 200 continuation must stream the model's answer through, not
# swallow it. The continuation (continueAfterAdvisor) references resIdx, which lives in the
# onAdvisorToolUse closure; if that capture breaks the success path loses the answer. A 200
# stub proves the answer round-trips.
cat > c1okstub.mjs <<'OKSTUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      const isContinuation = body.includes('"role":"tool"') && body.includes('"tool_call_id"');
      if (isContinuation) {
        const payload = { id: "c", choices: [{ index: 0,
          message: { role: "assistant", content: "THE MODEL ANSWER" }, finish_reason: "stop" }],
          usage: { prompt_tokens: 1, completion_tokens: 1 } };
        res.writeHead(200, { "content-type": "application/json" });
        return res.end(JSON.stringify(payload));
      }
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_c1","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n');
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
      res.end('data: [DONE]\n\n');
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`C1OKPORT=${s.address().port}`));
OKSTUB

node c1okstub.mjs > c1okstub.out 2>&1 &
C1OKSTUB_PID=$!
C1OKUP=""
while [ -z "$C1OKUP" ]; do C1OKUP=$(sed -n 's/^C1OKPORT=//p' c1okstub.out); done

C1_OK_PORT=4300
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > c1okgateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1OKUP/v1" \
CORTI_PORT="$C1_OK_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1okgateway.mjs > c1okgw.out 2>&1 &
C1_OK_GW_PID=$!
wait_banner c1okgw.out || { echo "FAIL C1-OK gateway did not start" >&2; FAILED=$((FAILED + 1)); }

C1OKG="http://127.0.0.1:$C1_OK_PORT"
C1OKRESP=$(curl -s -m 15 -N -H 'content-type: application/json' -d "$C1BODY" "$C1OKG/v1/messages" 2>&1 || true)

# set +e: same as the non-2xx block — a crashed gateway yields zero-match grep -c (exit 1), which
# set -e would abort on; we want clean FAIL lines.
set +e
# The model's answer must come through on a 200 continuation — guards against the continuation
# losing the answer when its block-index capture goes out of scope.
check "C1: 200 continuation streams the model answer through" \
  "$(printf '%s' "$C1OKRESP" | grep -c 'THE MODEL ANSWER')" "1"
check "C1: 200 continuation streams advisor advice" \
  "$(printf '%s' "$C1OKRESP" | grep -c 'stub advisor advice')" "1"
check "C1: 200 continuation emits no failure note" \
  "$(printf '%s' "$C1OKRESP" | grep -c 'proceed using the advice above')" "0"
set -e

kill "$C1_OK_GW_PID" "$C1OKSTUB_PID" 2>/dev/null || :
wait "$C1_OK_GW_PID" "$C1OKSTUB_PID" 2>/dev/null || :

# --- C1 streaming continuation: the continuation upstream answers with an SSE stream
# (content-type text/event-stream), not a JSON completion. The proxy must route it through
# a fresh stream translator seeded at resIdx+1 (not the JSON-drain path) and emit the deltas
# as content blocks under the same turn. This is the path Corti's real streaming endpoint
# takes — the fix that replaced the non-streaming continuation.
cat > c1ssestub.mjs <<'SSESTUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      const isContinuation = body.includes('"role":"tool"') && body.includes('"tool_call_id"');
      if (isContinuation) {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"STREAMED"}}]}\n\n');
        res.write('data: {"choices":[{"index":0,"delta":{"content":" ANSWER"}}]}\n\n');
        res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
        return res.end('data: [DONE]\n\n');
      }
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_c1","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n');
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
      res.end('data: [DONE]\n\n');
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`C1SSEPORT=${s.address().port}`));
SSESTUB

node c1ssestub.mjs > c1ssestub.out 2>&1 &
C1SSESTUB_PID=$!
C1SSEUP=""
while [ -z "$C1SSEUP" ]; do C1SSEUP=$(sed -n 's/^C1SSEPORT=//p' c1ssestub.out); done

C1_SSE_PORT=4400
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > c1ssegateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1SSEUP/v1" \
CORTI_PORT="$C1_SSE_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1ssegateway.mjs > c1ssegw.out 2>&1 &
C1_SSE_GW_PID=$!
wait_banner c1ssegw.out || { echo "FAIL C1-SSE gateway did not start" >&2; FAILED=$((FAILED + 1)); }

C1SSEG="http://127.0.0.1:$C1_SSE_PORT"
C1SSERESP=$(curl -s -m 15 -N -H 'content-type: application/json' -d "$C1BODY" "$C1SSEG/v1/messages" 2>&1 || true)

set +e
# The SSE continuation's streamed deltas must arrive as a text content block. Both fragments
# prove the SSE path (not the JSON-drain path) translated incremental deltas.
check "C1-SSE: streaming continuation emits first text delta" \
  "$(printf '%s' "$C1SSERESP" | grep -c 'STREAMED')" "1"
check "C1-SSE: streaming continuation emits second text delta" \
  "$(printf '%s' "$C1SSERESP" | grep -c 'ANSWER')" "1"
check "C1-SSE: streaming continuation streams advisor advice" \
  "$(printf '%s' "$C1SSERESP" | grep -c 'stub advisor advice')" "1"
check "C1-SSE: streaming continuation emits no failure note" \
  "$(printf '%s' "$C1SSERESP" | grep -c 'proceed using the advice above')" "0"
# Exactly one terminal message_delta — the continuation translator must not double-terminate.
C1SSE_ENDTURN=$(printf '%s' "$C1SSERESP" | grep -A1 'event: message_delta' | grep -c '"stop_reason":"end_turn"')
check "C1-SSE: streaming continuation ends with one end_turn" "$C1SSE_ENDTURN" "1"
# Exactly one message_start — the continuation suppresses it (the harness already saw one).
C1SSE_MSGSTART=$(printf '%s' "$C1SSERESP" | grep -c 'event: message_start')
check "C1-SSE: exactly one message_start (continuation suppresses its own)" "$C1SSE_MSGSTART" "1"
set -e

kill "$C1_SSE_GW_PID" "$C1SSESTUB_PID" 2>/dev/null || :
wait "$C1_SSE_GW_PID" "$C1SSESTUB_PID" 2>/dev/null || :

# --- C1-SSE no-[DONE]: an SSE continuation that closes without a [DONE] frame must still end
# the turn (res.end + finalize), not hang open. The stub emits the finish_reason chunk then ends
# the socket without the trailing `data: [DONE]`.
cat > c1nodonestub.mjs <<'NODSTUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      const isContinuation = body.includes('"role":"tool"') && body.includes('"tool_call_id"');
      if (isContinuation) {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"NODONE ANSWER"}}]}\n\n');
        res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
        return res.end();
      }
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_c1","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n');
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
      res.end('data: [DONE]\n\n');
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`C1NODONEPORT=${s.address().port}`));
NODSTUB

node c1nodonestub.mjs > c1nodonestub.out 2>&1 &
C1NODONESTUB_PID=$!
C1NODONEUP=""
while [ -z "$C1NODONEUP" ]; do C1NODONEUP=$(sed -n 's/^C1NODONEPORT=//p' c1nodonestub.out); done

C1_NODONE_PORT=4500
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > c1nodonegateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1NODONEUP/v1" \
CORTI_PORT="$C1_NODONE_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1nodonegateway.mjs > c1nodonegw.out 2>&1 &
C1_NODONE_GW_PID=$!
wait_banner c1nodonegw.out || { echo "FAIL C1-NODONE gateway did not start" >&2; FAILED=$((FAILED + 1)); }

C1NODONEG="http://127.0.0.1:$C1_NODONE_PORT"
C1NODONERESP=$(curl -s -m 15 -N -H 'content-type: application/json' -d "$C1BODY" "$C1NODONEG/v1/messages" 2>&1 || true)

set +e
check "C1-NODONE: no-[DONE] continuation streams the answer" \
  "$(printf '%s' "$C1NODONERESP" | grep -c 'NODONE ANSWER')" "1"
check "C1-NODONE: no-[DONE] continuation ends with end_turn" \
  "$(printf '%s' "$C1NODONERESP" | grep -A1 'event: message_delta' | grep -c '"stop_reason":"end_turn"')" "1"
check "C1-NODONE: no-[DONE] continuation emits message_stop (turn closed)" \
  "$(printf '%s' "$C1NODONERESP" | grep -c 'event: message_stop')" "1"
set -e

kill "$C1_NODONE_GW_PID" "$C1NODONESTUB_PID" 2>/dev/null || :
wait "$C1_NODONE_GW_PID" "$C1NODONESTUB_PID" 2>/dev/null || :

# --- C1-ABORT: the continuation dies mid-turn *after* streaming blocks of its own. The failure
# note must land after them at a fresh index — a note pinned to resIdx+1 re-opens a block the
# continuation already used, clobbering finished model output and leaving the open one dangling.
# The note must also repeat the advice: the harness never replays advisor blocks into the next
# request's history, so this note is the only copy that reaches the model's context.
cat > c1abortstub.mjs <<'ABORTSTUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      const isContinuation = body.includes('"role":"tool"') && body.includes('"tool_call_id"');
      res.writeHead(200, { "content-type": "text/event-stream" });
      if (isContinuation) {
        // A finished text block, then an *open* tool_use block, then the socket dies.
        res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"PARTIALTEXT"}}]}\n\n');
        res.write('data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"tc1","type":"function","function":{"name":"Read","arguments":"{}"}}]}}]}\n\n');
        return void setTimeout(() => res.socket.destroy(), 300);
      }
      res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_c1","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n');
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
      res.end('data: [DONE]\n\n');
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`C1ABORTPORT=${s.address().port}`));
ABORTSTUB

node c1abortstub.mjs > c1abortstub.out 2>&1 &
C1ABORTSTUB_PID=$!
C1ABORTUP=""
while [ -z "$C1ABORTUP" ]; do C1ABORTUP=$(sed -n 's/^C1ABORTPORT=//p' c1abortstub.out); done

C1_ABORT_PORT=4600
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > c1abortgateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1ABORTUP/v1" \
CORTI_PORT="$C1_ABORT_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1abortgateway.mjs > c1abortgw.out 2>&1 &
C1_ABORT_GW_PID=$!
wait_banner c1abortgw.out || { echo "FAIL C1-ABORT gateway did not start" >&2; FAILED=$((FAILED + 1)); }

C1ABORTG="http://127.0.0.1:$C1_ABORT_PORT"
C1ABORTRESP=$(curl -s -m 20 -N -H 'content-type: application/json' -d "$C1BODY" "$C1ABORTG/v1/messages" 2>&1 || true)

set +e
# Every content_block_start index appears exactly once: no block is ever re-opened.
C1ABORT_IDX=$(printf '%s' "$C1ABORTRESP" | sed -n 's/.*"type":"content_block_start","index":\([0-9]*\).*/\1/p')
C1ABORT_IDX_ALL=$(printf '%s\n' "$C1ABORT_IDX" | grep -c .)
C1ABORT_IDX_UNIQ=$(printf '%s\n' "$C1ABORT_IDX" | sort -u | grep -c .)
check "C1-ABORT: no content block index is re-opened" "$C1ABORT_IDX_ALL" "$C1ABORT_IDX_UNIQ"
# Every started block is also stopped — closeOpen() must close the dangling tool_use.
check "C1-ABORT: every started block is stopped" \
  "$(printf '%s' "$C1ABORTRESP" | grep -c '"type":"content_block_stop"')" "$C1ABORT_IDX_ALL"
check "C1-ABORT: streamed text survives the failure note" \
  "$(printf '%s' "$C1ABORTRESP" | grep -c 'PARTIALTEXT')" "1"
check "C1-ABORT: failure note carries the advice verbatim" \
  "$(printf '%s' "$C1ABORTRESP" | grep -c 'advisor_guidance')" "1"
# Exactly one terminal frame: the abort must not append a second message_stop to a closed turn.
check "C1-ABORT: exactly one message_stop" \
  "$(printf '%s' "$C1ABORTRESP" | grep -c '^event: message_stop')" "1"
set -e

kill "$C1_ABORT_GW_PID" "$C1ABORTSTUB_PID" 2>/dev/null || :
wait "$C1_ABORT_GW_PID" "$C1ABORTSTUB_PID" 2>/dev/null || :

# --- C1-SETTLE: the continuation promise must settle on the *success* path. A stub that flushes
# [DONE] and the chunk terminator in separate writes (what a real stream does) used to leave the
# promise pending forever: finalize() destroyed the socket before 'end' could fire, so the whole
# request frame stayed suspended and the continuation's upstream response never reached the log.
# Both the settled diagnostic and the tagged UPSTREAM-RESPONSE entry prove the path completed.
cat > c1settlestub.mjs <<'SETTLESTUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      const isContinuation = body.includes('"role":"tool"') && body.includes('"tool_call_id"');
      res.writeHead(200, { "content-type": "text/event-stream" });
      if (isContinuation) {
        res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"SETTLED"}}]}\n\n');
        res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
        // [DONE] alone, terminator later: the response is not complete when [DONE] is parsed.
        return void setTimeout(() => {
          res.write('data: [DONE]\n\n');
          setTimeout(() => res.end(), 300);
        }, 300);
      }
      res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_c1","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n');
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
      res.end('data: [DONE]\n\n');
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`C1SETTLEPORT=${s.address().port}`));
SETTLESTUB

node c1settlestub.mjs > c1settlestub.out 2>&1 &
C1SETTLESTUB_PID=$!
C1SETTLEUP=""
while [ -z "$C1SETTLEUP" ]; do C1SETTLEUP=$(sed -n 's/^C1SETTLEPORT=//p' c1settlestub.out); done

C1_SETTLE_PORT=4700
mkdir -p "$SCRATCH/settle-logs"
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > c1settlegateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1SETTLEUP/v1" \
CORTI_PORT="$C1_SETTLE_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
CORTI_DEBUG=1 \
CORTI_DEBUG_DIR="$SCRATCH/settle-logs" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1settlegateway.mjs > c1settlegw.out 2>&1 &
C1_SETTLE_GW_PID=$!
wait_banner c1settlegw.out || { echo "FAIL C1-SETTLE gateway did not start" >&2; FAILED=$((FAILED + 1)); }

C1SETTLEG="http://127.0.0.1:$C1_SETTLE_PORT"
C1SETTLERESP=$(curl -s -m 20 -N -H 'content-type: application/json' -d "$C1BODY" "$C1SETTLEG/v1/messages" 2>&1 || true)
C1SETTLELOG=$(cat "$SCRATCH"/settle-logs/*.log 2>/dev/null || true)

set +e
check "C1-SETTLE: continuation answer reaches the client" \
  "$(printf '%s' "$C1SETTLERESP" | grep -c 'SETTLED')" "1"
check "C1-SETTLE: no failure note on the success path" \
  "$(printf '%s' "$C1SETTLERESP" | grep -c 'the follow-up response failed')" "0"
# The diagnostic is pushed when the promise settles and written by finalize() — its presence in
# the RESPONSE entry proves the await returned rather than hanging.
check "C1-SETTLE: continuation promise settled" \
  "$(printf '%s' "$C1SETTLELOG" | grep -c 'advisor continuation settled')" "1"
check "C1-SETTLE: continuation upstream response is logged" \
  "$(printf '%s' "$C1SETTLELOG" | grep -c 'UPSTREAM-RESPONSE \[continuation\]')" "1"
set -e

kill "$C1_SETTLE_GW_PID" "$C1SETTLESTUB_PID" 2>/dev/null || :
wait "$C1_SETTLE_GW_PID" "$C1SETTLESTUB_PID" 2>/dev/null || :

# --- C1-ERRFRAME: the continuation upstream answers 200 and then streams an *error frame*
# mid-turn. feed() would terminate the translator with a bare `error` event and no terminal
# frame, and the turn would settle as a clean success — stranding the advice exactly like the
# stall this fix removes. It must be treated as a continuation failure so the note carries it.
cat > c1errstub.mjs <<'ERRSTUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      const isContinuation = body.includes('"role":"tool"') && body.includes('"tool_call_id"');
      res.writeHead(200, { "content-type": "text/event-stream" });
      if (isContinuation) {
        res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"BEFOREERR"}}]}\n\n');
        return res.end('data: {"error":{"code":503,"message":"backend overloaded"}}\n\n');
      }
      res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_c1","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n');
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
      res.end('data: [DONE]\n\n');
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`C1ERRPORT=${s.address().port}`));
ERRSTUB

node c1errstub.mjs > c1errstub.out 2>&1 &
C1ERRSTUB_PID=$!
C1ERRUP=""
while [ -z "$C1ERRUP" ]; do C1ERRUP=$(sed -n 's/^C1ERRPORT=//p' c1errstub.out); done

C1_ERR_PORT=4900
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > c1errgateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1ERRUP/v1" \
CORTI_PORT="$C1_ERR_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1errgateway.mjs > c1errgw.out 2>&1 &
C1_ERR_GW_PID=$!
wait_banner c1errgw.out || { echo "FAIL C1-ERRFRAME gateway did not start" >&2; FAILED=$((FAILED + 1)); }

C1ERRG="http://127.0.0.1:$C1_ERR_PORT"
C1ERRRESP=$(curl -s -m 20 -N -H 'content-type: application/json' -d "$C1BODY" "$C1ERRG/v1/messages" 2>&1 || true)

set +e
check "C1-ERRFRAME: error frame produces the failure note, not a silent success" \
  "$(printf '%s' "$C1ERRRESP" | grep -c 'the follow-up response failed')" "1"
check "C1-ERRFRAME: the note carries the advice" \
  "$(printf '%s' "$C1ERRRESP" | grep -c 'advisor_guidance')" "1"
check "C1-ERRFRAME: the turn is closed with a terminal message_stop" \
  "$(printf '%s' "$C1ERRRESP" | grep -c '^event: message_stop')" "1"
# The translator must never have emitted its bare error event for this frame.
check "C1-ERRFRAME: no raw upstream error event reaches the client" \
  "$(printf '%s' "$C1ERRRESP" | grep -c '^event: error')" "0"
check "C1-ERRFRAME: text streamed before the error survives" \
  "$(printf '%s' "$C1ERRRESP" | grep -c 'BEFOREERR')" "1"
set -e

kill "$C1_ERR_GW_PID" "$C1ERRSTUB_PID" 2>/dev/null || :
wait "$C1_ERR_GW_PID" "$C1ERRSTUB_PID" 2>/dev/null || :

# --- C1-PARTIALTOOL: the continuation dies partway through a tool_use's argument JSON. The
# accumulated partial_json is unrepairable, so the turn must at least stay well-formed and stamp
# end_turn (never tool_use) — a tool_use stop_reason would ask the harness to dispatch a call
# whose input cannot parse.
cat > c1ptstub.mjs <<'PTSTUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      const isContinuation = body.includes('"role":"tool"') && body.includes('"tool_call_id"');
      res.writeHead(200, { "content-type": "text/event-stream" });
      if (isContinuation) {
        res.write('data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"tc9","type":"function","function":{"name":"Read","arguments":"{\\"file_pa"}}]}}]}\n\n');
        return void setTimeout(() => res.socket.destroy(), 300);
      }
      res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_c1","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n');
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
      res.end('data: [DONE]\n\n');
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`C1PTPORT=${s.address().port}`));
PTSTUB

node c1ptstub.mjs > c1ptstub.out 2>&1 &
C1PTSTUB_PID=$!
C1PTUP=""
while [ -z "$C1PTUP" ]; do C1PTUP=$(sed -n 's/^C1PTPORT=//p' c1ptstub.out); done

C1_PT_PORT=4950
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > c1ptgateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1PTUP/v1" \
CORTI_PORT="$C1_PT_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1ptgateway.mjs > c1ptgw.out 2>&1 &
C1_PT_GW_PID=$!
wait_banner c1ptgw.out || { echo "FAIL C1-PARTIALTOOL gateway did not start" >&2; FAILED=$((FAILED + 1)); }

C1PTG="http://127.0.0.1:$C1_PT_PORT"
C1PTRESP=$(curl -s -m 20 -N -H 'content-type: application/json' -d "$C1BODY" "$C1PTG/v1/messages" 2>&1 || true)

set +e
check "C1-PARTIALTOOL: stop_reason is end_turn, never tool_use" \
  "$(printf '%s' "$C1PTRESP" | grep -c '"stop_reason":"tool_use"')" "0"
check "C1-PARTIALTOOL: the turn still ends with end_turn" \
  "$(printf '%s' "$C1PTRESP" | grep -A1 '^event: message_delta' | grep -c '"stop_reason":"end_turn"')" "1"
C1PT_STARTS=$(printf '%s' "$C1PTRESP" | grep -c '"type":"content_block_start"')
check "C1-PARTIALTOOL: the partial tool block is closed" \
  "$(printf '%s' "$C1PTRESP" | grep -c '"type":"content_block_stop"')" "$C1PT_STARTS"
check "C1-PARTIALTOOL: the note still carries the advice" \
  "$(printf '%s' "$C1PTRESP" | grep -c 'advisor_guidance')" "1"
set -e

kill "$C1_PT_GW_PID" "$C1PTSTUB_PID" 2>/dev/null || :
wait "$C1_PT_GW_PID" "$C1PTSTUB_PID" 2>/dev/null || :

# --- CAL e2e: message_start carries the char/4 estimate, and a turn that dies before its real
# message_delta leaves that estimate standing as its final recorded usage. An estimate below the
# previous turn therefore walks the context readout backwards. The gateway must scale it by what
# upstream actually charged for the last turn of the same session. The stub reports an absurd
# prompt_tokens so the ratio ceiling is what decides the result.
cat > calstub.mjs <<'CALSTUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      // The advisor continuation must not answer, so the turn ends on the proxy's failure note.
      if (body.includes('"role":"tool"') && body.includes('"tool_call_id"')) {
        res.writeHead(500, { "content-type": "application/json" });
        return res.end('{"error":{"message":"unavailable"}}');
      }
      res.writeHead(200, { "content-type": "text/event-stream" });
      if (body.includes("TRIGGER-ADVISOR")) {
        res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_cal","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n');
        res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":999999,"completion_tokens":1}}\n\n');
        return res.end('data: [DONE]\n\n');
      }
      res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"HI"}}]}\n\n');
      // Two usage frames: real streams report a partial before the final one, and only the last
      // is the turn's actual prompt cost.
      res.write('data: {"choices":[{"index":0,"delta":{"content":"!"}}],"usage":{"prompt_tokens":5,"completion_tokens":1}}\n\n');
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":999999,"completion_tokens":1}}\n\n');
      res.end('data: [DONE]\n\n');
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`CALPORT=${s.address().port}`));
CALSTUB

node calstub.mjs > calstub.out 2>&1 &
CALSTUB_PID=$!
CALUP=""
while [ -z "$CALUP" ]; do CALUP=$(sed -n 's/^CALPORT=//p' calstub.out); done

CAL_PORT=4960
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > calgateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$CALUP/v1" \
CORTI_PORT="$CAL_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node calgateway.mjs > calgw.out 2>&1 &
CAL_GW_PID=$!
wait_banner calgw.out || { echo "FAIL CAL gateway did not start" >&2; FAILED=$((FAILED + 1)); }

# The sample floor is in tokens, so the prompt has to be big enough to clear it.
CALPAD=$(awk 'BEGIN{s="";while(length(s)<24000)s=s "corti bridge padding text ";print s}')
CALBODY='{"model":"corti-s1","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"'"$CALPAD"'"}]}'
CALG="http://127.0.0.1:$CAL_PORT"
cal_post() {
  curl -s -m 15 -N -H 'content-type: application/json' -H "x-claude-code-session-id: $1" \
    -d "$CALBODY" "$CALG/v1/messages" 2>&1 || true
}
cal_input() { printf '%s' "$1" | grep -A1 '^event: message_start' | sed -n 's/.*"input_tokens":\([0-9]*\).*/\1/p' | head -1; }

cal_note_input() { printf '%s' "$1" | grep -A1 '^event: message_delta' | sed -n 's/.*"input_tokens":\([0-9]*\).*/\1/p' | tail -1; }

CAL_A1=$(cal_input "$(cal_post cal-a)")
CAL_A2=$(cal_input "$(cal_post cal-a)")
CAL_B1=$(cal_input "$(cal_post cal-b)")

# The failure note ends the turn with a usage of its own, and that is the shape behind the two
# largest backward steps observed in real transcripts. It has to carry the same calibrated number
# message_start did, not the raw estimate.
CALADVBODY='{"model":"corti-s1","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"TRIGGER-ADVISOR '"$CALPAD"'"}]}'
cal_adv_post() {
  curl -s -m 20 -N -H 'content-type: application/json' -H "x-claude-code-session-id: $1" \
    -d "$CALADVBODY" "$CALG/v1/messages" 2>&1 || true
}
# cal-a is already calibrated by the two turns above; cal-c has never been seen, so its estimate
# is raw. Same body, so the gap between them is the calibration and nothing else.
CALADV_WARM=$(cal_adv_post cal-a)
CALADV_COLD=$(cal_adv_post cal-c)
# Derived from the policy module rather than restated here, so the ceiling constant has one owner.
CAL_WANT=$(node --input-type=module -e '
import { calibrationKey, calibratedEstimate, recordPromptTokens } from "'"$REPO"'/lib/prompt-estimate.mjs";
const k = calibrationKey("t", "corti-s1");
recordPromptTokens(k, '"$CAL_A1"', 999999);
console.log(calibratedEstimate(k, '"$CAL_A1"'));
')

set +e
check "CAL: the first turn of a session reports the raw estimate" \
  "$([ "$CAL_A1" -gt 4096 ] && echo yes || echo no)" "yes"
check "CAL: the next turn is scaled by what upstream charged" "$CAL_A2" "$CAL_WANT"
check "CAL: scaling never lands below the raw estimate" \
  "$([ "$CAL_A2" -ge "$CAL_A1" ] && echo yes || echo no)" "yes"
check "CAL: a different session is not calibrated by this one" "$CAL_B1" "$CAL_A1"
check "CAL-NOTE: the advisor failure note is reached" \
  "$(printf '%s' "$CALADV_WARM" | grep -c 'the follow-up response failed')" "1"
check "CAL-NOTE: the note ends the turn on the calibrated estimate" \
  "$(cal_note_input "$CALADV_WARM")" "$(cal_input "$CALADV_WARM")"
check "CAL-NOTE: and that is above what an uncalibrated session reports" \
  "$([ "$(cal_note_input "$CALADV_WARM")" -gt "$(cal_note_input "$CALADV_COLD")" ] && echo yes || echo no)" "yes"
set -e

kill "$CAL_GW_PID" "$CALSTUB_PID" 2>/dev/null || :
wait "$CAL_GW_PID" "$CALSTUB_PID" 2>/dev/null || :

if [ "$FAILED" -gt 0 ]; then
  printf '\n%s check(s) failed\n' "$FAILED"
  exit 1
fi
printf '\nall checks passed\n'
