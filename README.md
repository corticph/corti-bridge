<p align="center">
  <img src="https://raw.githubusercontent.com/corticph/corti-bridge/main/corti-mascot.png" width="180" alt="corti-bridge logo"/>
</p>

# corti-bridge

Run Claude Code on [Corti Models](https://docs.corti.ai/models/welcome.md) — a local gateway that translates Anthropic Messages to OpenAI Chat Completions and back, including streaming. No dependencies, no build step.

&nbsp;

## What it does

- **Bidirectional translation** — Anthropic Messages ⇄ OpenAI Chat Completions both ways: system prompts, tools, model names, tool_use/tool_result pairing, thinking config, and images
- **Streaming** — SSE; parallel tool calls round-trip by index
- **Auth swap** — discards the client's token, sends `CORTI_BEARER` upstream; writes nothing to any `settings.json`, so a plain `claude` session stays on Anthropic models
- **Model tiers** — maps fable/opus/sonnet/haiku to Corti S1 models by model-ID shape, so a new generation needs no code change
- **WebSearch** — converted to a function tool, results intercepted via Tavily with a keyless DuckDuckGo fallback
- **Resilient gateway** — keeps running between sessions, auto-restarts when stale, and retries transient upstream `5xx` bursts before the client ever sees them
- **Diagnostics & model picker** — `corti-bridge doctor` checks the install, gateway, and state; `corti-bridge models` picks which Corti S1 model backs each tier

&nbsp;

## Quick start

Requires a Corti account (`CORTI_BEARER`/`CORTI_BASE_URL` from `npx @corti/cli models init` — see the [Corti Models docs](https://docs.corti.ai/models/welcome.md)) and Node.js 20+. POSIX `sh`, so it runs under any shell.

```bash
git clone https://github.com/corticph/corti-bridge
cd corti-bridge
./setup.sh     # checks deps + creds, installs the wrapper, picks models
corti-bridge   # starts the gateway if needed, then launches claude
```

Re-running `./setup.sh` is safe; `--yes` skips the prompts for an unattended install.

&nbsp;

## Usage

```bash
corti-bridge                 # start the gateway if needed, then launch claude
corti-bridge models          # pick which Corti model backs each tier
corti-bridge doctor          # diagnose the install, gateway, and state
corti-bridge theme           # print the lime-mascot TUI theme + install steps
corti-bridge restart         # stop then start (needs CORTI_BEARER/CORTI_BASE_URL)
corti-bridge --stop          # stop the gateway
corti-bridge help            # full reference
corti-bridge --anthropic     # pass-through mode (escape hatch; some features unavailable)
```

The gateway runs on `127.0.0.1:4192` and outlives any single session; the wrapper auto-restarts it when stale (moved base URL, old build).

&nbsp;

## How it works

The default `openai` mode is a translating gateway: Anthropic Messages in, OpenAI Chat Completions to `CORTI_BASE_URL`, responses translated back. `--anthropic` is a thin pass-through with no translation — an escape hatch only, since streaming drops input-token accounting (context and cost readouts stop working). See [GUIDE.md](GUIDE.md) for the full mechanics, trade-offs, and known degradations.

Model mapping lives in `~/.corti-bridge/models.env`, written by `setup.sh` from Corti's catalog. The wrapper exports it as process-scoped env, so Corti model IDs never leak into a plain `claude` session.

&nbsp;

## Files

```
corti-bridge/
├── gateway.mjs         # The server: routing, phases, upstream client, logging
├── translate.mjs       # All wire-format logic: request/response/SSE translation, errors
├── bin/corti-bridge    # Wrapper: starts the proxy, launches claude
├── setup.sh            # Installer
├── lib/                # Shell + JS helpers sourced by setup.sh and the wrapper
└── test/               # smoke, translate, retry, dispatch, models — each a self-contained suite
```

After install, the runtime layout is:

```
~/.corti-bridge/             # Proxy state (models.env, profile.env, gateway.log)
~/.local/bin/corti-bridge    # The wrapper
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

## Upgrading

1. `git pull`
2. `./setup.sh` — refreshes the wrapper, reports what's already current, re-asks nothing you've already answered
3. `corti-bridge` — the wrapper auto-restarts a stale gateway
4. `./setup.sh --fresh` if Corti has changed what it serves since you last ran it

`./setup.sh --uninstall` removes the wrapper and the PATH block it added. It leaves `~/.corti-bridge` alone (your model mapping and profile choice) and prints the path so you can delete it yourself.

&nbsp;

## Reference

[GUIDE.md](GUIDE.md) covers the rest: the translation surface (system-prompt merge, tool mapping, thinking config, images), the model-ranking algorithm and capability derivation, the fingerprint probe that de-aliases models, debug-logging internals and sensitivity, the profile choice, the full environment reference, and the known degradations in `openai` and `anthropic` mode.
