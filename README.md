<p align="center">
  <img src="corti-clawd.png" width="180" alt="corti-claude-proxy logo"/>
</p>

# corti-claude-proxy

Local gateway that lets Claude Code talk to Corti's OpenAI-compatible API while speaking Anthropic Messages to the client. Claude Code sends Anthropic Messages to localhost; the proxy translates them to OpenAI Chat Completions against `CORTI_BASE_URL`, swaps in the real auth header, and translates responses back — including streaming. No dependencies, no build step.

## What it does

- **Bidirectional translation** — Anthropic Messages ⇄ OpenAI Chat Completions both ways: system prompts, tools, model names, tool_use/tool_result pairing, thinking config, and images
- **Streaming** — SSE; parallel tool calls round-trip by index
- **Pass-through mode** — `--anthropic` skips translation and forwards to Corti's `/anthropic` endpoint (auth swap only); `openai` translation is the default. One gateway serves both routes at once, so switching costs no restart and leaves other sessions alone
- **Auth swap** — discards the client's token, sends `CORTI_BEARER` upstream; writes nothing to any `settings.json`, so a plain `claude` session stays on Anthropic models
- **Model tiers** — maps fable/opus/sonnet/haiku to Corti models by model-ID shape, so a new generation needs no code change
- **WebSearch** — converted to a function tool, results intercepted via Tavily with a keyless DuckDuckGo fallback
- **Upstream retries** — bounded, pre-stream retry with back-off absorbs the empty-bodied `5xx` bursts Corti's edge emits, which are otherwise too fast for Claude Code's own retry ladder to outlast
- **Persistent gateway** — keeps running between sessions and auto-restarts when stale (moved base URL, old build)

&nbsp;

## Prerequisites

- A Corti account and Corti-issued credentials — there is no other upstream
- `CORTI_BEARER` and `CORTI_BASE_URL` set in your shell environment (normally exported by Corti's CLI after `npx @corti/cli models init`)
- Node.js 20 or newer

Both `setup.sh` and `bin/corti-claude` are POSIX `sh`, so they run under bash, zsh, or dash regardless of your login shell (fish included — it execs scripts via their shebang).

&nbsp;

## Quick start

```bash
git clone https://github.com/corticph/corti-claude-proxy ~/projects/corti-claude-proxy
cd ~/projects/corti-claude-proxy
./setup.sh        # checks deps + creds, installs the wrapper, picks models
corti-claude      # starts the gateway if needed, then launches claude
```

Clone wherever you like — `setup.sh` records the clone's real path in the installed wrapper. Re-running `./setup.sh` is safe; `--yes` accepts every prompt for an unattended install.

The wrapper starts the gateway on `127.0.0.1:4192` if it isn't running (and restarts it if it's stale), points Claude Code at it, then launches `claude`.

```bash
corti-claude --stop       # stop the gateway and exit
corti-claude --restart    # stop then start it (needs CORTI_BEARER/CORTI_BASE_URL)
corti-claude --anthropic  # thin pass-through to Corti's /anthropic endpoint
corti-claude --help       # full flag reference
```

&nbsp;

## How it works

Claude Code sends Anthropic Messages requests to localhost; the proxy translates them to OpenAI Chat Completions against `CORTI_BASE_URL`, swaps in the real auth header, and translates responses back. The default `openai` mode is a translating gateway; `--anthropic` is a thin pass-through with no translation. Use `openai` unless you have a reason not to — `anthropic` mode currently drops input-token accounting on streaming, so context and cost readouts stop working. See [GUIDE.md](GUIDE.md) for the full mechanics, trade-offs, and known degradations.

Model mapping lives in `~/.corti-claude/models.env`, written by `setup.sh` from Corti's catalog. Only the wrapper reads it — it exports the aliases as process-scoped environment variables, so Corti model IDs never leak into a plain `claude` session. Run one outside the wrapper and it still talks to Anthropic with Anthropic's models.

&nbsp;

## Files

```
corti-claude-proxy/
├── gateway.mjs         # The server: routing, phases, upstream client, logging
├── translate.mjs       # All wire-format logic: request/response/SSE translation, errors
├── bin/corti-claude    # Wrapper: starts the proxy, launches claude
├── setup.sh            # Installer
├── lib/                # Shell + JS helpers sourced by setup.sh and the wrapper
└── test/               # smoke.sh (install + idempotency), translate.sh (pure-function)
```

After install, the runtime layout is:

```
~/.corti-claude/             # Proxy state (models.env, profile.env, gateway.log)
~/.local/bin/corti-claude    # The wrapper
```

&nbsp;

## Environment

Read directly from the shell — no local secrets file.

| Var | Required | Notes |
|---|---|---|
| `CORTI_BEARER` | yes | Sent upstream; the client's own token is never used |
| `CORTI_BASE_URL` | yes | Must match `https://ai.<env>.corti.app/v1` |
| `CORTI_PORT` | no | Proxy bind port, default `4192` |
| `CORTI_HOST` | no | Proxy bind address, default `127.0.0.1` |
| `CORTI_DEBUG` | no | Any value except `0`/`false`/`no`/`off` enables request/response logging |
| `CORTI_ADVISOR` | no | `auto` (default) — the `consult_advisor` advisor tool is on in `openai` mode, off in `anthropic` mode; `on`/`off` force both modes. Spawns a headless Opus-tier consult on the request path. See [GUIDE.md](GUIDE.md) for the advisor mechanism, the experimental `anthropic`-mode caveat, and `CORTI_ADVISOR_*` tuning. |

`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_ATTRIBUTION_HEADER=0`, and `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` are exported by the wrapper itself — plumbing this tool owns, not something you configure. The full variable reference (search backends, reasoning mode, debug caps, state directories) is in [GUIDE.md](GUIDE.md).

&nbsp;

## Tests

```bash
sh test/smoke.sh       # sandboxed install + idempotency; runs against a scratch HOME
sh test/translate.sh   # pure-function tests for translate.mjs; offline, no credentials
```

&nbsp;

## Upgrading

1. `git pull`
2. `./setup.sh` — refreshes the wrapper, reports what's already current, re-asks nothing you've already answered
3. `corti-claude` — the wrapper auto-restarts a stale gateway
4. `./setup.sh --fresh` if Corti has changed what it serves since you last ran it

`./setup.sh --uninstall` removes the wrapper and the PATH block it added. It leaves `~/.corti-claude` alone (your model mapping and profile choice) and prints the path so you can delete it yourself.

&nbsp;

## Reference

[GUIDE.md](GUIDE.md) covers the rest: the translation surface (system-prompt merge, tool mapping, thinking config, images), the model-ranking algorithm and capability derivation, the fingerprint probe that de-aliases models, debug-logging internals and sensitivity, the profile choice, the full environment reference, and the known degradations in `openai` and `anthropic` mode.
