#!/bin/sh
# corti-claude-proxy setup — installs the corti-claude wrapper.
# Run from the repo root: ./setup.sh
# Run with --detect-models to fetch Corti's live model catalog (via CORTI_BASE_URL)
# and write ~/.corti-claude/settings.json from it.
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN_DIR="${CC_PROXY_BIN_DIR:-$HOME/.local/bin}"
CORTI_DIR="${CC_PROXY_CONFIG_DIR:-$HOME/.corti-claude}"

detect_models() {
    if [ -z "${CORTI_BEARER:-}" ] || [ -z "${CORTI_BASE_URL:-}" ]; then
        echo "detect-models: CORTI_BEARER and CORTI_BASE_URL must be set in your environment" >&2
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

    echo "Fetching model catalog from $CORTI_BASE_URL/models..." >&2
    if ! catalog=$(curl -sf --max-time 10 -H "Authorization: Bearer $CORTI_BEARER" "$CORTI_BASE_URL/models"); then
        echo "detect-models: failed to fetch model catalog" >&2
        exit 1
    fi

    # Preference lists, first match wins. opus = strongest stable tier (ultra-beta is an RC
    # build — it's offered as the custom option instead); embedding models never qualify.
    if ! mapping=$(node -e '
        const data = JSON.parse(process.argv[1]);
        const ids = (Array.isArray(data.data) ? data.data : [])
            .map((m) => m && m.id)
            .filter((id) => typeof id === "string" && !/embedding/i.test(id));
        if (ids.length < 3) {
            console.error("catalog has fewer than 3 chat models");
            process.exit(1);
        }
        const prefs = {
            opus: ["corti-s1", "corti-s1-ultra-beta", "corti-s1-beta"],
            sonnet: ["corti-s1-instant", "corti-s1"],
            haiku: ["corti-s1-mini-instant", "corti-s1-tiny-instant", "corti-s1-mini"],
            custom: ["corti-s1-ultra-beta", "corti-s1-mini"],
        };
        const pick = (list) => list.find((id) => ids.includes(id)) || null;
        const out = { opus: pick(prefs.opus), sonnet: pick(prefs.sonnet), haiku: pick(prefs.haiku), custom: pick(prefs.custom) };
        // any slot that missed its preference list falls back to the first unused catalog model
        const used = new Set(Object.values(out).filter(Boolean));
        for (const slot of Object.keys(out)) {
            if (!out[slot]) {
                out[slot] = ids.find((id) => !used.has(id)) || ids[0];
                console.error(`warning: no preference match for ${slot}; using ${out[slot]}`);
                used.add(out[slot]);
            }
        }
        process.stdout.write(JSON.stringify(out));
    ' "$catalog"); then
        exit 1
    fi

    mkdir -p "$CORTI_DIR"
    node -e '
        const fs = require("fs");
        const [path, mappingJson] = process.argv.slice(1);
        const m = JSON.parse(mappingJson);
        const env = {
            ANTHROPIC_DEFAULT_OPUS_MODEL: m.opus,
            ANTHROPIC_DEFAULT_SONNET_MODEL: m.sonnet,
            ANTHROPIC_DEFAULT_HAIKU_MODEL: m.haiku,
        };
        if (m.custom) {
            env.ANTHROPIC_CUSTOM_MODEL_OPTION = m.custom;
            env.ANTHROPIC_CUSTOM_MODEL_OPTION_NAME = m.custom;
        }
        env.CLAUDE_CODE_MAX_CONTEXT_TOKENS = "262144";
        fs.writeFileSync(path, JSON.stringify({ env: env }, null, 2) + "\n");
    ' "$CORTI_DIR/settings.json" "$mapping"

    echo "" >&2
    node -e 'const m = JSON.parse(process.argv[1]);
        console.log("Opus: " + m.opus);
        console.log("Sonnet: " + m.sonnet);
        console.log("Haiku: " + m.haiku);
        if (m.custom) console.log("Custom: " + m.custom);
    ' "$mapping" >&2
    echo "" >&2
    echo "Wrote $CORTI_DIR/settings.json — edit it anytime to change these." >&2
    echo "Context window is set to 262144 (probed on all current tiers); edit if Corti ships smaller-context models." >&2
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
