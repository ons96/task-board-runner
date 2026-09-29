# task-board-runner

Public GitHub Actions runner for [`ons96/task-board`](https://github.com/ons96/task-board). Claims issues, runs [opencode](https://opencode.ai) with free-tier LLM providers, opens PRs. Free (unlimited public Actions minutes).

## Why public

Private repos get 2000 Actions minutes/month; public repos get unlimited. The runner needs no secrets from `task-board` itself — it only reads OPEN issues and claims via `gh` CLI using a PAT hosted as a secret here.

## How it works

1. Cron schedule `*/30 * * * *` fires `claim-and-dispatch`.
2. The short dispatcher claims up to four issues with `claim-task.sh` and starts one `task-worker` run per issue.
3. Workers run concurrently across different issues, with `task-$ISSUE_NUM` concurrency preventing duplicate workers for one issue.
4. Each worker clones the target repo on `work/$ISSUE_NUM`, runs opencode, pushes the branch, and opens a draft PR.
5. Issue locks survive dispatcher exit; workers release them on success, failure, or no-change paths.

## LLM providers used

Runner cannot reach the VPS-40 gateway (Tailscale-only) so it uses free DIRECT providers committed in `.github/runner-config.json`:

- `groq` — llama-3.3-70b-versatile (12K TPM, free)
- `dlab` — GPT-5.6 Sol (`DLAB_API_KEY`, model `gpt-5-6-sol`, primary while temporary credit lasts)
- `cerebras` — llama3.1-8b, gpt-oss-120b, zai-glm-4.7 (free, higher TPM)
- `mistral` — mistral-large-latest (free, ~1B tok/mo)
- `together` — fallback (free-tier)

API keys live as GitHub Secrets in THIS repo:

- `NVIDIA_API_KEY`
- `DLAB_API_KEY` — temporary DLab Proxy key; omit or delete after its 24-hour credit expires
- `KIOSAPI_API_KEY`
- `SILICONFLOW_API_KEY`
- `MISTRAL_API_KEY`
- `TOGETHER_API_KEY`
- `TASK_BOARD_PAT` — fine-grained PAT with `repo` scope on `ons96/task-board` (used by `gh` CLI for claim/push). The default `GITHUB_TOKEN` cannot act on other repos.

Workers try DLab GPT-5.6 Sol first, then NVIDIA, KiosAPI, SiliconFlow, Mistral, and Together. A failed request (including exhausted credits, authentication errors, rate limits, timeouts, and provider errors) moves to the next provider; the workflow only proceeds to verification after one provider exits successfully. Add `DLAB_API_KEY` as a repository secret; if absent or expired, DLab fails closed and NVIDIA is attempted next.

Provider failures are logged as `provider_failure` records without response bodies or credentials. Rate limits are classified separately and use bounded 1s/5s/25s/30s backoff before the next approved provider; auth failures are not retried against the same provider.

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
