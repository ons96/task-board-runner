# Epic #933 status — runner reliability + autonomy hardening

Durable acceptance record for [task-board issue #933](https://github.com/ons96/task-board/issues/933).
The epic closes when every child below is closed or explicitly blocked with
reason; this page is the in-repo map of that state. Update it when a child
merges or a block reason changes — the board issue is the source of truth for
open/closed state, this page tracks what landed where.

Goal: full-autonomy queue work is reliable — no false-dones, no infinite
requeue, no silent failures, onboarding documented. Out of scope: gateway
chain rewrites (owned by #904/#750/#757) and secret rotation policy.

## Child map

| # | Child | Board issue | State | Where it lives |
|---|-------|-------------|-------|----------------|
| 1 | verify-gate port from task-board-loop PRs #13/#14 | #932, #934 | done — merged via runner PR #2 | `scripts/verify-work.sh` + gate step in `task-worker.yml` + false-done self-tests |
| 2 | issue retry budget → `blocked:repeated-failure` | #933 | done — this branch (`work/933`) | `scripts/requeue-task.sh`, wired into worker release, dispatcher rollback, sweeper, and claim paths |
| 3 | failure taxonomy labels + cause comment | #936 | in flight — branch `work/936` | `scripts/failure-reason.sh` + classified release comment |
| 4 | lock-lease timestamp + timeout sweep | #937 | in flight — branch `work/937` | `lease-until:` labels, lease-honoring sweeper, in-run lease refresh |
| 5 | compaction model pin in `runner-config.json` | #938 | in flight — branch `work/938` | `scripts/validate-runner-config.sh` + bounded compaction in the worker launch path |
| 6 | switch runner model to gateway coding-smart | — | **explicitly blocked** — see below | n/a until unblocked |
| 7 | `docs/ADDING-A-WORKER.md` onboarding doc | #940 | in flight — branch `work/940` | README "Worker onboarding" section |
| 8 | auto-merge policy for docs/deps PRs | #941 | in flight — branch `work/941` | `docs/auto-merge-policy.md` + `scripts/check-merge-policy.sh` |
| 9 | cross-worker NIM quota awareness | #942 | in flight — branch `work/942` | `scripts/provider-fallback.sh` bounded rate-limit backoff |
| 10 | README redirect on `vps-gh-agent-loop` | #933 | done — this branch (`work/933`) | README "Why public" supersede note; the retired repo's own banner is owned outside this runner repo |

## Explicit block: model switch to coding-smart (child 6)

The runner stays on `nvidia/z-ai/glm-5.3` (see "LLM providers used" in the
README). Switching to the gateway coding-smart chain is deliberately blocked
until that chain is verified — the chain work is owned by task-board #904,
#750, and #757, and this epic must not duplicate it. Do not point
`.github/runner-config.json` at the gateway chain before those issues close.

## Merge-order notes (keep the hardening intact)

- Children #936 and #937 branched before the retry budget landed, so their
  worker-release steps still post plain release comments. When they merge,
  route every release through `scripts/requeue-task.sh` so each attempt
  keeps consuming the same bounded budget — otherwise a repeatedly failing
  task can loop in the queue again (a "no infinite requeue" regression).
- #937 introduces `lease-until:` labels. `scripts/requeue-task.sh` already
  strips any `lease-until:` label it finds when releasing, so a crashed
  worker's lease cannot outlive its release.
- #938 validates and pins runner config; keep the model in
  `.github/runner-config.json` in sync with the README provider list, and do
  not unpin the model while child 6 is blocked.
- #942's rate-limit classification should stay compatible with the release
  reasons that `requeue-task.sh` records, so quota exhaustion remains
  distinguishable from auth or timeout failures in the board history.

## Re-arming a blocked task

`blocked:repeated-failure` means the retry budget was exhausted. Remove the
label and re-add `status:new` to give the task a fresh budget (see
[Retry budget](../README.md#retry-budget)).

## Verification

```bash
gh issue list -R ons96/task-board --label tag:github-actions --state open
```
