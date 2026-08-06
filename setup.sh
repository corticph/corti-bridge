#!/bin/zsh
# cc-proxy setup — installs the corti-claude wrapper and creates config dir.
# Run from the repo root: ./setup.sh
set -euo pipefail

REPO_DIR="${0:A:h}"
CORTI_DIR="$HOME/.corti-claude"
BIN_DIR="${CC_PROXY_BIN_DIR:-$HOME/.local/bin}"

echo "cc-proxy setup"
echo ""

# 1. Config dir
mkdir -p "$CORTI_DIR"

# 2. corti.env (don't overwrite if exists)
if [[ ! -f "$CORTI_DIR/corti.env" ]]; then
    cp "$REPO_DIR/corti.env.example" "$CORTI_DIR/corti.env"
    echo "Created $CORTI_DIR/corti.env — edit it to add your CORTI_BEARER"
else
    echo "Found $CORTI_DIR/corti.env (kept)"
fi

# 3. settings.json (don't overwrite if exists)
if [[ ! -f "$CORTI_DIR/settings.json" ]]; then
    BEARER=$(grep '^CORTI_BEARER=' "$CORTI_DIR/corti.env" | sed 's/.*:-\([^"]*\)".*/\1/')
    sed "s/__CORTI_BEARER__/$BEARER/" "$REPO_DIR/settings.template.json" > "$CORTI_DIR/settings.json"
    echo "Created $CORTI_DIR/settings.json"
else
    echo "Found $CORTI_DIR/settings.json (kept)"
fi

# 4. Wrapper
mkdir -p "$BIN_DIR"
cp "$REPO_DIR/bin/corti-claude" "$BIN_DIR/corti-claude"
chmod +x "$BIN_DIR/corti-claude"
echo "Installed corti-claude to $BIN_DIR"

# 5. PATH check
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo ""
    echo "Warning: $BIN_DIR is not in your PATH"
    echo "Add this to your shell config:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi

# 6. Verify
if [[ -f "$CORTI_DIR/corti.env" ]] && ! grep -q "your-corti-bearer-token" "$CORTI_DIR/corti.env"; then
    echo ""
    echo "Done. Run: corti-claude"
else
    echo ""
    echo "Done. Edit $CORTI_DIR/corti.env to add your CORTI_BEARER, then run: corti-claude"
fi
