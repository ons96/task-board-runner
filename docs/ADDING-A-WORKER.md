# Adding a worker

How to add and safely operate an autonomous task-board worker. A worker is a
GitHub Actions job in this repo that claims an issue from
[`ons96/task-board`](https://github.com/ons96/task-board), runs
[opencode](https://opencode.ai) on the target repository, and opens a draft PR
from a `work/<issue>` branch.

Free-tier only: this repo is public (unlimited Actions minutes) and every
configured model provider is free-tier. Never add paid providers or depend on
paid infrastructure.

## Prerequisites

- **Task board** — [`ons96/task-board`](https://github.com/ons96/task-board)
  holds the queue. Issues must carry the labels described in
  [Labels and scopes](#labels-and-scopes); unlabelled issues are never claimed.
- **Gateway** — the VPS-40 LLM gateway is Tailscale-only and unreachable from
  public GitHub runners. Workers therefore use the free DIRECT providers
  configured in `.github/runner-config.json`. Do not point a worker at the
  gateway or any other private-network service.

## Moving parts

- `.github/workflows/claim-and-dispatch.yml` — dispatcher: claims up to
  `max_tasks` issues and starts one worker per issue.
- `.github/workflows/task-worker.yml` — worker: runs opencode, verifies the
  result, pushes, opens the draft PR.
- `.github/workflows/self-test.yml` — CI: shell syntax, verification-gate
  self-tests, and YAML validation.
- `scripts/claim-task.sh` — atomic claim (priority order, scope filter, lock
  confirmation).
- `scripts/verify-work.sh` — verification gate; `--self-test` exercises the
  false-done cases.
- `.github/runner-config.json` — committed opencode config: model, providers,
  MCP decisions.

## Workflow triggers

- **Claim and Dispatch Tasks** — `schedule: */30 * * * *` plus manual
  `workflow_dispatch` with inputs `scope_filter` (default
  `cross-device,github-actions`) and `max_tasks` (default `4`, clamped to 8).
  Concurrency group `claim-and-dispatch` allows one dispatcher run at a time.
- **Run Task Worker** — `workflow_dispatch` only; started by the dispatcher
  with `issue_number`, `project`, and `lock_label`. Concurrency group
  `task-<issue_number>` blocks duplicate workers on one issue. Job timeout is
  45 minutes (the opencode step gets 40).
- **Runner Self-Test** — on push or pull request touching `scripts/**` or
  `.github/workflows/**`, and on manual dispatch.

## Labels and scopes

An issue is claimable only with all of:

- `status:new` — available. A claim moves it to `status:in_progress`; verified
  success to `status:done`; every failure path back to `status:new`.
- `priority:P0` … `priority:P9` — lower number first.
- `tag:<scope>` — one of `cross-device`, `device-local`, `vps-155`,
  `gateway-40`, `github-actions`. `cross-device` is always claimable; other
  scopes must also appear in the dispatcher's `scope_filter`. This runner's
  default scope is `cross-device,github-actions`; hardware-bound scopes
  (`device-local`, `vps-155`, `gateway-40`) are skipped because their tasks
  need specific machines. An issue with no recognized tag is treated as
  always-claimable — tag issues deliberately.
- `project:<repo>` — target repository under the `ons96` org, e.g.
  `project:task-board-runner`.

## Locks

- `scripts/claim-task.sh` claims atomically: it adds `status:in_progress` plus
  `locked-by:<worker-id>` (e.g. `locked-by:gha-<run-id>-<n>`; lock labels are
  auto-created), removes `status:new`, waits 2 s, re-reads the issue, and skips
  it if a different lock is present.
- The `task-<issue_number>` workflow concurrency group is the second guard
  against duplicate workers.
- Locks survive dispatcher exit; each worker releases its own lock on success,
  failure, and no-change paths (`Release task`, `if: always()`).
- Every dispatcher run sweeps locks older than 1 hour (worker jobs cap at 45
  minutes) and requeues those issues as `status:new`.

Safe operation: do not delete a `work/<issue>` branch or edit `status:*` /
`locked-by:*` labels while a worker is active — the worker resumes that branch
and owns the lock until it releases it.

## Secrets

All credentials are GitHub Actions secrets in this repo. Reference them only
as `${{ secrets.NAME }}` in workflows or `{env:NAME}` in
`runner-config.json`. Never write secret values into issues, comments,
commits, docs, or workflow files.

- `TASK_BOARD_PAT` — PAT used by `gh` and `actions/checkout`. It must be able
  to list/edit/comment/close issues on `ons96/task-board` and to push branches
  and open PRs on the target repos. The default `GITHUB_TOKEN` cannot act on
  other repositories.
- `NVIDIA_API_KEY` — primary model provider (free tier).
- `DLAB_API_KEY` — first fallback; temporary key, delete the secret once its
  credit expires. A missing or expired key simply falls through to the next
  provider.
- `KIOSAPI_API_KEY`, `SILICONFLOW_API_KEY`, `MISTRAL_API_KEY`,
  `TOGETHER_API_KEY` — remaining free-tier fallbacks.

Add secrets under Settings → Secrets and variables → Actions (or
`gh secret set NAME`). Minimum viable worker: `TASK_BOARD_PAT` +
`NVIDIA_API_KEY`; missing fallback keys just move the run to the next
provider.

## Model configuration

- `.github/runner-config.json` is the committed opencode config: default model
  `nvidia/z-ai/glm-5.3`, `logLevel: WARN`, auto-compaction off, and API keys
  referenced via `{env:NAME}` so no values live in the repo.
- MCP/plugin decisions: every MCP server is disabled in the runner config
  (leanctx, context7, agentmemory) because the runner cannot reach
  Tailscale-only services and runs must stay hermetic. The worker also sets
  `OPENCODE_DISABLE_DEFAULT_PLUGINS`,
  `OPENCODE_DISABLE_EXTERNAL_SKILLS`, and
  `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`.
- Provider fallback chain, in the `Run opencode on claimed issue` step of
  `task-worker.yml`:

  1. `nvidia/z-ai/glm-5.3`
  2. `dlab/gpt-5-6-sol`
  3. `kiosapi/muse-spark-1.3-contributor`
  4. `siliconflow/z-ai/glm-5.3`
  5. `mistral/mistral-large-latest`
  6. `together/meta-llama/Llama-3.3-70B-Instruct-Turbo`

  The first provider that exits 0 wins. Exhausted credits, auth failures,
  rate limits, timeouts, and provider errors all fall through to the next
  provider; if every provider fails, the step fails before anything is pushed
  or marked done.

To change models: edit the provider block in `runner-config.json` (always
`{env:...}` for the key), map the new `*_API_KEY` env in `task-worker.yml`,
add the secret, and update the `PROVIDERS` array in your desired fallback
order. Keep every provider free-tier.

## Verification gate

`scripts/verify-work.sh` decides whether a run produced real work. A run
passes only when the agent log is at least 200 bytes, the work branch
resolves, the baseline commit is valid, and the tree shows a diff, untracked
files, or commits since baseline — and, when the target repo has
`package.json` or `pyproject.toml`, its tests (`npm test` / `pytest`) pass.
Log-only runs, missing commits, and failing tests never pass.

The workflow records the verdict without failing the job. On pass: push
`work/<issue>`, open a draft PR against `main`, relabel `status:done`, close
the issue. On fail: requeue (below).

## Failure handling

- **Salvage partial work** (`if: failure()`): commit uncommitted work as
  `wip(#<issue>)` and push the branch, so the next attempt resumes rather
  than restarts.
- **Release task** (`if: always()`): unless the gate passed and the job
  succeeded, remove `status:in_progress` and the lock, relabel `status:new`,
  and comment the reason — "no changes", "job failed (<status>)", or
  "verification failed: <reason>".
- **Stale-lock sweep**: locks untouched for over an hour are released and
  requeued by the dispatcher.
- **Artifacts**: `agent-output.txt` and the worker's `HEAD` are uploaded for
  7 days for post-mortems.
- The worker prompt requires incremental commits (about every 10 minutes) so
  partial progress survives step timeouts; the next run resumes
  `work/<issue>` and continues from those commits.

## Bringing up a worker

1. Confirm the [prerequisites](#prerequisites) and that target issues carry
   `status:new`, a priority, a claimable `tag:` scope, and `project:<repo>`.
2. Fork or clone this public repository — no local services are required.
3. Add the [secrets](#secrets): at minimum `TASK_BOARD_PAT` and
   `NVIDIA_API_KEY`.
4. Check the PAT can list and edit issues on `ons96/task-board` and push to
   the target repos.
5. Run **Claim and Dispatch Tasks** manually (Actions tab → Run workflow),
   optionally narrowing `scope_filter` (e.g. `github-actions`), or wait for
   the 30-minute cron.
6. Watch the run: the dispatcher comments each claim; the worker creates or
   resumes `work/<issue>`; the issue moves to `status:done` with a draft PR
   only after the verification gate passes.

## Minimal local validation checklist

From a clean checkout — no network, tokens, or secrets required. Mirrors the
**Runner Self-Test** workflow:

```bash
git clone https://github.com/ons96/task-board-runner.git
cd task-board-runner
bash -n scripts/claim-task.sh              # claim script parses
bash -n scripts/verify-work.sh              # gate script parses
bash scripts/verify-work.sh --self-test    # all false-done cases pass
python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]; print('YAML OK')"
git grep -nE 'ghp_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+' || echo "no token values committed"
```

Do not run `scripts/claim-task.sh` with an authenticated `gh` unless you
intend to claim real issues — the script operates on the live task board.
