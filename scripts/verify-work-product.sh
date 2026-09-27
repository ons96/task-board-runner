#!/usr/bin/env bash
# verify-work-product.sh - work-product verify gate for task-board-runner (#932)
#
# Ported from task-board-loop's verify gate (PRs #13/#14): an issue may only be
# marked status:done when the diff against the base branch has real substance.
# Catches false-dones where the agent commits something trivial (edits its own
# README, adds a single comment line) and the worker marks the issue done.
#
# Usage: verify-work-product.sh [BASE_REF]     default: origin/main
# Run from inside the target repo worktree, after everything is committed.
#
# Substance bar: reject when fewer than VERIFY_MIN_FILES files are touched OR
# fewer than VERIFY_MIN_INSERTIONS lines are inserted vs the base branch.
# Whitelist: dependency-shaped diffs (lockfiles plus their matching package
# manifests) count as real however small, so lockfile regens and tiny
# dependency bumps are never false-requeued.
#
# Output: key=value lines on stdout (files, insertions, deletions, min_files,
# min_insertions, verdict, reason).
# Exit 0 = real work product (marking done allowed); exit 1 = trivial (requeue).
set -euo pipefail

BASE_REF="${1:-origin/main}"
MIN_FILES="${VERIFY_MIN_FILES:-2}"
MIN_INSERTIONS="${VERIFY_MIN_INSERTIONS:-5}"

emit() { echo "$1=$2"; }

fail() {
  emit verdict fail
  emit reason "$1"
  exit 1
}

is_lockfile() {
  case "$1" in
    package-lock.json|*/package-lock.json|npm-shrinkwrap.json|*/npm-shrinkwrap.json|\
    yarn.lock|*/yarn.lock|pnpm-lock.yaml|*/pnpm-lock.yaml|bun.lockb|*/bun.lockb|\
    bun.lock|*/bun.lock|Cargo.lock|*/Cargo.lock|poetry.lock|*/poetry.lock|\
    Pipfile.lock|*/Pipfile.lock|uv.lock|*/uv.lock|composer.lock|*/composer.lock|\
    Gemfile.lock|*/Gemfile.lock|go.sum|*/go.sum|go.work.sum|*/go.work.sum|\
    flake.lock|*/flake.lock|mix.lock|*/mix.lock|deno.lock|*/deno.lock)
      return 0
      ;;
  esac
  return 1
}

# manifest that resolves a given lockfile, as its sibling in the same directory
manifest_for() {
  case "$(basename "$1")" in
    package-lock.json|npm-shrinkwrap.json|yarn.lock|pnpm-lock.yaml|bun.lockb|bun.lock) echo package.json ;;
    Cargo.lock) echo Cargo.toml ;;
    poetry.lock|uv.lock) echo pyproject.toml ;;
    Pipfile.lock) echo Pipfile ;;
    composer.lock) echo composer.json ;;
    Gemfile.lock) echo Gemfile ;;
    go.sum) echo go.mod ;;
    go.work.sum) echo go.work ;;
    flake.lock) echo flake.nix ;;
    mix.lock) echo mix.exs ;;
    deno.lock) echo deno.json ;;
    *) echo "" ;;
  esac
}

is_manifest() {
  case "$(basename "$1")" in
    package.json|Cargo.toml|pyproject.toml|Pipfile|composer.json|Gemfile|go.mod|go.work|flake.nix|mix.exs|deno.json)
      return 0
      ;;
  esac
  return 1
}

dependency_shaped() {
  # every changed path is a lockfile or a package manifest, at least one path is
  # a lockfile, and each changed lockfile's sibling manifest exists (committed
  # in HEAD or added in this diff). Anything else is not purely dependency work.
  local path locks=0 manifest sibling
  for path in "${CHANGED_PATHS[@]}"; do
    if is_lockfile "$path"; then
      locks=$((locks + 1))
      manifest=$(manifest_for "$path")
      case "$path" in
        */*) sibling="${path%/*}/$manifest" ;;
        *)   sibling="$manifest" ;;
      esac
      if ! git cat-file -e "HEAD:$sibling" 2>/dev/null \
         && ! printf '%s\n' "${CHANGED_PATHS[@]}" | grep -qxF "$sibling"; then
        return 1
      fi
    elif ! is_manifest "$path"; then
      return 1
    fi
  done
  [ "$locks" -gt 0 ]
}

FILES=0
INSERTIONS=0
DELETIONS=0
CHANGED_PATHS=()

# ponytail: fail closed — an unmeasurable diff must never be waved through to
# status:done; requeue loudly instead of silently marking done.
BASE_SHA=$(git merge-base "$BASE_REF" HEAD 2>/dev/null || true)
if [ -z "$BASE_SHA" ]; then
  emit files 0
  emit insertions 0
  emit deletions 0
  emit min_files "$MIN_FILES"
  emit min_insertions "$MIN_INSERTIONS"
  fail "cannot measure the diff (no merge-base between HEAD and $BASE_REF)"
fi

# --no-renames keeps numstat paths plain so the lockfile whitelist matches
# real paths instead of git's "{old => new}" rename notation.
while IFS=$'\t' read -r ADD DEL CHG_PATH; do
  [ -n "$CHG_PATH" ] || continue
  FILES=$((FILES + 1))
  if [[ "$ADD" =~ ^[0-9]+$ ]]; then INSERTIONS=$((INSERTIONS + ADD)); fi
  if [[ "$DEL" =~ ^[0-9]+$ ]]; then DELETIONS=$((DELETIONS + DEL)); fi
  CHANGED_PATHS+=("$CHG_PATH")
done < <(git diff --numstat --no-renames "$BASE_SHA" HEAD)

emit files "$FILES"
emit insertions "$INSERTIONS"
emit deletions "$DELETIONS"
emit min_files "$MIN_FILES"
emit min_insertions "$MIN_INSERTIONS"

if [ "$FILES" -eq 0 ]; then
  fail "no effective diff vs $BASE_REF — commits are ahead but the tree is identical (empty commits are not a work product)"
fi

if [ "$FILES" -lt "$MIN_FILES" ] || [ "$INSERTIONS" -lt "$MIN_INSERTIONS" ]; then
  # ponytail: whitelist — lockfiles + the manifests they resolve are real work
  # however small the line counts are; a lockfile regen or tiny dependency bump
  # must not be false-requeued.
  if dependency_shaped; then
    emit verdict pass
    emit reason "dependency-shaped diff ($FILES file(s), $INSERTIONS insertion(s)) counts as real work"
    exit 0
  fi
  fail "trivial diff: $FILES file(s) touched, $INSERTIONS insertion(s) vs $BASE_REF — below the substance bar of $MIN_FILES file(s) and $MIN_INSERTIONS insertion(s)"
fi

emit verdict pass
emit reason "diff has substance: $FILES file(s) touched, $INSERTIONS insertion(s) vs $BASE_REF"
exit 0
