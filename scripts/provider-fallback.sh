#!/usr/bin/env bash
set -euo pipefail

provider_failure_kind() {
  local output_file="$1"
  if grep -Eiq '(^|[^0-9])(401|403)([^0-9]|$)|unauthori[sz]ed|invalid.*(api|key)|authentication' "$output_file"; then
    printf '%s\n' auth_failed
  elif grep -Eiq '(^|[^0-9])(429)([^0-9]|$)|rate.?limit|quota|too many requests' "$output_file"; then
    printf '%s\n' rate_limited
  elif grep -Eiq 'timeout|timed out|connection (reset|refused)|temporary failure|502|503|504|upstream' "$output_file"; then
    printf '%s\n' transient_error
  else
    printf '%s\n' provider_error
  fi
}

provider_backoff_seconds() {
  local streak="$1"
  local delay=$((5 ** (streak < 3 ? streak : 3)))
  (( delay > 30 )) && delay=30
  printf '%s\n' "$delay"
}

case "${1:-}" in
  --classify)
    provider_failure_kind "$2"
    exit 0
    ;;
  --backoff)
    provider_backoff_seconds "$2"
    exit 0
    ;;
  --self-test)
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  printf 'HTTP 429 rate limit\n' > "$tmp/429"
  printf 'HTTP 401 unauthorized\n' > "$tmp/401"
  printf 'upstream timeout\n' > "$tmp/timeout"
  printf 'provider healthy\n' > "$tmp/ok"
  [[ "$(provider_failure_kind "$tmp/429")" == rate_limited ]]
  [[ "$(provider_failure_kind "$tmp/401")" == auth_failed ]]
  [[ "$(provider_failure_kind "$tmp/timeout")" == transient_error ]]
  [[ "$(provider_failure_kind "$tmp/ok")" == provider_error ]]
  [[ "$(provider_backoff_seconds 0)" == 1 ]]
  [[ "$(provider_backoff_seconds 1)" == 5 ]]
  [[ "$(provider_backoff_seconds 2)" == 25 ]]
  [[ "$(provider_backoff_seconds 3)" == 30 ]]
  printf '%s\n' 'provider fallback self-test: ALL PASS'
    ;;
esac
