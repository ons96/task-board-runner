# GPT-5.6-sol Benchmark / Decision Log

Bounded usage log for temporary DLab GPT-5.6-sol credits (task-board #961).
Purpose: spend temporary free strong-reasoning access on high-value work where
it reduces rework, never on routine edits, and never as the only model.

## Policy (who gets sol)

- Sol is the FIRST entry in the runner fallback chain, not the only one: a
  failed request (auth, rate-limit, timeout, exhausted credit, provider error)
  falls through to trusted fallbacks (see "Fallback preservation" below).
- Use sol for reasoning-heavy, high-rework-risk work only. Per the #961
  recommended order: gateway/tunnel reliability, Keep/NPV schema and
  edge-case review (never raw-secret handling), runner reliability hardening,
  feasibility reviews. Routine edits, docs formatting, and mechanical fixes
  stay on the standard chain models.
- The active interactive session model is never switched to sol by this
  policy; only runner-dispatched task runs consume the credits.

## Fallback preservation (verified in code)

`task-worker.yml` provider chain (order preserved, 2026-10-11):

1. `dlab/gpt-5-6-sol` (temporary credits)
2. `nvidia/z-ai/glm-5.3` (trusted, verified-free)
3. `dlab-free/space-bunny`
4. `dlab-free/nemotron-3-ultra`
5. + any provider-manifest optional models

Each failed attempt advances to the next provider with bounded backoff
(`scripts/provider-failure.sh`); `provider-manifest.py` skips expired,
non-free, or uncredentialed entries. Temporary access is therefore never
pinned as the only model, and removing `DLAB_API_KEY` (post-expiry) degrades
to the trusted chain without code changes.

## Decision log

| Date | Task | Used sol? | Why | Outcome / evidence |
|---|---|---|---|---|
| 2026-09-27 | Runner provider chain extension | yes (as first fallback) | temporary credits are cheap-strong reasoning for retry-path failure analysis | commit `991f6a0` "add DLab GPT-5.6 Sol as first fallback"; verify-work self-tests passed; secret scan clean |
| 2026-09-28 | VPS-40 gateway/tunnel reliability diagnostic (#961 target 1) | yes | reliability diagnosis is exactly the high-rework-risk category | found local gateway healthy (127.0.0.1:8000) but laptop Tailscale IP changed to 100.79.87.92, tailnet mismatch documented; follow-up needed interactive Tailscale re-auth (not automatable) |
| 2026-09-28 | Routine backlog edit attempt (worker `gha-36367542699`) | no | no code changes produced; task released as "no changes" instead of burning credits on retries | requeued under retry budget |
| 2026-10-11 | This log + fallback verification | no | documentation/verification is routine; standard models suffice | chain order and fall-through verified in `task-worker.yml` and `provider-failure.sh` |

## Benchmarks

Throughput/tokens-per-run benchmarks are intentionally not fabricated here;
entries above record decisions and outcomes only. Next scheduled runs should
append per-run rows: run id, model that served the run, wall time, attempts,
result (PR / requeue / blocked). The runner already emits
`provider_failure kind=... model=...` lines into `agent-output.txt`, which is
the source for those rows.

## Credit retirement

When the temporary credits expire: remove the `DLAB_API_KEY` secret and drop
the `dlab/gpt-5-6-sol` entry from the `PROVIDERS` chain in `task-worker.yml`.
The provider manifest loader already skips uncredentialed entries, so no
other code changes are required. Log the retirement date here.
