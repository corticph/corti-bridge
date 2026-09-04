#!/bin/sh
# corti-bridge setup — installs the corti-bridge wrapper.
# Run from the repo root: ./setup.sh   (./setup.sh --help for options)
#
# Ordering rule: every check runs before anything is written.
set -eu

CC_REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CC_BIN_DIR="${CORTI_PROXY_BIN_DIR:-${CC_PROXY_BIN_DIR:-$HOME/.local/bin}}"
CC_STATE_DIR="${CORTI_PROXY_CONFIG_DIR:-${CC_PROXY_CONFIG_DIR:-$HOME/.corti-bridge}}"

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
corti-bridge setup

Usage: ./setup.sh [options]

Installs the corti-bridge wrapper, checks it can reach Corti, and records which
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
  CORTI_PROXY_BIN_DIR               where the wrapper is installed (default ~/.local/bin)
  CORTI_PROXY_CONFIG_DIR            proxy state dir (default ~/.corti-bridge)

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
  _cc_tmp="$CC_BIN_DIR/corti-bridge.tmp"

  # A byte-identical result means the substitution missed the PROXY_DIR pattern — treat as failure.
  sed "s|\${CORTI_PROXY_DIR:-/path/to/corti-bridge}|\${CORTI_PROXY_DIR:-$CC_REPO_DIR}|" \
    "$CC_REPO_DIR/bin/corti-bridge" >"$_cc_tmp"
  if cmp -s "$CC_REPO_DIR/bin/corti-bridge" "$_cc_tmp"; then
    rm -f "$_cc_tmp"
    ui_fatal "path substitution failed; refusing to install a wrapper with the wrong PROXY_DIR" \
      "This is a bug in setup.sh — bin/corti-bridge's PROXY_DIR line no longer matches" \
      "the pattern setup.sh substitutes."
  fi

  if [ -f "$CC_BIN_DIR/corti-bridge" ] && cmp -s "$CC_BIN_DIR/corti-bridge" "$_cc_tmp"; then
    rm -f "$_cc_tmp"
    ui_detail "$(ui_tilde "$CC_BIN_DIR/corti-bridge") is up to date"
  else
    _cc_verb=installed
    if [ -f "$CC_BIN_DIR/corti-bridge" ]; then _cc_verb=updated; fi
    mv "$_cc_tmp" "$CC_BIN_DIR/corti-bridge"
    chmod +x "$CC_BIN_DIR/corti-bridge"
    ui_wrote "$_cc_verb $(ui_tilde "$CC_BIN_DIR/corti-bridge")"
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

  ui_detail "Claude Code keeps its settings (history, allowed commands, MCP servers) in a"
  ui_detail "config directory. Pick which one your Corti sessions should use:"
  ui_blank
  ui_detail "  1) Your normal profile at $(ui_tilde "$HOME/.claude")  (recommended)"
  ui_detail "     Reuses the settings you already have. Your regular \`claude\` command is"
  ui_detail "     unaffected — it still talks to Anthropic directly."
  ui_blank
  ui_detail "  2) A fresh profile at $(ui_tilde "$CC_STATE_DIR")"
  ui_detail "     Starts empty. Use this if you want Corti sessions walled off from your"
  ui_detail "     usual settings."
  ui_blank
  ui_detail "  3) A path you choose"
  ui_detail "     Any other Claude Code config directory."
  ui_blank

  # Re-ask once on a miskey rather than silently falling through to option 1; a second
  # empty/EOF honours ui_ask's $3 and defaults to 1.
  _cc_choice=1
  _cc_asked=0
  while [ "$_cc_asked" -lt 2 ]; do
    _cc_reply="$(ui_ask 'Choice [1]:' 1 1)"
    case "$_cc_reply" in
      1|2|3) _cc_choice=$_cc_reply; break ;;
      '') _cc_choice=1; break ;;
      *)
        _cc_asked=$((_cc_asked + 1))
        if [ "$_cc_asked" -lt 2 ]; then
          ui_warn "1, 2, or 3 — try again"
        fi
        ;;
    esac
  done
  unset _cc_asked _cc_reply

  case "$_cc_choice" in
    2) _cc_dir="$CC_STATE_DIR" ;;
    3) _cc_dir="$(profile_custom_dir)" ;;
    *) _cc_dir="$HOME/.claude" ;;
  esac
  unset _cc_choice

  # A typo is otherwise invisible until Claude Code starts up against an empty profile.
  [ -d "$_cc_dir" ] || ui_detail "$(ui_tilde "$_cc_dir") does not exist yet - Claude Code will create it"

  mkdir -p "$CC_STATE_DIR"
  printf '# Written by setup.sh. Run ./setup.sh --fresh to change.\nCLAUDE_CONFIG_DIR="%s"\n' \
    "$_cc_dir" >"$_cc_pf"
  ui_detail "using $(ui_tilde "$_cc_dir")"
  ui_wrote "$(ui_tilde "$_cc_pf")"
}

uninstall() {
  ui_step "Removing corti-bridge"
  if [ -f "$CC_BIN_DIR/corti-bridge" ]; then
    rm -f "$CC_BIN_DIR/corti-bridge"
    ui_wrote "removed $(ui_tilde "$CC_BIN_DIR/corti-bridge")"
  else
    ui_detail "no wrapper at $(ui_tilde "$CC_BIN_DIR/corti-bridge")"
  fi
  pathrc_remove
  ui_blank
  printf 'corti-bridge removed. Your settings are still in %s —\n' "$(ui_tilde "$CC_STATE_DIR")" >&2
  printf 'delete that directory yourself if you want them gone too.\n' >&2
  exit 0
}

# Three states, two exit codes. set -e does NOT turn a function return into an exit for an
# unconditionally-called function, so the exit is explicit. State C (early-stop on missing
# creds) exits from the creds step and never reaches here.
verdict() {
  if [ "$CC_PROBLEM_COUNT" -eq 0 ]; then
    ui_step "Setup complete"
    ui_pair "installed" "$(ui_tilde "$CC_BIN_DIR/corti-bridge")"
    ui_pair "profile" "$(ui_tilde "${_cc_profile_dir:-$CC_STATE_DIR}")"
    ui_pair "models" "${_cc_models_line:-not detected}"
    ui_pair "context" "${_cc_context:-unknown}"
    ui_pair "state" "$(ui_tilde "$CC_STATE_DIR")"
    ui_blank
    if [ "$CC_NEEDS_RESTART" = 1 ] && [ -n "$CC_RC_FILE" ]; then
      printf 'Ready - open a new terminal (or run: source %s), then run: corti-bridge\n' \
        "$(ui_tilde "$CC_RC_FILE")" >&2
    else
      printf 'Ready. Run: corti-bridge\n' >&2
    fi
    exit 0
  fi

  ui_step "Setup incomplete — some steps need attention"
  printf '\n%s\n' "$CC_PROBLEMS" >&2
  printf '\nFix the above, then re-run:  ./setup.sh\n' >&2
  exit 1
}

# Banner names the command the user types next, with an optional git ref for bug reports.
_cc_ref="$(git -C "$CC_REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)"
if [ -n "$_cc_ref" ]; then
  ui_step "corti-bridge setup (git $_cc_ref)"
else
  ui_step "corti-bridge setup"
fi
unset _cc_ref
ui_detail "Configures the corti-bridge launcher. Claude Code will run on Corti's models,"
ui_detail "through a small local gateway that ./bin/corti-bridge starts for you."

if [ "$CC_UNINSTALL" = 1 ]; then uninstall; fi

# A re-run is one where the wrapper is already installed; on a re-run, missing creds is a
# runtime concern (the wrapper catches it), not an install blocker, so the early-stop downgrades
# to a warn-and-continue. Only a first run (no wrapper) hard-stops on missing creds.
_cc_is_update=0
[ -f "$CC_BIN_DIR/corti-bridge" ] && _cc_is_update=1

ui_step "Checking dependencies"
preflight_deps || true

ui_step "Checking Corti credentials"
if preflight_credentials; then
  CC_CREDS_OK=1
else
  CC_CREDS_OK=0
  if [ "$_cc_is_update" = 1 ]; then
    # Re-run with creds gone: preflight already named the missing var(s); add only the runtime
    # context it can't. The wrapper will catch missing creds at launch; let the model step skip.
    ui_detail "The wrapper will need these at runtime — run: npx @corti/cli models init"
  else
    # First run without creds: preflight already named the missing var(s); stop before copying
    # anything and add the guided remediation. The wrapper is useless without them.
    ui_blank
    ui_explain \
      "corti-bridge talks to Corti through two environment variables that the Corti" \
      "CLI exports into your shell. Set them up first, then re-run ./setup.sh:" \
      "" \
      "  npx @corti/cli models init" \
      "" \
      "(This exports CORTI_BEARER and CORTI_BASE_URL into the *current* shell. Open a" \
      "new terminal afterward, or the next ./setup.sh won't see them.)" \
      "" \
      "Nothing was installed."
    exit 1
  fi
fi

ui_step "Installing corti-bridge"
install_wrapper
set +e
pathrc_ensure "$CC_BIN_DIR"
_cc_path_rc=$?
set -e
case "$_cc_path_rc" in
  1) CC_NEEDS_RESTART=1 ;;
  3)
    # --no-modify-path: the user explicitly opted out, so the manual recipe pathrc printed is
    # informational, not a numbered problem. No problem_add → verdict lands in State A.
    ;;
  2)
    problem_add "$(ui_tilde "$CC_BIN_DIR") is not on PATH. Add it yourself, re-run ./setup.sh, or run
     corti-bridge by its full path:

       export PATH=\"$CC_BIN_DIR:\$PATH\"
       $(ui_tilde "$CC_BIN_DIR")/corti-bridge"
    ;;
esac

ui_step "Claude Code profile"
configure_profile
_cc_profile_dir="$(models_env_get "$CC_STATE_DIR/profile.env" CLAUDE_CONFIG_DIR 2>/dev/null || true)"

ui_step "Configuring models"
if models_configure "$CC_STATE_DIR" "$CC_DETECT_MODELS" "$CC_EXPERIMENTAL"; then
  _cc_models_line="$(models_env_get "$CC_STATE_DIR/models.env" ANTHROPIC_DEFAULT_OPUS_MODEL 2>/dev/null || true)"
  _cc_models_line="$_cc_models_line, $(models_env_get "$CC_STATE_DIR/models.env" ANTHROPIC_DEFAULT_SONNET_MODEL 2>/dev/null || true), $(models_env_get "$CC_STATE_DIR/models.env" ANTHROPIC_DEFAULT_HAIKU_MODEL 2>/dev/null || true)"
  _cc_context="$(models_env_get "$CC_STATE_DIR/models.env" CLAUDE_CODE_MAX_CONTEXT_TOKENS 2>/dev/null || true)"
else
  if [ "$CC_CREDS_OK" = 1 ]; then
    problem_add "Couldn't detect Corti's models. Re-run after fixing credentials:
       npx @corti/cli models init
     then: ./setup.sh --fresh"
  else
    problem_add "Once credentials are set, run:
       ./setup.sh --fresh"
  fi
fi

verdict
