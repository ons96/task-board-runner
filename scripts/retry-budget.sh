#!/usr/bin/env bash
set -euo pipefail

retry_state() {
  local attempts="$1" budget="$2"
  if (( attempts < budget )); then
    printf '%s\n' requeue
  else
    printf '%s\n' blocked
  fi
}

if [[ "${1:-}" == --self-test ]]; then
  [[ "$(retry_state 0 2)" == requeue ]]
  [[ "$(retry_state 1 2)" == requeue ]]
  [[ "$(retry_state 2 2)" == blocked ]]
  [[ "$(retry_state 3 2)" == blocked ]]
  printf '%s\n' 'retry budget self-test: ALL PASS'
elif [[ "${1:-}" == --state ]]; then
  retry_state "${2:-0}" "${3:-2}"
fi
