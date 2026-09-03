# shellcheck shell=sh
# Pre-install dependency and credential checks. Blocking (node, curl) abort the install;
# advisory (claude, pkill, credentials) are reported but the wrapper installs anyway.

CC_NODE_MIN=20

preflight_deps() {
  if ! command -v node >/dev/null 2>&1; then
    ui_fatal "node is required but not found on PATH" \
      "corti-bridge needs Node.js ($CC_NODE_MIN or newer) to run the proxy gateway." \
      "Install it, then re-run ./setup.sh:" \
      "" \
      "  https://nodejs.org/"
  fi

  _pf_major="$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')"
  case "$_pf_major" in
    '' | *[!0-9]*)
      ui_warn "couldn't read the node version - continuing"
      ;;
    *)
      if [ "$_pf_major" -lt "$CC_NODE_MIN" ]; then
        ui_fatal "node $(node -v) found, but $CC_NODE_MIN or newer is required" \
          "corti-bridge needs Node.js ($CC_NODE_MIN or newer) to run the proxy gateway." \
          "Upgrade it, then re-run ./setup.sh:" \
          "" \
          "  https://nodejs.org/"
      fi
      ;;
  esac

  if ! command -v curl >/dev/null 2>&1; then
    ui_fatal "curl is required but not found on PATH" \
      "corti-bridge uses curl to talk to Corti and to check on the proxy." \
      "Install it, then re-run ./setup.sh."
  fi

  _pf_summary="node $(node -v 2>/dev/null), curl"

  if command -v claude >/dev/null 2>&1; then
    _pf_claude_v="$(claude --version 2>/dev/null | awk '{print $1}')"
    _pf_summary="$_pf_summary, claude ${_pf_claude_v:-installed}"
    ui_detail "$_pf_summary"
  else
    ui_detail "$_pf_summary"
    # Version managers and shims can hide a working binary from /bin/sh, so this never blocks.
    ui_warn "couldn't find 'claude' on your PATH"
    ui_detail "  If \`claude --version\` works in your terminal, ignore this."
    return 1
  fi

  if ! command -v pkill >/dev/null 2>&1; then
    ui_warn "no 'pkill' - corti-bridge can't auto-restart a stale proxy; stop it by hand"
  fi

  return 0
}

# Shape-checked with the same glob the wrapper uses. Looser than gateway.mjs's regex, which
# stays the authority; this only turns a slow, silent failure into an immediate one.
preflight_base_url_ok() {
  case "${CORTI_BASE_URL:-}" in
    https://ai.*.corti.app/v1) return 0 ;;
    *) return 1 ;;
  esac
}

preflight_credentials() {
  _pf_ok=0

  if [ -z "${CORTI_BEARER:-}" ]; then
    ui_warn "CORTI_BEARER is not set"
    _pf_ok=1
  fi

  if [ -z "${CORTI_BASE_URL:-}" ]; then
    ui_warn "CORTI_BASE_URL is not set"
    _pf_ok=1
  elif ! preflight_base_url_ok; then
    ui_warn "CORTI_BASE_URL doesn't look like https://ai.<env>.corti.app/v1"
    ui_detail "  got: $CORTI_BASE_URL"
    _pf_ok=1
  else
    ui_pair "CORTI_BASE_URL" "$CORTI_BASE_URL"
  fi

  return "$_pf_ok"
}
