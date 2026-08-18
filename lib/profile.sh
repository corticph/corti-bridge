# shellcheck shell=bash
# Which Claude Code profile Corti sessions run against (CLAUDE_CONFIG_DIR).

# Resolves a typed config directory to an absolute path, echoing nothing when it cannot.
# Expands a leading ~, refuses relative paths (would resolve against setup.sh's CWD).
profile_resolve_dir() {
  _pf_in="$1"
  case "$_pf_in" in
    "~") _pf_in="$HOME" ;;
    "~/"*) _pf_in="$HOME/${_pf_in#\~/}" ;;
  esac

  case "$_pf_in" in
    /*) printf '%s' "$_pf_in" ;;
  esac
}
