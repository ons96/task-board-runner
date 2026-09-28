# task-board-runner

Public GitHub Actions runner for [`ons96/task-board`](https://github.com/ons96/task-board). Claims issues, runs [opencode](https://opencode.ai) with free-tier LLM providers, opens PRs. Free (unlimited public Actions minutes).

## Why public

Private repos get 2000 Actions minutes/month; public repos get unlimited. The runner needs no secrets from `task-board` itself — it only reads OPEN issues and claims via `gh` CLI using a PAT hosted as a secret here. This runner supersedes the retired [`vps-gh-agent-loop`](https://github.com/ons96/vps-gh-agent-loop).

## How it works

1. Cron schedule `*/30 * * * *` fires `claim-and-dispatch`.
2. The short dispatcher claims up to four issues with `claim-task.sh` and starts one `task-worker` run per issue.
3. Workers run concurrently across different issues, with `task-$ISSUE_NUM` concurrency preventing duplicate workers for one issue.
4. Each worker clones the target repo on `work/$ISSUE_NUM`, runs opencode, pushes the branch, and opens a draft PR.
5. Issue locks survive dispatcher exit; workers release them on success, failure, or no-change paths.
6. Failed or empty runs requeue through the bounded [retry budget](#retry-budget); a task never loops in the queue forever.

## Retry budget

Releases go through `scripts/requeue-task.sh`, which counts the issue's `re-queued` release comments (worker releases, stale-lock sweeps, and dispatcher failures all consume the same budget). While attempts remain the task goes back to `status:new`; once the budget (3 retries) is exhausted the issue is labeled `blocked:repeated-failure` and left open for a human instead of requeueing. To re-arm a blocked task, remove the label and add `status:new`.

## LLM providers used

Runner cannot reach the VPS-40 gateway (Tailscale-only) so it uses free DIRECT providers committed in `.github/runner-config.json`:

- `groq` — llama-3.3-70b-versatile (12K TPM, free)
- `dlab` — GPT-5.6 Sol (`DLAB_API_KEY`, model `gpt-5-6-sol`, first fallback after NVIDIA; 24-hour paid credit)
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

Workers try NVIDIA first, then DLab GPT-5.6 Sol, then the existing KiosAPI, SiliconFlow, Mistral, and Together fallbacks. A failed request (including exhausted credits, authentication errors, rate limits, timeouts, and provider errors) moves to the next provider; the workflow only proceeds to verification after one provider exits successfully. Add `DLAB_API_KEY` as a repository secret; if absent or expired, DLab fails closed and the next fallback is attempted.

The primary model stays `nvidia/z-ai/glm-5.3` for now: switching to the gateway coding-smart chain is deliberately blocked until that chain is verified (task-board #904, #750, #757).

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
