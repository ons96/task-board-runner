#!/usr/bin/env python3
"""Pick a rotating subset of free LLM providers for one worker run.

Why this exists: the workflow used to try providers in a fixed order, always
starting with the same one. A free key on that provider was exhausted (and
eventually disabled) while the other configured providers sat idle.

Eligibility is fail-closed on quality:
  * "enabled" must be true.
  * The provider's "tier" must equal the policy's require_tier (normally
    "approved"). A "utility" provider is fine for short jobs but never for
    agentic issue work; "blocked" is always excluded.
  * The provider must carry a measured "score" (agentic coding) at or above
    the policy's "min_agentic_coding_score". A missing/null score excludes it -
    an autonomous agent on an unmeasured model can confidently ship wrong work.
  * Excluded by --exclude.

Ordering:
  * Sensitive providers (small operators that disable keys for overuse) always
    sort after non-sensitive ones, so they never lead a run.
  * Within each group the order is a weighted deterministic shuffle keyed by
    --seed, so consecutive runs start on different providers while a run stays
    reproducible from its seed.

Usage:
  rotate-providers.py --config config/providers.json --seed "$GITHUB_RUN_ID"
  rotate-providers.py ... --explain
  rotate-providers.py ... --limit 1 --exclude nvidia-gpt-oss-20b
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys


def rank(seed: str, provider_id: str, weight: int) -> str:
    """Lowest hash across `weight` draws -> higher weight sorts earlier more often."""
    return min(
        hashlib.sha256(f"{seed}:{provider_id}:{i}".encode()).hexdigest()
        for i in range(max(1, weight))
    )


def eligibility(
    provider: dict,
    min_score: float,
    require_tier: str,
    min_coverage: int,
    excluded: set[str],
) -> tuple[bool, str]:
    pid = provider.get("id", "<missing-id>")
    if not provider.get("enabled", True):
        return False, "disabled"
    if pid in excluded:
        return False, "excluded by --exclude"
    tier = provider.get("tier", "blocked")
    if tier != require_tier:
        return False, f"tier={tier} (requires {require_tier})"
    if provider.get("owner_pinned"):
        # ponytail: owner explicitly chose this model; score/coverage floors are for auto-picked ones
        return True, f"owner_pinned (score {provider.get('score')})"
    coverage = int((provider.get("benchmarks") or {}).get("coverage", 0))
    if coverage < min_coverage:
        return False, f"benchmark coverage {coverage} < {min_coverage}"
    score = provider.get("score")
    if score is None:
        return False, "no measured quality score (fail closed)"
    try:
        score = float(score)
    except (TypeError, ValueError):
        return False, f"invalid score {score!r}"
    if score < min_score:
        return False, f"score {score:g} < minimum {min_score:g}"
    return True, f"score {score:g} >= {min_score:g}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True)
    ap.add_argument("--seed", required=True, help="Stable per-run seed, e.g. the GitHub run id")
    ap.add_argument("--limit", type=int, default=0, help="Max providers to emit (0 = policy max_attempts_per_run)")
    ap.add_argument("--exclude", action="append", default=[], help="Provider id already tried this run")
    ap.add_argument("--format", choices=["model", "id", "json"], default="model")
    ap.add_argument("--explain", action="store_true", help="Print eligibility reasons to stderr")
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as fh:
        policy = json.load(fh)

    quality = policy.get("quality_policy", policy)
    if "min_agentic_coding_score" not in quality:
        print("rotate-providers: policy has no min_agentic_coding_score; refusing to guess", file=sys.stderr)
        return 2
    min_score = float(quality["min_agentic_coding_score"])
    require_tier = str(quality.get("require_tier", "approved"))
    min_coverage = int(quality.get("min_benchmark_coverage", 0))
    excluded = set(args.exclude)

    eligible: list[dict] = []
    for provider in policy.get("providers", []):
        ok, reason = eligibility(provider, min_score, require_tier, min_coverage, excluded)
        if args.explain:
            print(f"  {provider.get('id', '?'):24} {'ELIGIBLE' if ok else 'skip':8} {reason}", file=sys.stderr)
        if ok:
            eligible.append(provider)

    if not eligible:
        print(
            "rotate-providers: no eligible providers (every provider is disabled, unscored, "
            f"not tier={require_tier}, below min_agentic_coding_score, or excluded)",
            file=sys.stderr,
        )
        return 2

    eligible.sort(
        key=lambda p: (
            1 if p.get("sensitive") else 0,
            int(p.get("priority", 100)),
            rank(args.seed, p["id"], int(p.get("weight", 1))),
        )
    )
    limit = args.limit or int(policy.get("max_attempts_per_run", 0))
    if limit:
        eligible = eligible[:limit]

    if args.format == "json":
        print(json.dumps(eligible, indent=2))
    else:
        for p in eligible:
            print(p["id"] if args.format == "id" else p["model"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
