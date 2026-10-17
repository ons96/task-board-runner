# Auto-Merge Policy for Mechanical PRs

Policy for `task-board-runner` (task-board #941, parent epic #933). The
question: may low-risk docs and dependency PRs merge autonomously while code
changes keep human review? Answer: **yes, narrowly**. The policy is
deny-by-default and enforced by `scripts/merge-policy.sh`.

## Decision

| PR content | Verdict |
|---|---|
| `docs/**`, `*.md`, `LICENSE`, `*.txt` only | auto-merge eligible |
| Dependency files only (`requirements*.txt`, `*.lock`, `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `uv.lock`, `package-lock.json`) | auto-merge eligible |
| Mix of docs + dependency files | auto-merge eligible |
| Any `scripts/**` or source file (`*.py`, `*.sh`, `*.js`, ...) | **review required** |
| Any `.github/workflows/**` | **review required** |
| Any config (`provider-manifest.json`, `.github/runner-config.json`, `.env*`) | **review required** |
| Any security path (`scripts/redteam-*`, `*gitleaks*`, `scripts/*secret*`, `scripts/merge-policy.sh`) | **review required** |
| Any unclassified file | **review required** |

## Required checks (all mandatory for auto-merge)

1. Required CI green (`--checks-pass 1`): the Runner Self-Test workflow passes
   (every script `--self-test` + workflow YAML validation).
2. No secret-like content in the diff: the classifier matches credential
   patterns (`sk-*`, `ghp_*`, `xai-*`, `AKIA*`, private keys, `Bearer *`,
   `api_key=`/`token=`/`password=`/`secret=` assignments) and any hit forces
   review, regardless of file categories.
3. No blocked label on the PR: `do-not-merge`, `needs-review`, or `security`
   forces review.

If any check fails, the verdict is `needs-review`. There is no override path
that lets code, security, workflow, or config changes bypass review: those
categories are hard-blocked before checks are even considered.

## Usage

```bash
git diff --name-only origin/main...HEAD > /tmp/pr-paths
bash scripts/merge-policy.sh --paths /tmp/pr-paths \
  --labels "dependencies" --checks-pass 1 --diff /tmp/pr.diff
# -> "auto-merge-eligible reason=deps-only category=deps" (exit 0)
# or "needs-review reason=... category=..." (exit 1)
```

## Testing

`bash scripts/merge-policy.sh --self-test` covers the representative cases
from the suggested verification: docs-only, dependency-only, code, workflow,
config, security, unclassified, mixed, secret-like diff, clean diff, checks
not green, blocked labels, missing input. The test fixtures include a fake
secret-shaped token to prove the diff scanner forces review; the policy never
prints diff contents.

## Safety notes

- Secret and protected-branch safety is never weakened: the only auto-merge
  paths are docs and dependency files, with green checks and a clean diff.
- The classifier is conservative by design: anything it cannot classify is
  treated as code.
