#!/bin/sh
# corti-claude-proxy setup — installs the corti-claude wrapper.
# Run from the repo root: ./setup.sh
# Run with --detect-models to fetch Corti's model catalog (via `npx @corti/cli`)
# and write ~/.corti-claude/settings.json from it.
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN_DIR="${CC_PROXY_BIN_DIR:-$HOME/.local/bin}"
CORTI_DIR="${CC_PROXY_CONFIG_DIR:-$HOME/.corti-claude}"

detect_models() {
    if ! command -v npx >/dev/null 2>&1; then
        echo "detect-models: npx not found — install Node.js first" >&2
        exit 1
    fi

    if [ -f "$CORTI_DIR/settings.json" ]; then
        printf '%s already exists. Overwrite? [y/N] ' "$CORTI_DIR/settings.json" >&2
        read -r reply
        case "$reply" in
            y | Y | yes | YES) ;;
            *)
                echo "Aborted." >&2
                exit 1
                ;;
        esac
    fi

    echo "Fetching model catalog via npx @corti/cli..." >&2
    if ! cli_json=$(npx --yes @corti/cli@alpha list models --json); then
        echo "detect-models: failed to run @corti/cli" >&2
        exit 1
    fi

    if ! models=$(node -e '
        const data = JSON.parse(process.argv[1]);
        if (!data.ok || data.error) {
            console.error("corti-cli probe failed: " + (data.error || "unknown error"));
            process.exit(1);
        }
        if (!Array.isArray(data.models) || data.models.length < 3) {
            console.error("corti-cli returned fewer than 3 models");
            process.exit(1);
        }
        process.stdout.write(data.models.join("\n"));
    ' "$cli_json"); then
        exit 1
    fi

    set -f
    set -- $models
    set +f

    opus="$1"
    sonnet="$2"
    haiku="$3"
    custom="${4:-}"

    mkdir -p "$CORTI_DIR"
    node -e '
        const fs = require("fs");
        const [path, opus, sonnet, haiku, custom, maxTokens] = process.argv.slice(1);
        const env = {
            ANTHROPIC_DEFAULT_OPUS_MODEL: opus,
            ANTHROPIC_DEFAULT_SONNET_MODEL: sonnet,
            ANTHROPIC_DEFAULT_HAIKU_MODEL: haiku,
        };
        if (custom) {
            env.ANTHROPIC_CUSTOM_MODEL_OPTION = custom;
            env.ANTHROPIC_CUSTOM_MODEL_OPTION_NAME = custom;
        }
        env.CLAUDE_CODE_MAX_CONTEXT_TOKENS = maxTokens;
        fs.writeFileSync(path, JSON.stringify({ env: env }, null, 2) + "\n");
    ' "$CORTI_DIR/settings.json" "$opus" "$sonnet" "$haiku" "$custom" "1000000"

    echo "" >&2
    echo "Opus: $opus" >&2
    echo "Sonnet: $sonnet" >&2
    echo "Haiku: $haiku" >&2
    if [ -n "$custom" ]; then
        echo "Custom: $custom" >&2
    fi
    echo "" >&2
    echo "Wrote $CORTI_DIR/settings.json — edit it anytime to change these." >&2
}

case "${1:-}" in
    --detect-models)
        detect_models
        exit 0
        ;;
    "") ;;
    *)
        echo "corti-claude-proxy setup: unknown argument: $1" >&2
        exit 1
        ;;
esac

echo "corti-claude-proxy setup"
echo ""

# 1. Wrapper
mkdir -p "$BIN_DIR"
cp "$REPO_DIR/bin/corti-claude" "$BIN_DIR/corti-claude"
chmod +x "$BIN_DIR/corti-claude"
echo "Installed corti-claude to $BIN_DIR"

# 2. PATH check
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        echo ""
        echo "Warning: $BIN_DIR is not in your PATH"
        echo "Add this to your shell config:"
        echo "  export PATH=\"$BIN_DIR:\$PATH\""
        ;;
esac

# 3. Verify
echo ""
if [ -n "${CORTI_BEARER:-}" ] && [ -n "${CORTI_BASE_URL:-}" ]; then
    echo "Done. Run: corti-claude"
else
    echo "Done. CORTI_BEARER and CORTI_BASE_URL must be set in your shell environment, then run: corti-claude"
fi

echo "See README for how to configure model aliases in ~/.corti-claude/settings.json (optional, or run ./setup.sh --detect-models)."
