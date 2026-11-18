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

# Ambient debug env from an invoking shell would make every test gateway write real
# gateway-session logs — the two boots that need logs set both vars explicitly.
unset CORTI_DEBUG CORTI_DEBUG_DIR

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
  [ -n "${IMGSTUB_PID:-}" ] && { kill "$IMGSTUB_PID" 2>/dev/null || :; wait "$IMGSTUB_PID" 2>/dev/null || :; }
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
      if (req.url.startsWith("/anthropic/")) {
        // Echo what actually reached upstream: full path (query included), every
        // anthropic-* header, and the bearer — the pass-through assertions below prove
        // open-list header forwarding and the auth swap (client token discarded,
        // CORTI_BEARER substituted) off this echo.
        const eh = {};
        for (const [k, v] of Object.entries(req.headers))
          if (/^anthropic-/.test(k)) eh[k] = v;
        return res.end(JSON.stringify({ id: "m", type: "message", role: "assistant",
          content: [{ type: "text", text: "ANTHROPIC" }], model: "corti-s1",
          stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 },
          echo: { url: req.url, anthropicHeaders: eh, authorization: req.headers.authorization } }));
      }
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

# Pass-through forwards as an open list: every anthropic-* request header the client sent
# (including ones the gateway does not know yet) plus the request's query string must arrive
# upstream exactly as built. The upstream stub echoes both.
PT_RESP=$(curl -s -m 10 -H 'content-type: application/json' -H 'authorization: Bearer victim-token' \
  -H 'anthropic-version: 2023-06-01' -H 'anthropic-beta: interleaved-thinking-s-2025-05-14' \
  -H 'anthropic-safeguards: future-capability' -d "$BODY" "$G/anthropic/v1/messages?beta=true")
check "passthrough: query string preserved on the upstream URL" \
  "$(printf '%s' "$PT_RESP" | grep -c '"url":"/anthropic/v1/messages?beta=true"')" "1"
check "passthrough: anthropic-beta forwarded verbatim" \
  "$(printf '%s' "$PT_RESP" | grep -c '"anthropic-beta":"interleaved-thinking-s-2025-05-14"')" "1"
check "passthrough: unknown anthropic-* header forwarded (open list)" \
  "$(printf '%s' "$PT_RESP" | grep -c '"anthropic-safeguards":"future-capability"')" "1"
# Defaulted when the client omits it — the upstream needs a version either way. The exact
# url match is the regression tripwire for a no-query request growing a garbage query
# (an indexOf of -1 fed straight into slice would append "?/anthropic/v1/messages").
PT_NOVER=$(curl -s -m 10 -H 'content-type: application/json' -d "$BODY" "$G/anthropic/v1/messages")
check "passthrough: no-query request reaches upstream with no query" \
  "$(printf '%s' "$PT_NOVER" | grep -c '"url":"/anthropic/v1/messages"')" "1"
# A raw "?" is legal inside a query; splitting on every "?" would drop the tail.
PT_QQ=$(curl -s -m 10 -H 'content-type: application/json' -d "$BODY" "$G/anthropic/v1/messages?beta=true&cb=x?y=1")
check "passthrough: query with a second ? arrives whole" \
  "$(printf '%s' "$PT_QQ" | grep -c '"url":"/anthropic/v1/messages?beta=true&cb=x?y=1"')" "1"
check "passthrough: anthropic-version defaulted upstream" \
  "$(printf '%s' "$PT_NOVER" | grep -c '"anthropic-version":"2023-06-01"')" "1"
# Auth swap: the client's token is always discarded, only CORTI_BEARER ("test" in this
# suite) goes upstream. The stub echoes the bearer it actually received; a client-sent
# victim token proves substitution rather than mere presence.
check "passthrough: client token swapped for CORTI_BEARER upstream" \
  "$(printf '%s' "$PT_RESP" | grep -c '"authorization":"Bearer test"')" "1"
check "passthrough: client's own token never reaches upstream" \
  "$(printf '%s' "$PT_RESP" | grep -c '"authorization":"Bearer victim-token"')" "0"

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
# Keep the transcript when asked (C1-CARRY asserts on what the advisor was actually shown);
# discard it otherwise, so the other suites stay unaffected.
ADVISOR_STUB_IN=$(cat)
[ -n "${ADVISOR_STUB_CAPTURE:-}" ] && printf '%s\n' "$ADVISOR_STUB_IN" >> "$ADVISOR_STUB_CAPTURE"
# ADVISOR-CWD: where the child was started and whether it may load CLAUDE.md files.
[ -n "${ADVISOR_STUB_ENVCAP:-}" ] && printf 'cwd=%s mds=%s\n' "$(pwd -P)" "${CLAUDE_CODE_DISABLE_CLAUDE_MDS:-}" >> "$ADVISOR_STUB_ENVCAP"
case "$ADVISOR_STUB_IN" in
  *TIMEOUTME*) printf '{"ok":false,"code":"execution_time_exceeded"}' ;;
  *) printf '{"ok":true,"text":"stub advisor advice"}' ;;
esac
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
# The tools array is load-bearing: the advisor intercept skips a request without one, so a body
# with no tools models a harness side call and never reaches the advisor at all.
C1TOOLS='"tools":[{"name":"run_bash","input_schema":{"type":"object"}}]'
C1BODY='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"advise me"}]}'
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

# --- C1-CARRY: a consult must still be visible to the NEXT turn. The harness renders the
# server_tool_use / advisor_tool_result pair but never replays it, so turn 2 arrives with the
# consult excised from between two text blocks — and the model reads its own announcement as a
# promise it never kept, apologising for a call it did make. The gateway records the advice
# against the surviving text block; translateRequest re-inserts it. Two real turns through one
# gateway process are required: the store is per-session and lives in the gateway, so a
# single-request test cannot see the carry-forward at all.
cat > c1carrystub.mjs <<'CARRYSTUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      // Both turns narrate then consult. Turn 1 creates the record; turn 2 consults again, which
      // is what puts the restored history in front of the advisor.
      const narration = body.includes("TURN2") ? "Checking with the advisor." : "Calling the advisor now.";
      const callId = body.includes("TURN2") ? "call_carry2" : "call_carry";
      // Keyed on *this* turn's call id, not on any tool message: turn 2's history legitimately
      // carries the restored pair from turn 1, which a generic tool_call_id probe reads as a
      // continuation and answers instead of consulting.
      const isContinuation = body.includes('"tool_call_id":"' + callId + '"');
      res.writeHead(200, { "content-type": "text/event-stream" });
      if (isContinuation) {
        res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"ANSWER"}}]}\n\n');
        res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
        return void res.end('data: [DONE]\n\n');
      }
      res.write(`data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"${narration}"}}]}\n\n`);
      res.write(`data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"${callId}","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n`);
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
      res.end('data: [DONE]\n\n');
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`C1CARRYPORT=${s.address().port}`));
CARRYSTUB

node c1carrystub.mjs > c1carrystub.out 2>&1 &
C1CARRYSTUB_PID=$!
C1CARRYUP=""
while [ -z "$C1CARRYUP" ]; do C1CARRYUP=$(sed -n 's/^C1CARRYPORT=//p' c1carrystub.out); done

C1_CARRY_PORT=4701
mkdir -p "$SCRATCH/carry-logs"
# Every transcript the advisor child is handed, appended in spawn order.
CARRY_ADVISOR_IN="$SCRATCH/carry-advisor-input.txt"
: > "$CARRY_ADVISOR_IN"
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > c1carrygateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1CARRYUP/v1" \
CORTI_PORT="$C1_CARRY_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
ADVISOR_STUB_CAPTURE="$CARRY_ADVISOR_IN" \
ADVISOR_STUB_ENVCAP="$SCRATCH/carry-advisor-env.txt" \
CORTI_DEBUG=1 \
CORTI_DEBUG_DIR="$SCRATCH/carry-logs" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1carrygateway.mjs > c1carrygw.out 2>&1 &
C1_CARRY_GW_PID=$!
wait_banner c1carrygw.out || { echo "FAIL C1-CARRY gateway did not start" >&2; FAILED=$((FAILED + 1)); }

C1CARRYG="http://127.0.0.1:$C1_CARRY_PORT"
CARRYSESS='x-claude-code-session-id: carry-sess-1'
# Turn 1: the consult runs and the advisor answers.
CARRYRESP1=$(curl -s -m 20 -N -H 'content-type: application/json' -H "$CARRYSESS" \
  -d "$C1BODY" "$C1CARRYG/v1/messages" 2>&1 || true)
# Turn 2: the history the harness actually replays — the two text blocks, consult gone.
CARRYBODY2='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"advise me"},{"role":"assistant","content":[{"type":"text","text":"Calling the advisor now."},{"type":"text","text":"Acting on it."}]},{"role":"user","content":"TURN2 did it actually answer?"}]}'
CARRYRESP2=$(curl -s -m 20 -N -H 'content-type: application/json' -H "$CARRYSESS" \
  -d "$CARRYBODY2" "$C1CARRYG/v1/messages" 2>&1 || true)
# Same history, a session that never consulted: proves the carry-forward is keyed on the session
# and not simply injected into every request that looks like this one.
CARRYRESP3=$(curl -s -m 20 -N -H 'content-type: application/json' \
  -H 'x-claude-code-session-id: carry-sess-2' \
  -d "$CARRYBODY2" "$C1CARRYG/v1/messages" 2>&1 || true)

CARRYLOG1=$(cat "$SCRATCH"/carry-logs/*carry-sess-1*.log 2>/dev/null || true)
CARRYLOG2=$(cat "$SCRATCH"/carry-logs/*carry-sess-2*.log 2>/dev/null || true)
# The upstream request body is what the model actually reads, so assert on one body at a time
# rather than on the whole log (which also holds the responses the advice appears in).
carry_upstream() { # <log> <n>: the Nth UPSTREAM-REQUEST body in that log
  printf '%s' "$1" | awk -v want="$2" '
    /^=== .*UPSTREAM-REQUEST/ { n++; inb = (n == want); next }
    /^=== / { inb = 0 }
    inb'
}
# sess-1 makes three upstream calls: turn 1 initial, turn 1 continuation, turn 2 initial.
CARRYTURN1REQ=$(carry_upstream "$CARRYLOG1" 1)
CARRYTURN2REQ=$(carry_upstream "$CARRYLOG1" 3)
CARRYCTRLREQ=$(carry_upstream "$CARRYLOG2" 1)

set +e
check "C1-CARRY: both turns consulted" \
  "$(printf '%s' "$CARRYLOG1" | grep -c 'advisor ok')" "2"
check "C1-CARRY: turn 1 has no prior consult to carry" \
  "$(printf '%s' "$CARRYTURN1REQ" | grep -c 'advisor_guidance')" "0"
check "C1-CARRY: turn 2 upstream carries the prior advice" \
  "$(printf '%s' "$CARRYTURN2REQ" | grep -c 'stub advisor advice')" "1"
check "C1-CARRY: the advice is re-inserted as advisor_guidance" \
  "$(printf '%s' "$CARRYTURN2REQ" | grep -c 'advisor_guidance')" "1"
# Shape matters, not just presence. Rendered as assistant prose the model read advice it had no
# memory of writing as its own fabrication and told the user it had faked the consult; as the
# result of a call it made, there is nothing to disown.
check "C1-CARRY: the advice arrives as a tool result, not assistant prose" \
  "$(printf '%s' "$CARRYTURN2REQ" | python3 -c '
import sys, json
b = json.JSONDecoder().raw_decode(sys.stdin.read().split("body:",1)[1].lstrip())[0]
tool = [m for m in b["messages"] if m.get("role") == "tool" and "advisor_guidance" in str(m.get("content"))]
asst = [m for m in b["messages"] if m.get("role") == "assistant" and "advisor_guidance" in str(m.get("content"))]
calls = [c for m in b["messages"] for c in (m.get("tool_calls") or []) if c["function"]["name"] == "consult_advisor"]
print("tool=%d asst=%d calls=%d" % (len(tool), len(asst), len(calls)))
')" "tool=1 asst=0 calls=1"
check "C1-CARRY: a session that never consulted gets no advice" \
  "$(printf '%s' "$CARRYCTRLREQ" | grep -c 'advisor_guidance')" "0"
# The advisor reads the history too. Shown the excised version it cannot see the consult it just
# answered, so it corroborates the executor's false "I never called it" instead of correcting it —
# which is how the reported apology loop got its confidence. Three spawns run here (sess-1 turn 1,
# sess-1 turn 2, sess-2 turn 2) and only sess-1's second one has a prior consult to be shown.
check "C1-CARRY: the advisor was spawned for both turns and the control" \
  "$(grep -c '<transcript>' "$CARRY_ADVISOR_IN")" "3"
check "C1-CARRY: the advisor sees the prior consult in its transcript" \
  "$(grep -c 'stub advisor advice' "$CARRY_ADVISOR_IN")" "1"
set -e

# --- C1-SIDECALL: a request with no tools is a harness one-shot (summarise a page, title a chat).
# It cannot act on advice, yet these were consulting: 6 of 7 consults in one measured session,
# 50s of Opus-tier advisor time. The upstream stub still offers a consult, so this also proves the
# gateway declines to hold the turn open rather than merely skipping the tool injection.
SIDEBODY='{"model":"corti-s1","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"TURN2 summarise this"}]}'
SIDESPAWNS_BEFORE=$(grep -c '<transcript>' "$CARRY_ADVISOR_IN" || true)
SIDERESP=$(curl -s -m 20 -N -H 'content-type: application/json' \
  -H 'x-claude-code-session-id: carry-sess-3' \
  -d "$SIDEBODY" "$C1CARRYG/v1/messages" 2>&1 || true)
SIDELOG=$(cat "$SCRATCH"/carry-logs/*carry-sess-3*.log 2>/dev/null || true)

set +e
check "C1-SIDECALL: no advisor spawn for a toolless request" \
  "$(grep -c '<transcript>' "$CARRY_ADVISOR_IN")" "$SIDESPAWNS_BEFORE"
# Scoped to the request body: the stub still *offers* a consult in its response, which is the
# point — the gateway must decline it rather than hold the turn open.
check "C1-SIDECALL: the consult_advisor tool is not offered upstream" \
  "$(carry_upstream "$SIDELOG" 1 | grep -c 'consult_advisor')" "0"
check "C1-SIDECALL: no executor advisor prompt is prepended" \
  "$(carry_upstream "$SIDELOG" 1 | grep -c 'You have access to an .advisor. tool')" "0"
check "C1-SIDECALL: the turn still completes normally" \
  "$(printf '%s' "$SIDERESP" | grep -c '^event: message_stop')" "1"
set -e

# --- ADVISOR-CWD: the advisor child runs in the executor directory (from the harness environment
# block), never the gateway one, and never loads CLAUDE.md files of its own.
EXECDIR="$SCRATCH/executor-project"
mkdir -p "$EXECDIR"
EXECDIR_REAL=$(cd "$EXECDIR" && pwd -P)
GWDIR_REAL=$(pwd -P)
TMPDIR_REAL=$(node -e 'process.stdout.write(require("fs").realpathSync(require("os").tmpdir()))')
cwd_body() { printf '%s' '{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"system","content":"# Environment\n - Primary working directory: '"$1"'\n"},{"role":"user","content":"advise me"}]}'; }
: > "$SCRATCH/carry-advisor-env.txt"
curl -s -m 20 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: cwd-sess-1' \
  -d "$(cwd_body "$EXECDIR")" "$C1CARRYG/v1/messages" >/dev/null 2>&1 || true
curl -s -m 20 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: cwd-sess-2' \
  -d "$(cwd_body "$SCRATCH/no-such-dir")" "$C1CARRYG/v1/messages" >/dev/null 2>&1 || true
set +e
check "ADVISOR-CWD: the child runs in the executor directory" \
  "$(sed -n 1p "$SCRATCH/carry-advisor-env.txt")" "cwd=$EXECDIR_REAL mds=1"
check "ADVISOR-CWD: a missing directory falls back to the temp dir" \
  "$(sed -n 2p "$SCRATCH/carry-advisor-env.txt")" "cwd=$TMPDIR_REAL mds=1"
check "ADVISOR-CWD: never the gateway directory" \
  "$(grep -c "cwd=$GWDIR_REAL " "$SCRATCH/carry-advisor-env.txt")" "0"
set -e

kill "$C1_CARRY_GW_PID" "$C1CARRYSTUB_PID" 2>/dev/null || :
wait "$C1_CARRY_GW_PID" "$C1CARRYSTUB_PID" 2>/dev/null || :

# --- C1-NESTED / CAP / NESTED-JSON / PARALLEL: a consult inside a continuation runs another
# round under the same message, and every request extends the prefix of the one before it.
cat > c1neststub.mjs <<'NESTSTUB'
import fs from "node:fs";
import https from "node:https";
let capCalls = 0;
const sse = (res, frames) => {
  res.writeHead(200, { "content-type": "text/event-stream" });
  for (const f of frames) res.write(`data: ${JSON.stringify(f)}\n\n`);
  res.end("data: [DONE]\n\n");
};
const consult = (id) => [
  { choices: [{ index: 0, delta: { role: "assistant", content: "Consulting." } }] },
  { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id, type: "function", function: { name: "consult_advisor", arguments: "" } }] } }] },
  { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }], usage: { prompt_tokens: 1, completion_tokens: 1 } },
];
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      if (body.includes("CAPME")) return sse(res, consult(`call_cap${++capCalls}`));
      if (body.includes("TIMEOUTME")) return sse(res, consult(`call_to${++capCalls}`));
      if (body.includes("DROPME")) {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"partial"}}]}\n\n');
        return void setTimeout(() => res.socket.destroy(), 300);
      }
      // TWINME: two consults in one assistant message.
      if (body.includes("TWINME") && body.includes('"tool_call_id":"call_t')) return sse(res, [
        { choices: [{ index: 0, delta: { role: "assistant", content: "TWIN ANSWER" } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1 } },
      ]);
      if (body.includes("TWINME")) return sse(res, [
        { choices: [{ index: 0, delta: { role: "assistant", content: "Asking twice." } }] },
        { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "call_t1", type: "function", function: { name: "consult_advisor", arguments: "{}" } }] } }] },
        { choices: [{ index: 0, delta: { tool_calls: [{ index: 1, id: "call_t2", type: "function", function: { name: "consult_advisor", arguments: "{}" } }] } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }], usage: { prompt_tokens: 1, completion_tokens: 1 } },
      ]);
      // PARALLELME: the consult arrives beside an ordinary tool call.
      if (body.includes("PARALLELME") && body.includes('"tool_call_id":"call_p1"')) return sse(res, [
        { choices: [{ index: 0, delta: { role: "assistant", content: "PAR ANSWER" } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1 } },
      ]);
      if (body.includes("PARALLELME")) return sse(res, [
        { choices: [{ index: 0, delta: { role: "assistant", content: "Running and asking." } }] },
        { choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "call_p0", type: "function", function: { name: "run_bash", arguments: "{}" } }] } }] },
        { choices: [{ index: 0, delta: { tool_calls: [{ index: 1, id: "call_p1", type: "function", function: { name: "consult_advisor", arguments: "" } }] } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }], usage: { prompt_tokens: 1, completion_tokens: 1 } },
      ]);
      // JSONME: the continuations answer as one JSON completion, the non-streamed path.
      const json = (message, finish) => {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ id: "j", choices: [{ index: 0, message, finish_reason: finish }], usage: { prompt_tokens: 1, completion_tokens: 1 } }));
      };
      if (body.includes("JSONME") && body.includes('"tool_call_id":"call_j2"'))
        return json({ role: "assistant", content: "JSON ANSWER" }, "stop");
      if (body.includes("JSONME") && body.includes('"tool_call_id":"call_j1"'))
        return json({ role: "assistant", content: "Once more.", tool_calls: [{ id: "call_j2", type: "function", function: { name: "consult_advisor", arguments: "{}" } }] }, "tool_calls");
      if (body.includes("JSONME")) return sse(res, consult("call_j1"));
      if (body.includes('"tool_call_id":"call_n2"')) return sse(res, [
        { choices: [{ index: 0, delta: { role: "assistant", content: "NESTED ANSWER" } }] },
        { choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1 } },
      ]);
      if (body.includes('"tool_call_id":"call_n1"')) return sse(res, consult("call_n2"));
      return sse(res, consult("call_n1"));
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`C1NESTPORT=${s.address().port}`));
NESTSTUB

node c1neststub.mjs > c1neststub.out 2>&1 &
C1NESTSTUB_PID=$!
C1NESTUP=""
while [ -z "$C1NESTUP" ]; do C1NESTUP=$(sed -n 's/^C1NESTPORT=//p' c1neststub.out); done

C1_NEST_PORT=4710
mkdir -p "$SCRATCH/nest-logs"
NEST_ADVISOR_IN="$SCRATCH/nest-advisor-input.txt"
: > "$NEST_ADVISOR_IN"
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > c1nestgateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1NESTUP/v1" \
CORTI_PORT="$C1_NEST_PORT" \
CORTI_ADVISOR_STUB="$SCRATCH/advisor-stub.sh" \
ADVISOR_STUB_CAPTURE="$NEST_ADVISOR_IN" \
CORTI_DEBUG=1 \
CORTI_DEBUG_DIR="$SCRATCH/nest-logs" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1nestgateway.mjs > c1nestgw.out 2>&1 &
C1_NEST_GW_PID=$!
wait_banner c1nestgw.out || { echo "FAIL C1-NESTED gateway did not start" >&2; FAILED=$((FAILED + 1)); }

C1NESTG="http://127.0.0.1:$C1_NEST_PORT"
NESTRESP=$(curl -s -m 30 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: nest-sess-1' \
  -d "$C1BODY" "$C1NESTG/v1/messages" 2>&1 || true)
NESTSPAWNS=$(grep -c '<transcript>' "$NEST_ADVISOR_IN" || true)
# Turn 2: what the harness replays — every text block of turn 1 in one message, advisor blocks gone.
NESTBODY2='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"advise me"},{"role":"assistant","content":[{"type":"text","text":"Consulting."},{"type":"text","text":"Consulting."},{"type":"text","text":"NESTED ANSWER"}]},{"role":"user","content":"TURN2 thanks"}]}'
curl -s -m 30 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: nest-sess-1' \
  -d "$NESTBODY2" "$C1NESTG/v1/messages" > /dev/null 2>&1 || true
CAPBODY='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"CAPME"}]}'
CAPRESP=$(curl -s -m 30 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: nest-sess-2' \
  -d "$CAPBODY" "$C1NESTG/v1/messages" 2>&1 || true)
CAPSPAWNS=$(( $(grep -c '<transcript>' "$NEST_ADVISOR_IN" || true) - NESTSPAWNS ))
JSONBODY='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"JSONME"}]}'
JSONRESP=$(curl -s -m 30 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: nest-sess-3' \
  -d "$JSONBODY" "$C1NESTG/v1/messages" 2>&1 || true)
JSONSPAWNS=$(( $(grep -c '<transcript>' "$NEST_ADVISOR_IN" || true) - NESTSPAWNS - CAPSPAWNS ))
# ADVISOR-TIMEOUT: the advisor stub times out on this transcript and the model keeps consulting.
TOBEFORE=$(grep -c '<transcript>' "$NEST_ADVISOR_IN" || true)
TOBODY='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"TIMEOUTME"}]}'
TORESP=$(curl -s -m 30 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: nest-sess-6' \
  -d "$TOBODY" "$C1NESTG/v1/messages" 2>&1 || true)
TOSPAWNS=$(( $(grep -c '<transcript>' "$NEST_ADVISOR_IN" || true) - TOBEFORE ))
# STREAM-ERROR: the first call dies mid-stream; the debug log must say why.
DROPBODY='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"DROPME"}]}'
curl -s -m 30 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: nest-sess-7' \
  -d "$DROPBODY" "$C1NESTG/v1/messages" >/dev/null 2>&1 || true
TWINBEFORE=$(grep -c '<transcript>' "$NEST_ADVISOR_IN" || true)
TWINBODY='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"TWINME"}]}'
TWINRESP=$(curl -s -m 30 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: nest-sess-5' \
  -d "$TWINBODY" "$C1NESTG/v1/messages" 2>&1 || true)
TWINSPAWNS=$(( $(grep -c '<transcript>' "$NEST_ADVISOR_IN" || true) - TWINBEFORE ))
PARBODY='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"PARALLELME"}]}'
PARRESP=$(curl -s -m 30 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: nest-sess-4' \
  -d "$PARBODY" "$C1NESTG/v1/messages" 2>&1 || true)

# Every upstream request body in a session log, in order, as JSON lines.
nest_bodies() {
  cat "$SCRATCH"/nest-logs/*"$1"*.log 2>/dev/null | python3 -c '
import sys, json
t = sys.stdin.read()
for sec in t.split("UPSTREAM-REQUEST")[1:]:
    print(json.dumps(json.JSONDecoder().raw_decode(sec.split("body:", 1)[1].lstrip())[0]))
'
}
NESTBODIES=$(nest_bodies nest-sess-1)

set +e
check "C1-NESTED: the advisor ran once per consult" "$NESTSPAWNS" "2"
check "C1-NESTED: both consults rendered" \
  "$(printf '%s' "$NESTRESP" | grep -c '"type":"server_tool_use"')/$(printf '%s' "$NESTRESP" | grep -c '"type":"advisor_tool_result"')" "2/2"
check "C1-NESTED: the answer after the second consult streams through" \
  "$(printf '%s' "$NESTRESP" | grep -c 'NESTED ANSWER')" "1"
check "C1-NESTED: one message_start, one message_stop" \
  "$(printf '%s' "$NESTRESP" | grep -c 'event: message_start')/$(printf '%s' "$NESTRESP" | grep -c 'event: message_stop')" "1/1"
check "C1-NESTED: no consult_advisor call reaches the client" \
  "$(printf '%s' "$NESTRESP" | grep -c '"name":"consult_advisor"')" "0"
check "C1-NESTED: block indexes run 0..n-1 across rounds" \
  "$(printf '%s' "$NESTRESP" | python3 -c '
import sys, json
idx = [json.loads(l[5:])["index"] for l in sys.stdin.read().splitlines() if l.startswith("data:") and "\"content_block_start\"" in l]
print("ok" if idx == list(range(len(idx))) and len(idx) == 7 else idx)
')" "ok"
check "C1-NESTED: first call, two continuations, then turn 2 went upstream" \
  "$(printf '%s\n' "$NESTBODIES" | grep -c .)" "4"
check "C1-NESTED: every continuation sends the first call tools byte for byte" \
  "$(printf '%s\n' "$NESTBODIES" | python3 -c '
import sys, json
b = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
names = [t["function"]["name"] for t in b[0]["tools"]]
same = all(json.dumps(x["tools"]) == json.dumps(b[0]["tools"]) for x in b[1:3])
print("consult_advisor" in names and same)
')" "True"
check "C1-NESTED: each continuation extends the previous request" \
  "$(printf '%s\n' "$NESTBODIES" | python3 -c '
import sys, json
b = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
d = lambda m: json.dumps(m)
print(all(d(b[i+1]["messages"][:len(b[i]["messages"])]) == d(b[i]["messages"]) for i in range(2)))
')" "True"
check "C1-NESTED: a continuation carries the text written before its consult" \
  "$(printf '%s\n' "$NESTBODIES" | sed -n 2p | python3 -c '
import sys, json
m = json.loads(sys.stdin.read())["messages"]
print([x.get("content") for x in m if x.get("role") == "assistant" and x.get("tool_calls")])
')" "['Consulting.']"
check "C1-NESTED: turn 2 extends the last continuation byte for byte" \
  "$(printf '%s\n' "$NESTBODIES" | python3 -c '
import sys, json
b = [json.loads(l) for l in sys.stdin.read().splitlines() if l.strip()]
d = lambda m: json.dumps(m)
print(d(b[3]["tools"]) == d(b[2]["tools"]) and d(b[3]["messages"][:len(b[2]["messages"])]) == d(b[2]["messages"]))
')" "True"
check "C1-CAP: three advisor runs, then no more" "$CAPSPAWNS" "3"
check "C1-CAP: the fourth consult gets max_uses_exceeded" \
  "$(printf '%s' "$CAPRESP" | grep -c '"error_code":"max_uses_exceeded"')" "1"
check "C1-CAP: four consults rendered" \
  "$(printf '%s' "$CAPRESP" | grep -c '"type":"server_tool_use"')" "4"
check "C1-CAP: the fifth consult reaches the client as a tool call" \
  "$(printf '%s' "$CAPRESP" | grep -c '"name":"consult_advisor"')" "1"
check "C1-CAP: the turn ends on tool_use" \
  "$(printf '%s' "$CAPRESP" | grep -A1 'event: message_delta' | grep -c '"stop_reason":"tool_use"')" "1"
check "ADVISOR-TIMEOUT: the timed-out round is the only advisor run of the turn" "$TOSPAWNS" "1"
check "ADVISOR-TIMEOUT: later consults are answered execution_time_exceeded at once" \
  "$(printf '%s' "$TORESP" | grep -o '"error_code":"execution_time_exceeded"' | wc -l | tr -d ' ')" "3"
check "ADVISOR-TIMEOUT: the use cap still ends the loop" \
  "$(printf '%s' "$TORESP" | grep -c '"error_code":"max_uses_exceeded"')" "1"
check "STREAM-ERROR: a mid-stream drop logs its cause" \
  "$(cat "$SCRATCH"/nest-logs/*nest-sess-7*.log 2>/dev/null | grep -c 'upstream stream error: ')" "1"
check "C1-NESTED-JSON: a nested consult in a JSON continuation runs the advisor again" "$JSONSPAWNS" "2"
check "C1-NESTED-JSON: the answer streams through, the consult does not" \
  "$(printf '%s' "$JSONRESP" | grep -c 'JSON ANSWER')/$(printf '%s' "$JSONRESP" | grep -c '"name":"consult_advisor"')" "1/0"
check "C1-NESTED-JSON: one terminal message_delta and message_stop" \
  "$(printf '%s' "$JSONRESP" | grep -c 'event: message_delta')/$(printf '%s' "$JSONRESP" | grep -c 'event: message_stop')" "1/1"
check "C1-NESTED-JSON: block indexes run 0..n-1 across rounds" \
  "$(printf '%s' "$JSONRESP" | python3 -c '
import sys, json
idx = [json.loads(l[5:])["index"] for l in sys.stdin.read().splitlines() if l.startswith("data:") and "\"content_block_start\"" in l]
print("ok" if idx == list(range(len(idx))) and len(idx) == 7 else idx)
')" "ok"
check "C1-PARALLEL: a consult beside a tool call still advises and answers" \
  "$(printf '%s' "$PARRESP" | grep -c 'stub advisor advice')/$(printf '%s' "$PARRESP" | grep -c 'PAR ANSWER')" "1/1"
check "C1-PARALLEL: the other tool call reaches the client, the consult does not" \
  "$(printf '%s' "$PARRESP" | grep -c '"name":"run_bash"')/$(printf '%s' "$PARRESP" | grep -c '"name":"consult_advisor"')" "1/0"
check "C1-TWIN: two consults in one message run the advisor once" "$TWINSPAWNS" "1"
check "C1-TWIN: one advisor block pair, then the answer" \
  "$(printf '%s' "$TWINRESP" | grep -c '"type":"server_tool_use"')/$(printf '%s' "$TWINRESP" | grep -c '"type":"advisor_tool_result"')/$(printf '%s' "$TWINRESP" | grep -c 'TWIN ANSWER')" "1/1/1"
check "C1-TWIN: neither consult reaches the client; one message_stop" \
  "$(printf '%s' "$TWINRESP" | grep -c '"name":"consult_advisor"')/$(printf '%s' "$TWINRESP" | grep -c 'event: message_stop')" "0/1"
check "C1-PARALLEL: one message_stop" "$(printf '%s' "$PARRESP" | grep -c 'event: message_stop')" "1"
set -e

# ADVISOR-PINGS: pings keep flowing while the advisor runs. Claude Code shows "Waiting for API
# response" after ~90s without bytes; its SDK drops pings before the UI, so "Advising" stays.
cat > pings-advisor.sh <<'PINGADV'
#!/bin/sh
cat >/dev/null
sleep 2
printf '{"ok":true,"text":"stub advisor advice"}'
PINGADV
chmod +x pings-advisor.sh
sed -e 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  -e 's#^const PING_INTERVAL_MS = .*#const PING_INTERVAL_MS = 300;#' \
  "$REPO/gateway.mjs" > c1pinggateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$C1NESTUP/v1" \
CORTI_PORT=4722 \
CORTI_ADVISOR_STUB="$SCRATCH/pings-advisor.sh" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node c1pinggateway.mjs > c1pinggw.out 2>&1 &
C1_PING_GW_PID=$!
wait_banner c1pinggw.out || { echo "FAIL ADVISOR-PINGS gateway did not start" >&2; FAILED=$((FAILED + 1)); }
PINGRESP=$(curl -s -m 30 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: ping-sess' \
  -d "$C1BODY" "http://127.0.0.1:4722/v1/messages" 2>&1 || true)
set +e
check "ADVISOR-PINGS: pings flow between each advisor call and its result" \
  "$(printf '%s' "$PINGRESP" | python3 -c '
import sys, re
t = sys.stdin.read()
ev = re.findall(r"^event: (\S+)\ndata: (.*)$", t, re.M)
ok, open_srv, gaps = True, False, []
for name, data in ev:
    if name == "content_block_start" and "\"server_tool_use\"" in data: open_srv, n = True, 0
    elif name == "ping" and open_srv: n += 1
    elif name == "content_block_start" and "\"advisor_tool_result\"" in data: gaps.append(n); open_srv = False
print(len(gaps) == 2 and all(g >= 2 for g in gaps))
')" "True"
check "ADVISOR-PINGS: the turn still answers" "$(printf '%s' "$PINGRESP" | grep -c 'NESTED ANSWER')" "1"
set -e
kill "$C1_PING_GW_PID" 2>/dev/null || :
wait "$C1_PING_GW_PID" 2>/dev/null || :

kill "$C1_NEST_GW_PID" "$C1NESTSTUB_PID" 2>/dev/null || :
wait "$C1_NEST_GW_PID" "$C1NESTSTUB_PID" 2>/dev/null || :

# --- HANGUP: a client that hangs up mid-turn must be noticed. The body is read before the handlers
# attach, so only res 'close' reports the hang-up; the gateway then skips the continuation, kills
# the advisor child, and (pass-through) cancels the upstream request.
cat > hangup-advisor.sh <<'HANGADV'
#!/bin/sh
cat >/dev/null
sleep 4
: > "$HANGUP_ADVISOR_DONE"
printf '{"ok":true,"text":"late advice"}'
HANGADV
chmod +x hangup-advisor.sh

cat > hangupstub.mjs <<'HANGSTUB'
import fs from "node:fs";
import https from "node:https";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      fs.appendFileSync("hangup-upstream.log", `${req.url} ${body.includes('"tool_call_id"') ? "continuation" : "first"}\n`);
      res.writeHead(200, { "content-type": "text/event-stream" });
      if (req.url.startsWith("/anthropic")) {
        // Pass-through: hold the response open and record when the gateway cancels it.
        res.on("close", () => fs.appendFileSync("hangup-upstream.log", "passthrough cancelled\n"));
        return void res.write('event: message_start\ndata: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"model":"corti-s1","usage":{"input_tokens":1,"output_tokens":1}}}\n\n');
      }
      res.write('data: {"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_hang","type":"function","function":{"name":"consult_advisor","arguments":""}}]}}]}\n\n');
      res.write('data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n');
      res.end("data: [DONE]\n\n");
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`HANGPORT=${s.address().port}`));
HANGSTUB

: > hangup-upstream.log
node hangupstub.mjs > hangupstub.out 2>&1 &
HANGSTUB_PID=$!
HANGUP=""
while [ -z "$HANGUP" ]; do HANGUP=$(sed -n 's/^HANGPORT=//p' hangupstub.out); done

mkdir -p "$SCRATCH/hangup-logs"
HANGUP_ADVISOR_DONE="$SCRATCH/hangup-advisor-done"
rm -f "$HANGUP_ADVISOR_DONE"
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > hangupgateway.mjs
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$HANGUP/v1" \
CORTI_PORT=4720 \
CORTI_ADVISOR_STUB="$SCRATCH/hangup-advisor.sh" \
HANGUP_ADVISOR_DONE="$HANGUP_ADVISOR_DONE" \
CORTI_DEBUG=1 \
CORTI_DEBUG_DIR="$SCRATCH/hangup-logs" \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node hangupgateway.mjs > hangupgw.out 2>&1 &
HANGUP_GW_PID=$!
wait_banner hangupgw.out || { echo "FAIL HANGUP gateway did not start" >&2; FAILED=$((FAILED + 1)); }

# Hang up 1s into the 4s advisor run, then give the advisor time it would have needed to finish.
curl -s -m 1 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: hangup-sess' \
  -d "$C1BODY" "http://127.0.0.1:4720/v1/messages" > /dev/null 2>&1 || true
curl -s -m 1 -N -H 'content-type: application/json' -H 'x-api-key: x' \
  -d "$C1BODY" "http://127.0.0.1:4720/anthropic/v1/messages" > /dev/null 2>&1 || true
sleep 6

set +e
check "HANGUP: the gateway records the hang-up during the advisor run" \
  "$(cat "$SCRATCH"/hangup-logs/*hangup-sess*.log 2>/dev/null | grep -c 'client-abort')" "1"
check "HANGUP: no continuation is sent for a client that left" \
  "$(grep -c '^/v1/chat/completions continuation' hangup-upstream.log)" "0"
check "HANGUP: the advisor child is stopped, not left to finish" \
  "$([ -e "$HANGUP_ADVISOR_DONE" ] && echo finished || echo stopped)" "stopped"
check "HANGUP: a pass-through request is cancelled upstream" \
  "$(grep -c '^passthrough cancelled' hangup-upstream.log)" "1"
set -e

# The rewrite path: a replayed consult the harness answered "Unknown tool" is answered by the
# intercept before anything goes upstream. A hang-up then must stop that advisor child too.
rm -f "$HANGUP_ADVISOR_DONE"
RWBODY='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"advise me"},{"role":"assistant","content":[{"type":"tool_use","id":"toolu_rw","name":"consult_advisor","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_rw","is_error":true,"content":"Error: No such tool available: consult_advisor"}]}]}'
curl -s -m 1 -N -H 'content-type: application/json' -H 'x-claude-code-session-id: hangup-rw' \
  -d "$RWBODY" "http://127.0.0.1:4720/v1/messages" > /dev/null 2>&1 || true
sleep 6
set +e
check "HANGUP: a rewrite-path advisor child is stopped on hang-up" \
  "$([ -e "$HANGUP_ADVISOR_DONE" ] && echo finished || echo stopped)" "stopped"
set -e

kill "$HANGUP_GW_PID" "$HANGSTUB_PID" 2>/dev/null || :
wait "$HANGUP_GW_PID" "$HANGSTUB_PID" 2>/dev/null || :

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
CALADVBODY='{"model":"corti-s1","max_tokens":16,"stream":true,'"$C1TOOLS"',"messages":[{"role":"user","content":"TRIGGER-ADVISOR '"$CALPAD"'"}]}'
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

# --- IMG e2e: the experimental opt-in gates whether the image-capability lookup sees a beta.
# A stub serves /models with the multimodal corti-s1-beta only when ?experimental=true is present,
# and records the /chat/completions body so we can assert an image reached upstream intact vs was
# described away. Two gateway launches: opted-in (image passes through) and not (image described).
cat > imgstub.mjs <<'IMGSTUB'
import fs from "node:fs";
import https from "node:https";
import { appendFileSync } from "node:fs";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      // Match the path portion: /models arrives as /v1/models?experimental=true (query attached).
      const path = req.url.split("?")[0];
      if (path.endsWith("/models")) {
        // Only the experimental catalog lists the multimodal corti-s1-beta.
        const exp = req.url.includes("experimental=true");
        const data = [
          { id: "corti-s1", capabilities: { image_input: false, reasoning: true },
            effort: { supported: true, levels: ["low", "high", "max"] } },
          { id: "corti-s1-mini", capabilities: { image_input: false, reasoning: true },
            effort: { supported: true, levels: ["low", "medium", "xhigh"] } },
          { id: "corti-s1-beta", capabilities: { image_input: true, reasoning: true } },
          { id: "corti-s1-mini-instant", capabilities: { image_input: true, reasoning: false } },
        ];
        res.writeHead(200, { "content-type": "application/json" });
        return res.end(JSON.stringify({
          data: exp ? data : data.filter((m) => !m.id.endsWith("-beta")),
          object: "list",
        }));
      }
      // The gateway posts upstream to /v1/chat/completions. An intact image becomes an image_url
      // part in the translated body; a described image becomes text. The vision sidecall re-enters
      // the gateway's own /v1/messages and posts upstream as another /chat/completions carrying
      // response_format+skipImages — so count those to detect delegation, and image_url to detect
      // passthrough. Both signals come from the same log.
      if (path.endsWith("/chat/completions")) {
        appendFileSync("imgchat.log", body + "\n<<<END>>>\n");
        res.writeHead(200, { "content-type": "application/json" });
        return res.end(JSON.stringify({ id: "c", choices: [{ index: 0,
          message: { role: "assistant", content: "ok" }, finish_reason: "stop" }],
          usage: { prompt_tokens: 1, completion_tokens: 1 } }));
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end("{}");
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`IMGPORT=${s.address().port}`));
IMGSTUB

node imgstub.mjs > imgstub.out 2>&1 &
IMGSTUB_PID=$!
IMGUP=""
while [ -z "$IMGUP" ]; do IMGUP=$(sed -n 's/^IMGPORT=//p' imgstub.out); done

# An image-bearing Anthropic request against the opus alias; mapModel resolves it to the pinned
# opus id before interceptImages checks the capability set. The image is a 1x1 PNG (iVBORw0KGgo).
IMG_BODY='{"model":"claude-opus-4","max_tokens":16,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}},{"type":"text","text":"what is this"}]}]}'

img_run() {
  # $1 = gateway port, $2 = experimental env value (1 or unset)
  _ir_port="$1"; _ir_exp="$2"
  rm -f imgchat.log
  _ir_gw="imggateway_$1.mjs"
  sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
    "$REPO/gateway.mjs" > "$_ir_gw"
  if [ -n "$_ir_exp" ]; then
    CORTI_EXPERIMENTAL="$_ir_exp" \
    CORTI_VISION_MODEL="" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="corti-s1-beta" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="corti-s1-mini-instant" \
    CORTI_BEARER=test \
    CORTI_BASE_URL="https://127.0.0.1:$IMGUP/v1" \
    CORTI_PORT="$_ir_port" \
    NODE_TLS_REJECT_UNAUTHORIZED=0 \
    node "$_ir_gw" > "imggw_$1.out" 2>&1 &
  else
    CORTI_EXPERIMENTAL="" \
    CORTI_VISION_MODEL="" \
    ANTHROPIC_DEFAULT_OPUS_MODEL="corti-s1-beta" \
    ANTHROPIC_DEFAULT_HAIKU_MODEL="corti-s1-mini-instant" \
    CORTI_BEARER=test \
    CORTI_BASE_URL="https://127.0.0.1:$IMGUP/v1" \
    CORTI_PORT="$_ir_port" \
    NODE_TLS_REJECT_UNAUTHORIZED=0 \
    node "$_ir_gw" > "imggw_$1.out" 2>&1 &
  fi
  _ir_pid=$!
  wait_banner "imggw_$1.out" || { echo "FAIL IMG gateway did not start (port $_ir_port)" >&2; FAILED=$((FAILED + 1)); }
  curl -s -m 15 -H 'content-type: application/json' -d "$IMG_BODY" "http://127.0.0.1:$_ir_port/v1/messages" >/dev/null || :
  kill "$_ir_pid" 2>/dev/null || :; wait "$_ir_pid" 2>/dev/null || :
  unset _ir_port _ir_exp _ir_gw _ir_pid
}

# Opted in: /models?experimental=true lists corti-s1-beta → sighted → the image passes through
# to upstream as an image_url in the one primary post, and no describe sidecall fires.
img_run 4301 1
check "IMG: opted-in makes one upstream post (primary, no sidecall)" \
  "$(grep -c '<<<END>>>' imgchat.log 2>/dev/null || :)" "1"
check "IMG: opted-in image reaches upstream as image_url" \
  "$(grep -c 'image_url' imgchat.log 2>/dev/null || :)" "1"
check "IMG: opted-in does not delegate to the vision sidecall" \
  "$(grep -c 'response_format' imgchat.log 2>/dev/null || :)" "0"

# Not opted in: plain /models omits corti-s1-beta → treated as blind → the image is described via
# the vision sidecall, which posts upstream with response_format+skipImages (a 2nd post). The
# image_url in the log comes from that sidecall's own re-post, so 1 — the sidecall-only signature
# is image_url *with* response_format.
img_run 4302 ""
check "IMG: not-opted-in delegates to the vision sidecall" \
  "$(grep -c 'response_format' imgchat.log 2>/dev/null || :)" "1"
check "IMG: not-opted-in sidecall post carries image_url" \
  "$(grep -c 'image_url' imgchat.log 2>/dev/null || :)" "1"

# Blind CORTI_VISION_MODEL must step down to the sighted sonnet and still fire the sidecall —
# drives the gateway wiring of resolveVisionModel that the pure tests do not reach.
rm -f imgchat.log
_ir_gw="imggateway_4303.mjs"
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > "$_ir_gw"
CORTI_EXPERIMENTAL="1" \
CORTI_VISION_MODEL="corti-s1" \
ANTHROPIC_DEFAULT_OPUS_MODEL="corti-s1" \
ANTHROPIC_DEFAULT_HAIKU_MODEL="corti-s1" \
ANTHROPIC_DEFAULT_SONNET_MODEL="corti-s1-mini-instant" \
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$IMGUP/v1" \
CORTI_PORT=4303 \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node "$_ir_gw" > "imggw_4303.out" 2>&1 &
_ir_pid=$!
wait_banner "imggw_4303.out" || { echo "FAIL IMG step-down gateway did not start" >&2; FAILED=$((FAILED + 1)); }
curl -s -m 15 -H 'content-type: application/json' -d "$IMG_BODY" "http://127.0.0.1:4303/v1/messages" >/dev/null || :
kill "$_ir_pid" 2>/dev/null || :; wait "$_ir_pid" 2>/dev/null || :
check "IMG: blind override steps down and fires the sidecall" \
  "$(grep -c 'response_format' imgchat.log 2>/dev/null || :)" "1"
check "IMG: step-down sidecall targets the sighted sonnet" \
  "$(grep -c '"model":"corti-s1-mini-instant"' imgchat.log 2>/dev/null || :)" "1"
check "IMG: step-down logs a deduped warning naming the blind override" \
  "$(grep -c 'corti-s1" is not multimodal' imggw_4303.out 2>/dev/null || :)" "1"
unset _ir_gw _ir_pid

# A failing /models fetch must still fire the sidecall on the default vision model — the image
# cache would otherwise pin the outage's placeholders for the whole session.
cat > imgstub503.mjs <<'IMGSTUB503'
import fs from "node:fs";
import https from "node:https";
import { appendFileSync } from "node:fs";
const s = https.createServer(
  { key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") },
  (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString();
      const path = req.url.split("?")[0];
      if (path.endsWith("/models")) { res.writeHead(503); return res.end(""); }
      if (path.endsWith("/chat/completions")) {
        appendFileSync("imgchat503.log", body + "\n<<<END>>>\n");
        res.writeHead(200, { "content-type": "application/json" });
        return res.end(JSON.stringify({ id: "c", choices: [{ index: 0, message: { role: "assistant", content: "ok" }, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1 } }));
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end("{}");
    });
  },
);
s.listen(0, "127.0.0.1", () => console.log(`IMGPORT503=${s.address().port}`));
IMGSTUB503
node imgstub503.mjs > imgstub503.out 2>&1 &
IMGSTUB503_PID=$!
IMGUP503=""
while [ -z "$IMGUP503" ]; do IMGUP503=$(sed -n 's/^IMGPORT503=//p' imgstub503.out); done
rm -f imgchat503.log
_ir_gw="imggateway_4304.mjs"
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > "$_ir_gw"
CORTI_EXPERIMENTAL="1" \
CORTI_VISION_MODEL="" \
ANTHROPIC_DEFAULT_OPUS_MODEL="corti-s1" \
ANTHROPIC_DEFAULT_HAIKU_MODEL="corti-s1" \
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$IMGUP503/v1" \
CORTI_PORT=4304 \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node "$_ir_gw" > "imggw_4304.out" 2>&1 &
_ir_pid=$!
wait_banner "imggw_4304.out" || { echo "FAIL IMG null-models gateway did not start" >&2; FAILED=$((FAILED + 1)); }
curl -s -m 15 -H 'content-type: application/json' -d "$IMG_BODY" "http://127.0.0.1:4304/v1/messages" >/dev/null || :
kill "$_ir_pid" 2>/dev/null || :; wait "$_ir_pid" 2>/dev/null || :
# imageModels is null after the 503, so the resolver falls back to VISION_DEFAULT and the sidecall
# fires against corti-s1-mini-instant (rather than short-circuiting to no_sighted_model).
check "IMG: null /models still fires the sidecall via VISION_DEFAULT" \
  "$(grep -c 'response_format' imgchat503.log 2>/dev/null || :)" "1"
check "IMG: null /models sidecall targets VISION_DEFAULT" \
  "$(grep -c '"model":"corti-s1-mini-instant"' imgchat503.log 2>/dev/null || :)" "1"
kill "$IMGSTUB503_PID" 2>/dev/null || :
wait "$IMGSTUB503_PID" 2>/dev/null || :
unset _ir_gw _ir_pid

# EFFORT e2e: the boot catalog fetch feeds effort levels into translation. A level the model does
# not list must never go upstream (corti-s1-mini 400s on high); a listed one passes through.
rm -f imgchat.log
_ef_gw="effortgateway_4304.mjs"
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > "$_ef_gw"
CORTI_BEARER=test \
CORTI_BASE_URL="https://127.0.0.1:$IMGUP/v1" \
CORTI_PORT=4304 \
NODE_TLS_REJECT_UNAUTHORIZED=0 \
node "$_ef_gw" > "effortgw_4304.out" 2>&1 &
_ef_pid=$!
wait_banner "effortgw_4304.out" || { echo "FAIL EFFORT gateway did not start" >&2; FAILED=$((FAILED + 1)); }
curl -s -m 15 -H 'content-type: application/json' \
  -d '{"model":"corti-s1-mini","max_tokens":16,"thinking":{"type":"adaptive"},"messages":[{"role":"user","content":"hi"}]}' \
  "http://127.0.0.1:4304/v1/messages" >/dev/null || :
check "EFFORT: mini default high goes upstream as xhigh" \
  "$(grep -c '"reasoning_effort":"xhigh"' imgchat.log 2>/dev/null || :)" "1"
check "EFFORT: mini never receives high" \
  "$(grep -c '"reasoning_effort":"high"' imgchat.log 2>/dev/null || :)" "0"
rm -f imgchat.log
curl -s -m 15 -H 'content-type: application/json' \
  -d '{"model":"corti-s1","max_tokens":16,"thinking":{"type":"adaptive"},"output_config":{"effort":"low"},"messages":[{"role":"user","content":"hi"}]}' \
  "http://127.0.0.1:4304/v1/messages" >/dev/null || :
check "EFFORT: s1 picker low is sent as low" \
  "$(grep -c '"reasoning_effort":"low"' imgchat.log 2>/dev/null || :)" "1"
rm -f imgchat.log
curl -s -m 15 -H 'content-type: application/json' -H 'authorization: Bearer local-gateway-noadvisor-openai' \
  -d '{"model":"corti-s1","max_tokens":32000,"thinking":{"type":"adaptive"},"messages":[{"role":"user","content":"hi"}]}' \
  "http://127.0.0.1:4304/v1/messages" >/dev/null || :
check "ADVISOR-BUDGET: the advisor child reaches upstream with a thinking budget" \
  "$(grep -c '"thinking_token_budget":8192' imgchat.log 2>/dev/null || :)" "1"
rm -f imgchat.log
curl -s -m 15 -H 'content-type: application/json' \
  -d '{"model":"corti-s1","max_tokens":32000,"thinking":{"type":"adaptive"},"messages":[{"role":"user","content":"hi"}]}' \
  "http://127.0.0.1:4304/v1/messages" >/dev/null || :
check "ADVISOR-BUDGET: an ordinary request carries none" \
  "$(grep -c 'thinking_token_budget' imgchat.log 2>/dev/null || :)" "0"
kill "$_ef_pid" 2>/dev/null || :; wait "$_ef_pid" 2>/dev/null || :
unset _ef_gw _ef_pid

# CATALOG-WAIT: a slow /models must only hold the requests that read effort levels.
cat > slowmodels.mjs <<'SLOWSTUB'
import fs from "node:fs";
import https from "node:https";
https.createServer({ key: fs.readFileSync("key.pem"), cert: fs.readFileSync("cert.pem") }, (req, res) => {
  req.resume();
  req.on("end", () => {
    if (req.url.split("?")[0].endsWith("/models")) return void setTimeout(() => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ object: "list", data: [{ id: "corti-s1", capabilities: { reasoning: true }, effort: { supported: true, levels: ["low", "high", "max"] } }] }));
    }, 8000);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ id: "c", choices: [{ index: 0, message: { role: "assistant", content: "fast" }, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1 } }));
  });
}).listen(0, "127.0.0.1", function () { console.log(`SLOWPORT=${this.address().port}`); });
SLOWSTUB
node slowmodels.mjs > slowmodels.out 2>&1 &
SLOWSTUB_PID=$!
SLOWUP=""
while [ -z "$SLOWUP" ]; do SLOWUP=$(sed -n 's/^SLOWPORT=//p' slowmodels.out); done
sed 's#^const BASE_URL_PATTERN = .*#const BASE_URL_PATTERN = /^https:\\/\\/127\\.0\\.0\\.1:[0-9]+\\/v1$/;#' \
  "$REPO/gateway.mjs" > slowgateway_4305.mjs
CORTI_BEARER=test CORTI_BASE_URL="https://127.0.0.1:$SLOWUP/v1" CORTI_PORT=4305 NODE_TLS_REJECT_UNAUTHORIZED=0 \
  node slowgateway_4305.mjs > slowgw_4305.out 2>&1 &
SLOWGW_PID=$!
wait_banner slowgw_4305.out || { echo "FAIL CATALOG-WAIT gateway did not start" >&2; FAILED=$((FAILED + 1)); }
check "CATALOG-WAIT: a request without thinking does not wait on a slow /models" \
  "$(curl -s -m 3 -H 'content-type: application/json' \
    -d '{"model":"corti-s1","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' \
    "http://127.0.0.1:4305/v1/messages" | grep -c '"text":"fast"')" "1"
kill "$SLOWGW_PID" "$SLOWSTUB_PID" 2>/dev/null || :
wait "$SLOWGW_PID" "$SLOWSTUB_PID" 2>/dev/null || :

kill "$IMGSTUB_PID" 2>/dev/null || :
wait "$IMGSTUB_PID" 2>/dev/null || :

if [ "$FAILED" -gt 0 ]; then
  printf '\n%s check(s) failed\n' "$FAILED"
  exit 1
fi
printf '\nall checks passed\n'
