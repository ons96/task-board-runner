# Adding a Worker

How to add and safely operate an autonomous worker for the task board
(parent epic task-board#933). A worker claims `status:new` issues, runs an
agent on them, and verifies the work product before anything is marked done.

## Prerequisites

- **task-board** (https://github.com/ons96/task-board): the queue. Issues are
  tasks; labels are state. Required labels: `status:new`, `status:in_progress`,
  `status:done`, `status:blocked`, `priority:P0`-`priority:P9`,
  `project:<repo>`, one scope tag, `locked-by:<worker-id>`.
- **Gateway** (https://github.com/ons96/LLM-API-Key-Proxy): upstream model
  access. Workers must only use verified-free models; see
  `README.md` "provider manifest" for onboarding a provider entry.
- `gh` CLI authenticated with a machine-user PAT with `repo`, `project`,
  `workflow` scopes (never a broad classic PAT).

## Workflow triggers

| Workflow | Trigger | Purpose |
|---|---|---|
| `claim-and-dispatch.yml` | cron `*/30` + `workflow_dispatch` | sweeps stale locks, claims top-priority task, dispatches `task-worker.yml` |
| `task-worker.yml` | `workflow_dispatch` (issue_number, project, lock_label) | runs the agent on one claimed issue |
| `self-test.yml` | push/PR touching `scripts/**` or `.github/workflows/**` | unit-tests every script's `--self-test` |

Dispatch order: `priority:P0` down to `priority:P9`, filtered by scope.

## Labels and scopes

- Scope tag on the issue decides which worker may claim it:
  `cross-device` (any), `github-actions` (this runner), `vps-155`,
  `gateway-40` (VPS workers). Set `TASK_ALLOWED_SCOPES` accordingly
  (default `cross-device,github-actions`).
- Claiming: add `locked-by:<worker-id>` + `status:in_progress`, remove
  `status:new`, then re-read the issue after 2s to confirm the lock (race
  check). Never remove another worker's `locked-by:*` label unless the sweep
  rule below says its lease is expired.

## Locks and leases

- Lock label: `locked-by:gha-<run-id>[-<index>]` (or `local-<hostname>`).
- Every claim records a `lease:<unix-epoch>` label (`scripts/lock-lease.sh
  --mark`). The dispatcher sweep releases a lock only when the lease is
  provably older than `LEASE_TTL` (default 14400s). A fresh lease is never
  released. Long-running workers renew with
  `bash scripts/lock-lease.sh --renew <issue>` and must remove the lease label
  on every exit path (done, cancel, failure); removal of a missing label is a
  no-op.

## Secrets (names only - never values)

| Secret | Used for |
|---|---|
| `TASK_BOARD_PAT` | gh CLI on the task board and target repos |
| `NVIDIA_API_KEY` | NVIDIA provider models |
| `DLAB_API_KEY` | DLAB provider models |
| `DLAB_FREE_API_KEY` | DLAB free-tier models |

Secrets are passed only via workflow env; logs and issue comments must never
contain secret values or prompt contents. Rotate in the GitHub UI; update the
provider manifest `credential_env` names to match.

## Model configuration

- `provider-manifest.json` + `.github/runner-config.json` define eligible
  providers/models. The loader skips expired, non-free, or uncredentialed
  entries (`scripts/provider-manifest.py`).
- The static fallback chain lives in `task-worker.yml` (`PROVIDERS`); runtime
  failures step through it with bounded backoff
  (`scripts/provider-failure.sh --backoff`). Validate before shipping:
  `python3 scripts/provider-manifest.py --self-test`.

## Verification gate and failure handling

- `scripts/verify-work.sh` runs before anything is marked done: log size +
  work-product (diff or commits vs baseline) + tests. A log-only run FAILS the
  gate; the Release step requeues instead of marking done. Exit-0 alone is
  never success.
- Failures are classified by `scripts/failure-taxonomy.sh` into
  `auth|provider|timeout|validation|test|no_change|lock|infrastructure`,
  recorded as a `runner-fail:<class>` label, and commented with a one-line
  cause + run URL (no log dumps).
- Repeated failures consume a retry budget (`scripts/retry-budget.sh`):
  `attempts:<n>` labels track attempts; past `RETRY_BUDGET_MAX` the issue gets
  `retry-exhausted` + `status:blocked` instead of requeue.

## Minimal local validation checklist

Run from a clean checkout before enabling a new worker:

```bash
bash -n scripts/claim-task.sh scripts/verify-work.sh scripts/retry-budget.sh
bash -n scripts/failure-taxonomy.sh scripts/lock-lease.sh
python3 -m py_compile scripts/provider-manifest.py
python3 scripts/provider-manifest.py --self-test
bash scripts/provider-failure.sh --self-test
bash scripts/verify-work.sh --self-test
bash scripts/retry-budget.sh --self-test
bash scripts/failure-taxonomy.sh --self-test
bash scripts/lock-lease.sh --self-test
python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]"
```

Then a supervised dry run: `claim-task.sh --worker local-test` on a throwaway
`priority:P9` issue, confirm the claim comment + `lease:` label appear, and
confirm Release removes both. Only then point the dispatcher at real scopes.
