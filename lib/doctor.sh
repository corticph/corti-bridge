# shellcheck shell=sh
# Diagnostics library for `corti-bridge doctor`. Sourced by bin/corti-bridge (and
# reusable by setup.sh). Defines the per-check functions (1-18), the runtime
# entry point `doctor_run`, and the shared `doctor_proxy_dir` extractor.
#
# Output goes to STDOUT (a report), not stderr — a deliberate exception to the
# ui_*→stderr rule so `doctor | grep FAIL` and `doctor > file` work.
#
# Honest limits: every passive check that cannot fully validate labels itself
# ("not validated against Corti", "clone not confirmed from health alone") and
# the run ends with a "Not checked (passive run)" footer. No green glyph
# endorses the whole system.
#
# All doctor-local vars use the `_d_` prefix. `i` is avoided as a loop var
# (gateway_start leaks it). Toolkit is the allowed POSIX set; no jq, no
# column -t, no lsof/netstat/ss, no sort -u, no wc, no stat.

# Resolve a value to ~-prefixed for display only; absolute paths stay literal.
# Local mirror of lib/ui.sh's ui_tilde so the doctor stays decoupled from ui.sh
# (it prints to stdout, ui_* prints to stderr).
_d_tilde() {
    case "$1" in
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Decide whether to colorize, mirroring lib/ui.sh's guard but checking [ -t 1 ]
# (stdout) instead of [ -t 2 ] (stderr): the doctor is a stdout report.
_d_color_init() {
    if [ -n "${NO_COLOR:-}" ]; then
        _d_color=0
    elif [ -n "${FORCE_COLOR:-}" ]; then
        _d_color=1
    elif [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        _d_color=1
    else
        _d_color=0
    fi
    if [ "$_d_color" = 1 ]; then
        _d_c_ok=$(printf '\033[32m')
        _d_c_warn=$(printf '\033[33m')
        _d_c_fail=$(printf '\033[31m')
        _d_c_reset=$(printf '\033[0m')
    else
        _d_c_ok=''
        _d_c_warn=''
        _d_c_fail=''
        _d_c_reset=''
    fi
}

# Counters and accumulated state shared across checks. Initialized to 0/''
# at the top of doctor_run; _d_report increments them per call.
_d_n_ok=0
_d_n_warn=0
_d_n_fail=0
# Clone paths discovered by checks 7 (wrapper baked) and 12/16 (running), used
# by the dual-clone correlation (Check 15).
_d_baked=''
_d_run_clone=''

# One check row. $1 glyph word (OK/WARN/FAIL), $2 check name, $3 value, $4 fix.
# The glyph is padded to 6 via %-6s so [OK] aligns with [WARN]/[FAIL]. Fix text
# is indented on following lines when non-empty. Color is a TTY-only accent on
# the glyph; the glyph word always carries the signal (never color-only).
# Increments the _d_n_ok/_d_n_warn/_d_n_fail counters directly.
_d_report() {
    case "$1" in
        OK)   _d_glyph="${_d_c_ok}[$1]${_d_c_reset}";   _d_n_ok=$((_d_n_ok + 1)) ;;
        WARN) _d_glyph="${_d_c_warn}[$1]${_d_c_reset}"; _d_n_warn=$((_d_n_warn + 1)) ;;
        FAIL) _d_glyph="${_d_c_fail}[$1]${_d_c_reset}"; _d_n_fail=$((_d_n_fail + 1)) ;;
        *)    _d_glyph="[$1]"; _d_n_ok=$((_d_n_ok + 1)) ;;
    esac
    printf '%-6s %-16s %s\n' "$_d_glyph" "$2" "$3"
    if [ -n "$4" ]; then
        printf '      %s\n' "$4"
    fi
}

# Shared extractor for the baked PROXY_DIR from an installed wrapper file.
# Echoes the clone path, or empty if unparseable/uninstalled. Callable
# standalone (doctor Check 7; setup.sh dual-clone warning in a later step).
# $1 = wrapper file path
doctor_proxy_dir() {
    [ -f "$1" ] || return 0
    sed -n 's/^PROXY_DIR="${CORTI_PROXY_DIR:-\([^}]*\)}".*/\1/p' "$1" | head -1
}

# Check 1 — node present + version >=20. The case guard before [ -ge ] is
# load-bearing: without it [ "" -ge 20 ] errors "Illegal number:" under dash.
_d_check_node() {
    if ! command -v node >/dev/null 2>&1; then
        _d_report FAIL node "not found on PATH (need >=20)" \
            "If 'node -v' works in your terminal, a version manager (nvm/fnm/volta) may be hiding it from /bin/sh. The gateway has the same blindness (gateway_start runs 'nohup node ...')."
    else
        _d_major=$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')
        case "$_d_major" in
            ''|*[!0-9]*)
                _d_report FAIL node "present but version unparseable: $(node -v 2>/dev/null)" "" ;;
            *)
                if [ "$_d_major" -ge 20 ]; then
                    _d_report OK node "$(node -v 2>/dev/null) (major $_d_major)" ""
                else
                    _d_report FAIL node "$(node -v 2>/dev/null) (need >=20, got $_d_major)" \
                        "Upgrade Node, then re-run ./setup.sh: https://nodejs.org/"
                fi
                ;;
        esac
    fi
}

# Check 2 — curl present.
_d_check_curl() {
    if command -v curl >/dev/null 2>&1; then
        _d_report OK curl "$(command -v curl)" ""
    else
        _d_report FAIL curl "not found on PATH" "Install curl, then re-run ./setup.sh."
    fi
}

# Check 3 — claude on PATH (advisory WARN, not FAIL: version managers hide it).
_d_check_claude() {
    if command -v claude >/dev/null 2>&1; then
        _d_report OK claude "$(command -v claude)" ""
    else
        _d_report WARN claude "not found in this process's PATH" \
            "If 'claude --version' works in your terminal, a version manager is likely hiding it from /bin/sh. The wrapper would have the same blindness."
    fi
}

# Check 4 — CORTI_BEARER present. ok message is deliberately hedged: presence
# is never collapsed into validity.
_d_check_bearer() {
    if [ -z "${CORTI_BEARER:-}" ]; then
        _d_report FAIL CORTI_BEARER "not set (or empty)" \
            "Run 'npx @corti/cli models init', then open a new terminal."
    else
        _d_report OK CORTI_BEARER "set (${#CORTI_BEARER} chars) - not validated against Corti" ""
    fi
}

# Check 5 — CORTI_BASE_URL present + shape (glob, looser than gateway regex).
_d_check_base_url() {
    if [ -z "${CORTI_BASE_URL:-}" ]; then
        _d_report FAIL CORTI_BASE_URL "not set" \
            "Run 'npx @corti/cli models init', then open a new terminal."
    else
        case "$CORTI_BASE_URL" in
            https://ai.*.corti.app/v1)
                _d_report OK CORTI_BASE_URL "$CORTI_BASE_URL" "" ;;
            *)
                _d_report FAIL CORTI_BASE_URL "bad shape (want https://ai.<env>.corti.app/v1): $CORTI_BASE_URL" \
                    "The gateway enforces a stricter regex; fix the URL and re-run."
                ;;
        esac
    fi
}

# Check 6 — wrapper installed at the bin dir.
_d_check_wrapper() {
    if [ -f "$_d_WRAPPER" ]; then
        _d_report OK wrapper "installed at $(_d_tilde "$_d_WRAPPER")" ""
    else
        _d_report FAIL wrapper "not installed at $(_d_tilde "$_d_WRAPPER")" \
            "Run ./setup.sh from your clone to install it."
    fi
}

# Check 7 — wrapper's baked-in PROXY_DIR. Extract via the shared function,
# confirm gateway.mjs exists; detect the uninstalled placeholder. Also reports
# a runtime CORTI_PROXY_DIR override (the doctor reads the file, not the runtime).
_d_check_proxy_dir() {
    if [ ! -f "$_d_WRAPPER" ]; then
        return 0
    fi
    _d_baked=$(doctor_proxy_dir "$_d_WRAPPER")
    if [ -n "$_d_baked" ]; then
        # The uninstalled wrapper's placeholder is also matched by the sed, so
        # detect it before the gateway.mjs existence check: a placeholder path
        # is FAIL "UNINSTALLED", not WARN "no gateway.mjs".
        case "$_d_baked" in
            */path/to/corti-bridge)
                _d_report FAIL proxy-dir "wrapper is UNINSTALLED (placeholder PROXY_DIR)" \
                    "Run ./setup.sh from your clone." ;;
            *)
                if [ -f "$_d_baked/gateway.mjs" ]; then
                    _d_report OK proxy-dir "wrapper's clone: $(_d_tilde "$_d_baked")" ""
                else
                    _d_report WARN proxy-dir "wrapper's clone $(_d_tilde "$_d_baked") has no gateway.mjs" \
                        "The clone was moved/deleted, or this is the wrong clone. Re-run ./setup.sh from the clone you want."
                fi
                ;;
        esac
    else
        case "$(sed -n 's/^PROXY_DIR=.*/&/p' "$_d_WRAPPER" | head -1)" in
            *'/path/to/corti-bridge'*)
                _d_report FAIL proxy-dir "wrapper is UNINSTALLED (placeholder PROXY_DIR)" \
                    "Run ./setup.sh from your clone." ;;
            *)
                _d_report WARN proxy-dir "could not parse PROXY_DIR from wrapper" "" ;;
        esac
    fi
    if [ -n "${CORTI_PROXY_DIR:-${CC_PROXY_DIR:-}}" ]; then
        _d_report WARN proxy-dir "runtime CORTI_PROXY_DIR=${CORTI_PROXY_DIR:-${CC_PROXY_DIR:-}} overrides the baked path" \
            "The wrapper will use this when launched from a shell with it set."
    fi
}

# Check 8 — bin dir on PATH + rc block written. Two sub-checks: "active now"
# (pathrc_on_path) vs "survives a new shell" (pathrc_already_configured).
_d_check_bin_path() {
    if pathrc_on_path "$_d_BIN_DIR"; then
        _d_report OK bin-path "$(_d_tilde "$_d_BIN_DIR") is on PATH" ""
    else
        _d_report WARN bin-path "$(_d_tilde "$_d_BIN_DIR") is not on PATH" \
            "Open a new terminal, or add it manually: export PATH=\"$HOME/.local/bin:\$PATH\""
    fi
}

_d_check_rc_block() {
    _d_shell=$(pathrc_detect_shell)
    _d_targets=$(pathrc_target_files "$_d_shell")
    _d_found=0
    _d_found_file=""
    for _d_f in $_d_targets; do
        if pathrc_already_configured "$_d_f"; then
            _d_found=1
            _d_found_file="$_d_f"
        fi
    done
    if [ "$_d_found" = 1 ]; then
        _d_report OK rc-block "PATH block in $(_d_tilde "$_d_found_file")" ""
    else
        _d_report WARN rc-block "no PATH block in any rc file ($_d_shell)" \
            "Run ./setup.sh to add it, or add it manually."
    fi
}

# Check 9 — state dir exists.
_d_check_state_dir() {
    if [ -d "$_d_CORTI_DIR" ]; then
        _d_report OK state-dir "$(_d_tilde "$_d_CORTI_DIR") exists" ""
    else
        _d_report WARN state-dir "$(_d_tilde "$_d_CORTI_DIR") does not exist yet" \
            "Run ./setup.sh, or the wrapper will create it on first launch."
    fi
}

# Check 10 — models.env present + required keys. ok message carries the honest
# hedge: syntax/keys checked, values not validated against the catalog.
_d_check_models_env() {
    _d_md_file="$_d_CORTI_DIR/models.env"
    if [ ! -f "$_d_md_file" ]; then
        _d_report FAIL models-env "missing" \
            "Run ./setup.sh (or ./setup.sh --fresh to re-detect from Corti)."
    else
        _d_opus=$(models_env_get "$_d_md_file" ANTHROPIC_DEFAULT_OPUS_MODEL || true)
        _d_sonnet=$(models_env_get "$_d_md_file" ANTHROPIC_DEFAULT_SONNET_MODEL || true)
        _d_haiku=$(models_env_get "$_d_md_file" ANTHROPIC_DEFAULT_HAIKU_MODEL || true)
        _d_ctx=$(models_env_get "$_d_md_file" CLAUDE_CODE_MAX_CONTEXT_TOKENS || true)
        _d_missing=""
        [ -n "$_d_opus" ]   || _d_missing="$_d_missing opus"
        [ -n "$_d_sonnet" ] || _d_missing="$_d_missing sonnet"
        [ -n "$_d_haiku" ]  || _d_missing="$_d_missing haiku"
        [ -n "$_d_ctx" ]    || _d_missing="$_d_missing context-tokens"
        if [ -n "$_d_missing" ]; then
            _d_report FAIL models-env "missing keys:$_d_missing" \
                "Run ./setup.sh --fresh to re-detect from Corti."
        else
            _d_report OK models-env "opus=$_d_opus sonnet=$_d_sonnet haiku=$_d_haiku ctx=$_d_ctx" \
                "Values not validated against Corti's catalog (run ./setup.sh --fresh to verify)."
        fi
    fi
}

# Check 11 — profile.env present + CLAUDE_CONFIG_DIR exists (warn, not fail:
# claude may create the dir on startup).
_d_check_profile_env() {
    _d_pf_file="$_d_CORTI_DIR/profile.env"
    if [ ! -f "$_d_pf_file" ]; then
        _d_report WARN profile-env "missing (wrapper defaults to $(_d_tilde "$_d_CORTI_DIR"))" \
            "Run ./setup.sh to choose a Claude Code profile dir."
    else
        _d_cfg=$(models_env_get "$_d_pf_file" CLAUDE_CONFIG_DIR || true)
        if [ -n "$_d_cfg" ]; then
            if [ -d "$_d_cfg" ]; then
                _d_report OK profile-env "CLAUDE_CONFIG_DIR=$(_d_tilde "$_d_cfg")" ""
            else
                _d_report WARN profile-env "CLAUDE_CONFIG_DIR=$(_d_tilde "$_d_cfg") (directory does not exist yet)" \
                    "Claude Code may create it on startup."
            fi
        else
            _d_report WARN profile-env "exists but CLAUDE_CONFIG_DIR is missing/empty" \
                "Run ./setup.sh --fresh to re-choose."
        fi
    fi
}

# Check 12 — pid file present + valid (four-stage filter: exists, numeric,
# alive, is-a-gateway). Also extracts the running clone from the cmdline for
# the dual-clone check (Check 15). The numeric guard rejects garbage before
# kill -0.
_d_check_pid_file() {
    if [ -f "$_d_PID_FILE" ]; then
        _d_pid=$(cat "$_d_PID_FILE" 2>/dev/null) || true
        case "$_d_pid" in
            ''|*[!0-9]*)
                _d_report FAIL pid-file "garbage in $(_d_tilde "$_d_PID_FILE"): $_d_pid" \
                    "Remove it: rm \"$_d_PID_FILE\""
                return 0
                ;;
        esac
        if [ -n "$_d_pid" ] && kill -0 "$_d_pid" 2>/dev/null; then
            _d_cmd=$(ps -o command= -p "$_d_pid" 2>/dev/null)
            if printf '%s' "$_d_cmd" | grep -q 'gateway\.mjs'; then
                # The space between argv tokens delimits the clone path; [^ ]*
                # captures the full path. The spec's [ /] was greedy on the
                # last slash and captured only the final path component.
                _d_run_clone=$(printf '%s' "$_d_cmd" | sed -n 's/.* \([^ ]*\)\/gateway\.mjs.*/\1/p' | head -1)
                _d_report OK pid-file "pid=$_d_pid alive (clone: $(_d_tilde "${_d_run_clone:-unknown}"))" ""
            else
                _d_report WARN pid-file "STALE pid: $_d_pid is alive but not a gateway (recycled)" \
                    "cmdline: $_d_cmd. Remove the pid file: rm \"$_d_PID_FILE\""
            fi
        else
            _d_report WARN pid-file "stale pid file: $_d_pid is not alive (process exited)" \
                "Remove it: rm \"$_d_PID_FILE\""
        fi
    else
        _d_report WARN pid-file "no pid file for port $_d_PORT" \
            "If a gateway is running, it was started by hand (no wrapper). corti-bridge --stop will use path-based kill."
    fi
}

# Check 13 — running gateway on the default port (/health). Parse mode,
# upstream, version, debug; confirm ours; warn on staleness/old build/foreign.
# Check 14 (foreign process) is the gateway_is_ours failure branch here.
_d_check_gateway() {
    _d_health=$(gateway_health)
    if [ -z "$_d_health" ]; then
        _d_report WARN gateway "no responder on port $_d_PORT" \
            "Run corti-bridge to start one."
    elif ! gateway_is_ours "$_d_health"; then
        _d_report FAIL gateway "foreign process answering HTTP on port $_d_PORT (not our gateway)" \
            "Set CORTI_PORT to a free port, or stop the other process."
    else
        _d_mode=$(printf '%s' "$_d_health" | sed -n 's/.*"mode":"\([^"]*\)".*/\1/p')
        _d_upstream=$(printf '%s' "$_d_health" | sed -n 's/.*"upstream":"\([^"]*\)".*/\1/p')
        _d_version=$(printf '%s' "$_d_health" | sed -n 's/.*"gatewayVersion":\([0-9]*\).*/\1/p')
        case "$_d_health" in
            *'"debug":"'*) _d_debug=$(printf '%s' "$_d_health" | sed -n 's/.*"debug":"\([^"]*\)".*/\1/p') ;;
            *) _d_debug="(off)" ;;
        esac
        _d_sub="mode=$_d_mode upstream=$_d_upstream version=$_d_version debug=$_d_debug"
        case "$_d_health" in
            *'"gatewayVersion":'*) ;;
            *)
                _d_report WARN gateway "older build (no gatewayVersion) - a corti-bridge launch will auto-restart to upgrade" "$_d_sub"
                return 0
                ;;
        esac
        if [ -n "${CORTI_BASE_URL:-}" ]; then
            case "$_d_health" in
                *"\"upstream\":\"$CORTI_BASE_URL\""*) ;;
                *)
                    _d_report WARN gateway "upstream mismatch: running gateway targets $_d_upstream, your shell has CORTI_BASE_URL=$CORTI_BASE_URL" \
                        "A corti-bridge launch will restart to switch upstreams."
                    return 0
                    ;;
            esac
        fi
        _d_report OK gateway "healthy on :$_d_PORT ($_d_sub)" \
            "Clone not confirmed from health alone (see proxy-dir + process checks)."
    fi
}

# Check 15 — THE DUAL-CLONE CHECK: wrapper's baked PROXY_DIR vs running
# gateway's clone. Mismatch = warn. Cannot catch CORTI_PROXY_DIR runtime overrides
# or hand-started gateways (stated in the limits footer).
_d_check_dual_clone() {
    if [ -n "$_d_baked" ] && [ -n "$_d_run_clone" ]; then
        if [ "$_d_baked" = "$_d_run_clone" ]; then
            _d_report OK dual-clone "wrapper and running gateway agree on $(_d_tilde "$_d_baked")" ""
        else
            _d_report WARN dual-clone "wrapper points at $(_d_tilde "$_d_baked") but a running gateway is from $(_d_tilde "$_d_run_clone")" \
                "corti-bridge --stop/restart will target the wrapper's clone, not the running one. To run two clones safely: set CORTI_PROXY_CONFIG_DIR per clone (splits models.env/profile.env/pid/log) AND use distinct CORTI_PORT values."
        fi
    fi
}

# Check 16 — multiple running gateways (ps scan). `ps ... | while read` runs in
# a subshell under dash, so counters don't survive; write found-process lines
# to a temp file in the loop, re-read outside. Dedupe clone paths with a
# seen-list (no sort -u). Re-count with grep -c (no wc).
_d_check_processes() {
    _d_gw_tmp="${TMPDIR:-/tmp}/cc-doctor-gw.$$"
    : > "$_d_gw_tmp"
    ps -e -o pid= -o command= 2>/dev/null | grep '[g]ateway\.mjs' | while read -r _d_p _d_rest; do
        _d_pclone=$(printf '%s' "$_d_rest" | sed -n 's/.* \([^ ]*\)\/gateway\.mjs.*/\1/p' | head -1)
        printf 'pid=%s clone=%s\n' "$_d_p" "${_d_pclone:-unknown}" >> "$_d_gw_tmp"
    done
    _d_gw_count=$(grep -c '' "$_d_gw_tmp" 2>/dev/null || true)
    case "$_d_gw_count" in
        ''|*[!0-9]*) _d_gw_count=0 ;;
    esac
    if [ "$_d_gw_count" = 0 ]; then
        _d_report OK processes "0 gateway processes found" ""
    elif [ "$_d_gw_count" = 1 ]; then
        _d_report OK processes "1 gateway process found" ""
    else
        _d_report WARN processes "$_d_gw_count gateway processes found (multiple clones?)" \
            "The wrapper manages one clone; the others are unmanaged. Run corti-bridge doctor to see the dual-clone check."
    fi
    # Emit each found process as a detail line under the row.
    while read -r _d_gw_line; do
        [ -n "$_d_gw_line" ] || continue
        printf '      %s\n' "$_d_gw_line"
    done < "$_d_gw_tmp"
    rm -f "$_d_gw_tmp"
}

# Check 17 — multiple pid files (different ports). Warn on >1: models.env /
# profile.env / gateway.log are shared across ports; last --fresh wins.
_d_check_pid_files() {
    _d_pidfiles=$(ls "$_d_CORTI_DIR"/gateway-*.pid 2>/dev/null || true)
    _d_npid=0
    for _d_pf in $_d_pidfiles; do
        _d_npid=$((_d_npid + 1))
    done
    if [ "$_d_npid" = 0 ]; then
        _d_report OK pid-files "0 pid files" ""
    elif [ "$_d_npid" = 1 ]; then
        _d_report OK pid-files "1 pid file (port $_d_PORT)" ""
    else
        _d_report WARN pid-files "$_d_npid pid files found (multiple ports)" \
            "models.env/profile.env/gateway.log are shared across ports; the last ./setup.sh --fresh wins."
    fi
    # Detail lines (each pid file with its port) go under the report row.
    for _d_pf in $_d_pidfiles; do
        _d_pport=$(printf '%s' "$_d_pf" | sed -n 's/.*gateway-\([0-9]*\)\.pid/\1/p')
        printf '      pid file: %s (port %s)\n' "$_d_pf" "$_d_pport"
    done
}

# Check 18 — gateway.log existence (advisory). mtime is NOT a liveness signal
# (the gateway writes here only on start/error).
_d_check_gateway_log() {
    _d_log="$_d_CORTI_DIR/gateway.log"
    if [ ! -f "$_d_log" ]; then
        _d_report WARN gateway-log "no gateway.log (gateway never started, or log deleted)" ""
    elif [ ! -s "$_d_log" ]; then
        _d_report WARN gateway-log "gateway.log exists but is empty" ""
    else
        _d_report OK gateway-log "$(_d_tilde "$_d_log") exists" \
            "Log recency is not a liveness signal; use the /health check."
    fi
}

# Active credential/model probe for --deep. Reports HTTP codes as distinct
# advisories (not collapsed): 000 = network, 401 = rejected, 400 = malformed,
# 200 = ok. Auto-skips when CORTI_BEARER is unset.
_d_deep_probe() {
    if [ -z "${CORTI_BEARER:-}" ]; then
        _d_report WARN deep "skipped: CORTI_BEARER not set (cannot probe Corti)" ""
        return 0
    fi
    if [ -z "${CORTI_BASE_URL:-}" ]; then
        _d_report WARN deep "skipped: CORTI_BASE_URL not set (cannot probe Corti)" ""
        return 0
    fi
    _d_dp_url="$CORTI_BASE_URL/models"
    _d_dp_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "Authorization: Bearer $CORTI_BEARER" "$_d_dp_url" 2>/dev/null) || _d_dp_code=000
    case "$_d_dp_code" in
        200)
            _d_report OK deep "Corti /models returned 200 (credentials accepted)" \
                "Model-id correctness/tiering still not validated (a tier swap parses fine)."
            ;;
        401)
            _d_report WARN deep "Corti rejected credentials (401) - token may be revoked or regenerated" \
                "Run: npx @corti/cli models init"
            ;;
        400)
            _d_report WARN deep "Corti returned 400 - a malformed CORTI_BEARER is the usual cause" \
                "Run: npx @corti/cli models init"
            ;;
        000)
            _d_report WARN deep "couldn't reach Corti (000) - network/VPN, or could be a dead token" \
                "Check your network/VPN; 000 can't distinguish revoked-token from no-network."
            ;;
        *)
            _d_report WARN deep "Corti /models returned HTTP $_d_dp_code" ""
            ;;
    esac
}

# Honest-limits footer. Lists what the run could NOT validate, adjusted for
# --deep: a deep run reaches Corti's /models (credential reachability), but still
# can't confirm model-id tiering or map pid->port. A passive run can't reach Corti
# at all.
_d_limits_footer() {
    printf '\n'
    if [ "$_d_deep" = 1 ]; then
        printf 'Not checked (even with --deep): model-id correctness/tiering (a tier\nswap parses fine), port of ps-found gateways, second clones on disk. Credential\nreachability was probed; 401 != definitively revoked.\n'
    else
        printf 'Not checked (passive run): credential validity against Corti, model-id\ncorrectness/tiering, port of ps-found gateways, second clones on disk.\n'
        printf "Run 'corti-bridge doctor --deep' to probe Corti's /models endpoint.\n"
    fi
}

# Full runtime entry point. Called by bin/corti-bridge as `corti-bridge doctor`.
# Parses --deep from argv; runs all 18 checks; prints summary + limits footer;
# exits 0/1/2.
doctor_run() {
    _d_deep=0
    for _d_arg in "$@"; do
        case "$_d_arg" in
            --deep) _d_deep=1 ;;
            --help|-h)
                cat <<EOF
corti-bridge doctor - diagnostics for the corti-bridge proxy.

Usage: corti-bridge doctor [--deep]

  (default)  Run 18 passive checks (no network except localhost /health)
  --deep     Also probe Corti's /models endpoint (active; needs CORTI_BEARER)

Exit codes: 0 = all OK, 1 = warnings present, 2 = one or more failures.
EOF
                return 0
                ;;
        esac
    done

    # Resolve doctor-local state from the same env the wrapper reads, and reset
    # mutable accumulators so repeated calls (sourced once, called multiple times)
    # don't carry stale counts or clone paths from a prior run.
    _d_CORTI_DIR="${CORTI_PROXY_CONFIG_DIR:-${CC_PROXY_CONFIG_DIR:-$HOME/.corti-bridge}}"
    _d_PORT="${CORTI_PORT:-4192}"
    _d_GATEWAY="http://${CORTI_HOST:-127.0.0.1}:$_d_PORT"
    _d_PID_FILE="$_d_CORTI_DIR/gateway-$_d_PORT.pid"
    _d_BIN_DIR="${CORTI_PROXY_BIN_DIR:-${CC_PROXY_BIN_DIR:-$HOME/.local/bin}}"
    _d_WRAPPER="$_d_BIN_DIR/corti-bridge"
    _d_n_ok=0
    _d_n_warn=0
    _d_n_fail=0
    _d_baked=''
    _d_run_clone=''

    _d_color_init

    printf '\ncorti-bridge doctor\n'

    _d_check_node
    _d_check_curl
    _d_check_claude
    _d_check_bearer
    _d_check_base_url
    _d_check_wrapper
    _d_check_proxy_dir
    _d_check_bin_path
    _d_check_rc_block
    _d_check_state_dir
    _d_check_models_env
    _d_check_profile_env
    _d_check_pid_file
    _d_check_gateway
    _d_check_dual_clone
    _d_check_processes
    _d_check_pid_files
    _d_check_gateway_log

    if [ "$_d_deep" = 1 ]; then
        _d_deep_probe
    fi

    printf '\nSummary: %s OK, %s WARN, %s FAIL\n' "$_d_n_ok" "$_d_n_warn" "$_d_n_fail"

    _d_limits_footer

    if [ "$_d_n_fail" -gt 0 ]; then
        return 2
    elif [ "$_d_n_warn" -gt 0 ]; then
        return 1
    fi
    return 0
}
