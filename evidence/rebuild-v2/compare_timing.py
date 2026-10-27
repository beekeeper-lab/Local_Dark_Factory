#!/usr/bin/env python3
"""compare_timing.py — per-bean, per-step compute time: seating-planner-py (v1,
the original build) vs seating-planner-py-v2 (the rebuild on the same, current
bean set and the same hidden-test suite). Run from Local_Dark_Factory.

For each bean, takes the LATEST run directory (the final attempt that reached
whatever state it's in) and sums each step's duration across every attempt
within that run, the same way factory/pipeline/telemetry-report.sh attributes
cost to a stage. v1's numbers are a fixed baseline (the original build is
finished and merged); v2's are live and this script is meant to be re-run after
every bean as the rebuild progresses.

usage: python3 compare_timing.py [--write evidence/rebuild-v2/timing-comparison.md]
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import statistics
from collections import defaultdict
from pathlib import Path

V1_ROOT = Path("/home/gregg/workspace/seating-planner-py/factory/runs")
V2_ROOT = Path("/home/gregg/workspace/seating-planner-py-v2/factory/runs")
COLS = ["spec", "build", "gate", "audit-spec", "audit-impl", "audit-doc", "audit-package", "doc", "ci"]


def parse_ts(s: str) -> dt.datetime:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def step_durations(steps_jsonl: Path) -> dict[str, float]:
    starts: dict[tuple, dt.datetime] = {}
    out: dict[str, float] = defaultdict(float)
    for line in steps_jsonl.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        key = (e.get("step"), e.get("attempt", 1))
        if e.get("event") == "start":
            starts[key] = parse_ts(e["ts"])
        elif e.get("event") == "end":
            dur = e.get("duration_s")
            if dur is None and key in starts:
                dur = (parse_ts(e["ts"]) - starts[key]).total_seconds()
            if dur is not None:
                out[e.get("step")] += dur
    return out


def final_state(run_dir: Path) -> str:
    rj = run_dir / "run.json"
    if not rj.is_file():
        return "?"
    try:
        body = json.loads(rj.read_text())
    except ValueError:
        return "?"
    status = body.get("status") or "?"
    if status == "halted":
        return f"halted@{body.get('halted_at_step', '?')}"
    return status


def runs_per_bean(root: Path) -> dict[str, list[str]]:
    out = defaultdict(list)
    for p in sorted(root.glob("bean-*-*/steps.jsonl")):
        run = p.parent.name
        bean = run.split("-20")[0]
        out[bean].append(run)
    return out


def final_run_per_bean(root: Path) -> dict[str, str]:
    rb = runs_per_bean(root)
    return {b: sorted(rs)[-1] for b, rs in rb.items()}


def totals_for(root: Path, run: str) -> dict[str, float]:
    return step_durations(root / run / "steps.jsonl")


def fmt_min(seconds: float) -> str:
    return f"{seconds / 60:.1f}"


def build_table(write_path: Path | None) -> None:
    v1_final = final_run_per_bean(V1_ROOT)
    v2_final = final_run_per_bean(V2_ROOT)
    all_beans = sorted(set(v1_final) | set(v2_final), key=lambda b: (len(b), b))

    lines = []
    lines.append(f"# Rebuild timing comparison — generated {dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')}")
    lines.append("")
    lines.append("v1 = seating-planner-py (original build, finished). v2 = seating-planner-py-v2 ")
    lines.append("(rebuild in progress, same bean set v1 current state, same hidden tests).")
    lines.append("Per-bean total is the sum of step durations across every attempt in that bean's")
    lines.append("final (or current, for v2) run directory — i.e. what the bean actually cost,")
    lines.append("retries included. 'state' is run.json's own status and can show a stale")
    lines.append("transient halt (e.g. a CI flake) for a bean that was actually merged later out")
    lines.append("of band via `factory reconcile`, which updates beanstate, not the old run.json;")
    lines.append("see `factory state <bean>` for the authoritative status.")
    lines.append("")
    header = "| bean | v1 state | v1 total (min) | v2 state | v2 total (min) | delta (min) | delta (%) |"
    sep = "|---|---|---|---|---|---|---|"
    lines.append(header)
    lines.append(sep)

    v1_total_sum = 0.0
    v2_total_sum = 0.0
    v2_done = 0
    for bean in all_beans:
        v1_run = v1_final.get(bean)
        v2_run = v2_final.get(bean)
        v1_total = sum(totals_for(V1_ROOT, v1_run).get(c, 0) for c in COLS) if v1_run else None
        v2_total = sum(totals_for(V2_ROOT, v2_run).get(c, 0) for c in COLS) if v2_run else None
        v1_state = final_state(V1_ROOT / v1_run) if v1_run else "—"
        v2_state = final_state(V2_ROOT / v2_run) if v2_run else "not started"
        if v1_total is not None:
            v1_total_sum += v1_total
        if v2_total is not None:
            v2_total_sum += v2_total
            if v2_state == "merged" or v2_state.startswith("ci") or v2_state.startswith("pr"):
                v2_done += 1
        delta = (v2_total - v1_total) if (v1_total is not None and v2_total is not None) else None
        delta_pct = (100 * delta / v1_total) if (delta is not None and v1_total) else None
        lines.append(
            f"| {bean} | {v1_state} | {fmt_min(v1_total) if v1_total is not None else '—'} "
            f"| {v2_state} | {fmt_min(v2_total) if v2_total is not None else '—'} "
            f"| {f'{delta/60:+.1f}' if delta is not None else '—'} "
            f"| {f'{delta_pct:+.0f}%' if delta_pct is not None else '—'} |"
        )

    lines.append("")
    lines.append(f"**v1 total (all {len(v1_final)} beans): {v1_total_sum/3600:.1f} hours**")
    lines.append(f"**v2 total so far ({len(v2_final)} beans with at least one run): {v2_total_sum/3600:.1f} hours**")
    lines.append("")

    # per-step aggregate comparison, only over beans v2 has actually run
    lines.append("## Per-step totals, beans v2 has run so far (minutes)")
    lines.append("")
    lines.append("| step | v1 (same beans) | v2 | delta |")
    lines.append("|---|---|---|---|")
    for col in COLS:
        v1_sum = sum(totals_for(V1_ROOT, v1_final[b]).get(col, 0) for b in v2_final if b in v1_final)
        v2_sum = sum(totals_for(V2_ROOT, v2_final[b]).get(col, 0) for b in v2_final)
        d = v2_sum - v1_sum
        lines.append(f"| {col} | {fmt_min(v1_sum)} | {fmt_min(v2_sum)} | {d/60:+.1f} |")

    out = "\n".join(lines) + "\n"
    print(out)
    if write_path:
        write_path.parent.mkdir(parents=True, exist_ok=True)
        write_path.write_text(out)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", type=Path, default=None)
    a = ap.parse_args()
    build_table(a.write)
