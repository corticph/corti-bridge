# shellcheck shell=sh
# Output primitives for setup.sh. Sourced first; defines functions and colour variables only.
#
# Everything prints to stderr so `./setup.sh 2>/dev/null` leaves a clean exit-code-only signal
# and nothing competes with stdout, which functions use to return values.
#
# ASCII markers: `==>` steps, `!` warn, `x` fatal, `-` skipped, `->` wrote.

# `\033` is the POSIX printf octal escape; `\e` is a bash/zsh extension dash does not honour.
if [ -n "${NO_COLOR:-}" ]; then
  _ui_color=0
elif [ -n "${FORCE_COLOR:-}" ]; then
  _ui_color=1
elif [ -t 2 ] && [ "${TERM:-dumb}" != "dumb" ]; then
  _ui_color=1
else
  _ui_color=0
fi

if [ "$_ui_color" = 1 ]; then
  _ui_blue=$(printf '\033[34m')
  _ui_bold=$(printf '\033[1m')
  _ui_red=$(printf '\033[31m')
  _ui_yellow=$(printf '\033[33m')
  _ui_reset=$(printf '\033[0m')
else
  _ui_blue=''
  _ui_bold=''
  _ui_red=''
  _ui_yellow=''
  _ui_reset=''
fi

ui_step() { printf '\n%s==>%s %s%s%s\n' "$_ui_blue" "$_ui_reset" "$_ui_bold" "$1" "$_ui_reset" >&2; }
ui_detail() { printf '    %s\n' "$1" >&2; }
ui_pair() { printf '    %-16s %s\n' "$1" "$2" >&2; }
ui_warn() { printf '    %s!%s %s\n' "$_ui_yellow" "$_ui_reset" "$1" >&2; }
ui_skip() { printf '    - skipped (%s)\n' "$1" >&2; }
ui_wrote() { printf '    -> %s\n' "$1" >&2; }
ui_error() { printf '    %sx%s %s\n' "$_ui_red" "$_ui_reset" "$1" >&2; }
ui_blank() { printf '\n' >&2; }

# Fatal: message, then the remediation block, then stop.
ui_fatal() {
  ui_error "$1"
  shift
  ui_blank
  for _ui_line in "$@"; do
    printf '%s\n' "$_ui_line" >&2
  done
  ui_blank
  printf 'Nothing was installed.\n' >&2
  exit 1
}

# A non-fatal multi-line block (ui_detail looped): indented prose under a step.
ui_explain() {
  for _ui_line in "$@"; do
    printf '    %s\n' "$_ui_line" >&2
  done
  unset _ui_line
}

# Prompt on stderr, answer on stdout.
#   $1 prompt  $2 default for empty input or --yes  $3 answer when there is no terminal
# A bare `read` would abort the whole script under `set -e` when stdin is closed, so the
# unreadable case is handled explicitly rather than left to fail.
ui_ask() {
  if [ "${CC_ASSUME_YES:-0}" = 1 ]; then
    printf '%s' "$2"
    return 0
  fi
  if [ -t 0 ]; then
    _ui_tty=/dev/stdin
  else
    _ui_tty=/dev/tty
  fi
  if [ ! -r "$_ui_tty" ]; then
    printf '%s' "$3"
    return 0
  fi
  printf '    %s ' "$1" >&2
  # A failed read is EOF; return $3, never fall through to the interactive default $2.
  if ! read -r _ui_reply <"$_ui_tty"; then
    printf '%s' "$3"
    return 0
  fi
  [ -n "$_ui_reply" ] || _ui_reply="$2"
  printf '%s' "$_ui_reply"
}

ui_is_yes() {
  case "$1" in
    y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Absolute paths under $HOME shown as ~/… to keep aligned columns from wrapping.
ui_tilde() {
  case "$1" in
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
