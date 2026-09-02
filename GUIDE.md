# corti-claude-proxy — Guide

The README sells. This document explains — the translation surface, the model-ranking program, the installer, and every known trade-off and degradation. Read it when something isn't behaving the way you expected, or before you change how the gateway works.

This is a reference, not a tutorial. For install and run, see the [README](README.md).

## Table of contents

- [The translation layer](#the-translation-layer)
- [Model config](#model-config)
- [Claude Code profile](#claude-code-profile)
- [The gateway](#the-gateway)
- [Upstream failures and retries](#upstream-failures-and-retries)
- [Debug logging](#debug-logging)
- [Environment reference](#environment-reference)
- [Known degradations (openai mode)](#known-degradations-openai-mode)
- [`anthropic` mode](#anthropic-mode)
- [PATH and uninstalling](#path-and-uninstalling)

## The translation layer

`gateway.mjs` is the server (routing, phases, upstream client, logging) and `translate.mjs` holds all wire-format logic — zero dependencies. The default `openai` mode translates Anthropic Messages ⇄ OpenAI Chat Completions bidirectionally:

- **system prompt** — a string or content blocks, merged with in-conversation system entries into one system message
- **tools** — mapped to function tools; WebSearch is converted from a server-side tool to a function tool and its results intercepted via the Tavily API (with a keyless DuckDuckGo scrape fallback when `TAVILY_API_KEY` is unset or Tavily fails/rate-limits). Other server-side tools (web_fetch etc.) are stripped with no replacement.
- **model names** — mapped to configured Corti models (e.g. `claude-opus-5` → `corti-s1`)
- **tool_use / tool_result** — pairing repaired for re-wound histories; parallel tool calls round-trip byte-exact via index-keyed streaming
- **thinking config** — Anthropic `thinking` maps to upstream `reasoning_effort` + `thinking_token_budget`; upstream reasoning streams back as Anthropic thinking blocks. History thinking blocks are stripped on re-entry (signatures are synthetic, see below).
- **images** — converted to `image_url` parts, including images inside tool results, which are attached as a following user message
- **auth** — whatever token the client sends is discarded; the real `CORTI_BEARER` is injected
- **`/v1/messages/count_tokens`** — handled locally (estimator: chars/4 + tools schema + per-image flat count)
- **errors** — upstream errors translated into Anthropic's envelope. Critically, context-overflow conditions become `400 prompt is too long`, which is what drives Claude Code's auto-compact
- **`/v1/models`** — serves the translated catalog for gateway model discovery

Reasoning effort rounding: effort is rounded up to `high` on `corti-s1-ultra` models.

## Model config

`setup.sh` asks whether to fetch Corti's catalog and generates `~/.corti-claude/models.env` — for example:

```sh
# Written by setup.sh. Do not edit by hand - run ./setup.sh --fresh to refresh.
ANTHROPIC_DEFAULT_FABLE_MODEL="corti-s1-ultra-beta"
ANTHROPIC_DEFAULT_FABLE_MODEL_NAME="corti-s1-ultra-beta"
ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES="thinking,adaptive_thinking,effort,max_effort,temperature,mid_conversation_system"
ANTHROPIC_DEFAULT_OPUS_MODEL="corti-s1"
ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES="thinking,adaptive_thinking,effort,max_effort,temperature,mid_conversation_system"
ANTHROPIC_DEFAULT_SONNET_MODEL="corti-s1-instant"
ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES="temperature,mid_conversation_system"
ANTHROPIC_DEFAULT_HAIKU_MODEL="corti-s1-mini-instant"
ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES="temperature,mid_conversation_system"
CLAUDE_CODE_MAX_CONTEXT_TOKENS="524288"
```

### The tiers

`fable` is a fourth tier Claude Code recognises alongside opus, sonnet and haiku, sitting above opus — it's where a model stronger than the opus pick goes. It is optional: Claude Code only offers it when `ANTHROPIC_DEFAULT_FABLE_MODEL` is set, which is why it's the one tier the installer may leave out entirely.

Only `bin/corti-claude` reads this file; it exports these as environment variables just before launching Claude Code. **Nothing is written to any `settings.json`, yours or otherwise** — which is what keeps Corti model IDs from leaking into a plain `claude` session.

### How tiers are ranked

Tiers are picked by decomposing model IDs into `size`/`speed`/`channel` parts rather than by matching exact names, so a new Corti generation slots in without a code change, and the result doesn't depend on what order the API happens to list models in. The program lives in `lib/models.mjs`.

A tier takes the first `[size, speed]` shape it can fill from an explicit shape table, and a beta beats the GA of that same shape:

| Tier | Shapes (in fill order) |
|---|---|
| `fable` | `["ultra", ""]` |
| `opus` | `["", ""]` |
| `sonnet` | `["", "instant"]` |
| `haiku` | `["mini", "instant"]` → `["mini", ""]` → `["tiny", "instant"]` → `["tiny", ""]` |

Sorting rather than scanning keeps every pick independent of the order the API returned. An unfilled tier borrows the one above it; nothing sits above opus, so it takes the roomiest model by context window. A fable that only repeats opus is not a tier — but a name comparison is not enough to tell (see [the fingerprint probe](#the-fingerprint-probe)).

`CLAUDE_CODE_MAX_CONTEXT_TOKENS` is derived from whichever model wins the opus slot, not hardcoded — that export is the window Claude Code compacts against. The gateway's own overflow backstop is a separate fixed constant that does *not* follow the mapping; it only catches absurd bodies, because upstream's 400 is authoritative for whichever model was actually called.

### Capability derivation

The `_SUPPORTED_CAPABILITIES` lines tell Claude Code what each model can actually do. Without them it infers capabilities from the model name — a heuristic written for `claude-*` IDs that credits every Corti model with reasoning. The installer derives them from the catalog's per-model `capabilities` and `effort` metadata instead:

- `reasoning` → `thinking,adaptive_thinking`
- `effort.supported` → `effort,max_effort`
- `temperature` → `temperature`
- `mid_conversation_system` is always offered

A capability is omitted only when the catalog explicitly says `false` — absence keeps it, because Corti's metadata has understated capabilities before. `xhigh` is never offered (no Corti model honours it, so acceptance doesn't prove support), and `interleaved_thinking` is omitted since the proxy strips thinking blocks from history on re-entry.

### Channels and context window

Opus, sonnet and haiku are drawn from the GA channel only. Fable is the exception: it takes the strongest model in the catalog whatever its channel, because when Corti ships a model larger than its GA line it has done so on the beta channel alone, and a GA-only rule would leave the tier permanently empty. Beta models only appear in the catalog when the fetch is made with `--experimental` (`?experimental=true`).

Models with a context window under 100k are excluded from every tier — small enough to break a coding session before it gets going. The window comes from each model's `max_input_tokens` in the catalog, so `CLAUDE_CODE_MAX_CONTEXT_TOKENS` tracks the opus tier's real window without a maintained table. A model that omits the field warns by name and falls back to a default — a drift signal, not a guess.

### The fingerprint probe

A fable that would only repeat the opus pick is dropped, and a name comparison is not enough to tell — several public model names can route to the same upstream backend, so an alias may resolve to whatever it aliases. The installer probes: it asks the candidate and the opus pick for a one-token completion and compares the `system_fingerprint` each reply carries, which identifies the backend. Same backend, no fable tier. A probe that fails to answer leaves the tiers as ranked rather than dropping one on a hunch.

### Changing the mapping

Edit `models.env` directly — hand edits stick until the next `--fresh` overwrites the file — or re-detect:

```bash
./setup.sh --fresh                    # GA models only
./setup.sh --fresh --experimental     # also consider beta models for the fable tier
```

The default flow never touches an existing `models.env`; `--fresh` is the only thing that overwrites it.

### Pinning the fable tier

You can pin the fable tier by hand: add `ANTHROPIC_DEFAULT_FABLE_MODEL_PIN="1"` to `models.env` beside the `ANTHROPIC_DEFAULT_FABLE_MODEL` you want (`_NAME` and `_SUPPORTED_CAPABILITIES` ride along if present). A pinned model is carried through verbatim — it survives `--fresh`, bypasses the duplicate check, and doesn't need to be in the catalog at all. It's the one hand-added line a refresh preserves.

## Claude Code profile

Claude Code keeps conversation history, plugins, skills, MCP servers and per-project trust in a profile directory. `setup.sh` asks which one Corti sessions should use and records the answer in `~/.corti-claude/profile.env`:

- **`~/.claude`** (default) — your normal profile, so your history, plugins, skills, and MCP servers carry over.
- **`~/.corti-claude`** — a clean room. Starts empty: no history, no plugins, no skills, no MCP servers. Use this if you want Corti sessions kept separate from your usual ones.
- **A path you choose** — any other config directory, for anyone already keeping profiles apart (a separate work profile, say). `~` is expanded; the path must be absolute, and it does not need to exist yet.

Whichever you pick, your regular `claude` is unaffected, because the model aliases are process-scoped exports rather than persisted settings. `--fresh` re-asks the profile choice (alongside re-detecting models); a bare `./setup.sh` reuses whatever `profile.env` already records.

Note that `~/.corti-claude` (the proxy's state directory, `CC_PROXY_CONFIG_DIR`) is *not* the same thing as Claude Code's profile directory.

## The gateway

`corti-claude` starts a local gateway on `127.0.0.1:4192` (set `CORTI_PORT` to move it) the first time you run it, and it **outlives any single session** — it keeps running after `corti-claude` exits, so the next session starts fast. That also means there's no first-class way to stop it just by quitting Claude Code. Two flags manage it:

```bash
corti-claude --stop       # stop the gateway and exit
corti-claude --restart    # stop then start it (needs CORTI_BEARER/CORTI_BASE_URL)
```

`--stop` needs nothing — not even credentials — so it works when something's wrong. `--restart` checks credentials *before* stopping, so a typo'd `CORTI_BEARER` won't take down a working gateway. Stopping a gateway that's already stopped is not an error.

Reconfiguring models (`./setup.sh --fresh`) or the profile does **not** require restarting the gateway: the gateway doesn't read `models.env` (the wrapper does, at launch), so a new mapping takes effect the next time you run `corti-claude`. You only need `--restart` if you've changed `CORTI_BASE_URL` — and even then, a normal `corti-claude` run detects the staleness and restarts it for you. Switching `--anthropic` never needs one: both modes are always being served.

## Upstream failures and retries

Corti's edge fails in bursts. During one on 2026-08-18 it answered most requests with an empty-bodied `503` for roughly a minute at a time, while a minority still succeeded — two requests 154ms apart came back `503` and `200`. Empty-bodied `403`s appeared in the same windows. That shape (no body, no `x-request-id`, sub-second) is the load balancer talking, not a model.

Claude Code retries on its own, but its ladder is about five attempts inside ~8 seconds — too fast to outlast a blip like that, so every message in the window failed. The gateway therefore retries upstream itself before the client ever sees an error:

- **Up to 3 attempts** (the original plus 2 retries), backing off ~0.5s then ~1.5s with jitter. Worst case adds under 3 seconds.
- **Only while the client response is still unwritten.** Once SSE frames have gone out, a retry would replay a partial turn, so a mid-stream failure is passed through as it always was.
- **Retryable:** `408`, `429`, `500`, `502`, `503`, `504`, `529`, and connection-level failures (`ECONNRESET`, `ETIMEDOUT`, and friends). A numeric `Retry-After` is honoured, clamped to 4s.
- **Not retryable:** `400`, `401`, `403`, `404`, `413`. A bad `CORTI_BEARER` has to fail on the first attempt rather than tripling the cost of every request.
- **Retries skip the connection pool.** A keep-alive socket pinned to an unhealthy backend would just hand back the same instant `5xx`, so attempt 2 opens a fresh connection.

The two ladders multiply — the client's five attempts each become up to three upstream calls — which is why this one stays deliberately short. It is meant to absorb sub-10-second edge blips, not to replace the client's policy or to ride out a real outage. When upstream is genuinely down you still get an `overloaded_error`, just a few seconds later.

Retries are invisible to the client but not to you: each one appends an `attempt N failed (…); retried after Nms` line to the request's `diagnostics` in the debug log, and the gateway's console log tags them (`POST /v1/messages 503 (attempt 2)`).

Separately, silence *before* upstream sends response headers now has its own deadline (`CORTI_HEADERS_TIMEOUT_MS`, default 60s) rather than sharing the 120s mid-stream idle timeout — an upstream that accepts the connection and then says nothing is a much stronger death signal than a pause mid-generation. Raise it if you see spurious timeouts on long generations; `0` restores the old shared 120s behaviour.

## Debug logging

Set `CORTI_DEBUG` and the gateway writes every request and response to a **per-session** log file — one file per Claude Code session (keyed on `x-claude-code-session-id`), not one per gateway start:

```bash
CORTI_DEBUG=1 corti-claude
```

Each session's traffic lands in its own file under the debug directory, named `gateway-session-<shortId>-<timestamp>.log`. Advisor consults file under their parent session's id (via `x-corti-advisor-for`), so an advisor turn appears in the same file as the executor request that spawned it; requests carrying no session id share one `__untracked__` file.

The wrapper prints the log directory on startup, and `/health` reports it too — note `debug` is the log **directory**, not a file path (or `false` when `CORTI_DEBUG` is unset):

```bash
curl -s http://127.0.0.1:4192/health
# {"status":"healthy","gatewayVersion":2,"mode":"openai","upstream":"https://ai.eu.corti.app/v1","debug":"/Users/you/Library/Logs/corti-claude-proxy"}
#
# `mode` is not a process-wide setting — it reports what a request carrying no path prefix
# resolves to, which is what the wrapper compares when deciding whether to restart.
```

In `openai` mode each request id gets up to four entries — REQUEST (what the client sent), UPSTREAM-REQUEST (translated OpenAI body), UPSTREAM-RESPONSE (raw upstream bytes, plus upstream headers when the status was an error — that's the only place `server`, `retry-after` and `x-request-id` survive), RESPONSE (translated bytes sent to the client, with a `note` of `completed`/`upstream-error`/`client-abort`/`watchdog-timeout`/`parse-fail` and per-request diagnostics). Mistranslation debugging is a diff problem: compare REQUEST→UPSTREAM-REQUEST and UPSTREAM-RESPONSE→RESPONSE.

**The log contains complete prompt bodies** — your source code, file contents, whatever Claude Code sent — including their translated forms. `CORTI_BEARER` is never written, and `authorization`/`x-api-key`/`cookie` headers are redacted, but treat the files as sensitive. The directory is created `0700` and files `0600`. Nothing rotates or prunes them; delete them yourself when done.

Where they go, in order of precedence:

| | |
|---|---|
| `CORTI_DEBUG_DIR` | If set, used as-is |
| macOS | `~/Library/Logs/corti-claude-proxy/` |
| Linux/other | `$XDG_STATE_HOME/corti-claude-proxy/` (or `~/.local/state/...`) |
| Fallback | `$TMPDIR/corti-claude-proxy/` if the above isn't writable |

Bodies are capped at 2 MB each by default so a long streaming response doesn't produce a giant file; raise it with `CORTI_DEBUG_MAX_BODY`, or set `0` for no cap. Truncated bodies are marked as such.

The gateway is a background process that outlives any single `corti-claude` run, so toggling `CORTI_DEBUG` has to restart it — the wrapper handles that automatically, in both directions. If you started the gateway some other way, stop it yourself first.

## Environment reference

Read directly from the shell — no local secrets file.

| Var | Required | Notes |
|---|---|---|
| `CORTI_BEARER` | yes | Sent upstream, never the client's own token |
| `CORTI_BASE_URL` | yes | Must match `https://ai.<env>.corti.app/v1`; used as-is (OpenAI-compatible endpoints) |
| `CORTI_HOST` | no | Proxy bind address, default `127.0.0.1` |
| `CORTI_PORT` | no | Proxy bind port, default `4192` |
| `CORTI_REASONING_MODE` | no | `thinking` (default: reasoning becomes Anthropic thinking blocks), `text` (fold into reply text), `drop` |
| `TAVILY_API_KEY` | no | Enables Tavily as the primary WebSearch backend; when unset (or when Tavily fails/rate-limits) the keyless DuckDuckGo scrape is used instead |
| `CORTI_SEARCH_DEPTH` | no | Tavily search depth: `basic` (default, 1 credit) or `advanced` (2 credits, richer snippets); ignored without `TAVILY_API_KEY` |
| `CORTI_HEADERS_TIMEOUT_MS` | no | How long to wait for upstream response headers before giving up, default `60000`; `0` falls back to the 120s mid-stream idle timeout |
| `CORTI_DEBUG` | no | Any value except `0`/`false`/`no`/`off` turns on request/response logging |
| `CORTI_DEBUG_DIR` | no | Where debug logs go; defaults per platform (see [Debug logging](#debug-logging)) |
| `CORTI_DEBUG_MAX_BODY` | no | Per-body byte cap, default `2097152` (2 MB); `0` means unlimited |
| `CORTI_ADVISOR` | no | `auto` (default) — the `consult_advisor` advisor tool is on in `openai` mode, off in `anthropic` mode. `on` — on in both modes. `off` — off in both modes. Unrecognized values warn once and use `auto`. The advisor spawns a headless `corti-claude -p` (Opus-tier by default, see `CORTI_ADVISOR_MODEL`) on the request path — a consult can take minutes; the child carries a recursion guard so it can't re-inject or recurse. |
| `CORTI_ADVISOR_MODEL` | no | Model alias for the advisor backing (default `opus`); resolved by the wrapper, so use a tier alias (`opus`, `sonnet`, `haiku`, `fable`), not a `claude-` name |
| `CORTI_ADVISOR_TIMEOUT_MS` | no | Bound on the advisor spawn, default `480000` (8 min); on timeout the `tool_result` becomes `<advisor_guidance>advisor unavailable (execution_time_exceeded)</advisor_guidance>` rather than hanging the turn |
| `CORTI_ADVISOR_MAX_TOKENS` | no | Soft per-call output cap, surfaced to the advisor via the serialized transcript's budget line; default `2048` (the official recommended starting point). No hard `max_tokens` cap exists through `corti-claude -p`; this is a soft steer plus the hard `CORTI_ADVISOR_TIMEOUT_MS` / maxBuffer ceilings. Lower it to bias toward brevity. |
| `CORTI_ADVISOR_EFFORT` | no | Reasoning effort for the advisor child, default `high` (the official advisor default, not the `medium` that adaptive thinking maps to). The gateway applies this only to the advisor child (detected via the `-noadvisor-` token). Override with `medium` to keep consults cheaper, `low` is not recommended (it undermines the advisor's value). A model that rejects the level will 400 upstream. |

`CC_PROXY_BIN_DIR` (defaults to `~/.local/bin`) controls where the wrapper is installed. `CC_PROXY_CONFIG_DIR` (defaults to `~/.corti-claude`) is the proxy's own state directory — model mapping, profile choice, gateway log. `CC_PROXY_DIR` tells the wrapper where `gateway.mjs` lives; `setup.sh` bakes your clone's real path into the installed wrapper, so you only need this if you move the clone afterwards.

`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_ATTRIBUTION_HEADER=0`, and `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` are exported by the `corti-claude` wrapper itself — that's plumbing this tool owns, not something you configure. (The attribution header is off because a per-request attribution line in the system prompt would defeat upstream prefix caching. The 1M context badge is disabled because it's misleading for proxied models — see degradations.)

## Known degradations (openai mode)

Compared to first-party Anthropic or `anthropic` mode, this setup cannot support:

- **WebSearch** — Anthropic's server-side search is stripped from requests, but the proxy converts it to a function tool and intercepts results via the Tavily API, falling back to a keyless DuckDuckGo scrape when `TAVILY_API_KEY` is unset or Tavily fails/rate-limits, so the model gets real search results. Other server-side tools (web_fetch etc.) are stripped with no replacement.
- **PDF input** — base64 PDF document blocks are replaced with a visible `[PDF document omitted...]` placeholder.
- **Misleading `[1M]` context badge** — newer Claude Code versions badge proxied models with a `[1M]` suffix via the server-side `context-1m` beta gate. `bin/corti-claude` neutralizes it by exporting `CLAUDE_CODE_DISABLE_1M_CONTEXT=1`.
- **A startup notice about the 200K limit is expected** — that export also makes Claude Code warn it can't enforce its 200K fallback. Auto-compaction already runs at the model's real window, so the notice is benign. Do not set `CLAUDE_CODE_AUTO_COMPACT_WINDOW` to silence it — that value is a *cap* (`min(real_window, value)`), so it throws away context — and only values ≤ 200000 silence the notice at all; anything higher caps the window without silencing it.
- **Image support depends on the resolved model** — not every Corti model is multimodal, and upstream rejects images for the ones that aren't with a clean `400 "not a multimodal model"`. If you use image workflows, point the tier you work in at a model that accepts them in `models.env`.
- **Prompt-caching economics** — caching is upstream's automatic prefix cache; usage reports zeros for cache fields when caching isn't active.
- **Reasoning signatures are synthetic** — thinking blocks emitted by the proxy carry a constant signature (`corti-proxy`, base64). Claude Code accepts and re-sends them; the proxy strips them from history on re-entry. If you ever take a session from `~/.corti-claude` and resume it against real Anthropic, those blocks will fail server-side signature validation — filter them out first.
- **Overflow is decided by tokens, not bytes** — upstream accepts multi-megabyte bodies, so the model's context window is what binds. Over-window turns become `prompt is too long` with a real token count, which is what drives compaction; only bodies over the gateway's own 8 MB byte cap get a local 413 instead.

### The advisor (openai mode)

The `consult_advisor` advisor tool is **on by default in `openai` mode** (`CORTI_ADVISOR=auto`); set `CORTI_ADVISOR=off` to disable it. When the model calls the tool, the gateway **holds the turn**: it emits a synthetic `server_tool_use` + `advisor_tool_result` inline — the shape the harness renders as "Advising…" — runs the advisor (a headless `corti-claude -p`), then makes a second upstream call so the model answers in the same turn. That "Advising" via hold-and-continue is the openai experience.

Each consult spawns a headless session **on the request path**, so a turn that consults blocks for up to `CORTI_ADVISOR_TIMEOUT_MS` (8 min default) while the advisor reasons over the serialized transcript. The executor timing prompt (`lib/advisor-executor-prompt.txt`, ~2 KB / ~500-700 tokens) is prepended to every `openai` system prompt while the advisor is on, consulted or not — that is the per-request cost of default-on.

The advisor receives the executor's **full serialized transcript** (system + tools + messages + a budget line carrying `CORTI_ADVISOR_MAX_TOKENS`), not a focus string; the tool takes empty input (`additionalProperties: false`) — the executor signals timing only, and the harness forwards context automatically. Prior advisor advice **round-trips** into both views: the executor sees past `<advisor_guidance>` blocks in its history, and the advisor sees its own prior guidance in the transcript it's sent — so a follow-up consult can build on or correct earlier advice rather than starting blind. A three-part guard keeps the advisor child from re-injecting or recursing: (1) `CORTI_ADVISOR_NOINJECT=1` stamps a `noadvisor-` marker on the child's token, which the gateway's `wantsNoAdvisor` turns into `skipAdvisor: true`; (2) `CORTI_NO_MANAGE_GATEWAY=1` keeps a debug-mode mismatch from making the child restart-kill its parent gateway mid-consult; (3) `maxBuffer: 32 MB` bounds the child's combined stdout.

The advisor child reasons at **high effort by default** (`CORTI_ADVISOR_EFFORT`, the official advisor default), not the `medium` that adaptive thinking maps to — the advisor's value is in its reasoning, so it gets a deeper pass than a routine turn.

> **Upgrading from `CORTI_ADVISOR_TOOL`:** the advisor is now controlled by `CORTI_ADVISOR`; the former `CORTI_ADVISOR_TOOL` is removed — set `CORTI_ADVISOR=on` to get the old behavior, or leave it unset for the mode default (on in `openai`).

## `anthropic` mode

```bash
corti-claude --anthropic
```

Points **this session** at the gateway's pass-through route instead of the translating one — no translation, every path forwarded, auth swap only. It changes nothing about the gateway: one process serves both routes at all times, so the flag costs no restart and does not disturb sessions running in the other mode. `count_tokens` is still answered locally by the estimator on both routes.

Mechanically, the wrapper exports `ANTHROPIC_BASE_URL=http://127.0.0.1:4192/anthropic` rather than the bare origin, and the gateway dispatches on that prefix. You only need to know this if you are curling the gateway by hand or reading raw debug-log paths.

`openai` mode is the default because pass-through loses something Claude Code relies on (see below), which the translation layer supplies. Use `openai` mode unless you have a reason not to.

Use `anthropic` mode to escape-hatch a translation bug, or as a comparison harness: run `corti-claude` and `corti-claude --anthropic` **at the same time**. Both write to the same debug log, so the two modes interleave by timestamp in one file — compare by request id rather than diffing two logs from two gateway lifetimes.

The cost is specific and worth knowing before you reach for it: Corti's `/anthropic` endpoint drops input-token accounting on streaming responses. `message_start` reports `usage: {"input_tokens": 0, "output_tokens": 0}` and `message_delta` carries only `output_tokens` — no input count, no cache fields. Claude Code always streams, so in this mode every transcript records zero input tokens and context/cost readouts stop working. Non-streaming requests to the same endpoint return full usage, so no request parameter fixes it. Tool use is unaffected.

### The advisor in `anthropic` mode (experimental, off by default)

The advisor is **off by default in `anthropic` mode** (`CORTI_ADVISOR=auto`). The inline hold-and-continue above is a translator-stream hook: pass-through has no translator stream, so it can't fire here. With `CORTI_ADVISOR=on` the tool is still injected and its `tool_result` is synthesized by the same spawn, but the delivery differs — it arrives as a **next-turn `tool_result` rewrite, not inline**. The flow: the model calls `consult_advisor`, the client (Claude Code does this) synthesizes an `is_error` `tool_result` for the unknown tool and round-trips it, and the intercept rewrites that result with the advisor's output on the next request. There is no "Advising" indicator; the executor reads the advice on its next turn.

This depends on the client synthesizing an `is_error` tool_result for the unknown tool — if it doesn't, the model sees an unhandled-tool error with no recovery. Because of that client dependency and the loss of the inline experience, prefer `openai` mode for the advisor.

## PATH and uninstalling

The wrapper installs to `~/.local/bin`, which is **not** on macOS's default `PATH` and is only sometimes on Linux's. When it's missing, `setup.sh` offers to add it to your shell config — `.zshrc` for zsh, `.bash_profile` and `.bashrc` for bash, `~/.config/fish/conf.d/corti-claude.fish` for fish. It backs the file up first, marks what it added, and can only ever add it once. Decline with `--no-modify-path` and it prints the line for you to add yourself.

Nothing it writes takes effect in the terminal you ran it from — a script can't change its parent shell. Open a new terminal, or `source` the file it names.

```bash
./setup.sh --uninstall
```

removes the wrapper and the PATH block. It leaves `~/.corti-claude` alone, since that's your model mapping and profile choice, and prints the path so you can delete it yourself.
