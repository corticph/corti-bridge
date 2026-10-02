# update verb: pull the clone, re-deploy the wrapper when bin/corti-bridge changed, say what
# applies when. Reuses the wrapper's globals. Never restarts the gateway.

# Epoch seconds in update_refresh's exact format; a bad stamp just costs one extra fetch.
_update_stamp() {
    printf '%s' "$(date +%s 2>/dev/null || echo 0)" > "$UPDATE_STAMP_FILE" 2>/dev/null || true
}

# Echoes (space-separated) the action sets OLD..NEW touches: install gateway.
# $1/$2 are SHAs, never paths. Renames list their new path; deletions match nothing.
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
    if [ "$_uc_install" = 1 ] && [ "$_uc_gateway" = 1 ]; then
        printf 'install gateway'
    elif [ "$_uc_install" = 1 ]; then
        printf 'install'
    elif [ "$_uc_gateway" = 1 ]; then
        printf 'gateway'
    fi
}

# Re-run setup to re-deploy the wrapper. Not an installer: missing state aborts (under --yes
# it would be silently created); a foreign baked path is refused, never re-pointed.
update_redeploy() {
    if [ ! -f "$CORTI_DIR/models.env" ] || [ ! -f "$CORTI_DIR/profile.env" ]; then
        echo "corti-bridge: $CORTI_DIR/models.env or profile.env is missing — run ./setup.sh in $PROXY_DIR first" >&2
        return 1
    fi
    # Single-quoted sed: it must see the literal \1 and the ${...} text.
    _ur_baked="$(sed -n 's/^PROXY_DIR="\${CORTI_PROXY_DIR:-\([^}]*\)}".*/\1/p' "$_update_bin_dir/corti-bridge" 2>/dev/null | head -1)"
    if [ "$_ur_baked" != "$PROXY_DIR" ]; then
        echo "corti-bridge: the installed wrapper points at ${_ur_baked:-nowhere}, not $PROXY_DIR — run ./setup.sh manually from the right clone" >&2
        return 1
    fi
    # || keeps a failing setup reachable under set -eu. Benign and fatal both arrive as rc 1,
    # so the signal lines below are the only discriminator.
    _ur_rc=0
    CORTI_PROXY_CONFIG_DIR="$CORTI_DIR" CORTI_PROXY_BIN_DIR="$_update_bin_dir" \
        "$PROXY_DIR/setup.sh" --yes --no-modify-path >"$_update_setup_out" 2>&1 || _ur_rc=$?
    cat "$_update_setup_out" >&2
    # ui_wrote's "-> updated <path>" / ui_detail's "<path> is up to date" are the success
    # signals; ui_fatal's "Nothing was installed." must not match, hence the anchors.
    if printf '%s' "$(cat "$_update_setup_out" 2>/dev/null || true)" | grep -Eq '^ *-> (updated|installed) |is up to date$'; then
        printf 'deployed'
    else
        printf 'not-deployed'
    fi
}

# Main. $@: --dry-run. Exit codes: 0 updated/current, 1 refusal or failure.
update_run() {
    _update_bin_dir="${CORTI_PROXY_BIN_DIR:-${CC_PROXY_BIN_DIR:-$HOME/.local/bin}}"
    _update_setup_out="$(mktemp "${TMPDIR:-/tmp}/corti-update.XXXXXX")"
    _update_dry=0
    for _update_arg in "$@"; do
        case "$_update_arg" in
            --dry-run) _update_dry=1 ;;
            # Refuse, don't silently ignore: --dryrun must not run a real mutating update.
            *) echo "corti-bridge: update: unknown argument: $_update_arg (usage: update [--dry-run])" >&2
               rm -f "$_update_setup_out"
               return 1 ;;
        esac
    done
    unset _update_arg

    # Gates: clone, branch, reachability, behind. Any "no" is a refusal with a recipe.
    if ! command -v git >/dev/null 2>&1; then
        echo "corti-bridge: git is not installed — update cannot run" >&2
        rm -f "$_update_setup_out"
        return 1
    fi
    # Gate on PROXY_DIR itself — an unset override with a real baked path is a normal install.
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
    # Dry-run must fetch nothing — the fetch itself writes refs — so count from the last fetch.
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

    # No timeout(1) on macOS: pin throughput, kill credential prompts.
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
            # The fetch succeeded, so this is a real check — stamp as much as a pull would.
            mkdir -p "$CORTI_DIR"
            _update_stamp
            rm -f "$_update_setup_out"
            return 0
            ;;
    esac

    # A failed --ff-only leaves HEAD unmoved; three refusal shapes get their own recipes.
    # merge, not pull: the fetch above already moved refs, and pull would reach the network
    # a second time with none of the bounds.
    _update_old="$(mktemp "${TMPDIR:-/tmp}/corti-old.XXXXXX")"
    _update_pull_err="$(mktemp "${TMPDIR:-/tmp}/corti-mergeerr.XXXXXX")"
    git -C "$PROXY_DIR" rev-parse HEAD > "$_update_old" 2>/dev/null || true
    if ! git -C "$PROXY_DIR" merge --ff-only --quiet origin/main 2>"$_update_pull_err"; then
        rm -f "$_update_setup_out" "$_update_old"
        if [ -e "$PROXY_DIR/.git/MERGE_HEAD" ]; then
            echo "corti-bridge: an earlier merge was never concluded — run: git -C \"$PROXY_DIR\" status, then resolve or git merge --abort" >&2
        elif [ "$(git -C "$PROXY_DIR" rev-list --count HEAD --not --remotes=origin 2>/dev/null)" != "0" ] 2>/dev/null; then
            echo "corti-bridge: your clone has local commits — update cannot replay them. Rebase or push first: git -C \"$PROXY_DIR\" status" >&2
        elif [ -s "$_update_pull_err" ] && grep -q "would be overwritten" "$_update_pull_err" 2>/dev/null; then
            echo "corti-bridge: uncommitted changes to tracked files would be overwritten — commit or stash first (git -C \"$PROXY_DIR\" status)" >&2
        else
            echo "corti-bridge: merge failed — run: cd \"$PROXY_DIR\" && git status" >&2
        fi
        rm -f "$_update_pull_err"
        return 1
    fi
    rm -f "$_update_pull_err"

    _update_head="$(git -C "$PROXY_DIR" rev-parse HEAD 2>/dev/null || echo '')"
    _update_classes="$(update_classify "$(cat "$_update_old" 2>/dev/null || true)" "$_update_head")"
    rm -f "$_update_old"

    _update_redeployed=not-needed
    case "$_update_classes" in
        *install*)
            # Precondition refusal must not kill the run (set -eu).
            _update_redeploy_res="$(update_redeploy)" || :
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
        # The dispatcher label precedes the launch path's mkdir; the stamp must not no-op.
        mkdir -p "$CORTI_DIR"
        _update_stamp
        echo "corti-bridge: update complete" >&2
        return 0
    fi
    return 1
}
