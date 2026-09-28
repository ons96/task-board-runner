#!/usr/bin/env bash
# requeue-task.sh - Release a claimed task and requeue it with a bounded
# retry budget (task-board #933: no infinite requeue).
#
# Every release path (worker failure, verify-gate failure, no-change runs,
# stale-lock sweeps, dispatcher rollbacks) funnels through this script so a
# repeatedly failing task can never loop in the queue forever. Retry
# attempts are counted from the issue's own history: every release comment
# carries the marker "re-queued" — including the historical "re-queued for
# retry" and "re-queued as status:new" wordings — so counting also sees
# attempts made before this script existed. Once the budget is reached the
# issue is labeled blocked:repeated-failure and left open for a human
# instead of going back to status:new.
#
# Usage:
#   requeue-task.sh --issue N --lock LABEL --reason "TEXT"
#                   [--budget N] [--repo OWNER/REPO]
#   requeue-task.sh --self-test   # offline assertions, no network needed
#
# Exit 0 after the release (requeue or blocked); label edits and comments
# are best-effort because this runs in cleanup paths. Exit 2 on usage
# error, exit 1 on self-test failure.
set -uo pipefail

TASK_BOARD_REPO="${TASK_BOARD_REPO:-ons96/task-board}"
RETRY_BUDGET="${RETRY_BUDGET:-3}"
ISSUE=""
LOCK=""
REASON="unknown"
SELF_TEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue) ISSUE="$2"; shift 2 ;;
    --lock) LOCK="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --budget) RETRY_BUDGET="$2"; shift 2 ;;
    --repo) TASK_BOARD_REPO="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- pure decision helpers (self-tested offline) ---------------------------

retry_action() {
  # $1 = retry attempts already consumed, $2 = budget.
  # "requeue" while attempts remain, "blocked" at the budget.
  if [ "$1" -lt "$2" ]; then
    printf 'requeue\n'
  else
    printf 'blocked\n'
  fi
}

requeue_comment() {
  # $1 = attempt number, $2 = budget, $3 = reason. Keeps the historical
  # "re-queued" marker so the next release can count this attempt.
  printf 'released the task due to %s; re-queued for retry (attempt %s of %s).\n' \
    "$3" "$1" "$2"
}

blocked_comment() {
  # $1 = budget, $2 = reason. Must NOT contain the retry marker.
  printf 'retry budget exhausted after %s attempts; marking blocked:repeated-failure so the task stops looping. Remove the label and re-add status:new to re-arm. Last failure: %s\n' \
    "$1" "$2"
}

matches_retry_marker() {
  printf '%s' "$1" | grep -Eiq 're-queued'
}

# --- offline self-test ------------------------------------------------------

if [ "$SELF_TEST" = "1" ]; then
  fails=0
  check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok: $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
  check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL: $d"; fails=$((fails+1)); else echo "ok: $d"; fi; }

  check "under-budget release requeues" test "$(retry_action 0 3)" = requeue
  check "last-budget release requeues" test "$(retry_action 2 3)" = requeue
  check "at-budget release blocks" test "$(retry_action 3 3)" = blocked
  check "over-budget release blocks" test "$(retry_action 9 3)" = blocked
  check "zero budget blocks immediately" test "$(retry_action 0 0)" = blocked

  RC="$(requeue_comment 1 3 "tests failed")"
  check "requeue comment keeps retry marker" matches_retry_marker "$RC"
  check "requeue comment names the attempt" \
    test "$RC" = "released the task due to tests failed; re-queued for retry (attempt 1 of 3)."
  BC="$(blocked_comment 3 "tests failed")"
  check_not "blocked comment omits retry marker" matches_retry_marker "$BC"
  check "blocked comment names the reason" grep -q "Last failure: tests failed" <<<"$BC"
  check "blocked comment says how to re-arm" grep -q "status:new" <<<"$BC"

  # Historical release wordings must keep counting as attempts.
  check "worker release comment counts" \
    matches_retry_marker "Worker 36301918518 released the task due to no changes; re-queued for retry."
  check "sweeper release comment counts" \
    matches_retry_marker "Sweeper released stale lock \`locked-by:gha-1\` (age 4000s). Re-queued as status:new."
  check "dispatcher release comment counts" \
    matches_retry_marker "Dispatcher failed to start worker; re-queued as status:new."
  check_not "ordinary comment does not count" \
    matches_retry_marker "Opened PR: https://github.com/ons96/task-board-runner/pull/2"

  [ "$fails" = "0" ] && { echo "requeue self-test: ALL PASS"; exit 0; }
  echo "requeue self-test: $fails FAILURES"
  exit 1
fi

# --- online release ---------------------------------------------------------

if [ -z "$ISSUE" ]; then
  echo "missing --issue" >&2
  exit 2
fi
if ! [[ "$RETRY_BUDGET" =~ ^[0-9]+$ ]]; then
  echo "invalid --budget: $RETRY_BUDGET" >&2
  exit 2
fi

count_retries() {
  gh issue view "$ISSUE" -R "$TASK_BOARD_REPO" --json comments \
    --jq '[.comments[] | select((.body // "") | test("re-queued"; "i"))] | length' \
    2>/dev/null || printf '0'
}

edit_issue() {
  gh issue edit "$ISSUE" -R "$TASK_BOARD_REPO" "$@" >/dev/null 2>&1 || true
}

ATTEMPTS=$(count_retries)
ACTION=$(retry_action "$ATTEMPTS" "$RETRY_BUDGET")

# Each label edit is best-effort and independent: one missing label or a
# board hiccup must not strand the task in the wrong state.
edit_issue --remove-label "status:in_progress"
[ -n "$LOCK" ] && edit_issue --remove-label "$LOCK"
# Drop any heartbeat lease labels left by a crashed worker (#937 leases).
for LEASE in $(gh issue view "$ISSUE" -R "$TASK_BOARD_REPO" --json labels \
    --jq '.labels[].name | select(startswith("lease-until:"))' 2>/dev/null); do
  edit_issue --remove-label "$LEASE"
done

if [ "$ACTION" = "requeue" ]; then
  edit_issue --add-label "status:new"
  BODY="$(requeue_comment "$((ATTEMPTS + 1))" "$RETRY_BUDGET" "$REASON")"
else
  gh label create "blocked:repeated-failure" -R "$TASK_BOARD_REPO" \
    --color "D73A4A" --description "Retry budget exhausted; needs human review" \
    >/dev/null 2>&1 || true
  edit_issue --add-label "blocked:repeated-failure"
  BODY="$(blocked_comment "$RETRY_BUDGET" "$REASON")"
fi

gh issue comment "$ISSUE" -R "$TASK_BOARD_REPO" --body "$BODY" >/dev/null 2>&1 || true
echo "requeue-task: issue #$ISSUE -> $ACTION (attempts consumed: $ATTEMPTS, budget: $RETRY_BUDGET)"
exit 0
