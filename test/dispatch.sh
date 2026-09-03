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
      // The continuation carries the synthesized tool_result for consult_advisor.
      const isContinuation = body.includes('"tool_result"') && body.includes('consult_advisor');
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
while ! grep -q "corti-proxy on" c1gw.out 2>/dev/null; do :; done

C1G="http://127.0.0.1:$C1_GW_PORT"
C1BODY='{"model":"corti-s1","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"advise me"}]}'
C1RESP=$(curl -s -m 15 -N -H 'content-type: application/json' -d "$C1BODY" "$C1G/v1/messages" 2>&1)

check "C1: continuation 500 ends with the text note" \
  "$(printf '%s' "$C1RESP" | grep -c 'proceed using the advice above')" "1"
check "C1: no second advisor_tool_result_error after success" \
  "$(printf '%s' "$C1RESP" | grep -c 'advisor_tool_result_error')" "0"
check "C1: advisor advice was streamed (advisor_result)" \
  "$(printf '%s' "$C1RESP" | grep -c 'stub advisor advice')" "1"
# The terminal message_delta carries end_turn; the advisor_result block also carries stop_reason
# end_turn, so assert on the message_delta event specifically (exactly one terminal delta).
C1_ENDTURN=$(printf '%s' "$C1RESP" | grep -A1 'event: message_delta' | grep -c '"stop_reason":"end_turn"')
check "C1: turn ends with end_turn (terminal message_delta)" "$C1_ENDTURN" "1"

kill "$C1_GW_PID" "$C1STUB_PID" 2>/dev/null || :
wait "$C1_GW_PID" "$C1STUB_PID" 2>/dev/null || :

if [ "$FAILED" -gt 0 ]; then
  printf '\n%s check(s) failed\n' "$FAILED"
  exit 1
fi
printf '\nall checks passed\n'
