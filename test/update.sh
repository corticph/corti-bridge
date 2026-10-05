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

# A stub claude: on PATH, exits cleanly, prints a marker so a forbidden fall-through is detectable.
printf '#!/bin/sh\necho "STUB-CLAUDE $*"\nexit 0\n' > "$SCRATCH/bin/claude"
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
health_cred() {
    curl -sf --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null |
        sed -n 's/.*"credId":"\([0-9]*\)".*/\1/p'
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

# --- K. credential staleness drives the restart ------------------------------------------
# The credId mirror of section B/C/D: a rotated bearer (corti-cli init --fresh, then a new
# shell) must restart the gateway on the next launch, or it keeps 401-ing upstream with the
# dead key it baked in at boot.
check "unchanged bearer does not restart the gateway" \
    "$(CORTI_NO_UPDATE_CHECK=1 launch_count 'CORTI_BEARER changed')" "0"

CORTI_BEARER="test-rotated"
check "a changed bearer restarts the gateway" \
    "$(CORTI_NO_UPDATE_CHECK=1 launch_count 'CORTI_BEARER changed')" "1"
check "the restarted gateway carries the new credId" \
    "$(health_cred)" "$(printf '%s' "$CORTI_BEARER" | cksum | cut -d' ' -f1)"
check "and does not restart again on the next launch" \
    "$(CORTI_NO_UPDATE_CHECK=1 launch_count 'CORTI_BEARER changed')" "0"

# Realign the gateway with the suite's base state: everything below asserts on other reasons.
CORTI_BEARER=test
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
check "notice carries the full update command" "$(launch_count 'corti-bridge update')" "1"
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

# --- K. the update verb ------------------------------------------------------------------
# The re-deploy path reads the *installed* wrapper, so bake one like setup.sh does.
STATE="$HOME/.corti-bridge"
mkdir -p "$STATE"
[ -f "$STATE/models.env" ] || printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=corti-s1\nCORTI_EXPERIMENTAL=1\n' > "$STATE/models.env"
[ -f "$STATE/profile.env" ] || printf 'CLAUDE_CONFIG_DIR=%s\n' "$STATE/profile" > "$STATE/profile.env"
sed "s|\${CORTI_PROXY_DIR:-/path/to/corti-bridge}|\${CORTI_PROXY_DIR:-$CLONE}|" \
    "$CLONE/bin/corti-bridge" > "$SCRATCH/bin/corti-bridge"
chmod +x "$SCRATCH/bin/corti-bridge"
# rc goes through a file: callers capture output with $( ), which loses vars to the subshell.
K_RC_FILE="$SCRATCH/krc"
update_run_in() {
    : > "$K_RC_FILE"
    _krc=0
    CORTI_PROXY_BIN_DIR="$SCRATCH/bin" "$BRIDGE" "$@" >"$SCRATCH/kout" 2>&1 || _krc=$?
    printf '%s' "$_krc" > "$K_RC_FILE"
    cat "$SCRATCH/kout"
}
up_get_rc() { cat "$K_RC_FILE"; }
up_ct() {
    printf '%s' "$1" | grep -c "$2" || :
}

# K1: docs-only — pull lands, no re-deploy advisory, stamped quiet.
git -C "$CLONE" reset -q --hard origin/main 2>/dev/null || :
git -C "$SCRATCH/up" pull -q origin main 2>/dev/null || :
echo "docs change" >> "$SCRATCH/up/README.md"
git -C "$SCRATCH/up" commit -qam docs
git -C "$SCRATCH/up" push -q origin main
K1=$(update_run_in update)
check "update: docs-only reports complete" "$(up_ct "$K1" 'update complete')" "1"
check "update: docs-only exits 0" "$(up_get_rc)" "0"
check "update: docs-only prints no restart" "$(up_ct "$K1" 'gateway restarted')" "0"
check "update: docs-only leaves wrapper bytes" "$(up_ct "$K1" 'wrapper updated')" "0"
check "update: stamps the checked file" "$([ -f "$STATE/update.checked" ] && echo yes || echo no)" "yes"

# K2: immediately current
K2=$(update_run_in update)
check "update: current reports it" "$(up_ct "$K2" 'already up to date')" "1"
check "update: current exits 0" "$(up_get_rc)" "0"

# K3: dry-run skips the fetch entirely — an unfetched push is invisible to it.
# Capture the base AFTER K1's pull: that is the HEAD a no-op dry-run must preserve.
K3_BASE=$(git -C "$CLONE" rev-parse HEAD)
echo "dry" >> "$SCRATCH/up/GUIDE.md"
git -C "$SCRATCH/up" commit -qam dry
git -C "$SCRATCH/up" push -q origin main
K3=$(update_run_in update --dry-run)
check "update: dry-run exits 0 with nothing written" "$(up_ct "$K3" 'dry run'"'"'; nothing written\|already up to date (as of the last fetch')" "1"
check "update: dry-run does not move HEAD" \
    "$(git -C "$CLONE" rev-parse HEAD)" "$K3_BASE"

# K4: wrapper-only diff → the installed copy is re-deployed.
# The commit propagates the file mode — keep +x.
sed 's/corti-bridge update \[--dry-run\]/corti-bridge update [--dry-run] v2/' "$SCRATCH/up/bin/corti-bridge" > "$SCRATCH/up/bin/w"
chmod +x "$SCRATCH/up/bin/w" && mv "$SCRATCH/up/bin/w" "$SCRATCH/up/bin/corti-bridge"
git -C "$SCRATCH/up" commit -qam "wrapper v2"
git -C "$SCRATCH/up" push -q origin main
K4=$(update_run_in update)
check "update: wrapper-diff reports the re-deploy" "$(up_ct "$K4" 'wrapper updated')" "1"
check "update: deployed wrapper carries the new content" \
    "$(grep -c 'v2' "$SCRATCH/bin/corti-bridge")" "1"
# bin/corti-bridge is not in the fingerprint set: a wrapper-only change must NOT restart.
check "update: wrapper-only change does not restart the gateway" "$(up_ct "$K4" 'older build')" "0"

# K5: gateway-source-only → advice, no explicit restart.
echo "// g" >> "$SCRATCH/up/lib/retry.mjs"
git -C "$SCRATCH/up" commit -qam "gateway v2"
git -C "$SCRATCH/up" push -q origin main
K5=$(update_run_in update)
check "update: gateway-diff advises next-session pickup" "$(up_ct "$K5" 'next session start')" "1"
check "update: gateway-diff restarts nothing itself" "$(up_ct "$K5" 'gateway restarted')" "0"

# K6: divergence refuses with its own message, HEAD unmoved.
git -C "$CLONE" commit -q --allow-empty -m local-divergent
BEHIND_HEAD=$(git -C "$CLONE" rev-parse HEAD)
echo "divergent" >> "$SCRATCH/up/README.md"
git -C "$SCRATCH/up" commit -qam "divergent-docs"
git -C "$SCRATCH/up" push -q origin main
K6=$(update_run_in update)
check "update: divergence names local commits" "$(up_ct "$K6" 'local commits')" "1"
check "update: divergence exits 1 (rc)" "$(up_get_rc)" "1"
check "update: divergence leaves HEAD" "$(git -C "$CLONE" rev-parse HEAD)" "$BEHIND_HEAD"
check "update: divergence leaves the stamp" "$([ -f "$STATE/update.checked" ] && echo still-there || echo gone)" "still-there"
git -C "$CLONE" reset -q --hard "@{u}"

# K7: offline refuses (origin renamed away, URL points nowhere).
git -C "$CLONE" remote set-url origin "$SCRATCH/origin-gone.git"
K7=$(update_run_in update)
check "update: offline refuses with the cannot-reach message" \
    "$(printf '%s' "$K7" | grep -c 'cannot reach origin' || :)" "1"
check "update: offline exits 1 (rc)" "$(up_get_rc)" "1"
git -C "$CLONE" remote set-url origin "$SCRATCH/origin.git"

# K8: the verb is claimed — no longer falls through to claude.
check "update: the verb does not reach claude" "$(printf '%s' "$(CORTI_NO_UPDATE_CHECK=1 sh "$BRIDGE" update 2>&1 || :)" | grep -c 'STUB-CLAUDE\|stub-claude' || :)" "0"

# K9: other branch refused (spec case v).
git -C "$CLONE" checkout -q -b update-feature
K9=$(update_run_in update)
check "update: feature branch refused in the verb" "$(up_ct "$K9" 'update only runs on main')" "1"
check "update: feature branch exits 1 (rc)" "$(up_get_rc)" "1"
git -C "$CLONE" checkout -q main

# K10: the deployed/not-deployed discriminator — stub setup.sh to print one of the two
# line shapes; a wrapper-only diff each time drives the install class.
K10_SETUP="$CLONE/setup.sh"
cp "$K10_SETUP" "$K10_SETUP.real"
wrapper_diff_and_push() {
    printf '// t-%s\n' "$1" >> "$SCRATCH/up/bin/corti-bridge"
    git -C "$SCRATCH/up" commit -qam "$1"
    git -C "$SCRATCH/up" push -q origin main
}
# (x) setup exit-1 WITH deployed wrapper: only the success signal, rc 1.
printf '#!/bin/sh\nprintf "    -> updated %%s\\n" "$0"\nexit 1\n' > "$K10_SETUP"
chmod +x "$K10_SETUP"
wrapper_diff_and_push t10
K10_A=$(update_run_in update)
check "update: deployed signal from a setup rc=1 → success" "$(up_ct "$K10_A" 'wrapper updated')" "1"
check "update: deployed-despite-exit-1 stamps and completes" "$(up_ct "$K10_A" 'update complete')" "1"
# (xi) fatal shape: "Nothing was installed." must NOT read as deployed.
printf '#!/bin/sh\nprintf "Nothing was installed.\\n"\nexit 1\n' > "$K10_SETUP"
chmod +x "$K10_SETUP"
wrapper_diff_and_push t10b
K10_B=$(update_run_in update)
check "update: fatal output reads not-deployed" "$(up_ct "$K10_B" 'could not be re-deployed')" "1"
check "update: fatal output does not complete" "$(up_ct "$K10_B" 'update complete')" "0"
check "update: fatal output exits 1 (rc)" "$(up_get_rc)" "1"
# (xii) foreign baked path → refuse rather than re-point.
printf '#!/bin/sh\nPROXY_DIR="${CORTI_PROXY_DIR:-/somewhere/else}"\n' > "$SCRATCH/bin/corti-bridge"
chmod +x "$SCRATCH/bin/corti-bridge"
K10_C=$(update_run_in update)
wrapper_diff_and_push t10c
K10_C=$(update_run_in update)
check "update: foreign baked wrapper refused" "$(up_ct "$K10_C" 'points at /somewhere/else')" "1"
check "update: foreign baked wrapper exits 1 (rc)" "$(up_get_rc)" "1"
mv "$K10_SETUP.real" "$K10_SETUP"
# restore the sandbox install target so the default state holds for later sections
sed "s|\${CORTI_PROXY_DIR:-/path/to/coti-bridge}|\${CORTI_PROXY_DIR:-$CLONE}|" "$CLONE/bin/corti-bridge" > "$SCRATCH/bin/corti-bridge" 2>/dev/null || true
sed "s|\${CORTI_PROXY_DIR:-/path/to/corti-bridge}|\${CORTI_PROXY_DIR:-$CLONE}|" \
    "$CLONE/bin/corti-bridge" > "$SCRATCH/bin/corti-bridge"
chmod +x "$SCRATCH/bin/corti-bridge"

# K11: exactly-one-changed-file under the state dir on the healthy path (the triple
# short-circuit must mean ONLY the stamp moves; models.env/profile.env bytes untouched).
MODELS_BEFORE=$(cksum "$STATE/models.env" | cut -d' ' -f1)
PROFILE_BEFORE=$(cksum "$STATE/profile.env" | cut -d' ' -f1)
git -C "$CLONE" pull -q origin main 2>/dev/null || :
update_run_in update > /dev/null
check "update: healthy run leaves models.env bytes" "$(cksum "$STATE/models.env" | cut -d' ' -f1)" "$MODELS_BEFORE"
check "update: healthy run leaves profile.env bytes" "$(cksum "$STATE/profile.env" | cut -d' ' -f1)" "$PROFILE_BEFORE"

# --- doctor ------------------------------------------------------------------------------
# K pulled the clone current; the doctor-behind check below needs an unfetched upstream commit.
echo "// after-k" >> "$SCRATCH/up/gateway.mjs"
git -C "$SCRATCH/up" commit -qam up4
git -C "$SCRATCH/up" push -q origin main
# Same reason the E-H section fetches directly: the launch-path fetch is throttled and
# backgrounded; doctor's count reads local refs.
git -C "$CLONE" fetch -q origin main
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
