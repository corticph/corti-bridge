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
  _md_ctx="$(models_env_get "$1" CLAUDE_CODE_MAX_CONTEXT_TOKENS || true)"
  _md_fable="$(models_env_get "$1" ANTHROPIC_DEFAULT_FABLE_MODEL || true)"
  [ -n "$_md_fable" ] && _md_summary_row fable "$_md_fable" "$1" "(your heaviest, beta-tier)"
  _md_summary_row opus "$(models_env_get "$1" ANTHROPIC_DEFAULT_OPUS_MODEL || true)" "$1" "(your heavy model, $_md_ctx ctx)"
  _md_summary_row sonnet "$(models_env_get "$1" ANTHROPIC_DEFAULT_SONNET_MODEL || true)" "$1" ""
  _md_summary_row haiku "$(models_env_get "$1" ANTHROPIC_DEFAULT_HAIKU_MODEL || true)" "$1" "(your fastest)"
  ui_pair "context" "$_md_ctx"
}

# Tier row for models_summary, checks _PIN flag.
_md_summary_row() {
  _md_note="$4"
  _md_pinned="$(models_env_get "$3" "ANTHROPIC_DEFAULT_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_MODEL_PIN" || true)"
  [ "$_md_pinned" = "1" ] && _md_note="${_md_note:+$_md_note, }(pinned)"
  [ -n "$_md_note" ] && _md_disp="$2 $_md_note" || _md_disp="$2"
  ui_pair "$1" "$_md_disp"
  unset _md_note _md_pinned _md_disp
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
    # --experimental only affects a fresh fetch; an existing mapping with no refresh makes it a
    # silent no-op. Say so rather than let the flag look like it did something.
    if [ "${CC_EXPERIMENTAL:-0}" = 1 ]; then
      ui_warn "--experimental needs --fresh to take effect - run: ./setup.sh --fresh --experimental"
    fi
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

models_pick() {
  _mp_exp=0
  _mp_reset=0
  for _mp_arg in "$@"; do
    case "$_mp_arg" in
      --experimental) _mp_exp=1 ;;
      --reset) _mp_reset=1 ;;
      *) ;;
    esac
  done
  unset _mp_arg

  if [ -z "${CORTI_BEARER:-}" ] || [ -z "${CORTI_BASE_URL:-}" ]; then
    echo "corti-claude models: CORTI_BEARER and CORTI_BASE_URL must be set" >&2
    echo "corti-claude models: run 'npx @corti/cli models init', then open a new terminal" >&2
    return 1
  fi

  _mp_dir="${CC_PROXY_CONFIG_DIR:-$HOME/.corti-claude}"
  _mp_file="$_mp_dir/models.env"
  _mp_js="${CC_REPO_DIR:-${REPO:-.}}/lib/models.mjs"

  _mp_catalog="$(models_fetch_catalog "$_mp_exp")" || return 1
  _mp_auto="$(node "$_mp_js" "$_mp_catalog")" || return 1

  if [ "$_mp_reset" = 1 ]; then
    _mp_env="$(models_dedupe_fable "$_mp_auto")"
    mkdir -p "$_mp_dir"
    printf '%s\n' "$_mp_env" >"$_mp_file.tmp" && mv "$_mp_file.tmp" "$_mp_file"
    ui_step "corti-claude models --reset"
    models_summary "$_mp_file"
    ui_wrote "cleared pins -> $(ui_tilde "$_mp_file")"
    return 0
  fi

  _mp_cands="$(node "$_mp_js" --candidates "$_mp_catalog")" || return 1

  ui_step "corti-claude models"
  ui_detail "Fetching Corti's model catalog..."
  ui_detail "Press Enter to keep default, or type a number to choose."

  _mp_picks=""
  for _mp_tier in fable opus sonnet haiku; do
    _mp_role=""
    case "$_mp_tier" in
      fable) _mp_role="(your heaviest model)" ;;
      opus) _mp_role="" ;;
      sonnet) _mp_role="" ;;
      haiku) _mp_role="(your fastest)" ;;
    esac

    _mp_tierkey="ANTHROPIC_DEFAULT_$(printf '%s' "$_mp_tier" | tr '[:lower:]' '[:upper:]')_MODEL"
    _mp_default="$(models_env_get "$_mp_file" "$_mp_tierkey" 2>/dev/null || true)"
    [ -n "$_mp_default" ] || _mp_default="$(printf '%s\n' "$_mp_auto" | sed -n "s/^$_mp_tierkey=\"\\(.*\\)\"\$/\\1/p" | head -1)"
    _mp_pinned="$(models_env_get "$_mp_file" "${_mp_tierkey}_PIN" 2>/dev/null || true)"

    # Menu sort (beta, id) differs from auto-rank (SHAPES); default prompt to auto-rank position.
    _mp_auto_id="$(printf '%s\n' "$_mp_auto" | sed -n "s/^$_mp_tierkey=\"\\(.*\\)\"\$/\\1/p" | head -1)"
    _mp_n=0
    _mp_menu=""
    _mp_default_n=1
    for _mp_cand in $(printf '%s\n' "$_mp_cands" | grep "^$_mp_tier	" | cut -f2); do
      _mp_n=$((_mp_n + 1))
      _mp_menu="${_mp_menu}      ${_mp_n}) $_mp_cand\n"
      [ "$_mp_cand" != "$_mp_auto_id" ] || _mp_default_n=$_mp_n
    done
    unset _mp_cand

    if [ "$_mp_n" = 0 ]; then
      [ "$_mp_tier" != fable ] || continue
      ui_warn "no candidate models for the $_mp_tier tier - keeping the default"
      continue
    fi

    # Single candidate — no point asking, just report it.
    if [ "$_mp_n" = 1 ]; then
      _mp_picked="$_mp_auto_id"
      if [ "$_mp_pinned" = "1" ]; then
        ui_detail "$_mp_tier: $_mp_auto_id (pinned, only option)"
      else
        ui_detail "$_mp_tier: $_mp_auto_id (only option)"
      fi
    else
      ui_blank
      ui_step "$_mp_tier  $_mp_role"
      ui_detail "Available:"
      printf '%b' "$_mp_menu" >&2
      ui_blank
      if [ "$_mp_pinned" = "1" ]; then
        ui_detail "Current: $_mp_default (pinned)"
      else
        ui_detail "Current: $_mp_default"
      fi

      # Default = the auto-rank pick's position; press Enter → no change → no pin.
      _mp_choice="$(ui_ask "Choice [$_mp_default_n]:" "$_mp_default_n" "$_mp_default_n")"
      case "$_mp_choice" in
        ''|*[!0-9]*) _mp_choice=$_mp_default_n ;;
      esac
      [ "$_mp_choice" -ge 1 ] 2>/dev/null && [ "$_mp_choice" -le "$_mp_n" ] 2>/dev/null || _mp_choice=$_mp_default_n

      # Resolve the chosen id from the menu (re-walk the candidate list to the nth).
      _mp_picked="$_mp_auto_id"
      _mp_i=1
      for _mp_cand in $(printf '%s\n' "$_mp_cands" | grep "^$_mp_tier	" | cut -f2); do
        if [ "$_mp_i" = "$_mp_choice" ]; then _mp_picked="$_mp_cand"; break; fi
        _mp_i=$((_mp_i + 1))
      done
      unset _mp_cand _mp_i
    fi

    # A choice differing from auto-rank is a pin. Choosing the auto-rank value unpins.
    if [ "$_mp_picked" != "$_mp_auto_id" ]; then
      _mp_picks="${_mp_picks:+$_mp_picks,}$_mp_tier=$_mp_picked"
    fi
  done
  unset _mp_tier _mp_role _mp_tierkey _mp_default _mp_pinned _mp_n _mp_menu _mp_default_n _mp_choice _mp_picked _mp_auto_id

  # Emit the full models.env: --emit overlays the picks on auto-rank (unpicked tiers fall through).
  _mp_env="$(node "$_mp_js" --emit "$_mp_catalog" "$_mp_picks")" || return 1

  # Append _PIN=1 for each pinned tier (the shell's job; models.mjs emits the ranker shape only).
  # Order in the file doesn't matter — the wrapper sources the whole file — so pins go at the end,
  # appended portably rather than spliced after each caps line (sed /a/ diverges BSD/GNU).
  _mp_pins=""
  for _mp_tier in fable opus sonnet haiku; do
    case ",$_mp_picks," in
      *",$_mp_tier="*)
        _mp_tierkey="ANTHROPIC_DEFAULT_$(printf '%s' "$_mp_tier" | tr '[:lower:]' '[:upper:]')_MODEL"
        _mp_pins="${_mp_pins}${_mp_pins:+
}${_mp_tierkey}_PIN=\"1\""
        ;;
    esac
  done
  unset _mp_tier _mp_tierkey
  [ -n "$_mp_pins" ] && _mp_env="$(printf '%s\n%s\n' "$_mp_env" "$_mp_pins")"
  unset _mp_pins

  # Fable dedup runs only when fable is unpinned (a pinned fable is served regardless).
  _mp_fable_pinned=0
  case ",$_mp_picks," in
    *",fable="*) _mp_fable_pinned=1 ;;
  esac
  [ "$_mp_fable_pinned" = 1 ] || _mp_env="$(models_dedupe_fable "$_mp_env")"
  unset _mp_fable_pinned

  mkdir -p "$_mp_dir"
  printf '%s\n' "$_mp_env" >"$_mp_file.tmp" && mv "$_mp_file.tmp" "$_mp_file"

  ui_blank
  ui_detail "==> Saving"
  models_summary "$_mp_file"
  ui_wrote "$(ui_tilde "$_mp_file")"
  ui_detail "Changes take effect on your next corti-claude session."
  return 0
}
