#!/usr/bin/env bash
# verify-work-product.sh - work-product verify gate for task-board-runner (#932)
#
# Ported from task-board-loop's verify gate (PRs #13/#14): an issue may only be
# marked status:done when the diff against the base branch has real substance.
# Catches false-dones where the agent commits something trivial (edits its own
# README, adds a single comment line) and the worker marks the issue done.
#
# Usage: verify-work-product.sh [BASE_REF]     default: origin/main
#        verify-work-product.sh --self-test   # fixture cases, no network needed
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

SELF_TEST=0
case "${1:-}" in
  --self-test) SELF_TEST=1 ;;
  "") BASE_REF="origin/main" ;;
  *) BASE_REF="$1" ;;
esac
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
  # ponytail: no grep-over-printf pipe here — `grep -q` closes the pipe early
  # and under `set -o pipefail` a half-written pipe reads as failure, which
  # would false-reject a legitimate lockfile bump. Plain loops are safe.
  local path sibling s found locks=0
  for path in "${CHANGED_PATHS[@]}"; do
    if is_lockfile "$path"; then
      locks=$((locks + 1))
      sibling=$(manifest_for "$path")
      case "$path" in
        */*) sibling="${path%/*}/$sibling" ;;
      esac
      if ! git cat-file -e "HEAD:$sibling" 2>/dev/null; then
        found=0
        for s in "${CHANGED_PATHS[@]}"; do
          [ "$s" = "$sibling" ] && { found=1; break; }
        done
        [ "$found" -eq 1 ] || return 1
      fi
    elif ! is_manifest "$path"; then
      return 1
    fi
  done
  [ "$locks" -gt 0 ]
}

# ponytail: self-test — the false-done shapes this gate exists to catch, as
# throwaway fixture repos. Proves the gate rejects trivial diffs, passes real
# ones, honors the lockfile whitelist, and fails closed on unmeasurable diffs.
self_test() {
  local self total=0 pass=0 out code verdict reason
  self="$(cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
  # tmp is global on purpose: the EXIT trap fires after this function returns,
  # when its locals would already be gone.
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  repo() { # repo NAME — fixture repo: base commit on main, then a work branch
    git init -q -b main "$tmp/$1"
    git -C "$tmp/$1" config user.email self@test
    git -C "$tmp/$1" config user.name self-test
    echo "base line" > "$tmp/$1/base.txt"
    git -C "$tmp/$1" add -A
    git -C "$tmp/$1" commit -qm base
    git -C "$tmp/$1" checkout -q -b work
  }

  commit_all() { # commit_all NAME MSG
    git -C "$tmp/$1" add -A
    git -C "$tmp/$1" commit -qm "$2"
  }

  check() { # check EXPECT NAME REASON_PREFIX DESC
    local expect="$1" name="$2" want="$3" desc="$4" want_code
    total=$((total + 1))
    out=$(cd "$tmp/$name" && VERIFY_MIN_FILES=2 VERIFY_MIN_INSERTIONS=5 bash "$self" main 2>&1) && code=0 || code=$?
    verdict=$(printf '%s\n' "$out" | sed -n 's/^verdict=//p')
    reason=$(printf '%s\n' "$out" | sed -n 's/^reason=//p')
    if [ "$expect" = pass ]; then want_code=0; else want_code=1; fi
    if [ "$code" -eq "$want_code" ] && [ "$verdict" = "$expect" ] \
       && [[ "$reason" == "$want"* ]]; then
      pass=$((pass + 1))
      echo "PASS: $desc"
    else
      echo "FAIL: $desc — expected $expect ('$want*'), got exit=$code verdict=$verdict reason='$reason'"
    fi
  }

  # --- false-done shapes: must be rejected ---
  repo trivial
  echo "# a single comment line" >> "$tmp/trivial/README.md"
  commit_all trivial "trivial: one comment line"
  check fail trivial "trivial diff:" "single-comment-line edit is rejected"

  repo tiny
  echo "# a" >> "$tmp/tiny/base.txt"
  echo "# b" > "$tmp/tiny/notes.txt"
  commit_all tiny "tiny: two files, two insertions"
  check fail tiny "trivial diff:" "two files but under 5 insertions is rejected"

  repo empty
  git -C "$tmp/empty" commit -q --allow-empty -m "empty commit"
  check fail empty "no effective diff" "commits ahead of base with identical tree are rejected"

  repo orphan
  printf '{"lockfileVersion":3}\n' > "$tmp/orphan/package-lock.json"
  commit_all orphan "orphan lockfile change"
  check fail orphan "trivial diff:" "lockfile with no matching package manifest is rejected"

  repo island
  git -C "$tmp/island" checkout -q --orphan unrelated
  git -C "$tmp/island" commit -q --allow-empty -m island
  check fail island "cannot measure" "branch with no merge-base to main fails closed"

  # --- real work: must pass ---
  repo real
  printf 'fix1\nfix2\nfix3\n' >> "$tmp/real/base.txt"
  printf 'new1\nnew2\nnew3\n' > "$tmp/real/fix.txt"
  commit_all real "real: fix across two files"
  check pass real "diff has substance:" "real diff (2 files, 6 insertions) passes"

  # --- lockfile whitelist: must pass however small ---
  repo bump
  printf '{"name":"x","version":"1.1.0"}\n' > "$tmp/bump/package.json"
  printf '{"lockfileVersion":3}\n' > "$tmp/bump/package-lock.json"
  commit_all bump "bump: manifest + lockfile"
  check pass bump "dependency-shaped diff" "manifest+lockfile bump passes despite tiny diff"

  repo lockonly
  printf '{"name":"x"}\n' > "$tmp/lockonly/package.json"
  git -C "$tmp/lockonly" add package.json
  git -C "$tmp/lockonly" commit -qm "base: manifest"
  printf '{"lockfileVersion":3,"packages":{}}\n' > "$tmp/lockonly/package-lock.json"
  commit_all lockonly "lockonly: lockfile regen"
  check pass lockonly "dependency-shaped diff" "lockfile-only regen passes (manifest already in HEAD)"

  repo nested
  mkdir -p "$tmp/nested/sub"
  printf '{"name":"y"}\n' > "$tmp/nested/sub/package.json"
  printf '{"lockfileVersion":3}\n' > "$tmp/nested/sub/package-lock.json"
  commit_all nested "nested: monorepo package bump"
  check pass nested "dependency-shaped diff" "subdirectory manifest+lockfile bump passes"

  echo "self-test: $pass/$total fixture cases passed"
  [ "$pass" -eq "$total" ]
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit 0
fi

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
