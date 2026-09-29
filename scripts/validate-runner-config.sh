#!/usr/bin/env bash
# validate-runner-config.sh - Validate runner-config.json before launching opencode
#
# Usage: ./validate-runner-config.sh <config-path> [--check-model]
#
# Checks:
#   1. Config parses as JSON.
#   2. Compaction settings: auto enabled, bounded preserve_recent_tokens,
#      positive reserved buffer, and no unknown keys (opencode silently
#      drops unknown compaction keys, so typos would otherwise go unnoticed).
#   3. Model is <provider>/<model-id>, its provider is defined in the config
#      with a free-tier baseURL, and (when opencode is installed) opencode
#      accepts the config and the compaction settings survive resolution.
#   4. --check-model: the provider actually serves the model right now
#      (GET $baseURL/models with the configured key) and it is free
#      (models.dev cost input/output == 0 when the provider is indexed).
#
# The compaction summary runs on the session's pinned model, so the model
# checks above double as compaction model/provider verification.
#
# Output: "validate-runner-config: OK ..." on success, failures on stderr.
# Exit 1 on any validation failure.
set -euo pipefail

CONFIG_PATH=""
CHECK_MODEL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-model) CHECK_MODEL=true; shift ;;
    *) CONFIG_PATH="$1"; shift ;;
  esac
done

if [[ -z "$CONFIG_PATH" || ! -f "$CONFIG_PATH" ]]; then
  echo "usage: $0 <config-path> [--check-model]" >&2
  exit 1
fi

# Sanity bounds for pinned compaction values. glm-5.3 has a 1M-token context,
# so these only reject clearly broken values, never valid tuning.
MAX_PRESERVE_RECENT_TOKENS=250000
MAX_RESERVED_TOKENS=100000

# Free-tier provider endpoints allowed by this runner (see README: costs $0).
free_provider_url() {
  case "$1" in
    nvidia) echo "https://integrate.api.nvidia.com/v1" ;;
    dlab) echo "https://api.dlabkeys.com/v1" ;;
    dlab-free) echo "https://api.dlabkeys.com/v1" ;;
    *) echo "" ;;
  esac
}

fail() {
  echo "validate-runner-config: FAIL: $*" >&2
  exit 1
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

jq -e . "$CONFIG_PATH" >/dev/null 2>&1 || fail "config is not valid JSON: $CONFIG_PATH"

# --- Compaction settings -----------------------------------------------------

AUTO=$(jq -r '.compaction.auto // ""' "$CONFIG_PATH")
[[ "$AUTO" == "true" ]] || fail "compaction.auto must be true, got '${AUTO:-<missing>}' (long sessions risk context overflow with it off)"

PRESERVE=$(jq -r '.compaction.preserve_recent_tokens // ""' "$CONFIG_PATH")
is_uint "$PRESERVE" || fail "compaction.preserve_recent_tokens must be a non-negative integer, got '${PRESERVE:-<missing>}' (bounded recent-token preservation must be pinned)"
[[ "$PRESERVE" -gt 0 ]] || fail "compaction.preserve_recent_tokens must be > 0, got $PRESERVE"
[[ "$PRESERVE" -le "$MAX_PRESERVE_RECENT_TOKENS" ]] || fail "compaction.preserve_recent_tokens $PRESERVE exceeds the sanity bound $MAX_PRESERVE_RECENT_TOKENS"

RESERVED=$(jq -r '.compaction.reserved // ""' "$CONFIG_PATH")
is_uint "$RESERVED" || fail "compaction.reserved must be a non-negative integer, got '${RESERVED:-<missing>}' (overflow buffer must be pinned)"
[[ "$RESERVED" -gt 0 ]] || fail "compaction.reserved must be > 0, got $RESERVED"
[[ "$RESERVED" -le "$MAX_RESERVED_TOKENS" ]] || fail "compaction.reserved $RESERVED exceeds the sanity bound $MAX_RESERVED_TOKENS"

TAIL_TURNS=$(jq -r '.compaction.tail_turns // ""' "$CONFIG_PATH")
if [[ -n "$TAIL_TURNS" ]]; then
  is_uint "$TAIL_TURNS" || fail "compaction.tail_turns must be a non-negative integer, got '$TAIL_TURNS'"
fi

UNKNOWN_KEYS=$(jq -r '.compaction // {} | keys[] | select(. != "auto" and . != "prune" and . != "tail_turns" and . != "preserve_recent_tokens" and . != "reserved")' "$CONFIG_PATH")
[[ -z "$UNKNOWN_KEYS" ]] || fail "unknown compaction key(s): $(echo "$UNKNOWN_KEYS" | tr '\n' ' ')— opencode silently drops them; fix the key name"

# --- Model / provider ---------------------------------------------------------

MODEL=$(jq -r '.model // ""' "$CONFIG_PATH")
[[ "$MODEL" =~ ^[a-z0-9-]+/.+$ ]] || fail "model must be <provider>/<model-id>, got '${MODEL:-<missing>}'"
PROVIDER="${MODEL%%/*}"
MODEL_ID="${MODEL#*/}"

BASE_URL=$(jq -r --arg p "$PROVIDER" '.provider[$p].options.baseURL // ""' "$CONFIG_PATH")
[[ -n "$BASE_URL" ]] || fail "provider '$PROVIDER' is not defined in the config (model $MODEL has no home)"

FREE_URL=$(free_provider_url "$PROVIDER")
[[ "$FREE_URL" == "$BASE_URL" ]] || fail "provider '$PROVIDER' baseURL '$BASE_URL' is not a known free-tier endpoint (expected '${FREE_URL:-<none>}')"

# --- Resolved-config check (catches schema violations and dropped keys) -------

if command -v opencode >/dev/null 2>&1; then
  # NOTE: the resolved config contains real API keys — never print it.
  # Route stdout to a file: opencode truncates piped stdout at 64KB, which
  # corrupts large resolved configs (e.g. dev machines with big global configs).
  ERRFILE=$(mktemp)
  RESOLVED_FILE=$(mktemp)
  if ! OPENCODE_PURE=1 OPENCODE_CONFIG_CONTENT="$(cat "$CONFIG_PATH")" \
       opencode debug config >"$RESOLVED_FILE" 2>"$ERRFILE"; then
    MSG=$(tail -n 2 "$ERRFILE" | head -n 1)
    rm -f "$ERRFILE" "$RESOLVED_FILE"
    fail "opencode rejected the config: $MSG"
  fi
  rm -f "$ERRFILE"
  jq -e \
      --argjson preserve "$PRESERVE" --argjson reserved "$RESERVED" --arg m "$MODEL" \
      '(.compaction.auto == true) and (.compaction.preserve_recent_tokens == $preserve) and (.compaction.reserved == $reserved) and (.model == $m)' <"$RESOLVED_FILE" >/dev/null \
    || { rm -f "$RESOLVED_FILE"; fail "resolved config lost compaction settings or model (silently dropped key?)"; }
  rm -f "$RESOLVED_FILE"
else
  echo "validate-runner-config: WARN: opencode not installed, skipping resolved-config check" >&2
fi

# --- Live availability + freeness (--check-model) -----------------------------

if [[ "$CHECK_MODEL" == "true" ]]; then
  KEY_SPEC=$(jq -r --arg p "$PROVIDER" '.provider[$p].options.apiKey // ""' "$CONFIG_PATH")
  [[ "$KEY_SPEC" =~ ^\{env:([A-Za-z_][A-Za-z0-9_]*)\}$ ]] || fail "provider '$PROVIDER' apiKey must be {env:VAR}, got '$KEY_SPEC'"
  KEY_VAR="${BASH_REMATCH[1]}"
  API_KEY="${!KEY_VAR:-}"
  [[ -n "$API_KEY" ]] || fail "env var $KEY_VAR (provider '$PROVIDER') is not set — cannot verify model availability"

  MODELS_JSON=$(curl -fsS --max-time 30 -H "Authorization: Bearer $API_KEY" "$BASE_URL/models") \
    || fail "could not list models at $BASE_URL/models — provider '$PROVIDER' unavailable?"
  echo "$MODELS_JSON" | jq -e --arg m "$MODEL_ID" '(.data // .) | if type == "array" then map(.id) | index($m) else false end' >/dev/null \
    || fail "model '$MODEL_ID' is not currently served by provider '$PROVIDER'"

  if COST_JSON=$(curl -fsS --max-time 30 https://models.dev/api.json 2>/dev/null); then
    COST=$(echo "$COST_JSON" | jq -r --arg p "$PROVIDER" --arg m "$MODEL_ID" '(.[$p].models[$m].cost.input // -1) // -1')
    if [[ "$COST" == "-1" ]]; then
      echo "validate-runner-config: WARN: $MODEL not indexed on models.dev; free-tier status rests on the endpoint allowlist" >&2
    else
      INPUT_COST=$(echo "$COST_JSON" | jq -r --arg p "$PROVIDER" --arg m "$MODEL_ID" '.[$p].models[$m].cost.input // -1')
      OUTPUT_COST=$(echo "$COST_JSON" | jq -r --arg p "$PROVIDER" --arg m "$MODEL_ID" '.[$p].models[$m].cost.output // -1')
      [[ "$INPUT_COST" == "0" && "$OUTPUT_COST" == "0" ]] \
        || fail "model $MODEL is not free (models.dev: input=$INPUT_COST, output=$OUTPUT_COST output) — free-tier only"
    fi
  else
    echo "validate-runner-config: WARN: models.dev unreachable; free-tier status rests on the endpoint allowlist" >&2
  fi
fi

echo "validate-runner-config: OK: compaction auto=true preserve_recent_tokens=$PRESERVE reserved=$RESERVED model=$MODEL"
