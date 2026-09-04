# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A local gateway that lets Claude Code run on Corti's API. Claude Code speaks Anthropic Messages to `127.0.0.1:4192`; the proxy translates to OpenAI Chat Completions against `CORTI_BASE_URL` (or passes through to Corti's `/anthropic` endpoint), swaps in `CORTI_BEARER`, and translates responses back, including streaming SSE.

**Zero dependencies, no build step, no package.json — this is intentional.** Plain Node ≥20 ESM (`.mjs`) plus POSIX `sh` (not bash — scripts must run under dash/zsh/bash alike). Don't introduce npm packages, a build pipeline, or bashisms.

## Commands

There is no build or lint step. Tests are plain shell scripts, each a self-contained suite:

```bash
sh test/translate.sh   # pure-function tests for translate.mjs — offline, no credentials
sh test/models.sh      # tier-mapping tests for lib/models.mjs against captured fixtures
sh test/retry.sh       # pure-function tests for lib/retry.mjs
sh test/smoke.sh       # sandboxed install + idempotency for setup.sh (scratch HOME)
sh test/dispatch.sh    # one gateway serving both modes, selected per request by path prefix
```

There is no per-test runner — each script runs its whole suite and prints `ok`/`FAIL` lines. To iterate on one case, comment out or edit within the script.

`test/dispatch.sh` runs lifecycle tests against a *copy* of the gateway with the Corti-URL check relaxed; never point `CORTI_PROXY_DIR` at a live clone when running it (its pattern-kill fallback matches by clone path).

Running the gateway directly (normally the wrapper does this):

```bash
CORTI_BEARER=… CORTI_BASE_URL=https://ai.<env>.corti.app/v1 node gateway.mjs
curl -s localhost:4192/health   # reports mode, upstream, gatewayVersion, debug log path
```

## Architecture

Two files carry almost everything; the split is deliberate and worth preserving:

- **`gateway.mjs`** — the server: routing, per-request mode dispatch, upstream HTTP client, retries/timeouts, debug logging. Never wire-format logic.
- **`translate.mjs`** — *all* wire-format logic: Anthropic Messages ⇄ OpenAI Chat Completions for requests, non-stream responses, and SSE (`createStreamTranslator`), error-envelope translation, token estimation, plus the WebSearch intercept (Tavily, DuckDuckGo fallback) and the `consult_advisor` tool (`runAdvisor`, prompts in `lib/advisor-*`). Mostly pure functions — this is what makes `test/translate.sh` hermetic. Validation failures throw `TranslateRejection` (status + Anthropic error envelope).

Supporting pieces:

- **`bin/corti-bridge`** — POSIX sh wrapper installed to `~/.local/bin`. Owns gateway lifecycle (per-port pid file, `/health` payload check, stale-gateway auto-restart), reads `~/.corti-bridge/models.env`, and exports model aliases + `ANTHROPIC_BASE_URL` as process-scoped env before launching `claude`. Also dispatches subcommands: `doctor` (diagnostics), `models` (interactive tier picker), `theme` (prints the lime-mascot TUI theme + install steps — no writes). The gateway never reads `models.env` — only the wrapper does, at launch. Nothing is ever written to any `settings.json`.
- **`setup.sh` + `lib/*.sh`** — installer. Preflight checks deps then creds before writing anything; a partial install exits 1 rather than leaving a half-configured state. Offers a profile menu (which Claude Code config dir Corti sessions use) and fetches the model catalog. Re-runnable; `--yes` for unattended, `--fresh` to re-fetch the catalog.
- **`lib/models.mjs`** — ranks Corti's catalog into fable/opus/sonnet/haiku tiers by model-ID *shape* (size/speed/channel suffixes), not hardcoded names, so a new model generation needs no code change. Emits `models.env`; also serves the picker's candidate lists (`--candidates`/`--emit`) so the menu and the ranker can't drift.
- **`lib/doctor.sh`** — `corti-bridge doctor`: ~18 passive checks on the install, gateway, and state, plus an active `/models` probe under `--deep`. Doctor output goes to stdout (a report) — a deliberate exception to the `ui_*`→stderr invariant, so `doctor | grep FAIL` and `doctor > file` work.
- **`lib/retry.mjs`** — the upstream retry policy as pure functions/constants, tested in isolation.

### Mode dispatch

One gateway process serves both modes simultaneously, chosen per request by URL path prefix: bare paths → `openai` translation mode; `/anthropic/...` prefix → thin pass-through (auth swap only). The wrapper selects a mode by pointing `ANTHROPIC_BASE_URL` at `$GATEWAY` or `$GATEWAY/anthropic` — so switching modes never requires a restart and doesn't affect other sessions. `CORTI_UPSTREAM_MODE=anthropic` exists only for pre-dispatch wrappers and re-meanings bare paths at boot.

### Invariants to keep

- **Auth swap**: the client's token is always discarded; only `CORTI_BEARER` goes upstream. `CORTI_BASE_URL` must match `https://ai.<env>.corti.app/v1` or the gateway refuses to boot.
- **Context overflow must become `400 prompt is too long`** (`promptTooLong`) — that exact shape is what triggers Claude Code's auto-compact.
- **Upstream retries only before any SSE has been written to the client** (a retry after frames have gone out would replay a partial turn). Bounded: 3 attempts, fresh connection per retry. Policy lives in `lib/retry.mjs`.
- **Parallel tool calls round-trip by stream index**; tool_use/tool_result pairing is repaired for re-wound histories; thinking blocks are stripped on re-entry (signatures are synthetic — `REASONING_SIGNATURE`).
- Runtime state lives in `~/.corti-bridge/` (`models.env`, `profile.env`, pid files, `gateway.log`); the repo itself stays stateless.

## Standing decisions and recurring gotchas

**Usage reporting — do not "simplify" these** (each shape was reversed once and broke something):

- `message_start.usage.input_tokens` carries the char/4 prompt estimate, **not 0**. Zeroing it (fbb9d23) froze the `/workflows` live per-agent token counter at "1 tok" — the harness reads `message_start` usage off yielded events *before* `message_delta` arrives; the estimate is the proxy's only live-growth signal (upstream only delivers usage in the final `include_usage` chunk). Reversed by `8e316a0`.
- Real `anthropicUsage` floors `input_tokens` at 1 (never 0): the harness merge keeps the old value when the incoming field is 0, so a 0 would leave the estimate standing and re-create the statusline double-count (estimate + cache_read ≈ 329k shown for ~170k real). Fully-cached turns reporting 1 instead of Anthropic's 0 is accepted.

**Prefix-cache stability (A1)** — mid-conversation `role:"system"` messages and `mid_conv_system` blocks must **never** be folded into the upstream system string. The harness injects reminders (task nudges, CLAUDE.md replays, plan-mode exits) as mid-conv system messages; folding them grew the cached prefix every few turns and broke Corti's automatic prefix cache — cache_read collapse plus ~25x cost spikes. They are emitted as user content at their original position; the upstream system string must stay byte-stable across turns. `body.system` itself (base prompt, appended prompts, output styles) is untouched and stable.

**Other known sharp edges:**

- `estimateTokens` (chars/4) undercounts real `prompt_tokens` by up to ~65% on long sessions. The overflow guard uses it, so it won't trip near the real 262k ceiling — with auto-compact off, sessions can die suddenly at the wall. Known, deliberately left; fix would be tracking real prompt_tokens.
- Deploying wrapper (`bin/corti-bridge`) changes requires `./setup.sh` (it copies the wrapper to `~/.local/bin`); gateway/translate changes require `corti-bridge restart`. Avoid `restart` while an advisor consult is in flight — it kills the continuation.
- Advisor sessions: children are marked via a `-noadvisor-` token placed *before* the mode marker (matched with `includes("-noadvisor-")`, not `endsWith`); they skip the 120s stream-idle watchdog and the advisor intercept (recursion guard). Debug logs are per-session (`x-claude-code-session-id`); advisor children log into the parent's file via `x-corti-advisor-for` through `ANTHROPIC_CUSTOM_HEADERS`.
- Three context readouts legitimately disagree: `/context` shows the harness's own estimate of the raw Anthropic body; the statusline shows the model's real usage from the *last successful* turn; the proxy's `count_tokens` is a local char/4 estimate. Divergence alone is not a bug.
- `test/models.sh` covers `lib/models.mjs` tier/caps logic against captured fixtures; it should stay green.

## Debugging

Set `CORTI_DEBUG=1` to get per-session request/response logs (path shown in `/health`). Retries are tagged in both the debug log (`diagnostics`) and the console log (`(attempt 2)`).

`GUIDE.md` is the deep reference: full translation surface, tier-ranking algorithm, fingerprint probe, environment reference, and known degradations per mode (e.g. `anthropic` mode drops streaming input-token accounting). Update it when behavior it documents changes.
