#!/usr/bin/env bash
# lock-lease.sh - Timestamped lock leases for task-board-runner (task-board #937)
#
# Every lock acquisition records an unambiguous lease marker: a
# `lease:<unix-epoch>` label on the issue, set when the claim is confirmed.
# The dispatcher sweep releases a lock only when its lease is provably past
# the documented timeout; a fresh lease (or a healthy renewing worker) is
# never released. Workers renew or safely release their lease; cancel and
# failure paths release idempotently (removing a missing label is a no-op).
#
# Usage:
#   lock-lease.sh --mark [NOW]           # print lease:<NOW> label (NOW=epoch, default date +%s)
#   lock-lease.sh --parse LABEL          # print epoch from lease:<epoch>, exit 1 if not a lease label
#   lock-lease.sh --state EPOCH NOW TTL  # print fresh | expired | invalid
#   lock-lease.sh --renew ISSUE [NOW]    # gh: replace lease label with lease:<NOW> (worker renewal)
#   lock-lease.sh --self-test            # fixture cases, no network needed
#
# Documented timeout: LEASE_TTL seconds (default 14400 = 4h). A 45-minute
# serial queue can back up behind live work, so 4h avoids releasing it;
# anything provably older than the lease timeout is half-alive and freed.
#
# Safety: never releases a lock whose lease is fresh or whose lease marker
# is absent (legacy locks fall back to the sweep's updatedAt rule).
set -uo pipefail

MODE=""
LEASE_TTL="${LEASE_TTL:-14400}"
TASK_BOARD_REPO="${TASK_BOARD_REPO:-ons96/task-board}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mark) MODE="mark"; NOW="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --parse) MODE="parse"; PARSE_LABEL="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
    --state) MODE="state"; S_EPOCH="${2:-}"; S_NOW="${3:-}"; [ $# -ge 4 ] && S_TTL="$4"; shift; [ $# -gt 0 ] && shift; [ $# -gt 0 ] && shift; [ $# -gt 0 ] && shift ;;
    --renew) MODE="renew"; R_ISSUE="${2:-}"; R_NOW="${3:-}"; shift; [ $# -gt 0 ] && shift; [ $# -gt 0 ] && shift ;;
    --self-test) MODE="self-test"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

is_epoch() { [[ "${1:-}" =~ ^[0-9]{10,}$ ]]; }
is_secs() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# lease_state EPOCH NOW TTL -> fresh | expired | invalid (stdout; exit 0 always)
lease_state() {
  local epoch="$1" now="$2" ttl="$3"
  is_epoch "$epoch" && is_epoch "$now" && is_secs "$ttl" || { echo invalid; return; }
  if [ $((now - epoch)) -gt "$ttl" ]; then
    echo expired
  else
    echo fresh
  fi
}

case "$MODE" in
  mark)
    NOW="${NOW:-}"
    is_epoch "$NOW" || NOW="$(date -u +%s)"
    echo "lease:$NOW"
    exit 0
    ;;
  parse)
    case "${PARSE_LABEL:-}" in
      lease:*)
        EPOCH="${PARSE_LABEL#lease:}"
        if is_epoch "$EPOCH"; then echo "$EPOCH"; exit 0; fi
        exit 1
        ;;
      *) exit 1 ;;
    esac
    ;;
  state)
    lease_state "${S_EPOCH:-}" "${S_NOW:-}" "${S_TTL-$LEASE_TTL}"
    exit 0
    ;;
  renew)
    EPOCH="${R_NOW:-}"
    is_epoch "$EPOCH" || EPOCH="$(date -u +%s)"
    if [ -z "${R_ISSUE:-}" ]; then echo "missing issue number" >&2; exit 2; fi
    gh issue view "$R_ISSUE" -R "$TASK_BOARD_REPO" --json labels \
      --jq '.labels[].name | select(startswith("lease:"))' 2>/dev/null | while read -r OLD; do
        [ -n "$OLD" ] && gh issue edit "$R_ISSUE" -R "$TASK_BOARD_REPO" --remove-label "$OLD" >/dev/null 2>&1 || true
      done
    gh label create "lease:$EPOCH" -R "$TASK_BOARD_REPO" --color "BFD4F2" >/dev/null 2>&1 || true
    gh issue edit "$R_ISSUE" -R "$TASK_BOARD_REPO" --add-label "lease:$EPOCH" >/dev/null 2>&1 || true
    echo "lease:$EPOCH"
    exit 0
    ;;
  self-test)
    fails=0
    check_eq() {
      if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (expected=$2 got=$3)"; fails=$((fails+1)); fi
    }
    check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok: $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
    check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL: $d"; fails=$((fails+1)); else echo "ok: $d"; fi; }

    check_eq "mark with explicit now" "lease:1700000000" "$(bash "$0" --mark 1700000000)"
    MARK="$(bash "$0" --mark)"
    check "mark default emits lease:<epoch>" bash -c "bash '$0' --parse '$MARK'"
    check "parse lease label" bash "$0" --parse "lease:1700000000"
    check_eq "parse yields epoch" "1700000000" "$(bash "$0" --parse "lease:1700000000")"
    check_not "parse rejects non-lease label" bash "$0" --parse "locked-by:gha-1"
    check_not "parse rejects malformed epoch" bash "$0" --parse "lease:soon"
    check_not "parse rejects empty" bash "$0" --parse ""

    # fresh / expired / invalid states (TTL=14400)
    check_eq "fresh lease is fresh" fresh "$(bash "$0" --state 1700000000 1700000000 14400)"
    check_eq "lease within ttl is fresh" fresh "$(bash "$0" --state 1700000000 1700014400 14400)"
    check_eq "lease past ttl is expired" expired "$(bash "$0" --state 1700000000 1700014401 14400)"
    check_eq "half-alive lease is expired" expired "$(bash "$0" --state 1700000000 1700040000 14400)"
    check_eq "clock-skew future lease is fresh" fresh "$(bash "$0" --state 1700009999 1700000000 14400)"
    check_eq "missing epoch is invalid" invalid "$(bash "$0" --state "" 1700000000 14400)"
    check_eq "garbage epoch is invalid" invalid "$(bash "$0" --state abc 1700000000 14400)"
    check_eq "garbage now is invalid" invalid "$(bash "$0" --state 1700000000 x 14400)"
    check_eq "garbage ttl is invalid" invalid "$(bash "$0" --state 1700000000 1700000000 soon)"
    check_eq "empty ttl is invalid" invalid "$(bash "$0" --state 1700000000 1700000000 "")"

    [ "$fails" = "0" ] && { echo "self-test: ALL PASS"; exit 0; } || { echo "self-test: $fails FAILURES"; exit 1; }
    ;;
  *)
    echo "usage: lock-lease.sh --mark|--parse LABEL|--state EPOCH NOW TTL|--renew ISSUE|--self-test" >&2
    exit 2
    ;;
esac
