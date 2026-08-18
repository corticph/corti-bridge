#!/bin/sh
# corti-claude-proxy setup — installs the corti-claude wrapper.
# Run from the repo root: ./setup.sh   (./setup.sh --help for options)
#
# Ordering rule: every check runs before anything is written.
set -eu

CC_REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CC_BIN_DIR="${CC_PROXY_BIN_DIR:-$HOME/.local/bin}"
CC_STATE_DIR="${CC_PROXY_CONFIG_DIR:-$HOME/.corti-claude}"

# ui.sh first: everything else prints through it. The libs define functions and defaults only,
# so nothing happens at source time.
. "$CC_REPO_DIR/lib/ui.sh"
. "$CC_REPO_DIR/lib/preflight.sh"
. "$CC_REPO_DIR/lib/pathrc.sh"
. "$CC_REPO_DIR/lib/models.sh"
. "$CC_REPO_DIR/lib/profile.sh"

CC_ASSUME_YES=0
CC_NO_MODIFY_PATH=0
CC_FRESH=0
CC_DETECT_MODELS=0
CC_EXPERIMENTAL=0
CC_ASK_PROFILE=0
CC_UNINSTALL=0

usage() {
  cat <<EOF
corti-claude-proxy setup

Usage: ./setup.sh [options]

Installs the corti-claude wrapper, checks it can reach Corti, and records which
Corti models back Claude Code's Opus/Sonnet/Haiku tiers.

Options:
  --yes             Accept all prompts (PATH edit, profile, model detection)
  --no-modify-path  Never edit shell rc files; just print the PATH line
  --fresh           Re-detect models from Corti and re-ask the profile choice,
                    ignoring existing models.env and profile.env
  --experimental    Include beta models in the catalog fetch (pairs with --fresh)
  --uninstall       Remove the wrapper and the PATH block setup.sh added
  -h, --help        Show this help

Environment:
  CORTI_BEARER, CORTI_BASE_URL   required at runtime (not managed by this script)
  CC_PROXY_BIN_DIR               where the wrapper is installed (default ~/.local/bin)
  CC_PROXY_CONFIG_DIR            proxy state dir (default ~/.corti-claude)

See README.md for details.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --yes) CC_ASSUME_YES=1 ;;
    --no-modify-path) CC_NO_MODIFY_PATH=1 ;;
    --fresh) CC_FRESH=1 ;;
    --experimental) CC_EXPERIMENTAL=1 ;;
    --uninstall) CC_UNINSTALL=1 ;;
    *)
      printf 'setup: unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done
export CC_ASSUME_YES CC_NO_MODIFY_PATH

# --fresh is the one refresh verb: redo both state files, ignoring what's there.
if [ "$CC_FRESH" = 1 ]; then
  CC_DETECT_MODELS=1
  CC_ASK_PROFILE=1
fi

# Outstanding work, accumulated as preformatted text so the verdict prints it verbatim.
CC_PROBLEMS=''
CC_PROBLEM_COUNT=0
CC_NEEDS_RESTART=0

problem_add() {
  CC_PROBLEM_COUNT=$((CC_PROBLEM_COUNT + 1))
  CC_PROBLEMS="${CC_PROBLEMS}${CC_PROBLEMS:+

}  $CC_PROBLEM_COUNT. $1"
}

install_wrapper() {
  mkdir -p "$CC_BIN_DIR"
  _cc_tmp="$CC_BIN_DIR/corti-claude.tmp"

  # A byte-identical result means the substitution missed the PROXY_DIR pattern — treat as failure.
  sed "s|\${CC_PROXY_DIR:-/path/to/corti-claude-proxy}|\${CC_PROXY_DIR:-$CC_REPO_DIR}|" \
    "$CC_REPO_DIR/bin/corti-claude" >"$_cc_tmp"
  if cmp -s "$CC_REPO_DIR/bin/corti-claude" "$_cc_tmp"; then
    rm -f "$_cc_tmp"
    ui_fatal "path substitution failed; refusing to install a wrapper with the wrong PROXY_DIR" \
      "This is a bug in setup.sh — bin/corti-claude's PROXY_DIR line no longer matches" \
      "the pattern setup.sh substitutes."
  fi

  if [ -f "$CC_BIN_DIR/corti-claude" ] && cmp -s "$CC_BIN_DIR/corti-claude" "$_cc_tmp"; then
    rm -f "$_cc_tmp"
    ui_detail "$(ui_tilde "$CC_BIN_DIR/corti-claude") is up to date"
  else
    _cc_verb=installed
    if [ -f "$CC_BIN_DIR/corti-claude" ]; then _cc_verb=updated; fi
    mv "$_cc_tmp" "$CC_BIN_DIR/corti-claude"
    chmod +x "$CC_BIN_DIR/corti-claude"
    ui_wrote "$_cc_verb $(ui_tilde "$CC_BIN_DIR/corti-claude")"
  fi
}

# Falls back to the fresh profile rather than re-prompting.
profile_custom_dir() {
  _cc_in="$(ui_ask 'Path to the config directory:' '' '')"
  _cc_out="$(profile_resolve_dir "$_cc_in")"

  if [ -n "$_cc_out" ]; then
    printf '%s' "$_cc_out"
    return 0
  fi

  if [ -z "$_cc_in" ]; then
    ui_warn "no path given - using $(ui_tilde "$CC_STATE_DIR")"
  else
    ui_warn "$_cc_in is not an absolute path - using $(ui_tilde "$CC_STATE_DIR")"
  fi
  printf '%s' "$CC_STATE_DIR"
}

configure_profile() {
  _cc_pf="$CC_STATE_DIR/profile.env"

  if [ -f "$_cc_pf" ] && [ "$CC_ASK_PROFILE" != 1 ]; then
    _cc_cur="$(models_env_get "$_cc_pf" CLAUDE_CONFIG_DIR || true)"
    ui_detail "using $(ui_tilde "${_cc_cur:-$CC_STATE_DIR}") (run ./setup.sh --fresh to change)"
    return 0
  fi

  ui_detail "Which Claude Code profile should Corti sessions use?"
  ui_blank
  ui_detail "  1) Your normal profile at $(ui_tilde "$HOME/.claude")  (recommended)"
  ui_detail "     Shares your existing history, plugins, skills, and MCP servers."
  ui_detail "     Your regular \`claude\` stays on Anthropic models either way."
  ui_blank
  ui_detail "  2) Fresh profile at $(ui_tilde "$CC_STATE_DIR")"
  ui_detail "     Starts empty - no history, plugins, skills, or MCP servers."
  ui_detail "     Use this if you want Corti sessions kept separate from your usual ones."
  ui_blank
  ui_detail "  3) A path you choose"
  ui_detail "     Any other Claude Code config directory - a separate work profile, say."
  ui_blank

  case "$(ui_ask 'Choice [1]:' 1 1)" in
    2) _cc_dir="$CC_STATE_DIR" ;;
    3) _cc_dir="$(profile_custom_dir)" ;;
    *) _cc_dir="$HOME/.claude" ;;
  esac

  # A typo is otherwise invisible until Claude Code starts up against an empty profile.
  [ -d "$_cc_dir" ] || ui_detail "$(ui_tilde "$_cc_dir") does not exist yet - Claude Code will create it"

  mkdir -p "$CC_STATE_DIR"
  printf '# Written by setup.sh. Run ./setup.sh --fresh to change.\nCLAUDE_CONFIG_DIR="%s"\n' \
    "$_cc_dir" >"$_cc_pf"
  ui_detail "using $(ui_tilde "$_cc_dir")"
  ui_wrote "$(ui_tilde "$_cc_pf")"
}

uninstall() {
  ui_step "Removing corti-claude"
  if [ -f "$CC_BIN_DIR/corti-claude" ]; then
    rm -f "$CC_BIN_DIR/corti-claude"
    ui_wrote "removed $(ui_tilde "$CC_BIN_DIR/corti-claude")"
  else
    ui_detail "no wrapper at $(ui_tilde "$CC_BIN_DIR/corti-claude")"
  fi
  pathrc_remove
  ui_blank
  printf 'corti-claude removed. Your settings are still in %s —\n' "$(ui_tilde "$CC_STATE_DIR")" >&2
  printf 'delete that directory yourself if you want them gone too.\n' >&2
  exit 0
}

verdict() {
  if [ "$CC_PROBLEM_COUNT" -eq 0 ]; then
    if [ "$CC_NEEDS_RESTART" = 1 ] && [ -n "$CC_RC_FILE" ]; then
      printf '\nReady - open a new terminal (or run: source %s), then run: corti-claude\n' \
        "$(ui_tilde "$CC_RC_FILE")" >&2
    else
      printf '\nReady. Run: corti-claude\n' >&2
    fi
    return 0
  fi

  _cc_noun=things
  if [ "$CC_PROBLEM_COUNT" -eq 1 ]; then _cc_noun=thing; fi
  printf '\n%d %s outstanding before corti-claude will work:\n\n' \
    "$CC_PROBLEM_COUNT" "$_cc_noun" >&2
  printf '%s\n' "$CC_PROBLEMS" >&2
}

ui_step "corti-claude-proxy setup"
if [ "$CC_UNINSTALL" = 1 ]; then uninstall; fi

ui_step "Checking dependencies"
preflight_deps || true

ui_step "Checking credentials"
if preflight_credentials; then
  CC_CREDS_OK=1
else
  CC_CREDS_OK=0
  problem_add "CORTI_BEARER and CORTI_BASE_URL aren't set. These normally come from Corti's
     CLI when your shell starts. Run:

       npx @corti/cli models init

     then open a new terminal and re-run ./setup.sh."
fi

ui_step "Installing corti-claude"
install_wrapper
set +e
pathrc_ensure "$CC_BIN_DIR"
_cc_path_rc=$?
set -e
case "$_cc_path_rc" in
  1) CC_NEEDS_RESTART=1 ;;
  2)
    problem_add "$(ui_tilde "$CC_BIN_DIR") is not on PATH. Add it yourself, re-run ./setup.sh, or run
     corti-claude by its full path:

       export PATH=\"$CC_BIN_DIR:\$PATH\"
       $(ui_tilde "$CC_BIN_DIR")/corti-claude"
    ;;
esac

ui_step "Claude Code profile"
configure_profile

ui_step "Configuring models"
if ! models_configure "$CC_STATE_DIR" "$CC_DETECT_MODELS" "$CC_EXPERIMENTAL"; then
  if [ "$CC_CREDS_OK" = 1 ]; then
    problem_add "No model mapping yet — Claude Code would fail on its first message. Run:

       ./setup.sh --fresh"
  else
    problem_add "Once credentials are set, run:

       ./setup.sh --fresh"
  fi
fi

verdict
