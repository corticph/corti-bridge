#!/bin/sh
# Update detection: the build fingerprint that makes a pulled gateway actually take effect, and
# the commits-behind notice that tells the user to pull in the first place. Zero dependencies.
#
# Fully sandboxed: a bare "origin" repo, a clone of it, a scratch HOME, a stub `claude`, and a
# port of its own. Kills are by recorded pid only — never a pattern kill, which would match a
# real gateway running from the developer's own clone.
#
# Run: sh test/update.sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=$(mktemp -d)
FAILED=0
PORT=4990
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

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

# --- sandbox ------------------------------------------------------------------------
mkdir -p "$SCRATCH/home" "$SCRATCH/bin" "$SCRATCH/up"
tar -cf - --exclude=.git --exclude=.context -C "$REPO" . | tar -xf - -C "$SCRATCH/up"
git -C "$SCRATCH/up" init -q -b main
git -C "$SCRATCH/up" add -A
git -C "$SCRATCH/up" commit -qm base
git init -q --bare "$SCRATCH/origin.git"
git -C "$SCRATCH/up" remote add origin "$SCRATCH/origin.git"
git -C "$SCRATCH/up" push -q origin main
git clone -q "$SCRATCH/origin.git" "$SCRATCH/clone"

# A stub claude: the wrapper only needs it to exist on PATH and to exit cleanly.
printf '#!/bin/sh\nexit 0\n' > "$SCRATCH/bin/claude"
chmod +x "$SCRATCH/bin/claude"

CLONE="$SCRATCH/clone"
BRIDGE="$CLONE/bin/corti-bridge"
export HOME="$SCRATCH/home"
export PATH="$SCRATCH/bin:$PATH"
export CORTI_PROXY_DIR="$CLONE"
export CORTI_PORT="$PORT"
export CORTI_BEARER=test
# Shaped like a real Corti URL so the wrapper and gateway both accept it. Nothing is ever sent
# there: only /health is exercised, which the gateway answers locally.
export CORTI_BASE_URL="https://ai.test.corti.app/v1"

# The fingerprint the wrapper computes, replicated here so a drift in either is caught.
fingerprint() {
    cat "$CLONE/gateway.mjs" "$CLONE/translate.mjs" "$CLONE"/lib/*.mjs "$CLONE"/lib/*.txt 2>/dev/null |
        cksum | cut -d' ' -f1
}
health_build() {
    curl -sf --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null |
        sed -n 's/.*"buildId":"\([0-9]*\)".*/\1/p'
}
# Count of a pattern in a launch's combined output.
launch_count() {
    _pat="$1"
    shift
    sh "$BRIDGE" "$@" 2>&1 | grep -c "$_pat" || :
}

# --- A. the fingerprint ---------------------------------------------------------------
FP1=$(fingerprint)
check "fingerprint: stable across reads" "$(fingerprint)" "$FP1"
echo "// drift" >> "$CLONE/lib/retry.mjs"
check "fingerprint: changes when an imported lib module changes" \
    "$([ "$(fingerprint)" != "$FP1" ] && echo changed || echo same)" "changed"
git -C "$CLONE" checkout -q -- lib/retry.mjs
echo "// drift" >> "$CLONE/lib/advisor-prompt.txt"
check "fingerprint: changes when a runtime-read prompt file changes" \
    "$([ "$(fingerprint)" != "$FP1" ] && echo changed || echo same)" "changed"
git -C "$CLONE" checkout -q -- lib/advisor-prompt.txt
check "fingerprint: restored after revert" "$(fingerprint)" "$FP1"

# --- B/C/D. build staleness drives the restart -----------------------------------------
CORTI_NO_UPDATE_CHECK=1 sh "$BRIDGE" >/dev/null 2>&1
check "gateway boots carrying the clone's fingerprint" "$(health_build)" "$(fingerprint)"
check "unchanged source does not restart the gateway" \
    "$(CORTI_NO_UPDATE_CHECK=1 launch_count 'older build')" "0"

echo "// pulled change" >> "$CLONE/translate.mjs"
check "a changed source file restarts the gateway" \
    "$(CORTI_NO_UPDATE_CHECK=1 launch_count 'older build')" "1"
check "the restarted gateway carries the new fingerprint" "$(health_build)" "$(fingerprint)"
check "and does not restart again on the next launch" \
    "$(CORTI_NO_UPDATE_CHECK=1 launch_count 'older build')" "0"
git -C "$CLONE" checkout -q -- translate.mjs
CORTI_NO_UPDATE_CHECK=1 sh "$BRIDGE" >/dev/null 2>&1

# --- E-H. the notice and its guards -----------------------------------------------------
echo "// up1" >> "$SCRATCH/up/translate.mjs"
git -C "$SCRATCH/up" commit -qam up1
echo "// up2" >> "$SCRATCH/up/gateway.mjs"
git -C "$SCRATCH/up" commit -qam up2
git -C "$SCRATCH/up" push -q origin main
# The launch-path fetch is backgrounded and throttled; fetch directly so the assertions below
# test the notice rather than the scheduler.
git -C "$CLONE" fetch -q origin main

check "notice names the number of new commits" "$(launch_count '2 new commits on main')" "1"
check "notice carries the full update command" "$(launch_count 'git pull && ./setup.sh')" "1"
check "print mode gets no notice" "$(launch_count 'new commits' -p hi)" "0"
check "CORTI_NO_UPDATE_CHECK silences the notice" \
    "$(CORTI_NO_UPDATE_CHECK=1 launch_count 'new commits')" "0"
check "an advisor child (CORTI_NO_MANAGE_GATEWAY) gets no notice" \
    "$(CORTI_NO_MANAGE_GATEWAY=1 launch_count 'new commits')" "0"

# --- I. pulling clears it immediately ---------------------------------------------------
git -C "$CLONE" pull -q origin main
# One launch, two assertions: the restart is consumed by whichever launch runs first, so asking
# twice would report the second (already-restarted) launch.
PULLED=$(sh "$BRIDGE" 2>&1 || :)
check "the notice stops the moment the clone is pulled" \
    "$(printf '%s' "$PULLED" | grep -c 'new commits' || :)" "0"
check "and the pulled build restarts the gateway" \
    "$(printf '%s' "$PULLED" | grep -c 'older build' || :)" "1"

# --- J. a working branch is not nagged --------------------------------------------------
git -C "$SCRATCH/up" pull -q --rebase origin main 2>/dev/null || :
echo "// up3" >> "$SCRATCH/up/gateway.mjs"
git -C "$SCRATCH/up" commit -qam up3
git -C "$SCRATCH/up" push -q origin main
git -C "$CLONE" fetch -q origin main
git -C "$CLONE" checkout -q -b wip
check "a clone on a feature branch is not nagged" "$(launch_count 'new commit')" "0"
git -C "$CLONE" checkout -q main

# --- doctor ------------------------------------------------------------------------------
# No 2>/dev/null: doctor is a stdout report, so anything on stderr is a defect.
check "doctor reports the clone is behind" \
    "$(sh "$BRIDGE" doctor | grep -c 'commit(s) behind origin/main')" "1"
git -C "$CLONE" pull -q origin main
check "doctor reports up to date after a pull" \
    "$(sh "$BRIDGE" doctor | grep -c 'up to date with the last fetch')" "1"

# An abort mid-report still prints every earlier row and can still exit 1, so only the tail
# proves the run finished. Both _d_check_update branch paths have their own early return.
check "doctor completes its report when up to date" \
    "$(sh "$BRIDGE" doctor | grep -c '^Summary:')" "1"
check "doctor writes nothing to stderr" \
    "$(sh "$BRIDGE" doctor 2>&1 >/dev/null | wc -l | tr -d ' ')" "0"
git -C "$CLONE" checkout -q wip
check "doctor completes its report on a feature branch" \
    "$(sh "$BRIDGE" doctor | grep -c '^Summary:')" "1"
git -C "$CLONE" checkout -q main

if [ "$FAILED" -gt 0 ]; then
    printf '\n%s check(s) failed\n' "$FAILED"
    exit 1
fi
printf '\nall checks passed\n'
