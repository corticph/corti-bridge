# cc-proxy

Thin reverse proxy that lets Claude Code talk to Corti's Anthropic-compatible API.

Corti has a native Anthropic Messages endpoint. This proxy just swaps the auth header and forwards. No format conversion, no model mapping, no dependencies.

## Install

```bash
git clone <repo-url> ~/projects/cc-proxy
cd ~/projects/cc-proxy
./setup.sh
```

`setup.sh` creates `~/.claude-corti/` with `corti.env` and `settings.json`, and installs the `corti-claude` wrapper to `~/.local/bin/`.

Edit `~/.claude-corti/corti.env` to add your `CORTI_BEARER`, then:

```bash
corti-claude
```

That's it. The wrapper starts the proxy if it's not running, then launches `claude` pointed at it.

## What it does

- Strips the local API key, injects the real Corti bearer
- Forwards to `https://ai.eu.corti.app/anthropic/v1/messages`
- Handles `/v1/messages/count_tokens` locally (Corti doesn't support it)
- Pipes SSE streaming responses straight through

## Files

```
cc-proxy/
├── gateway.mjs              # The proxy (zero dependencies)
├── bin/corti-claude         # Wrapper: starts proxy, launches claude
├── settings.template.json   # Claude Code env config (model aliases, base URL)
├── corti.env.example        # Env template (bearer, local key, host, port)
└── setup.sh                 # Installer
```

After install, the runtime layout is:

```
~/.claude-corti/             # Claude Code config dir (CLAUDE_CONFIG_DIR)
├── corti.env                # Your secrets (not in git)
├── settings.json            # Claude Code settings
└── gateway.log              # Proxy log

~/.local/bin/corti-claude    # The wrapper
```

## Environment

All vars use `:-` defaults, so shell env takes precedence over `corti.env`. This lets `corti init models` manage `CORTI_BEARER` in `~/.env` and the proxy picks it up automatically.

| Var | Required | Default |
|---|---|---|
| `CORTI_BEARER` | yes | — |
| `CORTI_LOCAL_KEY` | no | `sk-corti-local-change-me` |
| `HOST` | no | `127.0.0.1` |
| `PORT` | no | `4000` |

`CC_PROXY_DIR` (defaults to `~/projects/cc-proxy`) tells the wrapper where `gateway.mjs` lives. `CC_PROXY_BIN_DIR` (defaults to `~/.local/bin`) controls where the wrapper is installed.
