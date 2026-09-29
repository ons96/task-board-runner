#!/usr/bin/env bash
# claim-task.sh - Atomically claim the highest-priority available task
#
# Usage: ./claim-task.sh [--worker ID] [--heartbeat SECONDS] [--scope SCOPE]
#
# Output (JSON): { "number": 42, "title": "...", "project": "...", "body": "..." }
# Exit 1 if no tasks available
#
# Locking: Uses locked-by:<worker-id> labels. Race conditions handled by
# re-reading the issue after labeling to confirm ownership.
#
# Stale detection: Run watchdog.sh separately. It detects workers that
# haven't updated their heartbeat within the timeout period and frees
# their tasks.
set -euo pipefail

TASK_BOARD_REPO="${TASK_BOARD_REPO:-ons96/task-board}"
WORKER_ID=""
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-300}"
TASK_ALLOWED_SCOPES="${TASK_ALLOWED_SCOPES:-cross-device}"
LEASE_SECONDS="${LEASE_SECONDS:-3600}"

scope_allowed() {
  local row="$1"
  local issue_scope
  issue_scope=$(echo "$row" | jq -r '[.labels[].name | select(startswith("tag:")) | sub("^tag:";"") | select(. == "cross-device" or . == "device-local" or . == "vps-155" or . == "gateway-40" or . == "github-actions")] | .[0] // ""')

  if [[ -z "$issue_scope" || "$issue_scope" == "cross-device" ]]; then
    return 0
  fi

  IFS=',' read -ra allowed_scopes <<< "$TASK_ALLOWED_SCOPES"
  for allowed in "${allowed_scopes[@]}"; do
    if [[ "$allowed" == "$issue_scope" ]]; then
      return 0
    fi
  done

  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker) WORKER_ID="$2"; shift 2 ;;
    --heartbeat) HEARTBEAT_INTERVAL="$2"; shift 2 ;;
    --scope) TASK_ALLOWED_SCOPES="$2"; shift 2 ;;
    --lease-seconds) LEASE_SECONDS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$WORKER_ID" ]]; then
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    WORKER_ID="gha-${GITHUB_RUN_ID:-unknown}"
  elif [[ -n "${HOSTNAME:-}" ]]; then
    WORKER_ID="local-${HOSTNAME}"
  else
    WORKER_ID="local-$$"
  fi
fi

PRIORITY_ORDER=("priority:P0" "priority:P1" "priority:P2" "priority:P3" "priority:P4" "priority:P5" "priority:P6" "priority:P7" "priority:P8" "priority:P9")

for prio_label in "${PRIORITY_ORDER[@]}"; do
  ISSUES=$(gh issue list -R "$TASK_BOARD_REPO" \
    --label "status:new" \
    --label "$prio_label" \
    --json number,title,labels,body \
    --limit 10 2>/dev/null || echo "[]")

  COUNT=$(echo "$ISSUES" | jq 'length')
  if [[ "$COUNT" -eq 0 ]]; then
    continue
  fi

  INDEX=0
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    if ! scope_allowed "$row"; then
      continue
    fi
    ISSUE_NUM=$(echo "$row" | jq -r '.number')
    ISSUE_TITLE=$(echo "$row" | jq -r '.title')
    ISSUE_BODY=$(echo "$row" | jq -r '.body')

    LOCK_LABEL="locked-by:${WORKER_ID}"
    LEASE_LABEL="lease-until:$(( $(date +%s) + LEASE_SECONDS ))"

    gh label create "$LOCK_LABEL" -R "$TASK_BOARD_REPO" --color "BFD4F2" >/dev/null 2>&1 || true
    gh label create "$LEASE_LABEL" -R "$TASK_BOARD_REPO" --color "BFD4F2" >/dev/null 2>&1 || true

    gh issue edit "$ISSUE_NUM" -R "$TASK_BOARD_REPO" \
      --add-label "status:in_progress" \
      --add-label "$LOCK_LABEL" \
      --add-label "$LEASE_LABEL" \
      --remove-label "status:new" >/dev/null 2>&1 || continue

    sleep 2

    CURRENT_LOCK=$(gh issue view "$ISSUE_NUM" -R "$TASK_BOARD_REPO" \
      --json labels --jq '.labels[] | select(.name | startswith("locked-by:")) | .name' 2>/dev/null || echo "")

    if [[ "$CURRENT_LOCK" != "$LOCK_LABEL" ]]; then
      echo "Issue #$ISSUE_NUM already claimed by $CURRENT_LOCK, skipping" >&2
      continue
    fi

    PROJECT="unknown"
    for lbl in $(echo "$row" | jq -r '.labels[].name'); do
      if [[ "$lbl" == project:* ]]; then
        PROJECT="${lbl#project:}"
        break
      fi
    done
    if [[ "$PROJECT" == "unknown" ]]; then
      echo "Issue #$ISSUE_NUM has no project label, skipping" >&2
      gh issue edit "$ISSUE_NUM" -R "$TASK_BOARD_REPO" \
        --remove-label "status:in_progress" --add-label "status:new" \
        --remove-label "$LOCK_LABEL" >/dev/null 2>&1 || true
      continue
    fi

    gh issue comment "$ISSUE_NUM" -R "$TASK_BOARD_REPO" \
      --body "Claimed by \`${WORKER_ID}\` at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >/dev/null 2>&1 || true

    echo "$row" | jq -c \
      --arg worker "$WORKER_ID" \
      --arg project "$PROJECT" \
      '. + {worker: $worker, project: $project}'

    exit 0
    INDEX=$((INDEX + 1))
  done < <(echo "$ISSUES" | jq -c '.[]')
done

echo "No available tasks" >&2
exit 1
