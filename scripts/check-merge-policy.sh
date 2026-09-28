#!/usr/bin/env bash
set -euo pipefail

policy_dir=${1:-docs}
policy="$policy_dir/auto-merge-policy.md"

test -s "$policy"
grep -Fq 'does not auto-merge' "$policy"
grep -Fq 'Manual review is required' "$policy"
grep -Fq 'workflows' "$policy"
grep -Fq 'secrets' "$policy"
printf 'merge policy self-test: PASS\n'
