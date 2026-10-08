#!/usr/bin/env bash
set -euo pipefail

provider_failure_kind() {
  local input=${1:-}
  local text
  if [[ -f $input ]]; then
    text=$(cat "$input")
  else
    text=$input
  fi
  text=${text,,}
  case "$text" in
    *401*|*403*|*unauthorized*|*invalid\ api\ key*|*authentication*) printf auth_failed ;;
    *429*|*rate.limit*|*quota*|*resource_exhausted*) printf rate_limited ;;
    *timeout*|*timed\ out*|*connection\ reset*|*connection\ refused*|*502*|*503*|*504*|*temporarily\ unavailable*) printf provider_unavailable ;;
    *) printf provider_error ;;
  esac
}

provider_backoff_seconds() {
  local streak=${1:-0}
  local delay=$((5 ** (streak < 3 ? streak : 3)))
  (( delay > 30 )) && delay=30
  printf '%s\n' "$delay"
}

if [[ ${1:-} == --classify ]]; then
  provider_failure_kind "${2:-}"
elif [[ ${1:-} == --backoff ]]; then
  provider_backoff_seconds "${2:-0}"
elif [[ ${1:-} == --self-test ]]; then
  [[ $(provider_failure_kind 'HTTP 401 invalid API key') == auth_failed ]]
  [[ $(provider_failure_kind 'HTTP 429 quota exceeded') == rate_limited ]]
  [[ $(provider_failure_kind 'request timed out') == provider_unavailable ]]
  [[ $(provider_failure_kind 'HTTP 503 temporarily unavailable') == provider_unavailable ]]
  [[ $(provider_failure_kind 'HTTP 200 recovered') == provider_error ]]
  [[ $(provider_backoff_seconds 0) == 1 ]]
  [[ $(provider_backoff_seconds 1) == 5 ]]
  [[ $(provider_backoff_seconds 2) == 25 ]]
  [[ $(provider_backoff_seconds 3) == 30 ]]
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  printf 'HTTP 429 rate limit\n' > "$tmp"
  [[ $(provider_failure_kind "$tmp") == rate_limited ]]
  printf 'provider failure self-test: PASS (auth, quota, timeout, outage, recovery, backoff, file-input)\n'
else
  printf 'usage: %s --classify TEXT | --self-test\n' "$0" >&2
  exit 2
fi
