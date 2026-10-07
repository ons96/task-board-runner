# Safe auto-merge policy

Task-board #941. This repository does not auto-merge pull requests. A
maintainer may enable GitHub's native auto-merge on a protected branch for
exactly one narrow category; every other change keeps its review gate.
`scripts/check-merge-policy.sh` classifies diffs by the rules in this
document and is the single source of truth for eligibility.

## Allowed categories

Auto-merge without human review is allowed only for docs-only diffs:

- every changed file ends in `.md`, `.markdown`, or `.txt`
  (case-insensitive, any directory), and
- the diff contains nothing else.

Mechanical dependency updates are not in the allowed set: lockfiles,
manifests, and pins can change runtime behavior, so `package.json`,
`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `requirements*.txt`,
`pyproject.toml`, `poetry.lock`, `go.mod`, `go.sum`, `Cargo.*`, `Gemfile*`,
and similar always require review. Images, binaries, extension-less files,
and any unrecognized path also require review — the classifier fails
closed.

## Always require review

Manual review is required for source code, shell scripts, workflows, action
versions, configuration, provider/model settings, permissions, dependency
manifests and lockfiles, secrets, authentication, deployment, migrations,
and any PR with a mixed or uncertain diff. The classifier denies at least:

- Code: `.py`, `.sh`, `.js`, `.ts`, `.go`, `.rs`, `.c`, `.cpp`, `.java`,
  `.rb`, `.sql`, and similar executable source extensions.
- Workflows: anything under `.github/workflows/` or `.github/actions/`,
  plus any `action.yml`/`action.yaml`.
- Config: everything else under `.github/` (including `.md` files there),
  plus `.json`, `.yml`, `.yaml`, `.toml`, `.ini`, `.cfg`, `.conf`,
  `Makefile`, `Dockerfile`, and dotfiles.
- Secrets: `.env*`, `*.env`, `*.pem`, `*.key`, `*.p12`, `id_rsa*`,
  `id_ed25519*`, `*.keystore`, and any path containing `secret`,
  `credential`, `password`, or `token` — even when the file also ends in
  `.md` or `.txt`.

## Labels

Labels classify intent and never expand the allowed set. An `automerge`,
`dependencies`, or `docs` label on a code, workflow, config, dependency, or
secret-like diff does not make it eligible. The labels `do-not-merge`,
`needs-review`, `security`, `wip`, and `blocked` always force review, even
on an otherwise docs-only diff.

## Required checks

A PR may merge autonomously only when every condition below holds:

1. `scripts/check-merge-policy.sh --files-from <changed-files>` exits 0
   (docs-only classification, non-empty diff, no restricting labels);
2. the PR is not a draft and has no merge conflicts;
3. required CI is green, including the `Runner Self-Test` workflow;
4. secret scanning reports no findings on the diff;
5. branch protection keeps required reviews for every category other than
   docs-only, and no security or protected-branch exception is in force.

Labels or PR titles never substitute for these checks.

## Enforcement

This policy is documentation plus an offline classifier. No workflow in
this repository performs automatic merging, and enabling auto-merge
anywhere must not weaken secret protection or protected-branch rules.
`bash scripts/check-merge-policy.sh --self-test` covers the representative
cases — docs-only, dependency, code, workflow, config, secret-like, mixed,
unknown, empty, and label interactions — and runs in the self-test workflow.
