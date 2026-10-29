#!/usr/bin/env python3
"""Pick a rotating subset of free LLM providers for one worker run.

Why this exists: the workflow used to try providers in a fixed order, always
starting with the same one. A free key on that provider was exhausted (and
eventually disabled) while the other configured providers sat idle.

Ordering rules:
  * Only providers with "enabled": true are eligible.
  * Providers marked "sensitive": true always sort after non-sensitive ones,
    so a small/rate-happy operator never leads a run.
  * Within each group the order is a weighted deterministic shuffle keyed by
    --seed, so consecutive runs start on different providers but a run is
    reproducible from its seed.

Usage:
  rotate-providers.py --config config/providers.json --seed "$GITHUB_RUN_ID"
  rotate-providers.py ... --limit 2 --exclude dlab-free-bunny
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", required=True)
    ap.add_argument("--seed", required=True, help="Stable per-run seed, e.g. the GitHub run id")
    ap.add_argument("--limit", type=int, default=0, help="Max providers to emit (0 = policy max_attempts_per_run)")
    ap.add_argument("--exclude", action="append", default=[], help="Provider id already tried this run")
    ap.add_argument("--format", choices=["model", "id", "json"], default="model")
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as fh:
        policy = json.load(fh)

    excluded = set(args.exclude)
    providers = [
        p for p in policy.get("providers", [])
        if p.get("enabled", True) and p.get("id") not in excluded
    ]
    if not providers:
        print("rotate-providers: no enabled providers left", file=sys.stderr)
        return 1

    providers.sort(
        key=lambda p: (
            1 if p.get("sensitive") else 0,
            rank(args.seed, p["id"], int(p.get("weight", 1))),
        )
    )
    limit = args.limit or int(policy.get("max_attempts_per_run", 0))
    if limit:
        providers = providers[:limit]

    if args.format == "json":
        print(json.dumps(providers, indent=2))
    else:
        for p in providers:
            print(p["id"] if args.format == "id" else p["model"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
