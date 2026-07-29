# cc-proxy

Thin reverse proxy that lets Claude Code talk to Corti's Anthropic-compatible API.

Corti now has a native Anthropic Messages endpoint (`/anthropic/v1/messages`). This proxy just swaps the auth header and forwards. No format conversion, no model mapping, no dependencies.

## What it does

- Strips the local API key, injects the real Corti bearer
- Forwards to `https://ai.eu.corti.app/anthropic/v1/messages`
- Handles `/v1/messages/count_tokens` locally (Corti doesn't support it)
- Pipes SSE streaming responses straight through

## Setup

```bash
cp corti.env.example corti.env
# Edit corti.env — add your CORTI_BEARER and set a CORTI_LOCAL_KEY
```

Point Claude Code at the proxy via `settings.json`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:4000",
    "ANTHROPIC_AUTH_TOKEN": "sk-corti-local-change-me",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "corti-s1",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "corti-s1-instant",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "corti-s1-mini-instant"
  }
}
```

## Run

```bash
set -a; source corti.env; set +a
node gateway.mjs
```

## Environment

All vars use `:-` defaults, so shell env takes precedence over `corti.env`. This lets `corti init models` manage `CORTI_BEARER` in `~/.env` and the proxy picks it up automatically.

| Var | Required | Default |
|---|---|---|
| `CORTI_BEARER` | yes | — |
| `CORTI_LOCAL_KEY` | no | — |
| `HOST` | no | `127.0.0.1` |
| `PORT` | no | `4000` |
