# shellcheck shell=bash
# Maps each Claude Code tier to the Corti model that backs it, recorded in models.env
# (sourced by bin/corti-claude).
#
# Tiers are derived by decomposing model ids into size/speed/channel tokens rather than
# matching exact names, so a future generation slots in without a code change.

models_env_get() {
  [ -f "$1" ] || return 1
  sed -n "s/^$2=\"\\(.*\\)\"\$/\\1/p" "$1" | head -1
}

models_summary() {
  _md_fable="$(models_env_get "$1" ANTHROPIC_DEFAULT_FABLE_MODEL || true)"
  _md_line=""
  [ -n "$_md_fable" ] && _md_line="fable $_md_fable, "
  _md_line="${_md_line}opus $(models_env_get "$1" ANTHROPIC_DEFAULT_OPUS_MODEL)"
  _md_line="$_md_line, sonnet $(models_env_get "$1" ANTHROPIC_DEFAULT_SONNET_MODEL)"
  _md_line="$_md_line, haiku $(models_env_get "$1" ANTHROPIC_DEFAULT_HAIKU_MODEL)"
  ui_detail "$_md_line"

  _md_ctx="$(models_env_get "$1" CLAUDE_CODE_MAX_CONTEXT_TOKENS || true)"
  ui_detail "context $_md_ctx"
}

# Echoes the catalog JSON on stdout. Diagnosis is by HTTP status.
# $1 experimental (1 = append ?experimental=true so beta models compete for the fable tier).
models_fetch_catalog() {
  _md_exp="${1:-0}"
  _md_url="$CORTI_BASE_URL/models"
  [ "$_md_exp" = 1 ] && _md_url="$_md_url?experimental=true"
  _md_body="$(mktemp)"
  _md_code="$(curl -s -o "$_md_body" -w '%{http_code}' --max-time 15 \
    -H "Authorization: Bearer $CORTI_BEARER" "$_md_url" 2>/dev/null)" ||
    _md_code=000

  case "$_md_code" in
    200)
      cat "$_md_body"
      rm -f "$_md_body"
      return 0
      ;;
    000)
      ui_warn "couldn't reach $CORTI_BASE_URL"
      ui_detail "  check your network, or your VPN if Corti needs one"
      ;;
    401)
      ui_warn "Corti rejected your credentials (401)"
      ui_detail "  the token may have been revoked or regenerated - run: npx @corti/cli models init"
      ;;
    400)
      ui_warn "Corti returned 400"
      ui_detail "  a malformed CORTI_BEARER is the usual cause - run: npx @corti/cli models init"
      ;;
    *)
      ui_warn "Corti returned HTTP $_md_code"
      ;;
  esac

  rm -f "$_md_body"
  return 1
}

# Echoes a model's vLLM system_fingerprint, or nothing if the probe fails. Two public names
# can route to one pod; the fingerprint identifies the pod, so a one-token completion settles
# an alias without a hardcoded map.
models_fingerprint() {
  curl -s --max-time 20 -H "Authorization: Bearer $CORTI_BEARER" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
    "$CORTI_BASE_URL/chat/completions" 2>/dev/null |
    sed -n 's/.*"system_fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Drops the fable tier when its fingerprint matches opus. An empty fingerprint = no dedupe
# (unreachable/cold gateway leaves tiers as ranked); a pinned fable is returned untouched.
# $1 models.env content; echoes it back, fable lines removed if they are a duplicate.
models_dedupe_fable() {
  _md_fb="$(printf '%s\n' "$1" | sed -n 's/^ANTHROPIC_DEFAULT_FABLE_MODEL="\(.*\)"$/\1/p')"
  if [ -z "$_md_fb" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  if [ "$(printf '%s\n' "$1" | sed -n 's/^ANTHROPIC_DEFAULT_FABLE_MODEL_PIN="\(.*\)"$/\1/p')" = "1" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  _md_op="$(printf '%s\n' "$1" | sed -n 's/^ANTHROPIC_DEFAULT_OPUS_MODEL="\(.*\)"$/\1/p')"
  _md_fp_fb="$(models_fingerprint "$_md_fb")"
  _md_fp_op="$(models_fingerprint "$_md_op")"

  if [ -n "$_md_fp_fb" ] && [ "$_md_fp_fb" = "$_md_fp_op" ]; then
    ui_detail "$_md_fb is $_md_op under another name - leaving the fable tier unset"
    printf '%s\n' "$1" | grep -v '^ANTHROPIC_DEFAULT_FABLE_MODEL'
  else
    printf '%s\n' "$1"
  fi
}

# Echoes the pinned fable block from an existing models.env, or nothing if it isn't pinned.
# A pin is ANTHROPIC_DEFAULT_FABLE_MODEL plus _PIN=1; _NAME and _SUPPORTED_CAPABILITIES ride
# along if present. Carried verbatim across a --fresh refresh because a pinned model is one
# the auto-ranker can't (re)rank, served as fable regardless of which pod it routes to.
# $1 models.env path
models_fable_pin() {
  [ -f "$1" ] || return 0
  [ "$(models_env_get "$1" ANTHROPIC_DEFAULT_FABLE_MODEL_PIN || true)" = "1" ] || return 0
  _md_pin_fb="$(models_env_get "$1" ANTHROPIC_DEFAULT_FABLE_MODEL || true)"
  [ -n "$_md_pin_fb" ] || return 0

  _md_pin="ANTHROPIC_DEFAULT_FABLE_MODEL=\"$_md_pin_fb\""
  _md_pin_name="$(models_env_get "$1" ANTHROPIC_DEFAULT_FABLE_MODEL_NAME || true)"
  [ -n "$_md_pin_name" ] && _md_pin="${_md_pin}
ANTHROPIC_DEFAULT_FABLE_MODEL_NAME=\"$_md_pin_name\""
  _md_pin_caps="$(models_env_get "$1" ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES || true)"
  [ -n "$_md_pin_caps" ] && _md_pin="${_md_pin}
ANTHROPIC_DEFAULT_FABLE_MODEL_SUPPORTED_CAPABILITIES=\"$_md_pin_caps\""
  _md_pin="${_md_pin}
ANTHROPIC_DEFAULT_FABLE_MODEL_PIN=\"1\""
  printf '%s\n' "$_md_pin"
}

# 0 = models.env present and current, 1 = not written (caller records it).
# $1 state dir, $2 force (1 = --fresh: overwrite even if it exists),
# $3 experimental (1 = fetch with ?experimental=true so betas compete for fable)
models_configure() {
  _md_dir="$1"
  _md_force="$2"
  _md_exp="${3:-0}"
  _md_file="$_md_dir/models.env"

  if [ -f "$_md_file" ] && [ "$_md_force" != 1 ]; then
    models_summary "$_md_file"
    ui_detail "(run ./setup.sh --fresh to refresh)"
    return 0
  fi

  if [ -z "${CORTI_BEARER:-}" ] || [ -z "${CORTI_BASE_URL:-}" ]; then
    ui_skip "no credentials - can't reach Corti to detect models"
    return 1
  fi

  if [ "$_md_force" != 1 ]; then
    if ! ui_is_yes "$(ui_ask "no model mapping yet - detect Corti's current models now? [Y/n]" y n)"; then
      return 1
    fi
  fi

  _md_catalog="$(models_fetch_catalog "$_md_exp")" || return 1

  # Callers set the repo root before sourcing: CC_REPO_DIR from setup.sh, REPO from the tests.
  _md_js="${CC_REPO_DIR:-${REPO:-.}}/lib/models.mjs"
  _md_env="$(node "$_md_js" "$_md_catalog")" || return 1

  # Re-inject the pinned fable block (read from $_md_file before overwrite), replacing what
  # the auto-ranker emitted; otherwise dedupe against the live backend.
  _md_pin="$(models_fable_pin "$_md_file")"
  if [ -n "$_md_pin" ]; then
    _md_env="$(printf '%s\n' "$_md_env" | grep -v '^ANTHROPIC_DEFAULT_FABLE_MODEL'
    printf '%s\n' "$_md_pin")"
  else
    _md_env="$(models_dedupe_fable "$_md_env")"
  fi

  mkdir -p "$_md_dir"
  # Trailing newline: command substitution strips it, and the wrapper sources this file.
  printf '%s\n' "$_md_env" >"$_md_file"
  models_summary "$_md_file"
  ui_wrote "$(ui_tilde "$_md_file")"
  return 0
}
