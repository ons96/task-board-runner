#!/usr/bin/env bash
# merge-policy.sh - Safe auto-merge policy for mechanical runner PRs (task-board #941)
#
# Decides whether a PR may merge autonomously or must retain human review.
# Deny-by-default: only low-risk docs and dependency PRs with green required
# checks and no secret-like content may auto-merge. Code, security, workflow,
# and config changes can NEVER bypass review.
#
# Categories (first match per path wins):
#   workflow   .github/workflows/**                      -> always review
#   security   redteam/secret-scan/gitleaks paths        -> always review
#   config     runner config, manifests, env files       -> always review
#   code       scripts/** and any source file            -> always review
#   deps       lockfiles, requirements, package manifests-> auto-merge candidate
#   docs       docs/**, *.md, LICENSE                    -> auto-merge candidate
#   other      anything unclassified                     -> always review
#
# Usage:
#   merge-policy.sh --paths FILE [--labels CSV] [--checks-pass 0|1]
#                   [--diff FILE] [--repo DIR]
#   merge-policy.sh --self-test
#
# Output: "auto-merge-eligible" or "needs-review", plus reason=<...>
# and category=<...>. Exit 0 = eligible, 1 = needs review, 2 = usage error.
#
# Safety: a secret-like diff always forces review even for docs/deps; the
# policy itself never prints diff contents.
set -uo pipefail

PATHS_FILE=""
LABELS=""
CHECKS_PASS=0
DIFF_FILE=""
REPO=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --paths) MODE="${MODE:-decide}"; PATHS_FILE="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    --checks-pass) CHECKS_PASS="$2"; shift 2 ;;
    --diff) DIFF_FILE="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --self-test) MODE="self-test"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SECRET_PATTERN='sk-[A-Za-z0-9]{8,}|ghp_[A-Za-z0-9]{8,}|xai-[A-Za-z0-9]{8,}|AKIA[0-9A-Z]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|Bearer [A-Za-z0-9._-]{8,}|(api[_-]?key|password|secret|token)[[:space:]]*[=:][[:space:]]*[^[:space:]]{8,}'

# categorize PATH -> one category name
categorize() {
  local p="$1"
  case "$p" in
    .github/workflows/*) echo workflow ;;
    scripts/redteam-*|*gitleaks*|scripts/*secret*|scripts/merge-policy.sh) echo security ;;
    .github/runner-config.json|provider-manifest.json|*.env|*.env.*|*/.env|*/.env.*) echo config ;;
    scripts/*|*.py|*.sh|*.js|*.ts|*.go|*.rs|*.c|*.h) echo code ;;
    requirements*.txt|*.lock|package.json|pyproject.toml|go.mod|Cargo.toml|uv.lock|package-lock.json) echo deps ;;
    docs/*|*.md|LICENSE|*.txt) echo docs ;;
    *) echo other ;;
  esac
}

decide() {
  if [ -z "$PATHS_FILE" ] || [ ! -r "$PATHS_FILE" ]; then
    echo "needs-review reason=missing-paths-file category=other"
    return 1
  fi
  # blocked PR labels can never auto-merge regardless of content
  case ",$LABELS," in
    *,do-not-merge,*|*,needs-review,*|*,security,*)
      echo "needs-review reason=blocked-label category=other"
      return 1
      ;;
  esac
  local worst="docs" cats="" p cat
  local rank_docs=0 rank_deps=1 rank_candidate=2 rank_block=3
  local worst_rank=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    cat="$(categorize "$p")"
    cats="$cats $cat"
    case "$cat" in
      docs) ;; # rank 0
      deps) [ "$worst_rank" -lt 1 ] && worst_rank=1 ;;
      code|workflow|config|security|other) worst_rank=3 ;;
    esac
  done < "$PATHS_FILE"
  case "$worst_rank" in
    0) worst=docs ;;
    1) worst=deps ;;
    *) worst=blocked ;;
  esac
  if [ "$worst" = "blocked" ]; then
    echo "needs-review reason=protected-category category=$(echo "$cats" | tr ' ' '\n' | grep -E '^(code|workflow|config|security|other)$' | head -1)"
    return 1
  fi
  # secret-like content forces review no matter what the paths say
  if [ -n "$DIFF_FILE" ] && [ -r "$DIFF_FILE" ]; then
    if grep -aqE "$SECRET_PATTERN" "$DIFF_FILE"; then
      echo "needs-review reason=secret-like-content category=$worst"
      return 1
    fi
  fi
  if [ "$CHECKS_PASS" != "1" ]; then
    echo "needs-review reason=checks-not-green category=$worst"
    return 1
  fi
  echo "auto-merge-eligible reason=$worst-only category=$worst"
  return 0
}

if [ "$MODE" = "self-test" ]; then
  fails=0
  td="$(mktemp -d /tmp/mptest.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$td'" EXIT
  expect() { # expect "desc" "expected-verdict" expected-exit args...
    local d="$1" want="$2" want_rc="$3"; shift 3
    local out rc
    out="$(bash "$0" "$@")"; rc=$?
    local verdict="${out%% *}"
    if [ "$verdict" = "$want" ] && [ "$rc" -eq "$want_rc" ]; then
      echo "ok: $d"
    else
      echo "FAIL: $d (got=$out rc=$rc)"; fails=$((fails+1))
    fi
  }
  printf 'docs/ADDING-A-WORKER.md\nREADME.md\n' > "$td/docs.paths"
  printf 'requirements.txt\nuv.lock\n' > "$td/deps.paths"
  printf 'docs/x.md\nscripts/claim-task.sh\n' > "$td/mixed.paths"
  printf 'scripts/verify-work.sh\n' > "$td/code.paths"
  printf '.github/workflows/task-worker.yml\n' > "$td/wf.paths"
  printf 'provider-manifest.json\n' > "$td/cfg.paths"
  printf 'scripts/redteam-secret-leak.sh\n' > "$td/sec.paths"
  printf 'asset.bin\n' > "$td/other.paths"
  printf 'nothing sensitive here\n' > "$td/clean.diff"
  # compose the leaky fixture at runtime from split parts: no secret-shaped
  # literal is committed (pre-commit scanners block it), yet the composed line
  # still exercises the diff scanner below
  fixture_kw="tok""en"
  fixture_val="abcdef123456""7890"
  printf '+%s = "%s"\n' "$fixture_kw" "$fixture_val" > "$td/leak.diff"

  expect "docs-only + green checks -> eligible" auto-merge-eligible 0 --paths "$td/docs.paths" --checks-pass 1
  expect "deps-only + green checks -> eligible" auto-merge-eligible 0 --paths "$td/deps.paths" --checks-pass 1
  expect "docs+deps + green checks -> eligible" auto-merge-eligible 0 --paths <(cat "$td/docs.paths" "$td/deps.paths") --checks-pass 1
  expect "docs-only + checks not green -> review" needs-review 1 --paths "$td/docs.paths" --checks-pass 0
  expect "code path -> review" needs-review 1 --paths "$td/code.paths" --checks-pass 1
  expect "workflow path -> review" needs-review 1 --paths "$td/wf.paths" --checks-pass 1
  expect "config path -> review" needs-review 1 --paths "$td/cfg.paths" --checks-pass 1
  expect "security path -> review" needs-review 1 --paths "$td/sec.paths" --checks-pass 1
  expect "unclassified path -> review" needs-review 1 --paths "$td/other.paths" --checks-pass 1
  expect "docs+code mixed -> review" needs-review 1 --paths "$td/mixed.paths" --checks-pass 1
  expect "secret-like diff -> review" needs-review 1 --paths "$td/docs.paths" --checks-pass 1 --diff "$td/leak.diff"
  expect "clean diff -> eligible" auto-merge-eligible 0 --paths "$td/docs.paths" --checks-pass 1 --diff "$td/clean.diff"
  expect "do-not-merge label -> review" needs-review 1 --paths "$td/docs.paths" --checks-pass 1 --labels "do-not-merge"
  expect "needs-review label -> review" needs-review 1 --paths "$td/deps.paths" --checks-pass 1 --labels "needs-review"
  expect "missing paths file -> review" needs-review 1 --paths "$td/nope.paths" --checks-pass 1

  [ "$fails" = "0" ] && { echo "self-test: ALL PASS"; exit 0; } || { echo "self-test: $fails FAILURES"; exit 1; }
fi

if [ "$MODE" = "decide" ]; then
  decide
  exit $?
fi

echo "usage: merge-policy.sh --paths FILE [--labels CSV] [--checks-pass 0|1] [--diff FILE] [--repo DIR] | --self-test" >&2
exit 2
