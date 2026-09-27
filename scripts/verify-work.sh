#!/usr/bin/env bash
# verify-work.sh - Verification gate for task-board-runner workers.
#
# Port of verify_work() from task-board-loop/task-board-loop.sh (PRs #13/#14,
# issue #841): an agent run counts as success ONLY if this attempt produced a
# real work product plus verification. Substantial logs without a diff,
# log-only runs, failed tests, and missing commits all FAIL, and the caller
# requeues the task instead of marking it done.
#
# Usage:
#   verify-work.sh --log LOG --worktree WT --branch BRANCH --base BASE
#                  [--min-log-bytes N] [--reason-file PATH]
#   verify-work.sh --self-test   # false-done cases, no network needed
#
# Exit 0 = pass, 1 = fail, 2 = usage error. On fail the reason is written to
# --reason-file (default $VERIFY_REASON_FILE or /tmp/verify-reason) so the
# caller can surface it in the requeue comment.
set -uo pipefail

MIN_LOG_BYTES=200
LOG=""
WT="."
BRANCH=""
BASE=""
REASON_FILE="${VERIFY_REASON_FILE:-/tmp/verify-reason}"
SELF_TEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) LOG="$2"; shift 2 ;;
    --worktree) WT="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --min-log-bytes) MIN_LOG_BYTES="$2"; shift 2 ;;
    --reason-file) REASON_FILE="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

fail() {
  echo "$1" > "$REASON_FILE"
  echo "verify FAIL: $1" >&2
  return 1
}

verify() {
  [ -n "$LOG" ] || { fail "missing --log"; return 1; }
  [ -f "$LOG" ] || { fail "missing agent log"; return 1; }
  local bytes
  bytes=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  [ "$bytes" -ge "$MIN_LOG_BYTES" ] || { fail "log too small (${bytes} bytes)"; return 1; }
  [ -n "$BRANCH" ] && [ -n "$BASE" ] || { fail "missing --branch/--base"; return 1; }
  git -C "$WT" rev-parse --verify "$BRANCH" >/dev/null 2>&1 || { fail "branch $BRANCH unresolvable"; return 1; }
  git -C "$WT" cat-file -e "$BASE^{commit}" 2>/dev/null || { fail "invalid baseline commit"; return 1; }
  local changed commits content
  changed="$(git -C "$WT" status --porcelain 2>/dev/null)"
  commits="$(git -C "$WT" rev-list --count "$BASE..$BRANCH" 2>/dev/null || echo 0)"
  { [ -n "$changed" ] || [ "$commits" -gt 0 ]; } || { fail "no changes since baseline"; return 1; }
  content="$(git -C "$WT" diff --name-only "$BASE" -- 2>/dev/null; git -C "$WT" ls-files --others --exclude-standard 2>/dev/null)"
  { [ -n "$content" ] || [ "$commits" -gt 0 ]; } || { fail "no work product (no diff, no untracked, no new commits)"; return 1; }
  if [ -f "$WT/package.json" ]; then
    (cd "$WT" && npm test -- --silent) || { fail "tests failed"; return 1; }
  elif [ -f "$WT/pyproject.toml" ]; then
    (cd "$WT" && pytest -q) || { fail "python tests failed"; return 1; }
  fi
  echo "OK" > "$REASON_FILE"
  echo "verify PASS"
  return 0
}

if [ "$SELF_TEST" = "1" ]; then
  fails=0
  check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok: $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
  check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL: $d"; fails=$((fails+1)); else echo "ok: $d"; fi; }
  vdir="$(mktemp -d /tmp/vwtest.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$vdir'" EXIT
  if git init -q --bare "$vdir/origin.git" 2>/dev/null && \
     git clone -q "$vdir/origin.git" "$vdir/wt" 2>/dev/null && \
     git -C "$vdir/wt" config user.email t@t && git -C "$vdir/wt" config user.name t && \
     ( echo seed > "$vdir/wt/seed" && git -C "$vdir/wt" add -A && git -C "$vdir/wt" commit -qm seed ) && \
     git -C "$vdir/wt" push -q origin HEAD:main 2>/dev/null && \
     git -C "$vdir/wt" checkout -qb work/1 2>/dev/null; then
    vlog="$vdir/run.log"
    rfile="$vdir/reason"
    printf '%200s' '' > "$vlog"   # 200 bytes of padding, like a real agent log
    base="$(git -C "$vdir/wt" rev-parse HEAD)"
    check_not "no-change outcome fails" bash "$0" --log "$vlog" --worktree "$vdir/wt" --branch work/1 --base "$base" --reason-file "$rfile"
    echo change > "$vdir/wt/seed"     # modified tracked file
    check "tracked-diff outcome passes" bash "$0" --log "$vlog" --worktree "$vdir/wt" --branch work/1 --base "$base" --reason-file "$rfile"
    git -C "$vdir/wt" commit -qam work   # new commit relative to baseline
    check "new-commit outcome passes" bash "$0" --log "$vlog" --worktree "$vdir/wt" --branch work/1 --base "$base" --reason-file "$rfile"
    printf 'banner only' > "$vlog"   # 11 bytes < MIN_LOG_BYTES
    git -C "$vdir/wt" commit --allow-empty -qm work2
    check_not "log-only outcome fails" bash "$0" --log "$vlog" --worktree "$vdir/wt" --branch work/1 --base "$base" --reason-file "$rfile"
    rm -f "$vlog"
    check_not "missing-log outcome fails" bash "$0" --log "$vlog" --worktree "$vdir/wt" --branch work/1 --base "$base" --reason-file "$rfile"
    printf '%200s' '' > "$vlog"
    check_not "invalid-baseline outcome fails" bash "$0" --log "$vlog" --worktree "$vdir/wt" --branch work/1 --base deadbeef --reason-file "$rfile"
    # failed-test case: fake npm that always exits 1 (no real npm needed)
    mkdir -p "$vdir/bin"
    printf '#!/bin/sh\nexit 1\n' > "$vdir/bin/npm"
    if git clone -q "$vdir/origin.git" "$vdir/wt2" 2>/dev/null && \
      git -C "$vdir/wt2" config user.email t@t && git -C "$vdir/wt2" config user.name t && \
      git -C "$vdir/wt2" checkout -qb work/2 2>/dev/null && \
      printf '{"scripts":{"test":"exit 1"}}' > "$vdir/wt2/package.json" && \
      git -C "$vdir/wt2" add -A && git -C "$vdir/wt2" commit -qm work && \
      base2="$(git -C "$vdir/wt2" rev-parse HEAD~1 2>/dev/null || git -C "$vdir/origin.git" rev-parse main)"; then
      PATH="$vdir/bin:$PATH" check_not "failed-test outcome fails" bash "$0" --log "$vlog" --worktree "$vdir/wt2" --branch work/2 --base "$base2" --reason-file "$rfile"
    else
      echo "FAIL: failed-test repo setup"; fails=$((fails+1))
    fi
  else
    echo "FAIL: self-test repo setup"; fails=$((fails+1))
  fi
  [ "$fails" = "0" ] && { echo "self-test: ALL PASS"; exit 0; } || { echo "self-test: $fails FAILURES"; exit 1; }
fi

verify
