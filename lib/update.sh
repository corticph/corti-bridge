# update verb for the corti-bridge wrapper: pull from the clone's own origin, re-deploy the
# installed wrapper when (and only when) bin/corti-bridge changed, and print what takes effect
# when. Replaces the manual `cd "$PROXY_DIR" && git pull && ./setup.sh` recipe the post-session
# notice prints. Sourced by the dispatcher after the lifecycle functions (below them in the
# wrapper), so it uses the wrapper's globals directly: PROXY_DIR, CORTI_DIR, UPDATE_STAMP_FILE.
#
# Fail-closed in every gate won't act on anything it is not sure about: a failed behind-count is
# never reported as "already up to date" (update_behind returns 1 for both a clean zero and a
# failed rev-list, so the verb needs its own count), a failed pull leaves HEAD unmoved, and the
# re-deploy is refused rather than guessed when state is missing or foreign. The gateway is never
# restarted here — the build fingerprint restarts it on the next launch; an eager stop/start
# would kill an in-flight advisor consult.

# Epoch stamp in the exact format update_refresh writes and compares (decimal seconds via
# date +%s). A non-integer stamp would degrade silently to one extra background fetch.
_update_stamp() {
    printf '%s' "$(date +%s 2>/dev/null || echo 0)" > "$UPDATE_STAMP_FILE" 2>/dev/null || true
}

# Classification of OLD..NEWTREE into the action sets. Echoes (space-separated): install gateway.
# New path per entry: the deploy decision is about the working tree the setup re-run deploys
# from, so renames list their new path and deletions list a path that will not matter (the set
# match simply won't fire for a vanished file).
update_classify() {
    _uc_old="$1"
    _uc_new="$2"
    _uc_install=0
    _uc_gateway=0
    while IFS= read -r _uc_path; do
        [ -n "$_uc_path" ] || continue
        case "$_uc_path" in
            bin/corti-bridge) _uc_install=1 ;;
            gateway.mjs|translate.mjs|lib/*.mjs|lib/*.txt) _uc_gateway=1 ;;
        esac
    done <<EOF
$(git -C "$PROXY_DIR" diff --name-only "$_uc_old" "$_uc_new" 2>/dev/null || true)
EOF
    rm -f "$_uc_old" "$_uc_new" 2>/dev/null || true
    if [ "$_uc_install" = 1 ] && [ "$_uc_gateway" = 1 ]; then
        printf 'install gateway'
    elif [ "$_uc_install" = 1 ]; then
        printf 'install'
    elif [ "$_uc_gateway" = 1 ]; then
        printf 'gateway'
    fi
}

# Run setup.sh unattended to re-deploy the wrapper. Preconditions first: update is not an
# installer — under --yes a missing models.env/profile.env would be silently created, and a
# wrapper baked for a different clone must not be re-pointed by this run.
update_redeploy() {
    if [ ! -f "$CORTI_DIR/models.env" ] || [ ! -f "$CORTI_DIR/profile.env" ]; then
        echo "corti-bridge: $CORTI_DIR/models.env or profile.env is missing — run ./setup.sh in $PROXY_DIR first" >&2
        return 1
    fi
    # Single-quoted on purpose: the sed program must see the literal \1 backreference and the
    # ${...} text — shellcheck's "use double quotes" would break the extraction.
    _ur_baked="$(sed -n 's/^PROXY_DIR="\${CORTI_PROXY_DIR:-\([^}]*\)}".*/\1/p' "$_update_bin_dir/corti-bridge" 2>/dev/null | head -1)"
    if [ "$_ur_baked" != "$PROXY_DIR" ]; then
        echo "corti-bridge: the installed wrapper points at ${_ur_baked:-nowhere}, not $PROXY_DIR — run ./setup.sh manually from the right clone" >&2
        return 1
    fi
    # || _ur_rc=$? keeps the benign post-deploy exit-1 (pathrc rc=2) reachable under the
    # wrapper's set -eu: a bare failing simple command would exit the whole wrapper before
    # the deployed/not-deployed discriminator below could run.
    _ur_rc=0
    CORTI_PROXY_CONFIG_DIR="$CORTI_DIR" CORTI_PROXY_BIN_DIR="$_update_bin_dir" \
        "$PROXY_DIR/setup.sh" --yes --no-modify-path >"$_update_setup_out" 2>&1 || _ur_rc=$?
    cat "$_update_setup_out" >&2
    # Deployed-vs-not from setup's own signal lines, not its exit code: the only reachable
    # post-deploy exit-1 is benign (pathrc rc=2, unknown shell — _ur_rc=2), while setup's
    # fatals leave the previous wrapper in place (_ur_rc on a thrown ui_fatal is 1). The
    # installed copy is a sed-rewritten one, so the clone's file can never be cmp'd to it raw.
    if printf '%s' "$(cat "$_update_setup_out" 2>/dev/null || true)" | grep -q "is up to date\|installed\|updated "; then
        printf 'deployed'
    else
        printf 'not-deployed'
    fi
    return "$_ur_rc"
}

# Main. $@: --dry-run. Exit codes: 0 updated/current, 1 refusal or failure.
update_run() {
    _update_bin_dir="${CORTI_PROXY_BIN_DIR:-${CC_PROXY_BIN_DIR:-$HOME/.local/bin}}"
    _update_setup_out="$(mktemp "${TMPDIR:-/tmp}/corti-update.XXXXXX")"
    _update_dry=0
    for _update_arg in "$@"; do
        case "$_update_arg" in --dry-run) _update_dry=1 ;; esac
    done
    unset _update_arg

    # Gates: clone, branch, reachability, behind. Any "no" is a refusal with a recipe.
    if ! command -v git >/dev/null 2>&1; then
        echo "corti-bridge: git is not installed — update cannot run" >&2
        rm -f "$_update_setup_out"
        return 1
    fi
    # Gate on PROXY_DIR itself (baked at install time, possibly overridden by the env), not on
    # the override var's presence: an unset override with a real baked path is a normal install.
    if [ "${PROXY_DIR:-/path/to/corti-bridge}" = "/path/to/corti-bridge" ] || [ ! -d "$PROXY_DIR/.git" ]; then
        echo "corti-bridge: $PROXY_DIR is not a git clone — update needs a clone to pull" >&2
        rm -f "$_update_setup_out"
        return 1
    fi
    _update_branch="$(git -C "$PROXY_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
    if [ "$_update_branch" != main ]; then
        echo "corti-bridge: $PROXY_DIR is on branch ${_update_branch:-<detached>} — update only runs on main" >&2
        rm -f "$_update_setup_out"
        return 1
    fi
    # Dry-run: change nothing and fetch nothing — the fetch itself is a repo write (it moves
    # refs/remotes/origin/main). Count from the last-fetched refs and say how stale they may be.
    if [ "$_update_dry" = 1 ]; then
        _update_beyond="$(git -C "$PROXY_DIR" rev-list --count HEAD..origin/main 2>/dev/null)" || true
        case "${_update_beyond:-}" in
            ''|*[!0-9]*)
                echo "corti-bridge: could not count commits behind origin/main (dry run) — check the clone: git -C \"$PROXY_DIR\" status" >&2
                rm -f "$_update_setup_out"
                return 1
                ;;
            0)
                echo "corti-bridge: already up to date (as of the last fetch; dry run)" >&2
                rm -f "$_update_setup_out"
                return 0
                ;;
        esac
        echo "corti-bridge: $((_update_beyond)) new commit(s) on main, as of the last fetch — dry run; nothing written. Run: corti-bridge update" >&2
        rm -f "$_update_setup_out"
        return 0
    fi

    # Bounded, prompt-proof fetch: no timeout(1) on macOS, so pin throughput and kill prompts.
    if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
        git -C "$PROXY_DIR" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
        fetch --quiet origin main 2>/dev/null; then
        echo "corti-bridge: cannot reach origin — update did not change anything. Try again when connected." >&2
        rm -f "$_update_setup_out"
        return 1
    fi
    _update_beyond="$(git -C "$PROXY_DIR" rev-list --count HEAD..origin/main 2>/dev/null)" || true
    case "${_update_beyond:-}" in
        ''|*[!0-9]*)
            # A failed count is NOT "already up to date" — fail closed instead.
            echo "corti-bridge: could not count commits behind origin/main — check the clone: git -C \"$PROXY_DIR\" status" >&2
            rm -f "$_update_setup_out"
            return 1
            ;;
        0)
            echo "corti-bridge: already up to date" >&2
            rm -f "$_update_setup_out"
            return 0
            ;;
    esac

    # Pull. Atomicity: --ff-only refuses (HEAD unmoved) on divergence and on tracked-file
    # collisions; a stale MERGE_HEAD from a crashed manual pull needs its own recipe.
    _update_old="$(mktemp "${TMPDIR:-/tmp}/corti-old.XXXXXX")"
    _update_pull_err="$(mktemp "${TMPDIR:-/tmp}/corti-pullerr.XXXXXX")"
    git -C "$PROXY_DIR" rev-parse HEAD > "$_update_old" 2>/dev/null || true
    if ! git -C "$PROXY_DIR" pull --ff-only --quiet origin main 2>"$_update_pull_err"; then
        rm -f "$_update_setup_out" "$_update_old"
        if [ -e "$PROXY_DIR/.git/MERGE_HEAD" ]; then
            echo "corti-bridge: an earlier merge was never concluded — run: git -C \"$PROXY_DIR\" status, then resolve or git merge --abort" >&2
        elif [ "$(git -C "$PROXY_DIR" rev-list --count HEAD --not --remotes=origin 2>/dev/null)" != "0" ] 2>/dev/null; then
            echo "corti-bridge: your clone has local commits — update cannot replay them. Rebase or push first: git -C \"$PROXY_DIR\" status" >&2
        elif [ -s "$_update_pull_err" ] && grep -q "would be overwritten" "$_update_pull_err" 2>/dev/null; then
            echo "corti-bridge: uncommitted changes to tracked files would be overwritten — commit or stash first (git -C \"$PROXY_DIR\" status)" >&2
        else
            echo "corti-bridge: git pull failed — run: cd \"$PROXY_DIR\" && git status" >&2
        fi
        return 1
    fi
    rm -f "$_update_pull_err"

    _update_head="$(git -C "$PROXY_DIR" rev-parse HEAD 2>/dev/null || echo '')"
    _update_classes="$(update_classify "$(cat "$_update_old" 2>/dev/null || true)" "$_update_head")"
    # update_classify removes both its args' files when they are paths; reaching here they were
    # strings, so the temp could survive — remove it here for the string-arg form.
    rm -f "$_update_old"

    _update_redeployed=not-needed
    case "$_update_classes" in
        *install*)
            # || _update_redeploy_rc=1: a precondition refusal (return 1, no output) would
            # otherwise kill the run under set -eu before the failed-case mapping fires.
            _update_redeploy_rc=0
            _update_redeploy_res="$(update_redeploy)" || _update_redeploy_rc=1
            case "${_update_redeploy_res:-}" in
                deployed) _update_redeployed=deployed ;;
                *) _update_redeployed=failed ;;
            esac
            ;;
    esac

    case "$_update_classes" in
        *gateway*)
            echo "corti-bridge: gateway sources changed — picks up on your next session start (the gateway restarts itself on a changed build)" >&2
            ;;
    esac
    case "$_update_redeployed" in
        deployed)
            echo "corti-bridge: wrapper updated — new subcommands and flags apply to commands you run from now on" >&2
            ;;
        failed)
            echo "corti-bridge: the wrapper could not be re-deployed — the gateway code above still applies; run: ./setup.sh in $PROXY_DIR" >&2
            _update_rc=1
            ;;
        *)
            _update_rc=0
            ;;
    esac
    rm -f "$_update_setup_out"

    if [ "${_update_rc:-0}" = 0 ]; then
        # The dispatcher label sits before the launch path's mkdir -p "$CORTI_DIR"; a fresh
        # state dir must exist before the stamp write, or it silently no-ops.
        mkdir -p "$CORTI_DIR"
        _update_stamp
        echo "corti-bridge: update complete" >&2
        return 0
    fi
    return 1
}
