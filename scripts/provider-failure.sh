#!/usr/bin/env bash
set -euo pipefail

provider_failure_kind() {
  local text=${1,,}
  case "$text" in
    *401*|*403*|*unauthorized*|*invalid\ api\ key*|*authentication*) printf auth_failed ;;
    *429*|*rate.limit*|*quota*|*resource_exhausted*) printf rate_limited ;;
    *timeout*|*timed\ out*|*connection\ reset*|*connection\ refused*|*502*|*503*|*504*|*temporarily\ unavailable*) printf provider_unavailable ;;
    *) printf provider_error ;;
  esac
}

if [[ ${1:-} == --classify ]]; then
  provider_failure_kind "${2:-}"
elif [[ ${1:-} == --self-test ]]; then
  [[ $(provider_failure_kind 'HTTP 401 invalid API key') == auth_failed ]]
  [[ $(provider_failure_kind 'HTTP 429 quota exceeded') == rate_limited ]]
  [[ $(provider_failure_kind 'request timed out') == provider_unavailable ]]
  [[ $(provider_failure_kind 'HTTP 503 temporarily unavailable') == provider_unavailable ]]
  [[ $(provider_failure_kind 'HTTP 200 recovered') == provider_error ]]
  printf 'provider failure self-test: PASS (auth, quota, timeout, outage, recovery)\n'
else
  printf 'usage: %s --classify TEXT | --self-test\n' "$0" >&2
  exit 2
fi
