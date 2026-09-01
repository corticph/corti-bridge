#!/bin/sh
# Sandboxed install test. Zero dependencies — no bats, no shunit2.
#
# Every path setup.sh writes to is derived from $HOME, $CC_PROXY_BIN_DIR or
# $CC_PROXY_CONFIG_DIR, so redirecting those three into a scratch directory contains the whole
# thing. Nothing here touches the real home directory.
#
# Credentials stay unset so this stays hermetic and the model step exercises its skip path.
#
# Run: sh test/smoke.sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
FAILED=0

cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

pass() { printf 'ok   %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  FAILED=$((FAILED + 1))
}

check() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1 (expected '$3', got '$2')"
  fi
}

# grep -c prints 0 *and* exits 1 when there are no matches, and prints nothing at all when the
# file is missing, so neither the exit status nor the output alone is enough.
count_markers() {
  _n=$(grep -c 'corti-claude: added by setup.sh' "$1" 2>/dev/null) || :
  [ -n "$_n" ] || _n=0
  printf '%s' "$_n"
}

# $1 shell name, $2 shell path, $3 rc file relative to the sandbox home
run_shell_case() {
  _name="$1"
  _shell="$2"
  _rc="$3"

  if [ ! -x "$_shell" ]; then
    printf 'skip %s (%s not installed)\n' "$_name" "$_shell"
    return 0
  fi

  _box="$SCRATCH/$_name"
  mkdir -p "$_box/home"

  # Creds set (shape-valid; the model step will fail on a dummy token, which is State B, not an
  # early-stop) so the wrapper installs and the rc block is written — giving the two-run
  # idempotency check something to be idempotent about. A naive impl checks $PATH instead of the
  # rc file and appends its block a second time.
  for _i in 1 2; do
    (
      HOME="$_box/home"
      CC_PROXY_BIN_DIR="$_box/bin"
      CC_PROXY_CONFIG_DIR="$_box/state"
      SHELL="$_shell"
      CORTI_BEARER=dummy CORTI_BASE_URL=https://ai.eu.corti.app/v1
      export HOME CC_PROXY_BIN_DIR CC_PROXY_CONFIG_DIR SHELL CORTI_BEARER CORTI_BASE_URL
      cd "$REPO" && sh ./setup.sh --yes
    ) >/dev/null 2>&1 || true
  done

  if [ -x "$_box/bin/corti-claude" ]; then
    pass "$_name: wrapper installed and executable"
  else
    fail "$_name: wrapper missing or not executable"
  fi

  _markers=$(count_markers "$_box/home/$_rc")
  check "$_name: rc marker appears exactly once after two runs" "$_markers" "1"

  # The wrapper must point at this clone, not at the hardcoded in-repo default.
  if grep -q "CC_PROXY_DIR:-$REPO" "$_box/bin/corti-claude" 2>/dev/null; then
    pass "$_name: wrapper PROXY_DIR points at this clone"
  else
    fail "$_name: wrapper PROXY_DIR was not substituted"
  fi

  # Uninstall must leave the rc file clean and the state directory alone.
  (
    HOME="$_box/home"
    CC_PROXY_BIN_DIR="$_box/bin"
    CC_PROXY_CONFIG_DIR="$_box/state"
    SHELL="$_shell"
    export HOME CC_PROXY_BIN_DIR CC_PROXY_CONFIG_DIR SHELL
    cd "$REPO" && sh ./setup.sh --uninstall
  ) >/dev/null 2>&1 || true

  _left=$(count_markers "$_box/home/$_rc")
  check "$_name: uninstall removes the rc block" "$_left" "0"

  if [ -f "$_box/state/profile.env" ]; then
    pass "$_name: uninstall leaves the state directory alone"
  else
    fail "$_name: uninstall deleted state it should have kept"
  fi
}

printf '# sandbox: %s\n\n' "$SCRATCH"

run_shell_case zsh /bin/zsh .zshrc
run_shell_case bash /bin/bash .bash_profile
run_shell_case fish "$(command -v fish 2>/dev/null || echo /nonexistent)" \
  .config/fish/conf.d/corti-claude.fish

# A no-creds FIRST run (no wrapper present) must stop early: exit 1, install nothing, edit no
# rc file. This is the redesign's headline change — `./setup.sh && corti-claude` becomes safe.
box="$SCRATCH/noninteractive"
mkdir -p "$box/home"
set +e
(
  HOME="$box/home"
  CC_PROXY_BIN_DIR="$box/bin"
  CC_PROXY_CONFIG_DIR="$box/state"
  SHELL=/bin/zsh
  export HOME CC_PROXY_BIN_DIR CC_PROXY_CONFIG_DIR SHELL
  unset CORTI_BEARER CORTI_BASE_URL
  cd "$REPO" && sh ./setup.sh </dev/null
) >/dev/null 2>&1
_ni_rc=$?
set -e

check "noninteractive: no-creds first run exits 1" "$_ni_rc" "1"

if [ -x "$box/bin/corti-claude" ]; then
  fail "noninteractive: wrapper installed despite no-creds early-stop"
else
  pass "noninteractive: nothing installed on no-creds first run"
fi

nmark=$(count_markers "$box/home/.zshrc")
check "noninteractive: no rc file edited without consent" "$nmark" "0"

# A no-creds RE-run (wrapper already present) must NOT hard-stop: it warns and continues so the
# model step skips idempotently. Missing creds on an existing install is a runtime concern.
rebox="$SCRATCH/rerun"
mkdir -p "$rebox/home"
# First, install the wrapper with creds so the re-run sees it.
(
  HOME="$rebox/home"
  CC_PROXY_BIN_DIR="$rebox/bin"
  CC_PROXY_CONFIG_DIR="$rebox/state"
  SHELL=/bin/zsh
  CORTI_BEARER=dummy CORTI_BASE_URL=https://ai.eu.corti.app/v1
  export HOME CC_PROXY_BIN_DIR CC_PROXY_CONFIG_DIR SHELL CORTI_BEARER CORTI_BASE_URL
  cd "$REPO" && sh ./setup.sh --yes
) >/dev/null 2>&1 || true
# Then re-run WITHOUT creds. It must NOT early-stop (missing creds on an existing install is a
# runtime concern, not an install blocker): it proceeds past the creds step and lands in State B
# (exit 1) only because the model step skips — not because it hard-stopped at creds. The wrapper
# survives either way.
set +e
(
  HOME="$rebox/home"
  CC_PROXY_BIN_DIR="$rebox/bin"
  CC_PROXY_CONFIG_DIR="$rebox/state"
  SHELL=/bin/zsh
  export HOME CC_PROXY_BIN_DIR CC_PROXY_CONFIG_DIR SHELL
  unset CORTI_BEARER CORTI_BASE_URL
  cd "$REPO" && sh ./setup.sh --yes
) >/dev/null 2>&1
_re_rc=$?
set -e

# The distinguishing signal is the early-stop message, not the exit code: State B (model step
# skipped) also exits 1. A re-run that early-stopped would print "Nothing was installed" and
# leave no wrapper; one that continued reaches the verdict with the wrapper intact.
if [ -x "$rebox/bin/corti-claude" ]; then
  pass "rerun: wrapper survives a no-creds re-run (no early-stop)"
else
  fail "rerun: no-creds re-run early-stopped (wrapper gone)"
fi

# An uninstalled wrapper still holds the placeholder PROXY_DIR; it must say so, not poll for 20s.
# --restart reaches gateway_start without needing claude on PATH, which keeps this hermetic.
guard_out=$(CORTI_PORT=45917 CC_PROXY_DIR="$SCRATCH/nowhere" CORTI_BEARER=dummy \
  CORTI_BASE_URL=https://ai.eu.corti.app/v1 sh "$REPO/bin/corti-claude" --restart 2>&1 || true)
case "$guard_out" in
  *"no gateway.mjs at"*) pass "wrapper: missing gateway.mjs fails fast" ;;
  *) fail "wrapper: missing gateway.mjs (got '$guard_out')" ;;
esac

. "$REPO/lib/ui.sh"
. "$REPO/lib/models.sh"
. "$REPO/lib/profile.sh"

# Relative profile paths must resolve to empty so the caller warns and falls back.
check "profile: absolute path passes through" "$(profile_resolve_dir /srv/claude)" "/srv/claude"
check "profile: bare ~ becomes \$HOME" "$(profile_resolve_dir '~')" "$HOME"
check "profile: ~/ prefix expands" "$(profile_resolve_dir '~/profile-test')" "$HOME/profile-test"
check "profile: inner ~ is left alone" "$(profile_resolve_dir '/opt/~/x')" "/opt/~/x"
check "profile: relative path refused" "$(profile_resolve_dir some/rel)" ""
check "profile: empty input refused" "$(profile_resolve_dir '')" ""

FABLE_ENV='ANTHROPIC_DEFAULT_FABLE_MODEL="alias-of-opus"
ANTHROPIC_DEFAULT_FABLE_MODEL_NAME="alias-of-opus"
ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES="thinking"
ANTHROPIC_DEFAULT_OPUS_MODEL="the-opus-one"'

# grep -c exits 1 on zero matches, which set -e would take as a failed test run.
count_fable() {
  _n=$(printf '%s\n' "$1" | grep -c '^ANTHROPIC_DEFAULT_FABLE_MODEL') || :
  [ -n "$_n" ] || _n=0
  printf '%s' "$_n"
}

models_fingerprint() { printf 'one-and-the-same'; }
check "fable: dropped when it shares opus's pod" \
  "$(count_fable "$(models_dedupe_fable "$FABLE_ENV" 2>/dev/null)")" "0"

models_fingerprint() { printf 'fp-for-%s' "$1"; }
check "fable: kept when the pods differ" \
  "$(count_fable "$(models_dedupe_fable "$FABLE_ENV" 2>/dev/null)")" "3"

# An empty fingerprint (a cold-starting model) must not read as "different pod".
models_fingerprint() { :; }
check "fable: kept when the probe cannot answer" \
  "$(count_fable "$(models_dedupe_fable "$FABLE_ENV" 2>/dev/null)")" "3"

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf 'all checks passed\n'
  exit 0
fi
printf '%d check(s) failed\n' "$FAILED"
exit 1
