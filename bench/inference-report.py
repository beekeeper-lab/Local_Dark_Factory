#!/usr/bin/env python3
"""inference-report.py — where a run's inference seconds went, per role.

Reads one or more calls.jsonl files written by factory/pipeline/inference-recorder.py
(a run's <run>/inference/calls.jsonl, or a replay's
bench/results/inference-replay-<label>-<ts>.jsonl) and prints, for each
(label, role):

  n                       model calls
  ttft p50/p90            seconds to the first generated chunk (streamed calls only)
  prefill tok/s p50/p90   prompt_eval_count / prompt_eval_duration
  decode tok/s p50/p90    eval_count / eval_duration
  ISL p50/p90             prompt tokens in
  OSL p50/p90             tokens out
  prefill/decode/load %   each one's summed seconds over the summed wall seconds
                          of the calls that reported them; `other` is the rest —
                          queueing, the network, the server's own bookkeeping

Percentiles interpolate linearly between the two nearest ranks (numpy's default,
statistics.quantiles(method="inclusive")): p50 of 1..10 is 5.5, p90 is 9.1. A
value that is null in a record — a /v1 call has counts and no durations, a
non-streamed call has no TTFT — is left out of that column rather than counted
as zero, and `n` beside each column says how many there were.

Label is the record's tags.label (replays set it); a live run has none and shows
as `-`. A replay's provenance line, and any line without a `path`, is skipped.

usage: inference-report.py <calls.jsonl>... [--json] [--by role|step|model]
"""
from __future__ import annotations

import argparse
import json
import sys


def pct(vals: list[float], p: float):
    """Linear interpolation between closest ranks; None for an empty column."""
    xs = sorted(v for v in vals if isinstance(v, (int, float)) and not isinstance(v, bool))
    if not xs:
        return None
    if len(xs) == 1:
        return xs[0]
    k = (len(xs) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def load(paths: list[str]) -> list[dict]:
    out = []
    for p in paths:
        with open(p) as fh:
            for ln in fh:
                ln = ln.strip()
                if not ln:
                    continue
                try:
                    r = json.loads(ln)
                except ValueError:
                    print(f"inference-report: skipped an unreadable line in {p}", file=sys.stderr)
                    continue
                if isinstance(r, dict) and r.get("path") and r.get("kind") != "provenance":
                    out.append(r)
    return out


COLS = (("ttft_s", "ttft"), ("prefill_tok_s", "prefill_tok_s"), ("decode_tok_s", "decode_tok_s"),
        ("prompt_eval_count", "isl"), ("eval_count", "osl"))


def summarise(recs: list[dict], by: str) -> list[dict]:
    groups: dict[tuple, list[dict]] = {}
    for r in recs:
        tags = r.get("tags") or {}
        key_val = r.get("model") if by == "model" else tags.get(by)
        groups.setdefault((str(tags.get("label") or "-"), str(key_val or "-")), []).append(r)
    rows = []
    for (label, key), rs in sorted(groups.items()):
        row = {"label": label, by: key, "n": len(rs)}
        for field, name in COLS:
            vals = [r.get(field) for r in rs if r.get(field) is not None]
            row[name] = {"n": len(vals), "p50": pct(vals, 50), "p90": pct(vals, 90)}
        timed = [r for r in rs if r.get("wall_s") and r.get("prompt_eval_duration_s") is not None]
        wall = sum(r["wall_s"] for r in timed)
        share = {"n": len(timed), "prefill": None, "decode": None, "load": None, "other": None}
        if wall > 0:
            pre = sum(r.get("prompt_eval_duration_s") or 0 for r in timed)
            dec = sum(r.get("eval_duration_s") or 0 for r in timed)
            lod = sum(r.get("load_duration_s") or 0 for r in timed)
            share.update(prefill=pre / wall, decode=dec / wall, load=lod / wall,
                         other=max(0.0, 1 - (pre + dec + lod) / wall))
        row["wall_share"] = share
        row["wall_s_total"] = round(sum(r.get("wall_s") or 0 for r in rs), 3)
        row["errors"] = sum(1 for r in rs if r.get("error"))
        rows.append(row)
    return rows


def fmt(v, digits=1):
    if v is None:
        return "-"
    return f"{v:.{digits}f}"


def table(rows: list[dict], by: str) -> str:
    hdr = (f"{'label':<16} {by:<12} {'n':>4}  {'ttft p50/p90 s':>15}  {'prefill tok/s':>15}  "
           f"{'decode tok/s':>13}  {'ISL p50/p90':>13}  {'OSL p50/p90':>12}  "
           f"{'prefill%':>8} {'decode%':>7} {'load%':>6} {'other%':>6}  err")
    out = [hdr, "-" * len(hdr)]
    for r in rows:
        def pair(c, d=1):
            return f"{fmt(r[c]['p50'], d)}/{fmt(r[c]['p90'], d)}"
        s = r["wall_share"]

        def share(k):
            return "-" if s[k] is None else f"{100 * s[k]:.0f}"
        out.append(f"{r['label'][:16]:<16} {r[by][:12]:<12} {r['n']:>4}  {pair('ttft', 2):>15}  "
                   f"{pair('prefill_tok_s'):>15}  {pair('decode_tok_s'):>13}  {pair('isl', 0):>13}  "
                   f"{pair('osl', 0):>12}  {share('prefill'):>8} {share('decode'):>7} "
                   f"{share('load'):>6} {share('other'):>6}  {r['errors']}")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--json", action="store_true", help="machine-readable rows")
    ap.add_argument("--by", default="role", choices=("role", "step", "model"))
    a = ap.parse_args()
    try:
        recs = load(a.files)
    except OSError as e:
        print(f"inference-report: {e}", file=sys.stderr)
        return 2
    rows = summarise(recs, a.by)
    if a.json:
        print(json.dumps({"calls": len(recs), "rows": rows}, indent=2))
    else:
        if not recs:
            print("no model calls recorded")
            return 1
        print(table(rows, a.by))
    return 0


if __name__ == "__main__":
    sys.exit(main())
