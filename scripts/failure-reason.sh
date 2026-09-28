#!/usr/bin/env bash
set -euo pipefail

failure_reason() {
  local text="$1"
  case "$text" in
    *auth*|*401*|*403*) printf '%s\n' auth_failed ;;
    *429*|*rate*limit*|*quota*) printf '%s\n' rate_limited ;;
    *timeout*|*timed*out*|*502*|*503*|*504*) printf '%s\n' provider_unavailable ;;
    *test*fail*|*pytest*|*npm\ test*) printf '%s\n' tests_failed ;;
    *no\ changes*|*no\ work*) printf '%s\n' no_work_product ;;
    *lock*|*claim*) printf '%s\n' lock_conflict ;;
    *) printf '%s\n' execution_failed ;;
  esac
}

if [[ "${1:-}" == --self-test ]]; then
  [[ "$(failure_reason 'HTTP 401 authentication failed')" == auth_failed ]]
  [[ "$(failure_reason 'HTTP 429 quota exceeded')" == rate_limited ]]
  [[ "$(failure_reason 'upstream timeout')" == provider_unavailable ]]
  [[ "$(failure_reason 'pytest test failed')" == tests_failed ]]
  [[ "$(failure_reason 'no changes detected')" == no_work_product ]]
  [[ "$(failure_reason 'lock conflict')" == lock_conflict ]]
  [[ "$(failure_reason 'unexpected exit')" == execution_failed ]]
  printf '%s\n' 'failure taxonomy self-test: ALL PASS'
elif [[ "${1:-}" == --classify ]]; then
  failure_reason "${2:-}"
fi
