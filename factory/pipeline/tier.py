#!/usr/bin/env python3
"""tier.py — compute the binding risk tier of a change from the paths it touched.

    final_tier = max(policy_tier, bean_suggested_tier, judge_suggested_tier)

Every term can raise the tier and none can lower it. That asymmetry is the whole
design: §08 says "a model that under-reads its change cannot down-classify it",
and the forked pipeline got this exactly backwards — it read the tier out of a
line in the bean's own markdown, so a model that believed its change was small
was believed.

The policy term comes from the diff, not from anyone's opinion of the diff. A
path that matches no rule takes `default_tier`, which is the only defaulting that
happens here: an unmatched path is ordinary, not free.

usage:
  tier.py --policy <risk-policy.yaml|json> --paths-from <file|-> [--bean-tier N]
          [--judge-tier N] [--json]

Prints a human-readable explanation, or JSON with --json. Exit 0 always unless
the inputs are unusable — the tier is an answer, not a verdict.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contain import matches  # noqa: E402


def load_policy(path: Path) -> dict:
    text = path.read_text()
    if path.suffix in (".yaml", ".yml"):
        try:
            import yaml
        except ImportError:
            sys.exit("tier: python3 has no PyYAML; pass the policy as JSON or install it")

        class StringDateLoader(yaml.SafeLoader):
            pass

        StringDateLoader.add_constructor(
            "tag:yaml.org,2002:timestamp", yaml.SafeLoader.construct_yaml_str
        )
        return yaml.load(text, Loader=StringDateLoader)
    return json.loads(text)


def classify(policy: dict, paths: list[str]) -> dict:
    """Per-path tier and the rule that set it, plus the maximum over all paths."""
    default_tier = policy.get("default_tier", 1)
    rules = policy.get("rules") or []

    per_path = []
    for path in paths:
        path = path.strip()
        if not path:
            continue
        # Highest tier wins among everything that MATCHES; default_tier applies
        # only when nothing matches at all. Seeding the maximum with default_tier
        # instead would quietly kill every rule below it — the policy's own
        # tier-0 documents rule would never fire under a default_tier of 1, and
        # the file would read as if it did.
        matched = [r for r in rules if matches(path, r["match"])]
        if matched:
            best = max(matched, key=lambda r: r["min_tier"])
            entry = {
                "path": path,
                "tier": best["min_tier"],
                "rule": best["match"],
                "reason": best.get("reason") or best["match"],
            }
            if len(matched) > 1:
                entry["also_matched"] = [
                    r["match"] for r in matched if r["match"] != best["match"]
                ]
        else:
            entry = {
                "path": path,
                "tier": default_tier,
                "rule": None,
                "reason": f"no rule matched; default_tier {default_tier}",
            }
        per_path.append(entry)

    policy_tier = max((p["tier"] for p in per_path), default=default_tier)
    return {"policy_tier": policy_tier, "paths": per_path, "default_tier": default_tier}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--policy", required=True)
    ap.add_argument("--paths-from", default="-")
    ap.add_argument("--paths", default=None, help="JSON array, instead of --paths-from")
    ap.add_argument("--bean-tier", type=int, default=None,
                    help="the bean's suggested_risk_tier (advisory; can only raise)")
    ap.add_argument("--judge-tier", type=int, default=None,
                    help="the judge's suggested tier (advisory; can only raise)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    policy_path = Path(args.policy)
    if not policy_path.is_file():
        print(f"tier: policy not found: {policy_path}", file=sys.stderr)
        return 2
    policy = load_policy(policy_path)
    for key in ("default_tier", "rules"):
        if key not in policy:
            print(f"tier: policy has no {key}: {policy_path}", file=sys.stderr)
            return 2

    if args.paths is not None:
        paths = json.loads(args.paths)
    elif args.paths_from == "-":
        paths = sys.stdin.read().splitlines()
    else:
        paths = Path(args.paths_from).read_text().splitlines()

    result = classify(policy, paths)
    terms = {
        "policy": result["policy_tier"],
        "bean_suggested": args.bean_tier,
        "judge_suggested": args.judge_tier,
    }
    final = max(v for v in terms.values() if v is not None)
    binding = [k for k, v in terms.items() if v == final]

    out = {
        "final_tier": final,
        "terms": terms,
        "binding_term": binding,
        "policy_version": policy.get("policy_version"),
        "paths": result["paths"],
        "never_auto_merged": final >= 3,
    }

    if args.json:
        print(json.dumps(out, indent=2))
        return 0

    print(f"binding tier: {final}   (policy {result['policy_tier']}"
          f", bean {terms['bean_suggested']}, judge {terms['judge_suggested']}"
          f" — max wins, nothing lowers it)")
    print(f"set by: {', '.join(binding)}")
    if out["never_auto_merged"]:
        print("tier 3: never auto-merged in any merge mode (§08)")
    print()
    width = max((len(p["path"]) for p in result["paths"]), default=4)
    for p in sorted(result["paths"], key=lambda x: (-x["tier"], x["path"])):
        print(f"  {p['tier']}  {p['path']:<{width}}  {p['reason']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
