#!/usr/bin/env python3
"""telemetry-summary.py — the line's quality numbers across runs (§11, Phase 4 task 8).

telemetry-report.sh answers "what did this run cost, step by step" from Pi's
session logs. This answers the questions a line running unattended for two days
is judged by, across every run in a repository, from records the runs already
write:

  task attempts          tasks.jsonl: attempts per task, first-try rate
  revise rate per stage  verdicts/*.judgement.json: revise or reject / judgements
  stamp rate             a judgement audit-check accepted (verdicts/<t>.attempt-N.json)
  judge wall-clock       judged_by.seconds per audit
  refusals by rule       verdicts/*.refused.json
  swap overhead %        model-loads.jsonl load_seconds / the run's wall clock
  blocked reasons        run.json halted_at_step, and where a task blocked
  false approvals        a stamped accept on code the pre-merge review then found
                         a defect in, classed by the review index's defect_class
                         (the human_rejection_reason values in event.schema.json)

The review index is evidence/reviews/index.jsonl in the factory repository: one
line per pre-merge review {run_id, verdict, defect_class}. A review with no line
there is counted as unindexed, never as clean.

usage: telemetry-summary.py <runs_root>... [--reviews <index.jsonl>] [--json <out>]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path


def ts(s: str) -> dt.datetime:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def jl(p: Path) -> list[dict]:
    if not p.is_file():
        return []
    out = []
    for line in p.read_text(errors="replace").splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def jf(p: Path) -> dict:
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return {}


def one_run(d: Path, reviews: dict) -> dict:
    rj = jf(d / "run.json")
    steps = jl(d / "steps.jsonl")
    stamps = [ts(s["ts"]) for s in steps if s.get("ts")]
    wall = (max(stamps) - min(stamps)).total_seconds() if len(stamps) > 1 else 0.0
    # Time inside steps, not first-to-last: a run that halted on Friday and was
    # resumed on Sunday spent two days waiting, and dividing load time by that
    # reported a swap overhead of 0.03% (bean-024).
    opened, active = {}, 0.0
    for s_ in steps:
        k = (s_.get("step"), s_.get("attempt"))
        if s_.get("event") == "start" and s_.get("ts"):
            opened[k] = ts(s_["ts"])
        elif s_.get("event") == "end" and k in opened:
            active += max(0.0, (ts(s_["ts"]) - opened.pop(k)).total_seconds())

    tasks = defaultdict(list)
    for e in jl(d / "tasks.jsonl"):
        if e.get("event") == "attempt":
            tasks[e["task"]].append(e.get("result"))

    audits = []
    vd = d / "verdicts"
    for j in sorted(vd.glob("*.attempt-*.judgement.json")) if vd.is_dir() else []:
        target, attempt = j.name.split(".attempt-")[0], j.name.split(".attempt-")[1].split(".")[0]
        body = jf(j)
        audits.append({"target": target, "attempt": int(attempt), "verdict": body.get("verdict"),
                       "seconds": (body.get("judged_by") or {}).get("seconds"),
                       "stamped": (vd / f"{target}.attempt-{attempt}.json").is_file()})
    refusals = [jf(r).get("rule") or "?" for r in sorted(vd.glob("*.refused.json"))] if vd.is_dir() else []

    loads = jl(d / "model-loads.jsonl")
    load_s = sum(float(x.get("load_seconds") or 0) for x in loads)

    blocked = None
    if rj.get("status") == "halted":
        blocked = rj.get("halted_at_step") or "?"
        for b in (d / "build").glob("*/BLOCKED.md") if (d / "build").is_dir() else []:
            blocked = f"build:{b.parent.name}"
    rv = reviews.get(rj.get("run_id") or d.name)
    return {
        "run_id": rj.get("run_id") or d.name, "bean": rj.get("bean_id") or rj.get("bean"),
        "status": rj.get("status"), "wall_seconds": round(wall), "active_seconds": round(active),
        "tasks": dict(tasks),
        "audits": audits, "refusals": refusals, "loads": len(loads), "load_seconds": round(load_s, 1),
        "swap_overhead_pct": round(100 * load_s / active, 2) if active else None,
        "blocked_at": blocked, "review": rv,
    }


def summarise(runs: list[dict]) -> dict:
    attempts = [len(v) for r in runs for v in r["tasks"].values()]
    first = [v[0] == "verified" for r in runs for v in r["tasks"].values() if v]
    per_stage = defaultdict(lambda: {"judgements": 0, "revise_or_reject": 0, "stamped": 0, "seconds": []})
    for r in runs:
        for a in r["audits"]:
            s = per_stage[a["target"]]
            s["judgements"] += 1
            s["revise_or_reject"] += a["verdict"] in ("revise", "reject")
            s["stamped"] += bool(a["stamped"])
            if a["seconds"] is not None:
                s["seconds"].append(a["seconds"])
    stages = {k: {"judgements": v["judgements"],
                  "revise_rate": round(v["revise_or_reject"] / v["judgements"], 3) if v["judgements"] else None,
                  "stamp_rate": round(v["stamped"] / v["judgements"], 3) if v["judgements"] else None,
                  "judge_seconds_median": statistics.median(v["seconds"]) if v["seconds"] else None,
                  "judge_seconds_max": max(v["seconds"]) if v["seconds"] else None}
              for k, v in sorted(per_stage.items())}
    wall = sum(r["active_seconds"] for r in runs if r["loads"])
    load = sum(r["load_seconds"] for r in runs)
    # A false approval: the line stamped an accept on code a review then found a
    # defect in. Only stamped accepts count; an advisory accept approved nothing.
    false_approvals = Counter()
    reviewed = defective = 0
    for r in runs:
        rv = r["review"]
        if not rv:
            continue
        reviewed += 1
        if rv.get("defect_class"):
            defective += 1
            if any(a["stamped"] and a["verdict"] == "accept" and a["target"] in ("impl", "package")
                   for a in r["audits"]):
                false_approvals[rv["defect_class"]] += 1
    return {
        "runs": len(runs),
        "task_attempts": {"tasks": len(attempts), "mean": round(statistics.mean(attempts), 2) if attempts else None,
                          "first_try_rate": round(sum(first) / len(first), 3) if first else None},
        "stages": stages,
        "refusals_by_rule": dict(Counter(x for r in runs for x in r["refusals"]).most_common()),
        "swap_overhead_pct": round(100 * load / wall, 2) if wall else None,
        "loads": sum(r["loads"] for r in runs),
        "blocked_reasons": dict(Counter(r["blocked_at"] for r in runs if r["blocked_at"]).most_common()),
        "reviews": {"indexed": reviewed, "with_defect": defective,
                    "unindexed_runs": sum(1 for r in runs if not r["review"])},
        "false_approvals_by_class": dict(false_approvals),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("runs_roots", nargs="+")
    ap.add_argument("--reviews")
    ap.add_argument("--json", dest="out")
    a = ap.parse_args()
    reviews = {r["run_id"]: r for r in jl(Path(a.reviews))} if a.reviews else {}
    runs = []
    for root in a.runs_roots:
        for d in sorted(Path(root).glob("bean-*-*")):
            if (d / "run.json").is_file():
                runs.append(one_run(d, reviews))
    s = summarise(runs)
    if a.out:
        Path(a.out).write_text(json.dumps({"summary": s, "runs": runs}, indent=2) + "\n")
    ta = s["task_attempts"]
    print(f"runs {s['runs']} · tasks {ta['tasks']} · mean attempts {ta['mean']} · first try {ta['first_try_rate']}")
    print(f"swap overhead {s['swap_overhead_pct']}% over {s['loads']} loads")
    print("\nstage      judgements  revise  stamped  judge s (median/max)")
    for k, v in s["stages"].items():
        print(f"{k:10} {v['judgements']:>10}  {v['revise_rate']!s:>6}  {v['stamp_rate']!s:>7}  "
              f"{v['judge_seconds_median']}/{v['judge_seconds_max']}")
    print(f"\nrefusals by rule: {s['refusals_by_rule'] or 'none'}")
    print(f"blocked: {s['blocked_reasons'] or 'none'}")
    rv = s["reviews"]
    print(f"reviews: {rv['indexed']} indexed, {rv['with_defect']} with a defect, {rv['unindexed_runs']} runs unindexed")
    print(f"false approvals by class: {s['false_approvals_by_class'] or 'none'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
