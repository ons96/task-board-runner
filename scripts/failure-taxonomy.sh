#!/usr/bin/env bash
# failure-taxonomy.sh - Canonical failure classes for task-board-runner (task-board #936)
#
# Classifies every non-success runner exit into one stable class so failures
# are distinguishable from labels alone, without reading full run logs.
#
# Classes (canonical, closed set):
#   auth           credentials/token/401/403 problems
#   provider       all upstream providers failed (model/endpoint layer)
#   timeout        run or step exceeded its time budget
#   validation     runner config/schema validation failed
#   test           work product existed but tests failed
#   no_change      run produced no diff/commits/log (verify-gate no-op)
#   lock           claim/lock contention or lost lock
#   infrastructure anything else (runner, network, GitHub, setup errors)
#
# Usage:
#   failure-taxonomy.sh --classify [--log FILE] [--verify-reason R]
#                       [--job-status S] [--has-changes BOOL]
#   failure-taxonomy.sh --label CLASS        # print canonical label (runner-fail:CLASS)
#   failure-taxonomy.sh --self-test          # fixture cases, no network needed
#
# Output: one class name on stdout. Exit 2 on usage error.
# Safety: never prints log contents or secrets - only the class name.
set -uo pipefail

CLASSES=(auth provider timeout validation test no_change lock infrastructure)
LOG=""
VERIFY_REASON=""
JOB_STATUS="success"
HAS_CHANGES="true"
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --classify) MODE="classify"; shift ;;
    --label) MODE="label"; LABEL_CLASS="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --self-test) MODE="self-test"; shift ;;
    --log) LOG="$2"; shift 2 ;;
    --verify-reason) VERIFY_REASON="$2"; shift 2 ;;
    --job-status) JOB_STATUS="$2"; shift 2 ;;
    --has-changes) HAS_CHANGES="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

is_class() {
  local c
  for c in "${CLASSES[@]}"; do [ "$c" = "$1" ] && return 0; done
  return 1
}

# blob -> class, from log patterns only (ordered: most specific first)
classify_blob() {
  local blob="$1"
  if printf '%s' "$blob" | grep -qiE 'HTTP 40[13]\b|unauthori[sz]ed|bad credentials|gh auth |invalid token|authentication failed|GH_TOKEN.*(missing|expired)'; then
    echo auth; return
  fi
  if printf '%s' "$blob" | grep -qiE 'timed out|timeout exceeded|context deadline|ETIMEDOUT|job exceeded the maximum'; then
    echo timeout; return
  fi
  if printf '%s' "$blob" | grep -qiE 'validate-runner-config|invalid (json|config)|schema (error|violation)|runner config (error|invalid)'; then
    echo validation; return
  fi
  if printf '%s' "$blob" | grep -qiE 'already claimed by|lock (contention|lost|expired)|leased by'; then
    echo lock; return
  fi
  if printf '%s' "$blob" | grep -qiE 'all configured providers failed|provider_failure kind=|no eligible deployment|rate_limit_streak'; then
    echo provider; return
  fi
  echo ""
}

classify() {
  # Structured signals first - they are authoritative over log grepping.
  if [ "$HAS_CHANGES" != "true" ]; then
    echo no_change
    return
  fi
  case "$VERIFY_REASON" in
    *tests*failed*|*test*failed*|pytest*|*npm*test*) echo test; return ;;
    *"no changes"*|*"no work product"*|*"log too small"*|*"missing agent log"*) echo no_change; return ;;
    *baseline*|*branch*unresolvable*) echo validation; return ;;
  esac
  local blob=""
  if [ -n "$LOG" ] && [ -f "$LOG" ]; then
    # bounded read: classify from the first 512KB, NUL-stripped (binary logs)
    blob="$(head -c 524288 "$LOG" 2>/dev/null | tr -d '\000')"
  fi
  local from_log
  from_log="$(classify_blob "$blob")"
  if [ -n "$from_log" ]; then
    echo "$from_log"
    return
  fi
  if [ "$JOB_STATUS" != "success" ]; then
    echo infrastructure
    return
  fi
  echo infrastructure
}

case "$MODE" in
  classify)
    classify
    exit 0
    ;;
  label)
    CLASS="$LABEL_CLASS"
    if ! is_class "$CLASS"; then
      echo "unknown class: $CLASS (expected one of: ${CLASSES[*]})" >&2
      exit 2
    fi
    echo "runner-fail:$CLASS"
    exit 0
    ;;
  self-test)
    fails=0
    check_eq() { # check_eq "desc" "expected" "actual"
      if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected=$2 got=$3)"; fails=$((fails+1)); fi
    }
    tmp="$(mktemp -d /tmp/fttest.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    check_eq "no-change signal wins" no_change "$(bash "$0" --classify --has-changes false)"
    check_eq "verify tests-failed -> test" test "$(bash "$0" --classify --verify-reason 'verification failed: tests failed')"
    check_eq "verify no changes -> no_change" no_change "$(bash "$0" --classify --has-changes true --verify-reason 'no changes since baseline')"
    check_eq "verify log too small -> no_change" no_change "$(bash "$0" --has-changes true --verify-reason 'log too small (33 bytes)' --classify)"
    check_eq "verify bad baseline -> validation" validation "$(bash "$0" --has-changes true --verify-reason 'invalid baseline commit' --classify)"

    printf 'HTTP 401: Bad credentials from gh auth login\n' > "$tmp/auth.log"
    check_eq "auth log -> auth" auth "$(bash "$0" --classify --log "$tmp/auth.log")"
    printf 'step "Run opencode" timed out after 40m\n' > "$tmp/timeout.log"
    check_eq "timeout log -> timeout" timeout "$(bash "$0" --classify --log "$tmp/timeout.log")"
    printf 'runner config invalid: schema violation in compaction pin\n' > "$tmp/val.log"
    check_eq "validation log -> validation" validation "$(bash "$0" --classify --log "$tmp/val.log")"
    printf 'Issue #5 already claimed by locked-by:gha-9\n' > "$tmp/lock.log"
    check_eq "lock log -> lock" lock "$(bash "$0" --classify --log "$tmp/lock.log")"
    printf 'ERROR: all configured providers failed\nprovider_failure kind=rate_limited model=x\n' > "$tmp/provider.log"
    check_eq "provider log -> provider" provider "$(bash "$0" --classify --log "$tmp/provider.log")"
    printf 'random runner stack trace\nconnection reset\n' > "$tmp/infra.log"
    check_eq "unknown failure -> infrastructure" infrastructure "$(bash "$0" --classify --log "$tmp/infra.log")"
    check_eq "missing log -> infrastructure" infrastructure "$(bash "$0" --classify --log "$tmp/nope.log" --job-status failure)"
    printf 'HTTP 403 forbidden\x00\x01 trailing\n' > "$tmp/nul.log"
    check_eq "binary/NUL log handled" auth "$(bash "$0" --classify --log "$tmp/nul.log")"

    # --label contract
    check_eq "label format" "runner-fail:auth" "$(bash "$0" --label auth)"
    bad="$(bash "$0" --label not-a-class 2>/dev/null || true)"
    check_eq "unknown class rejected" "" "$bad"

    [ "$fails" = "0" ] && { echo "self-test: ALL PASS"; exit 0; } || { echo "self-test: $fails FAILURES"; exit 1; }
    ;;
  *)
    echo "usage: failure-taxonomy.sh --classify|--label CLASS|--self-test" >&2
    exit 2
    ;;
esac
