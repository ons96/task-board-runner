#!/usr/bin/env bash
# check-merge-policy.sh - Auto-merge eligibility classifier (task-board #941).
#
# Implements docs/auto-merge-policy.md: only docs-only diffs (files ending
# in .md/.markdown/.txt) may ever merge without review, and labels never
# expand that set. Code, workflows, config, dependencies, secret-like files,
# and unrecognized paths always require review. The classifier fails
# closed: an empty or uncertain diff is never eligible.
#
# Usage:
#   check-merge-policy.sh                       # validate the policy doc
#   check-merge-policy.sh --files-from PATH     # classify a changed-file list
#       [--labels-from PATH] [--policy-dir DIR] # optional PR labels / doc dir
#   check-merge-policy.sh --self-test           # offline representative cases
#
# --files-from takes one changed path per line (as from `git diff
# --name-only`, or a process substitution); --labels-from takes one PR
# label per line.
# Exit 0 = auto-merge eligible, 1 = review required, 2 = usage error.
set -uo pipefail

POLICY_DIR="docs"
FILES=""
LABELS=""
SELF_TEST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy-dir) POLICY_DIR="$2"; shift 2 ;;
    --files-from) FILES="$2"; shift 2 ;;
    --labels-from) LABELS="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

POLICY="$POLICY_DIR/auto-merge-policy.md"

validate_doc() {
  [ -s "$POLICY" ] || { echo "missing or empty $POLICY" >&2; return 1; }
  grep -Fq 'does not auto-merge' "$POLICY" || { echo "$POLICY: auto-merge stance missing" >&2; return 1; }
  grep -Fq 'Manual review is required' "$POLICY" || { echo "$POLICY: review gate missing" >&2; return 1; }
  grep -Fq '## Allowed categories' "$POLICY" || { echo "$POLICY: allowed categories missing" >&2; return 1; }
  grep -Fq '## Always require review' "$POLICY" || { echo "$POLICY: review categories missing" >&2; return 1; }
  grep -Fq '## Labels' "$POLICY" || { echo "$POLICY: label rules missing" >&2; return 1; }
  grep -Fq '## Required checks' "$POLICY" || { echo "$POLICY: required checks missing" >&2; return 1; }
  grep -Fq 'workflows' "$POLICY" || { echo "$POLICY: workflow category missing" >&2; return 1; }
  grep -Fq 'secrets' "$POLICY" || { echo "$POLICY: secrets category missing" >&2; return 1; }
  return 0
}

classify_file() {
  local p="$1" base lc
  base="${p##*/}"
  lc="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in
    .env|.env.*|*.env|*.pem|*.key|*.p12|*.pfx|id_rsa*|id_ed25519*|id_ecdsa*|*.keystore|*.jks)
      echo secrets; return 0 ;;
    *secret*|*credential*|*password*|*token*)
      echo secrets; return 0 ;;
  esac
  case "$p" in
    .github/workflows/*|.github/actions/*) echo workflow; return 0 ;;
  esac
  case "$lc" in
    action.yml|action.yaml) echo workflow; return 0 ;;
  esac
  case "$lc" in
    package.json|package-lock.json|npm-shrinkwrap.json|yarn.lock|pnpm-lock.yaml|bun.lockb|\
    requirements*.txt|constraints*.txt|pipfile|pipfile.lock|pyproject.toml|poetry.lock|\
    setup.py|setup.cfg|gemfile|gemfile.lock|go.mod|go.sum|cargo.toml|cargo.lock|uv.lock|\
    composer.json|composer.lock|pom.xml|gradle.properties|*.gradle|podfile|podfile.lock|\
    mix.lock|*.cabal|.nvmrc|.python-version|.ruby-version|.node-version|.tool-versions|*.lock)
      echo dependency; return 0 ;;
  esac
  case "$p" in
    .github/*) echo config; return 0 ;;
  esac
  case "$lc" in
    *.json|*.yml|*.yaml|*.toml|*.ini|*.cfg|*.conf|*.xml|makefile|dockerfile|*.dockerfile|\
    .gitignore|.gitattributes|.gitmodules|.editorconfig|.dockerignore|jenkinsfile)
      echo config; return 0 ;;
  esac
  case "$lc" in
    *.sh|*.bash|*.zsh|*.fish|*.py|*.js|*.mjs|*.cjs|*.ts|*.tsx|*.jsx|*.go|*.rs|*.c|*.h|\
    *.cpp|*.cc|*.cxx|*.hpp|*.java|*.kt|*.kts|*.rb|*.php|*.pl|*.pm|*.lua|*.sql|*.r|*.ps1|\
    *.bat|*.cmd|*.swift|*.scala|*.dart|*.vb)
      echo code; return 0 ;;
  esac
  case "$lc" in
    *.md|*.markdown|*.txt) echo docs; return 0 ;;
  esac
  echo unknown
}

classify_files() {
  local files="$1" labels="${2:-}"
  [ -n "$files" ] || { echo "missing --files-from" >&2; return 2; }
  [ -e "$files" ] || { echo "no such file list: $files" >&2; return 2; }
  { [ -z "$labels" ] || [ -e "$labels" ]; } || { echo "no such label list: $labels" >&2; return 2; }
  local n=0 f cat lbl reasons=""
  local seen_secrets=0 seen_workflow=0 seen_config=0 seen_dependency=0 seen_code=0 seen_unknown=0
  while IFS= read -r f; do
    f="${f%$'\r'}"
    [ -n "$f" ] || continue
    n=$((n + 1))
    cat="$(classify_file "$f")"
    case "$cat" in
      secrets)    [ "$seen_secrets" = 1 ] || { reasons+="review-required: secret-like file ($f)"$'\n'; seen_secrets=1; } ;;
      workflow)   [ "$seen_workflow" = 1 ] || { reasons+="review-required: workflow/action change ($f)"$'\n'; seen_workflow=1; } ;;
      config)     [ "$seen_config" = 1 ] || { reasons+="review-required: configuration change ($f)"$'\n'; seen_config=1; } ;;
      dependency) [ "$seen_dependency" = 1 ] || { reasons+="review-required: dependency change ($f)"$'\n'; seen_dependency=1; } ;;
      code)       [ "$seen_code" = 1 ] || { reasons+="review-required: code change ($f)"$'\n'; seen_code=1; } ;;
      unknown)    [ "$seen_unknown" = 1 ] || { reasons+="review-required: unrecognized file type ($f)"$'\n'; seen_unknown=1; } ;;
    esac
  done < "$files"
  if [ -n "$labels" ]; then
    while IFS= read -r lbl; do
      lbl="${lbl%$'\r'}"
      lbl="${lbl#"${lbl%%[![:space:]]*}"}"
      lbl="${lbl%"${lbl##*[![:space:]]}"}"
      [ -n "$lbl" ] || continue
      case "$(printf '%s' "$lbl" | tr '[:upper:]' '[:lower:]')" in
        do-not-merge|needs-review|security|wip|blocked)
          reasons+="review-required: restricting label ($lbl)"$'\n' ;;
      esac
    done < "$labels"
  fi
  [ "$n" -gt 0 ] || reasons+="review-required: empty diff (fail closed)"$'\n'
  if [ -n "$reasons" ]; then
    printf '%s' "$reasons"
    return 1
  fi
  echo "eligible: docs-only diff ($n file(s))"
  return 0
}

self_test() {
  local fails=0 t out
  t="$(mktemp -d /tmp/mptest.XXXXXX)" || { echo "FAIL: temp dir setup"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$t'" EXIT
  ok() { echo "ok: $1"; }
  bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
  expect() {
    local desc="$1" want="$2" files="$3" labels="${4:-}" rc=0
    classify_files "$files" "$labels" >/dev/null 2>&1 || rc=$?
    if { [ "$want" = eligible ] && [ "$rc" -eq 0 ]; } || { [ "$want" = review ] && [ "$rc" -eq 1 ]; }; then
      ok "$desc"
    else
      bad "$desc (want $want, got rc=$rc)"
    fi
  }
  reason_has() {
    local desc="$1" files="$2" pat="$3" got
    got="$(classify_files "$files" "" 2>&1)" || true
    if printf '%s\n' "$got" | grep -Fq "$pat"; then ok "$desc"; else bad "$desc"; fi
  }

  printf '%s\n' README.md docs/auto-merge-policy.md notes.txt > "$t/docs.list"
  printf '%s\n' package.json package-lock.json > "$t/deps-npm.list"
  printf '%s\n' requirements.txt poetry.lock > "$t/deps-py.list"
  printf '%s\n' src/app.py > "$t/code.list"
  printf '%s\n' scripts/run.sh > "$t/shell.list"
  printf '%s\n' .github/workflows/ci.yml > "$t/workflow.list"
  printf '%s\n' .github/runner-config.json > "$t/config.list"
  printf '%s\n' action.yml > "$t/action.list"
  printf '%s\n' .env > "$t/env.list"
  printf '%s\n' config/secrets.yaml > "$t/secrets.list"
  printf '%s\n' certs/server.pem > "$t/pem.list"
  printf '%s\n' docs/secrets.md > "$t/md-secrets.list"
  printf '%s\n' README.md src/app.py > "$t/mixed.list"
  printf '%s\n' assets/logo.png > "$t/unknown.list"
  : > "$t/empty.list"
  printf '%s\n' automerge docs > "$t/labels-expand.list"
  printf '%s\n' needs-review > "$t/labels-review.list"
  printf '%s\n' Security > "$t/labels-security.list"
  printf '%s\n' docs > "$t/labels-benign.list"

  # Representative diffs: only docs-only may merge without review.
  expect "docs-only diff is eligible" eligible "$t/docs.list"
  expect "npm dependency diff requires review" review "$t/deps-npm.list"
  expect "python dependency diff requires review" review "$t/deps-py.list"
  expect "code diff requires review" review "$t/code.list"
  expect "shell diff requires review" review "$t/shell.list"
  expect "workflow diff requires review" review "$t/workflow.list"
  expect "composite action diff requires review" review "$t/action.list"
  expect "config diff requires review" review "$t/config.list"
  expect "secret-like .env diff requires review" review "$t/env.list"
  expect "secret-named yaml requires review" review "$t/secrets.list"
  expect "certificate file requires review" review "$t/pem.list"
  expect "secret-named markdown requires review" review "$t/md-secrets.list"
  expect "mixed docs+code diff requires review" review "$t/mixed.list"
  expect "unrecognized file type requires review" review "$t/unknown.list"
  expect "empty diff fails closed" review "$t/empty.list"

  # Labels never expand the allowed set; some always force review.
  expect "automerge/docs labels cannot expand policy" review "$t/code.list" "$t/labels-expand.list"
  expect "labels cannot rescue an empty diff" review "$t/empty.list" "$t/labels-expand.list"
  expect "needs-review label forces review on docs" review "$t/docs.list" "$t/labels-review.list"
  expect "security label (any case) forces review on docs" review "$t/docs.list" "$t/labels-security.list"
  expect "benign docs label keeps docs-only eligible" eligible "$t/docs.list" "$t/labels-benign.list"

  # Verdict lines name the exact category so CI logs stay auditable.
  reason_has "code verdict names category" "$t/code.list" "code change"
  reason_has "workflow verdict names category" "$t/workflow.list" "workflow"
  reason_has "dependency verdict names category" "$t/deps-npm.list" "dependency"
  reason_has "config verdict names category" "$t/config.list" "configuration"
  reason_has "secret verdict names category" "$t/env.list" "secret-like"
  out="$(classify_files "$t/docs.list" "")" || true
  if printf '%s\n' "$out" | grep -Fq "eligible: docs-only diff"; then
    ok "eligible verdict is explicit"
  else
    bad "eligible verdict is explicit"
  fi

  if validate_doc >/dev/null 2>&1; then ok "policy doc validation"; else bad "policy doc validation"; fi

  if [ "$fails" -eq 0 ]; then
    echo "merge policy self-test: ALL PASS"
    return 0
  fi
  echo "merge policy self-test: $fails FAILURES"
  return 1
}

if [ "$SELF_TEST" = "1" ]; then
  self_test
elif [ -n "$FILES" ]; then
  classify_files "$FILES" "$LABELS"
else
  validate_doc || exit 1
  printf 'merge policy self-test: PASS\n'
fi
