# shellcheck shell=sh
# Shell startup-file handling. Every mutation is append-only, backed up first, and
# marked so it can be removed again. A subprocess cannot change its parent's PATH.

CC_PATH_MARKER='# corti-bridge: added by setup.sh'
# Legacy marker from pre-rename installs; removal/detection must match both so
# an upgrade cleans up the old PATH block rather than orphaning it.
CC_PATH_MARKER_LEGACY='# corti-claude: added by setup.sh'

# $SHELL is the registered login shell, the best signal available since this runs under /bin/sh.
pathrc_detect_shell() {
  case "${SHELL:-}" in
    */bash) printf 'bash' ;;
    */zsh) printf 'zsh' ;;
    */fish) printf 'fish' ;;
    *) printf 'unknown' ;;
  esac
}

# One path per line.
#   zsh   .zshrc (read by every interactive zsh, not login-only .zprofile)
#   bash  both files where they exist (login vs non-login varies by terminal)
#   fish  its own conf.d file, leaving config.fish untouched
pathrc_target_files() {
  case "$1" in
    zsh) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash)
      _prc_found=0
      for _prc_f in "$HOME/.bash_profile" "$HOME/.bashrc"; do
        if [ -f "$_prc_f" ]; then
          printf '%s\n' "$_prc_f"
          _prc_found=1
        fi
      done
      [ "$_prc_found" = 1 ] || printf '%s\n' "$HOME/.bash_profile"
      ;;
    fish) printf '%s\n' "$HOME/.config/fish/conf.d/corti-bridge.fish" ;;
    *) : ;;
  esac
}

# Keep $HOME literal in the written block so a synced dotfile still resolves on another machine.
pathrc_portable_dir() {
  case "$1" in
    "$HOME"/*) printf '$HOME%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The emitted block guards on $PATH at shell startup, so re-sourcing never adds a duplicate entry.
pathrc_block() {
  if [ "$1" = fish ]; then
    printf '%s\n' "$CC_PATH_MARKER"
    printf 'fish_add_path -a %s\n' "$(pathrc_portable_dir "$2")"
    return 0
  fi
  _prc_dir="$(pathrc_portable_dir "$2")"
  printf '%s\n' "$CC_PATH_MARKER"
  printf 'case ":${PATH}:" in\n'
  printf '  *":%s:"*) ;;\n' "$_prc_dir"
  printf '  *) export PATH="%s:$PATH" ;;\n' "$_prc_dir"
  printf 'esac\n'
}

# Grep the file, never $PATH: $PATH describes only this process, so an already-configured file
# would look unconfigured.
pathrc_already_configured() {
  grep -qF "$CC_PATH_MARKER" "$1" 2>/dev/null && return 0
  grep -qF "$CC_PATH_MARKER_LEGACY" "$1" 2>/dev/null
}

pathrc_on_path() {
  case ":$PATH:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 = already usable, 1 = written (needs a new shell), 2 = not written (caller records it),
# 3 = not written because --no-modify-path was given (informational, not a problem).
# Sets CC_RC_FILE to whatever was written, for the closing message.
CC_RC_FILE=''

pathrc_ensure() {
  _prc_bin="$1"

  if pathrc_on_path "$_prc_bin"; then
    ui_detail "already on PATH"
    return 0
  fi

  _prc_shell="$(pathrc_detect_shell)"
  ui_warn "$(ui_tilde "$_prc_bin") is not on PATH"

  if [ "$_prc_shell" = unknown ]; then
    ui_detail "  unrecognised shell (${SHELL:-none}), so nothing was edited"
    return 2
  fi

  _prc_targets="$(pathrc_target_files "$_prc_shell")"
  [ -n "$_prc_targets" ] || return 2

  # Already written but not yet active — offering again would be nonsense.
  _prc_configured=1
  for _prc_f in $_prc_targets; do
    pathrc_already_configured "$_prc_f" || _prc_configured=0
  done
  if [ "$_prc_configured" = 1 ]; then
    CC_RC_FILE="$(printf '%s\n' "$_prc_targets" | head -1)"
    ui_detail "already set up in $(ui_tilde "$CC_RC_FILE") - not active in this terminal yet"
    return 1
  fi

  if [ "${CC_NO_MODIFY_PATH:-0}" = 1 ]; then
    ui_detail "  --no-modify-path given, so nothing was edited"
    ui_detail "  to use corti-bridge now: export PATH=\"$(pathrc_portable_dir "$_prc_bin"):\$PATH\""
    return 3
  fi

  _prc_display=''
  for _prc_f in $_prc_targets; do
    _prc_display="${_prc_display}${_prc_display:+ and }$(ui_tilde "$_prc_f")"
  done

  # Default n when unattended.
  if ! ui_is_yes "$(ui_ask "Add it to $_prc_display now? [Y/n]" y n)"; then
    return 2
  fi

  for _prc_f in $_prc_targets; do
    mkdir -p "$(dirname "$_prc_f")"
    if [ -f "$_prc_f" ]; then
      cp -p "$_prc_f" "$_prc_f.corti-bridge.bak" 2>/dev/null || true
      ui_wrote "appended to $(ui_tilde "$_prc_f") (backed up to $(ui_tilde "$_prc_f").corti-bridge.bak)"
    else
      ui_wrote "created $(ui_tilde "$_prc_f")"
    fi
    # Leading newline: without it, a file with no trailing newline gets the marker glued onto
    # its last line.
    printf '\n%s\n' "$(pathrc_block "$_prc_shell" "$_prc_bin")" >>"$_prc_f"
    CC_RC_FILE="$_prc_f"
  done

  return 1
}

# Removal for --uninstall. The range ends at the first `esac` after the marker, which is the
# block's own. Avoid `sed -i`: BSD wants `-i ''`, GNU wants a bare `-i`.
pathrc_remove() {
  _prc_shell="$(pathrc_detect_shell)"
  _prc_removed=0

  # Fish uses a per-block file whose name changed in the rename, so the loop
  # below (which iterates the new filename) can't see a legacy corti-claude.fish.
  # Remove it explicitly.
  if [ "$_prc_shell" = fish ] && [ -f "$HOME/.config/fish/conf.d/corti-claude.fish" ]; then
    rm -f "$HOME/.config/fish/conf.d/corti-claude.fish"
    ui_wrote "removed legacy $(ui_tilde "$HOME/.config/fish/conf.d/corti-claude.fish")"
    _prc_removed=1
  fi

  for _prc_f in $(pathrc_target_files "$_prc_shell"); do
    [ -f "$_prc_f" ] || continue
    pathrc_already_configured "$_prc_f" || continue

    case "$_prc_shell" in
      fish)
        rm -f "$_prc_f"
        ui_wrote "removed $(ui_tilde "$_prc_f")"
        ;;
      *)
        cp -p "$_prc_f" "$_prc_f.corti-bridge.bak" 2>/dev/null || true
        # Delete the block for BOTH markers: a legacy block has the old marker
        # text but the same esac-terminated structure.
        sed -e "/^$CC_PATH_MARKER\$/,/^esac\$/d" \
            -e "/^$CC_PATH_MARKER_LEGACY\$/,/^esac\$/d" "$_prc_f" >"$_prc_f.tmp" &&
          mv "$_prc_f.tmp" "$_prc_f"
        ui_wrote "removed the PATH block from $(ui_tilde "$_prc_f")"
        ;;
    esac
    _prc_removed=1
  done

  [ "$_prc_removed" = 1 ] || ui_detail "no PATH block to remove"
}
