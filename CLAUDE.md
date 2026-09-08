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
sh test/prompt-estimate.sh  # pure-function tests for lib/prompt-estimate.mjs
sh test/smoke.sh       # sandboxed install + idempotency for setup.sh (scratch HOME)
sh test/dispatch.sh    # one gateway serving both modes, selected per request by path prefix
sh test/update.sh      # build-fingerprint restarts + the commits-behind notice (sandboxed clone)
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
- **`lib/prompt-estimate.mjs`** — calibration for the char/4 prompt estimate, same shape: pure functions over one bounded per-session store, tested in isolation.

### Staying current

The wrapper fingerprints the gateway's own source (`gateway.mjs`, `translate.mjs`, `lib/*.mjs`,
`lib/*.txt`) with `cksum` on every launch, hands it to the gateway as `CORTI_BUILD_ID`, and gets
it back in `/health` as `buildId`. A mismatch is a stale gateway and joins the existing
restart-reason list. The gateway never computes the fingerprint — one side owns the algorithm, so
the two can't drift. This is what makes a `git pull` take effect: the gateway holds its source in
memory from boot, so before this it kept serving the old code until an explicit `corti-bridge
restart`.

Separately, the wrapper backgrounds a throttled `git fetch origin main` (once a day) and counts
`HEAD..origin/main` from *local* refs at launch, so the count drops to zero the moment the user
pulls rather than nagging until the next fetch. The notice prints **after** the session, not
before: the wrapper hands the terminal to Claude Code, which repaints it. That is the one reason
the launch path gives up `exec` — and only when there is something to print. Off for print runs,
advisor children, non-clones, any branch but `main`, and `CORTI_NO_UPDATE_CHECK=1`.

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
- The estimate in `message_start` is **calibrated**, not raw char/4 (`lib/prompt-estimate.mjs`). A real `message_delta` normally overwrites it, but a turn that dies first — client abort, upstream error mid-response, a failed advisor continuation — leaves it standing as that message's *final* recorded usage. Raw char/4 lands a few percent under the truth, so the harness then holds less context than the previous turn did and the context readout steps backwards before recovering (measured: a visible backward step on 24 of 48 turns, worst -9328). Scaling by the last real/estimate ratio for that session+model, never below the raw estimate, drops that to 1 of 48 — the survivor being a rewind where the prompt genuinely shrank. Scale by the ratio rather than pinning to the last real total: after an auto-compact the estimate legitimately collapses, and a pinned floor would keep reporting the pre-compact size. The advisor continuation is deliberately excluded from feeding it — its prompt carries the advisor's answer on top of the body the estimate was measured from.

**Prefix-cache stability (A1)** — mid-conversation `role:"system"` messages and `mid_conv_system` blocks must **never** be folded into the upstream system string. The harness injects reminders (task nudges, CLAUDE.md replays, plan-mode exits) as mid-conv system messages; folding them grew the cached prefix every few turns and broke Corti's automatic prefix cache — cache_read collapse plus ~25x cost spikes. They are emitted as user content at their original position; the upstream system string must stay byte-stable across turns. `body.system` itself (base prompt, appended prompts, output styles) is untouched and stable.

**A past turn's tool_result must never change (A1, second form).** `interceptWebSearch` walks the whole history each request, so before the per-session cache it re-ran every historical WebSearch every turn. Live results drift, so the rewritten `tool_result` bytes changed mid-conversation and collapsed the prefix cache — the same failure as folding mid-conv system messages, reached from the other direction. Measured in one session: 132 searches for 2 queries, 4 cache collapses (80128→21632, 84480→21632, 95872→22784, 110848→0), and both watchdog kills landing on the first request to carry a changed body. Cached by `tool_use_id`, which is stable across turns; no session id means no cache, as with the advisor dedup.

**Other known sharp edges:**

- `estimateTokens` (chars/4) undercounts real `prompt_tokens` by up to ~65% on long sessions. The overflow guard uses it, so it won't trip near the real 262k ceiling — with auto-compact off, sessions can die suddenly at the wall. Known, deliberately left; fix would be tracking real prompt_tokens.
- Deploying wrapper (`bin/corti-bridge`) changes requires `./setup.sh` (it copies the wrapper to `~/.local/bin`); gateway/translate changes require `corti-bridge restart`. Avoid `restart` while an advisor consult is in flight — it kills the continuation.
- The harness does not replay `server_tool_use` / `advisor_tool_result` blocks into the next request's history **for this deployment** — verified as zero in the raw client bodies across sessions. Not a contradiction of C6 (`translate.mjs`) or of `findings.md` §5: the official replay happens only when the harness enabled its own advisor, and Gate 1 refuses that for an unranked base model like `corti-s1`, so it renders our synthesized blocks and drops them. Keep C6: if a harness ever does replay the blocks it produces the same `<advisor_guidance>` shape, and the two paths converge on one output. `endContinuationFailure` still repeats the advice verbatim rather than pointing at it — that path has no continuation text to anchor on, so its note is the only durable copy.
- **A consult must be re-inserted into later turns (A4) — this was once treated as harmless and is not.** With the blocks dropped, a hold-and-continue consult reaches the next turn as two adjacent text blocks with the advice excised from between them, so the model reads its own "calling the advisor now" as a promise it never kept. It then apologises for a call it did make and calls again; the apology is plain text, so it *is* replayed, and each one makes the next more likely. Measured: sporadic single occurrences since the advisor shipped, then 19 in one session once the user challenged it directly. Restating the advice in the continuation's own words does not help — two turns did exactly that and the next turn still folded. The gateway therefore records the advice against the surviving text block (`recordAdvisorGuidance`, anchored on `translator.lastText` captured before the synthetic blocks) and `translateRequest` re-inserts it there, feeding C6 from the gateway instead of the harness. The advice is restored as the consult's own `tool_use` plus a `tool_result`, never as assistant text: rendered as prose the model read advice it had no memory of writing as its own fabrication and told the user it had faked the consult (4 real consults, 4 matching blocks in history, 0 fabrications — it disowned all of them). The advisor's transcript goes through the same helper, since an advisor shown the excised history corroborates the false confession instead of correcting it. `restoreAdvisorGuidance` must run *after* `applyIntercepts` or the restored pair matches the intercept and spawns a fresh advisor run. The anchor is the pre-call text, else the continuation's first block — including its `tool_use` id, which covers a consult the model followed straight with a tool call. The store is per-session and in-process: a restart drops it and reverts to the old behaviour for that conversation. Insertion is byte-identical every turn, so A1 prefix stability holds — `test/translate.sh` (A4) and `test/dispatch.sh` (C1-CARRY) both guard that.
- **A request with no tools never reaches the advisor.** It has no next action to steer — it is a harness one-shot (summarise a fetched page, title a chat), not an agent loop. Measured before the gate: 6 of 7 consults in one session came from 2-message toolless calls, 50s of Opus-tier advisor time spent where no advice could be acted on. Gated in both halves, since either alone leaks: `interceptConsultAdvisor` returns before injecting the tool or the executor prompt, and the gateway only wires `onAdvisorToolUse` when the tool was actually offered. Guarded by `test/translate.sh` (G5) and `test/dispatch.sh` (C1-SIDECALL).
- The advisor continuation is exempt from the 120s stream-idle watchdog (`continuationActive`) and streams like the first call. Both are needed: Corti has gone silent for well over 120s *mid-generation* after emitting a token, so streaming alone does not keep the watchdog fed. Pings still go out during the continuation (the advisor phase is over, so they no longer displace the "Advising" indicator). Its ceiling is an absolute deadline computed from what is left of `NONSTREAM_TIMEOUT_MS` after the advisor phase — a fresh full budget would outlive the client's own deadline, so the graceful failure note would never land.
- Advisor sessions: children are marked via a `-noadvisor-` token placed *before* the mode marker (matched with `includes("-noadvisor-")`, not `endsWith`); they skip the 120s stream-idle watchdog and the advisor intercept (recursion guard). Debug logs are per-session (`x-claude-code-session-id`); advisor children log into the parent's file via `x-corti-advisor-for` through `ANTHROPIC_CUSTOM_HEADERS`.
- Three context readouts legitimately disagree: `/context` shows the harness's own estimate of the raw Anthropic body; the statusline shows the model's real usage from the *last successful* turn; the proxy's `count_tokens` is a local char/4 estimate. Divergence alone is not a bug.
- `test/models.sh` covers `lib/models.mjs` tier/caps logic against captured fixtures; it should stay green.

## Debugging

Set `CORTI_DEBUG=1` to get per-session request/response logs (path shown in `/health`). Retries are tagged in both the debug log (`diagnostics`) and the console log (`(attempt 2)`).

`GUIDE.md` is the deep reference: full translation surface, tier-ranking algorithm, fingerprint probe, environment reference, and known degradations per mode (e.g. `anthropic` mode drops streaming input-token accounting). Update it when behavior it documents changes.
