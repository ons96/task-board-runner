# task-board-runner

Public GitHub Actions runner for [`ons96/task-board`](https://github.com/ons96/task-board). Claims issues, runs [opencode](https://opencode.ai) with free-tier LLM providers, opens PRs. Free (unlimited public Actions minutes).

## Why public

Private repos get 2000 Actions minutes/month; public repos get unlimited. The runner needs no secrets from `task-board` itself — it only reads OPEN issues and claims via `gh` CLI using a PAT hosted as a secret here.

## How it works

1. Cron schedule `*/30 * * * *` fires `claim-and-dispatch`.
2. The short dispatcher claims at most one issue with `claim-task.sh` and starts a `task-worker` run for it.
3. Workers share a single global concurrency group, so exactly one worker runs at a time; the rest queue.
4. Each worker clones the target repo on `work/$ISSUE_NUM`, runs opencode, pushes the branch, and opens a draft PR.
5. Issue locks survive dispatcher exit; workers release them on success, failure, or no-change paths.

## LLM providers used

Runner cannot reach the VPS-40 gateway (Tailscale-only) so it uses free DIRECT providers committed in `.github/runner-config.json`:

- `dlab` — GPT-5.6 Sol (`DLAB_API_KEY`, model `gpt-5-6-sol`, primary while temporary credit lasts)
- `dlab-free` — Space Bunny and Nemotron 3 Ultra (`DLAB_FREE_API_KEY`, free-only key)
- `nvidia` — GLM-5.3 (free, shared rate limits)

API keys live as GitHub Secrets in THIS repo:

- `DLAB_API_KEY` — temporary DLab Proxy key; omit or delete after its 24-hour credit expires
- `DLAB_FREE_API_KEY` — separate DLab free-only key; only free models are configured
- `TASK_BOARD_PAT` — fine-grained PAT with `repo` scope on `ons96/task-board` (used by `gh` CLI for claim/push). The default `GITHUB_TOKEN` cannot act on other repos.

Workers try DLab GPT-5.6 Sol, then NVIDIA GLM-5.3, followed by DLab free-key Space Bunny and Nemotron 3 Ultra. A nonzero `opencode run` exit moves to the next model; missing or expired DLab keys fail closed. After a successful run, the verification gate checks for a work product before the workflow opens a draft PR. DLab free-key models were trap-tested successfully; `atria-dawn-preview` was omitted because it returned 429 during testing. SiliconFlow GLM-5.3 was tested but is paid ($1.40/M input, $4.40/M output), so it is not configured.

## Reverting

```bash
gh repo delete ons96/task-board-runner --yes  # or archive it
```

## Scope filter

Only issues with `tag:cross-device` OR `tag:github-actions` are claimable. `device-local`, `vps-155`, `gateway-40` are skipped — those need their specific hardware. Override per workflow run via `workflow_dispatch` inputs.

## Manual run

GitHub → Actions tab → `Claim and Run Task` → `Run workflow` → optional `scope_filter` input (`cross-device,github-actions` default).

## Costs

- GitHub Actions: $0 (unlimited public minutes).
- LLM API: $0 (all free-tier providers).
- Bandwidth/storage: $0.

## License

MIT — see LICENSE.
