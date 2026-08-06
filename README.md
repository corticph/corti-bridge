# cc-proxy

Thin reverse proxy that lets Claude Code talk to Corti's Anthropic-compatible API.

Corti has a native Anthropic Messages endpoint. This proxy just swaps the auth header and forwards. No format conversion, no model mapping, no dependencies.

## Prerequisites

`CORTI_BEARER` and `CORTI_BASE_URL` must already be set in your shell environment (e.g. via `~/.env` sourced from your shell's rc file, or a project `.env` you've loaded). This proxy doesn't manage secrets — it just reads them.

Both `setup.sh` and `bin/corti-claude` are POSIX `sh` — they run the same under bash, zsh, or dash regardless of what your login shell is (fish included, since it execs scripts via their shebang rather than parsing them).

## Install

```bash
git clone <repo-url> ~/projects/cc-proxy
cd ~/projects/cc-proxy
./setup.sh
```

`setup.sh` installs the `corti-claude` wrapper to `~/.local/bin/`.

```bash
corti-claude
```

That's it. The wrapper starts the proxy if it's not running, points Claude Code at it, then launches `claude`.

## What it does

- Discards whatever auth token the client sends, injects the real `CORTI_BEARER`
- Derives the Anthropic-compatible upstream from `CORTI_BASE_URL` (e.g. `https://ai.eu.corti.app/v1` becomes `https://ai.eu.corti.app/anthropic`), so it follows whatever region/environment you're pointed at (`eu`, `dev-weu`, etc.)
- Handles `/v1/messages/count_tokens` locally (Corti doesn't support it — it 404s with a plain-text body Claude Code can't parse)
- Pipes SSE streaming responses straight through

## Files

```
cc-proxy/
├── gateway.mjs         # The proxy (zero dependencies)
├── bin/corti-claude    # Wrapper: starts proxy, launches claude
└── setup.sh            # Installer
```

After install, the runtime layout is:

```
~/.corti-claude/             # Claude Code config dir (CLAUDE_CONFIG_DIR)
├── settings.json            # Your model config (optional, see below — not installed by this repo)
└── gateway.log               # Proxy log

~/.local/bin/corti-claude    # The wrapper
```

## Environment

Read directly from the shell — no local secrets file.

| Var | Required | Notes |
|---|---|---|
| `CORTI_BEARER` | yes | Sent upstream, never the client's own token |
| `CORTI_BASE_URL` | yes | Must match `https://ai.<env>.corti.app/v1`; `/v1` is swapped for `/anthropic` |
| `CORTI_HOST` | no | Proxy bind address, default `127.0.0.1` |
| `CORTI_PORT` | no | Proxy bind port, default `4000` |

`CC_PROXY_DIR` (defaults to `~/projects/cc-proxy`) tells the wrapper where `gateway.mjs` lives. `CC_PROXY_BIN_DIR` (defaults to `~/.local/bin`) controls where the wrapper is installed. `CC_PROXY_CONFIG_DIR` overrides the `CLAUDE_CONFIG_DIR` the wrapper uses — it defaults to `~/.corti-claude` so existing installs keep working without setting anything.

`ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` are exported by the `corti-claude` wrapper itself, pointed at the local proxy — that's plumbing this tool owns, not something you configure.

## Model config

Which Corti model backs each Claude Code tier is *not* managed by this repo — it changes independently of the proxy, so it belongs in config you own, not something baked into this repo's source.

To set it, create `~/.corti-claude/settings.json` yourself (the wrapper points `CLAUDE_CONFIG_DIR` there):

```json
{
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "corti-s1",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "corti-s1-instant",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "corti-s1-mini-instant",
    "ANTHROPIC_CUSTOM_MODEL_OPTION": "corti-s1-mini",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "Corti S1 Mini",
    "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "1000000"
  }
}
```

Adjust the model names to whatever Corti currently offers — run `./setup.sh --detect-models` (below) if you're unsure what's available. This file is entirely yours; `setup.sh` never creates, touches, or overwrites it (unless you explicitly ask it to — see below).

### `setup.sh --detect-models`

Optional shortcut: fetches Corti's live model catalog via `npx @corti/cli list models --json` and writes `~/.corti-claude/settings.json` from the first four models, in order: Opus, Sonnet, Haiku, then Custom.

```bash
./setup.sh --detect-models
```

It prints out what it picked and won't overwrite an existing `settings.json` without asking first. This assumes the catalog stays ordered the way it is today — if Corti reorders or inserts a model, re-run it and check the printed mapping, or just edit `settings.json` by hand.
