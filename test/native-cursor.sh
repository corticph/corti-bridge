#!/bin/sh
# The native-cursor export: the gateway doesn't serve /bootstrap, so the
# tengu_native_cursor feature flag never reaches the TUI and it falls back to a
# software-drawn cursor. The wrapper exports CLAUDE_CODE_NATIVE_CURSOR=1 so the
# TUI uses the terminal's native (blinking, terminal-colored) cursor instead.
#
# This is a launch-path concern: subcommands (doctor/models/theme/restart) exit
# before the export, so the test must drive the default launch path that execs
# `claude`. A stub `claude` on a sandboxed PATH captures the exported env the
# wrapper hands the child, instead of exec'ing the real binary.
#
# Fully sandboxed (same shape as test/update.sh): a clone, a scratch HOME, a
# stub `claude`, and a port of its own. Kills by recorded pid only.
#
# Run: sh test/native-cursor.sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
FAILED=0
PORT=4985
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

cleanup() {
    if [ -f "$SCRATCH/home/.corti-bridge/gateway-$PORT.pid" ]; then
        _pid=$(cat "$SCRATCH/home/.corti-bridge/gateway-$PORT.pid" 2>/dev/null || true)
        [ -n "${_pid:-}" ] && kill "$_pid" 2>/dev/null || :
    fi
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s (expected %s, got %s)\n' "$1" "$3" "$2"
        FAILED=$((FAILED + 1))
    fi
}

# grep -c prints 0 *and* exits 1 when there are no matches, and prints nothing when the file is
# missing, so neither the exit status nor the output alone is enough (test/smoke.sh's idiom).
count_in() {
    _n=$(grep -c "$1" "$2" 2>/dev/null) || :
    [ -n "$_n" ] || _n=0
    printf '%s' "$_n"
}

fail() {
    printf 'FAIL %s\n' "$1"
    [ -n "${2:-}" ] && printf '       %s\n' "$2"
    FAILED=$((FAILED + 1))
}

# --- sandbox -----------------------------------------------------------------------
# A clone (not the live repo) so the gateway's source-fingerprint check has a .git to
# root on and nothing here touches the developer's real install.
mkdir -p "$SCRATCH/home" "$SCRATCH/bin" "$SCRATCH/up"
tar -cf - --exclude=.git --exclude=.context -C "$REPO" . | tar -xf - -C "$SCRATCH/up"
git -C "$SCRATCH/up" init -q -b main
git -C "$SCRATCH/up" add -A
git -C "$SCRATCH/up" commit -qm base >/dev/null
git init -q --bare "$SCRATCH/origin.git"
git -C "$SCRATCH/up" remote add origin "$SCRATCH/origin.git"
git -C "$SCRATCH/up" push -q origin main
git clone -q "$SCRATCH/origin.git" "$SCRATCH/clone"

# A stub claude that records the environment it was launched with, then exits 0. The
# wrapper execs `claude` from PATH at the end of the launch path, so this is what the
# real binary would see. env -i is not used: the wrapper exports its additions onto
# the inherited environment, which is what the real `claude` inherits too.
cat > "$SCRATCH/bin/claude" <<'STUB'
#!/bin/sh
# Only the env that survived into the exec'd child matters here; print it sorted so a
# grep -c on a captured line is stable.
env | LC_ALL=C sort > "${CAPTURE_ENV:-/dev/null}"
exit 0
STUB
chmod +x "$SCRATCH/bin/claude"

CLONE="$SCRATCH/clone"
BRIDGE="$CLONE/bin/corti-bridge"
export HOME="$SCRATCH/home"
export PATH="$SCRATCH/bin:$PATH"
export CORTI_PROXY_DIR="$CLONE"
export CORTI_PORT="$PORT"
export CORTI_BEARER=test
# Shaped like a real Corti URL so the wrapper and gateway both accept it. Nothing is
# sent there: only /health is exercised, which the gateway answers locally.
export CORTI_BASE_URL="https://ai.test.corti.app/v1"
# Silence the commits-behind notice so it doesn't race the exec'd child's output.
export CORTI_NO_UPDATE_CHECK=1

CAPTURE="$SCRATCH/claude-env.txt"

# --- the export reaches the launched child -----------------------------------------
# Drive the default launch path (no subcommand): the wrapper starts the gateway, exports
# its CLAUDE_CODE_* env, and execs the stub claude, which captures them. The exec path is
# the only one that sets the export; doctor/models/theme/restart all exit earlier.
CAPTURE_ENV="$CAPTURE" sh "$BRIDGE" >/dev/null 2>&1 || true

if [ ! -s "$CAPTURE" ]; then
    fail "launch: stub claude was not exec'd (no env captured)"
    # Fall through to the checks below, which will all FAIL with a clear diff.
fi

# The whole point: the export must land in the child's environment.
check "launch: CLAUDE_CODE_NATIVE_CURSOR=1 is exported to claude" \
    "$(count_in '^CLAUDE_CODE_NATIVE_CURSOR=1$' "$CAPTURE")" "1"

# The sibling CLAUDE_CODE_* exports the wrapper already owned must still arrive too, so
# the new line didn't displace the block. Sample one stable neighbor.
check "launch: a sibling CLAUDE_CODE_DISABLE_ARTIFACT=1 still exports" \
    "$(count_in '^CLAUDE_CODE_DISABLE_ARTIFACT=1$' "$CAPTURE")" "1"

# A user can still override it: CLAUDE_CODE_NATIVE_CURSOR=0 in the parent environment must
# survive the wrapper's export, not be silently clobbered to 1. This guards against a future
# edit that switches to an unconditional `export CLAUDE_CODE_NATIVE_CURSOR=1`, which would
# ignore the user's value. Set explicitly here to 0 and re-launch through the same path.
CAPTURE2="$SCRATCH/claude-env2.txt"
CAPTURE_ENV="$CAPTURE2" CLAUDE_CODE_NATIVE_CURSOR=0 sh "$BRIDGE" >/dev/null 2>&1 || true
check "launch: an explicit CLAUDE_CODE_NATIVE_CURSOR=0 is respected, not clobbered" \
    "$(count_in '^CLAUDE_CODE_NATIVE_CURSOR=0$' "$CAPTURE2")" "1"

# --- subcommands do NOT set it -----------------------------------------------------
# doctor/models/theme/restart exit before the export block. The export is a launch-path
# concern (it only matters for the exec'd `claude`), so leaking it into a subcommand's
# environment would be harmless but also wrong-shaped: those are sh scripts, not the TUI.
# Doctor runs without creds or a gateway, so it's the cheapest subcommand to exercise.
DOCTOR_OUT="$SCRATCH/doctor.txt"
sh "$BRIDGE" doctor >"$DOCTOR_OUT" 2>&1 || true
# The wrapper sources lib files for doctor, not the launch env; assert the export never
# became a global the subcommand inherits. (It can't: it's an `export` in the launch path
# the subcommand never reaches. This guards a future refactor that lifts it above the
# subcommand dispatch.) Doctor's own output is the only thing that could carry the name.
check "doctor: the export is not present on a subcommand path" \
    "$(count_in 'CLAUDE_CODE_NATIVE_CURSOR' "$DOCTOR_OUT")" "0"

printf '\n'
if [ "$FAILED" -eq 0 ]; then
    printf 'all checks passed\n'
    exit 0
fi
printf '%d check(s) failed\n' "$FAILED"
exit 1
