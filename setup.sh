#!/bin/zsh
# cc-proxy setup — installs the corti-claude wrapper.
# Run from the repo root: ./setup.sh
set -euo pipefail

REPO_DIR="${0:A:h}"
BIN_DIR="${CC_PROXY_BIN_DIR:-$HOME/.local/bin}"

echo "cc-proxy setup"
echo ""

# 1. Wrapper
mkdir -p "$BIN_DIR"
cp "$REPO_DIR/bin/corti-claude" "$BIN_DIR/corti-claude"
chmod +x "$BIN_DIR/corti-claude"
echo "Installed corti-claude to $BIN_DIR"

# 2. PATH check
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    echo "Warning: $BIN_DIR is not in your PATH"
    echo "Add this to your shell config:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi

# 3. Verify
echo ""
if [[ -n "${CORTI_BEARER:-}" && -n "${CORTI_BASE_URL:-}" ]]; then
    echo "Done. Run: corti-claude"
else
    echo "Done. CORTI_BEARER and CORTI_BASE_URL must be set in your shell environment, then run: corti-claude"
fi

echo "See README for how to configure model aliases in ~/.corti-claude/settings.json (optional)."
