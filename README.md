# task-board-runner

Public GitHub Actions runner for [`ons96/task-board`](https://github.com/ons96/task-board). Claims issues, runs [opencode](https://opencode.ai) with free-tier LLM providers, opens PRs. Free (unlimited public Actions minutes).

## Why public

Private repos get 2000 Actions minutes/month; public repos get unlimited. The runner needs no secrets from `task-board` itself — it only reads OPEN issues and claims via `gh` CLI using a PAT hosted as a secret here.

## How it works

1. Cron schedule `*/30 * * * *` fires the `claim-and-run` workflow.
2. Workflow runs `claim-task.sh` (copied from `task-board/scripts/`) with `--worker gha-$GITHUB_RUN_ID --scope github-actions,cross-device`.
3. If no claimable issue → exit 0 (no PR, no minutes wasted).
4. If claimed: clone target repo on a work branch `work/$ISSUE_NUM`, install opencode + minimal config, run `opencode --print "..."` against the issue body, push the branch, open a draft PR.
5. Issue labels flip to `status:in_progress` + `locked-by:gha-$RUN_ID`. Watchdog on `task-board` frees stale claims after 30 min.

## LLM providers used

Runner cannot reach the VPS-40 gateway (Tailscale-only) so it uses free DIRECT providers committed in `.github/runner-config.json`:

- `groq` — llama-3.3-70b-versatile (12K TPM, free)
- `cerebras` — llama3.1-8b, gpt-oss-120b, zai-glm-4.7 (free, higher TPM)
- `mistral` — mistral-large-latest (free, ~1B tok/mo)
- `together` — fallback (free-tier)

API keys live as GitHub Secrets in THIS repo:

- `GROQ_API_KEY`
- `CEREBRAS_API_KEY`
- `MISTRAL_API_KEY`
- `TOGETHER_API_KEY`
- `TASK_BOARD_PAT` — fine-grained PAT with `repo` scope on `ons96/task-board` (used by `gh` CLI for claim/push). The default `GITHUB_TOKEN` cannot act on other repos.

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
