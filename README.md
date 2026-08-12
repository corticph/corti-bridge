# corti-claude-proxy

Local gateway that lets Claude Code talk to Corti's OpenAI-compatible API while speaking Anthropic Messages to the client.

Claude Code sends Anthropic Messages requests to localhost; the proxy translates them to OpenAI Chat Completions against `CORTI_BASE_URL`, swaps in the real auth header, and translates responses back — including a full SSE event machine for streaming. No dependencies, no build step.

## Prerequisites

`CORTI_BEARER` and `CORTI_BASE_URL` must already be set in your shell environment (e.g. via `~/.env` sourced from your shell's rc file, or a project `.env` you've loaded). This proxy doesn't manage secrets — it just reads them. Node.js is required (any version that can run `gateway.mjs`; modern LTS recommended).

Both `setup.sh` and `bin/corti-claude` are POSIX `sh` — they run the same under bash, zsh, or dash regardless of what your login shell is (fish included, since it execs scripts via their shebang rather than parsing them).

## Install

```bash
git clone https://github.com/corticph/corti-claude-proxy ~/projects/corti-claude-proxy
cd ~/projects/corti-claude-proxy
./setup.sh
```

`setup.sh` installs the `corti-claude` wrapper to `~/.local/bin/`.

```bash
corti-claude
```

That's it. The wrapper starts the proxy if it's not running (and restarts it if it's stale — wrong mode, debug mismatch, or a pre-modes binary), points Claude Code at it, then launches `claude`.

## What it does

- Translates Anthropic Messages ⇄ OpenAI Chat Completions, bidirectionally:
  - system prompt (string or blocks) merged with in-conversation system entries into one system message
  - tools mapped to function tools; server-side tools (web_search etc.) stripped
  - tool_use/tool_result pairing repaired for re-wound histories; parallel tool calls round-trip byte-exact via index-keyed streaming
  - Anthropic `thinking` config maps to upstream `reasoning_effort` + `thinking_token_budget`; upstream reasoning streams back as Anthropic thinking blocks
  - images → `image_url` parts (including images inside tool results, attached as a following user message)
  - history thinking blocks stripped on re-entry (signatures are synthetic, see below)
- Discards whatever auth token the client sends, injects the real `CORTI_BEARER`
- Handles `/v1/messages/count_tokens` locally (estimator: chars/4 + tools schema + per-image flat count)
- Translates upstream errors into Anthropic's envelope — critically, context-overflow conditions become `400 prompt is too long`, which is what drives Claude Code's auto-compact
- Serves `/v1/models` (translated catalog) for gateway model discovery
- Optionally logs every request and response to a timestamped file (see [Debug logging](#debug-logging))

## Files

```
corti-claude-proxy/
├── gateway.mjs         # The server: routing, phases, upstream client, logging (zero dependencies)
├── translate.mjs       # All wire-format logic: request/response/SSE translation, errors, token estimate
├── bin/corti-claude    # Wrapper: starts proxy, launches claude
└── setup.sh            # Installer
```

After install, the runtime layout is:

```
~/.corti-claude/             # Claude Code config dir (CLAUDE_CONFIG_DIR)
├── settings.json            # Your model config (optional, see below — not installed by this repo)
└── gateway.log               # Proxy log

~/.local/bin/corti-claude    # The wrapper

~/Library/Logs/corti-claude-proxy/   # Debug logs, one per gateway start (only when CORTI_DEBUG is set)
```

## Environment

Read directly from the shell — no local secrets file.

| Var | Required | Notes |
|---|---|---|
| `CORTI_BEARER` | yes | Sent upstream, never the client's own token |
| `CORTI_BASE_URL` | yes | Must match `https://ai.<env>.corti.app/v1`; used as-is (OpenAI-compatible endpoints) |
| `CORTI_HOST` | no | Proxy bind address, default `127.0.0.1` |
| `CORTI_PORT` | no | Proxy bind port, default `4000` |
| `CORTI_UPSTREAM_MODE` | no | `openai` (default, translating gateway) or `anthropic` (legacy pass-through, see [Legacy `anthropic` mode](#legacy-anthropic-mode)) |
| `CORTI_REASONING_MODE` | no | `thinking` (default: reasoning becomes Anthropic thinking blocks), `text` (fold into reply text), `drop` |
| `CORTI_DEBUG` | no | Any value except `0`/`false`/`no`/`off` turns on request/response logging |
| `CORTI_DEBUG_DIR` | no | Where debug logs go; defaults per platform (see below) |
| `CORTI_DEBUG_MAX_BODY` | no | Per-body byte cap, default `65536`; `0` means unlimited |

`CC_PROXY_DIR` (defaults to `~/projects/corti-claude-proxy`) tells the wrapper where `gateway.mjs` lives. `CC_PROXY_BIN_DIR` (defaults to `~/.local/bin`) controls where the wrapper is installed. `CC_PROXY_CONFIG_DIR` overrides the `CLAUDE_CONFIG_DIR` the wrapper uses — it defaults to `~/.corti-claude` so existing installs keep working without setting anything.

`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and `CLAUDE_CODE_ATTRIBUTION_HEADER=0` are exported by the `corti-claude` wrapper itself — that's plumbing this tool owns, not something you configure. (The attribution header is off because a per-request attribution line in the system prompt would defeat upstream prefix caching.)

## Debug logging

Set `CORTI_DEBUG` and the gateway writes every request and response to a timestamped file, one per gateway start:

```bash
CORTI_DEBUG=1 corti-claude
```

The wrapper prints the log path on startup, and `/health` reports it too:

```bash
curl -s http://127.0.0.1:4000/health
# {"status":"healthy","mode":"openai","upstream":"https://ai.eu.corti.app/v1","debug":"/Users/you/Library/Logs/corti-claude-proxy/gateway-2026-08-08T14-19-35-470Z.log"}
```

In `openai` mode each request id gets up to four entries — REQUEST (what the client sent), UPSTREAM-REQUEST (translated OpenAI body), UPSTREAM-RESPONSE (raw upstream bytes), RESPONSE (translated bytes sent to the client, with a `note` of `completed`/`upstream-error`/`client-abort`/`watchdog-timeout`/`parse-fail` and per-request diagnostics). Mistranslation debugging is a diff problem: compare REQUEST→UPSTREAM-REQUEST and UPSTREAM-RESPONSE→RESPONSE.

**The log contains complete prompt bodies** — your source code, file contents, whatever Claude Code sent — including their translated forms. `CORTI_BEARER` is never written, and `authorization`/`x-api-key`/`cookie` headers are redacted, but treat the files as sensitive. The directory is created `0700` and files `0600`. Nothing rotates or prunes them; delete them yourself when done.

Where they go, in order of precedence:

| | |
|---|---|
| `CORTI_DEBUG_DIR` | If set, used as-is |
| macOS | `~/Library/Logs/corti-claude-proxy/` |
| Linux/other | `$XDG_STATE_HOME/corti-claude-proxy/` (or `~/.local/state/...`) |
| Fallback | `$TMPDIR/corti-claude-proxy/` if the above isn't writable |

Bodies are capped at 64 KB each by default so a long streaming response doesn't produce a giant file; raise it with `CORTI_DEBUG_MAX_BODY`, or set `0` for no cap. Truncated bodies are marked as such.

The gateway is a background process that outlives any single `corti-claude` run, so toggling `CORTI_DEBUG` (or `CORTI_UPSTREAM_MODE`) has to restart it — the wrapper handles that automatically, in both directions. If you started the gateway some other way, stop it yourself first.

## Model config

Which Corti model backs each Claude Code tier is *not* managed by this repo — it changes independently of the proxy, so it belongs in config you own, not something baked into this repo's source.

To set it, create `~/.corti-claude/settings.json` yourself (the wrapper points `CLAUDE_CONFIG_DIR` there):

```json
{
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "corti-s1",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "corti-s1-instant",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "corti-s1-mini-instant",
    "ANTHROPIC_CUSTOM_MODEL_OPTION": "corti-s1-ultra-beta",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Corti S1 Ultra (beta)",
    "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "262144"
  }
}
```

`262144` is the probed context window of every current Corti tier — adjust if Corti ships smaller-context models. `corti-s1-ultra-beta` is offered as a custom option rather than a default because it's an RC build. Adjust model names to whatever Corti currently offers — run `./setup.sh --detect-models` (below) if you're unsure what's available. This file is entirely yours; `setup.sh` never creates, touches, or overwrites it (unless you explicitly ask it to — see below).

### `setup.sh --detect-models`

Optional shortcut: fetches Corti's live model catalog via `curl "$CORTI_BASE_URL/models"` and writes `~/.corti-claude/settings.json` from preference lists — opus: `corti-s1` → `corti-s1-ultra-beta` → `corti-s1-beta`; sonnet: `corti-s1-instant` → `corti-s1`; haiku: `corti-s1-mini-instant` → `corti-s1-tiny-instant` → `corti-s1-mini`; custom: `corti-s1-ultra-beta` → `corti-s1-mini`. Embedding models never qualify; slots that miss their preference list fall back to the first unused catalog model with a printed warning.

```bash
./setup.sh --detect-models
```

It prints out what it picked and won't overwrite an existing `settings.json` without asking first.

## Known degradations (openai mode)

Compared to first-party Anthropic, this setup cannot support:

- **WebSearch and other server-side tools** — they're stripped from requests; the model has no live web access.
- **PDF input** — base64 PDF document blocks are replaced with a visible `[PDF document omitted...]` placeholder.
- **Image support depends on the resolved model** — e.g. upstream rejects images for `corti-s1` (DS V4F) with a clean 400, while `corti-s1-ultra-beta` and `corti-s1-mini-instant` accept them. Pick a multimodal tier in `settings.json` if you use image workflows.
- **Prompt-caching economics** — caching is upstream's automatic prefix cache; usage reports zeros for cache fields when caching isn't active.
- **Reasoning signatures are synthetic** — thinking blocks emitted by the proxy carry a constant signature (`corti-proxy`, base64). Claude Code accepts and re-sends them; the proxy strips them from history on re-entry. If you ever take a session from `~/.corti-claude` and resume it against real Anthropic, those blocks will fail server-side signature validation — filter them out first.
- **~1 MB upstream body cap** — very large pastes/libraries of images that exceed the byte cap are answered locally: near-context-window turns become `prompt is too long` (compaction kicks in), byte-bound image-heavy turns get an honest 413.

## Legacy `anthropic` mode

`CORTI_UPSTREAM_MODE=anthropic` runs the gateway as a thin pass-through to Corti's `/anthropic` endpoint — the pre-rewrite behavior: no translation, every path forwarded, auth swap only. Two intentional deltas: `/health` reports the mode field, and `count_tokens` uses the current estimator.

Use it to escape hatch a translation bug, or as a comparison harness: run a session in each mode and diff the debug logs. Note that Corti's `/anthropic` endpoint gets less support than the OpenAI one — this mode exists as a fallback, not a target.

## Upgrading

1. `git pull`
2. `./setup.sh` (refreshes the wrapper)
3. `corti-claude` — the wrapper auto-restarts a stale gateway (old binary, wrong mode, debug mismatch)
4. Re-run `./setup.sh --detect-models` if your `settings.json` predates the 262144 context window or you want the refresh (it warns but never overwrites without asking)
5. If you ever need the old behavior back entirely: `git checkout main` — no other state changes were made
