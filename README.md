# task-board-runner

Public GitHub Actions runner for [`ons96/task-board`](https://github.com/ons96/task-board). Claims issues, runs [opencode](https://opencode.ai) with free-tier LLM providers, opens PRs. Free (unlimited public Actions minutes).

## Why public

Private repos get 2000 Actions minutes/month; public repos get unlimited. The runner needs no secrets from `task-board` itself — it only reads OPEN issues and claims via `gh` CLI using a PAT hosted as a secret here.

## How it works

1. Cron schedule `*/30 * * * *` fires `claim-and-dispatch`.
2. The short dispatcher claims up to four issues with `claim-task.sh` and starts one `task-worker` run per issue.
3. Workers run concurrently across different issues, with `task-$ISSUE_NUM` concurrency preventing duplicate workers for one issue.
4. Each worker clones the target repo on `work/$ISSUE_NUM`, runs opencode, pushes the branch, and opens a draft PR.
5. A verify gate (`scripts/verify-work-product.sh`, ported from task-board-loop, task #932) rejects trivial work products — diffs under 2 files touched or 5 insertions vs `main`, with lockfile+manifest bumps whitelisted — and requeues the issue `status:new` with a reason comment instead of marking it done.
6. Issue locks survive dispatcher exit; workers release them on success, failure, no-change, or verify-fail paths.

## LLM providers used

Runner cannot reach the VPS-40 gateway (Tailscale-only) so it uses free DIRECT providers committed in `.github/runner-config.json`:

- `groq` — llama-3.3-70b-versatile (12K TPM, free)
- `cerebras` — llama3.1-8b, gpt-oss-120b, zai-glm-4.7 (free, higher TPM)
- `mistral` — mistral-large-latest (free, ~1B tok/mo)
- `together` — fallback (free-tier)

API keys live as GitHub Secrets in THIS repo:

- `NVIDIA_API_KEY`
- `KIOSAPI_API_KEY`
- `SILICONFLOW_API_KEY`
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

## Self-tests

`Runner Self-Test` runs on pushes and PRs touching `scripts/**` or workflows: shell syntax checks, workflow YAML validation, and verify-gate fixtures proving trivial diffs are rejected, real diffs pass, and lockfile-only bumps are whitelisted (`scripts/verify-work-product.sh --self-test`).

## Costs

- GitHub Actions: $0 (unlimited public minutes).
- LLM API: $0 (all free-tier providers).
- Bandwidth/storage: $0.

## License

MIT — see LICENSE.
