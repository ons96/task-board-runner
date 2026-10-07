#!/usr/bin/env bash
# failure-reason.sh - Structured failure taxonomy for task-board-runner (#936).
#
# Maps free-form failure text onto a stable canonical label plus a fixed,
# secret-free one-line cause. Raw log text is only ever classifier input:
# only the canonical label and its fixed cause are published to issue
# comments, so credentials or prompt contents can never leak.
#
# Usage:
#   failure-reason.sh --classify "TEXT"   # print canonical label for TEXT
#   failure-reason.sh --cause LABEL       # print fixed one-line cause for LABEL
#   failure-reason.sh --list              # print all canonical labels
#   failure-reason.sh --self-test         # offline tests, one per category
set -uo pipefail

# Canonical taxonomy (#936): auth, rate, timeout, test, no-change, lock,
# validation, provider, and infrastructure failures are all distinguishable;
# execution_failed is the catch-all.
FAILURE_LABELS=(
  auth_failed
  rate_limited
  timeout_exceeded
  tests_failed
  no_work_product
  lock_conflict
  validation_failed
  provider_failed
  infrastructure_failed
  execution_failed
)

# Priority order matters: more specific causes win (e.g. a 401 inside
# provider output classifies as auth_failed). Patterns are matched against
# lowercased text; `*` in case patterns also matches newlines, so multi-line
# log tails classify correctly.
failure_reason() {
  local text
  text="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$text" in
    *401*|*403*|*unauthorized*|*forbidden*|*authentication*|*gh\ auth*|*invalid\ api\ key*|*api_key\ invalid*|*invalid\ credentials*|*permission\ denied*|*access\ denied*)
      printf '%s\n' auth_failed ;;
    *lock\ conflict*|*lock\ contention*|*failed\ to\ lock*|*lock\ failed*|*locked\ by*|*already\ claimed*|*claim\ failed*|*claim\ conflict*|*could\ not\ claim*)
      printf '%s\n' lock_conflict ;;
    *429*|*rate\ limit*|*rate_limit*|*ratelimit*|*quota\ exceeded*|*too\ many\ requests*|*tpm\ limit*|*rpm\ limit*)
      printf '%s\n' rate_limited ;;
    *timeout*|*timed\ out*|*timed-out*|*deadline\ exceeded*|*cancelled*|*canceled*)
      printf '%s\n' timeout_exceeded ;;
    *tests\ failed*|*test\ failed*|*testing\ failed*|*npm\ test*|*pytest*)
      printf '%s\n' tests_failed ;;
    *no\ changes*|*nothing\ to\ commit*|*no\ diff*|*no\ work\ product*|*nothing\ changed*)
      printf '%s\n' no_work_product ;;
    *verification*|*verify*|*log\ too\ small*|*log-only*|*log\ only*|*missing\ agent\ log*|*missing\ --log*|*unresolvable*|*invalid\ baseline*|*cli\ help*|*instead\ of\ running*)
      printf '%s\n' validation_failed ;;
    *provider*|*bad\ gateway*|*service\ unavailable*|*server\ error*|*model\ not\ found*|*overloaded*|*502*|*503*|*504*)
      printf '%s\n' provider_failed ;;
    *infrastructure*|*network*|*connection\ refused*|*connection\ reset*|*no\ space\ left*|*out\ of\ memory*|*disk\ quota*|*read-only\ file\ system*)
      printf '%s\n' infrastructure_failed ;;
    *)
      printf '%s\n' execution_failed ;;
  esac
}

# Fixed, secret-free one-line cause per canonical label.
failure_cause() {
  case "${1:-}" in
    auth_failed)           echo "runner authentication or permissions were rejected" ;;
    rate_limited)          echo "LLM provider rate limit or quota was exhausted" ;;
    timeout_exceeded)      echo "the run exceeded its time budget and was cancelled" ;;
    tests_failed)         echo "repository tests failed during verification" ;;
    no_work_product)      echo "the run produced no changes to commit" ;;
    lock_conflict)        echo "the task was already claimed or could not be locked" ;;
    validation_failed)    echo "the work product failed the verification gate" ;;
    provider_failed)      echo "every configured LLM provider failed" ;;
    infrastructure_failed) echo "a runner infrastructure step failed" ;;
    *)                     echo "the run failed without a classified cause" ;;
  esac
}

if [[ "${1:-}" == --self-test ]]; then
  fails=0
  assert_reason() {
    local desc="$1" text="$2" want="$3" got
    got="$(failure_reason "$text")"
    if [ "$got" = "$want" ]; then
      echo "ok: $desc"
    else
      echo "FAIL: $desc (input '$text' -> '$got', want '$want')"
      fails=$((fails + 1))
    fi
  }

  # One failure-path test per taxonomy category (#936 acceptance criteria).
  assert_reason "auth failure"          "HTTP 401 authentication failed" auth_failed
  assert_reason "auth step failure"     "gh auth status failed: access denied" auth_failed
  assert_reason "rate limit"            "HTTP 429 too many requests, quota exceeded" rate_limited
  assert_reason "timeout failure"      "upstream request timed out after 300s" timeout_exceeded
  assert_reason "run cancellation"      "run cancelled: job or step timeout exceeded" timeout_exceeded
  assert_reason "test failure"          "verification failed: python tests failed" tests_failed
  assert_reason "no-change outcome"     "verification failed: no changes since baseline" no_work_product
  assert_reason "empty worktree"        "no changes detected in worktree" no_work_product
  assert_reason "lock conflict"         "issue already claimed: lock contention" lock_conflict
  assert_reason "validation: log-only"  "verification failed: log-only run, log too small" validation_failed
  assert_reason "validation: gate"     "verification failed: invalid baseline commit" validation_failed
  assert_reason "provider exhaustion"  "ERROR: all configured providers failed" provider_failed
  assert_reason "provider 5xx"          "provider responded 503 service unavailable" provider_failed
  assert_reason "infrastructure"        "infrastructure error: git push or PR step failed" infrastructure_failed
  assert_reason "unclassified"          "unexpected exit code 17" execution_failed

  # Classifier must not misread benign log text as a failure category.
  assert_reason "git author is not auth" "commit author: task-board-runner" execution_failed
  assert_reason "prompt wording is not infra" "do not push or open a PR" execution_failed

  # Every canonical label needs a non-empty fixed cause.
  for label in "${FAILURE_LABELS[@]}"; do
    if [ -n "$(failure_cause "$label")" ]; then
      echo "ok: cause for $label"
    else
      echo "FAIL: no cause for $label"
      fails=$((fails + 1))
    fi
  done

  if [ "$fails" -eq 0 ]; then
    echo "self-test: ALL PASS"
    exit 0
  fi
  echo "self-test: $fails FAILURES"
  exit 1
fi

case "${1:-}" in
  --classify) failure_reason "${2:-}" ;;
  --cause)    failure_cause "${2:-}" ;;
  --list)     printf '%s\n' "${FAILURE_LABELS[@]}" ;;
  *)
    echo "usage: $0 --classify TEXT | --cause LABEL | --list | --self-test" >&2
    exit 2
    ;;
esac
