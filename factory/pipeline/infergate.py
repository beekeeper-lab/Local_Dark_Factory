#!/usr/bin/env python3
"""infergate.py — one model call at a time, batched by role (§09, Phase 4 task 4).

With two beans in flight (`factory go --max-inflight 2`), both will want the GPU,
and on Forge only one model fits (Phase 0: the regime is serial). Without a gate
the second bean's ensure-loaded evicts the model the first is in the middle of
using. So every model step holds this gate for the length of the step, and the
gate decides who goes next:

  * the role already resident goes first. Switching models costs a load (and
    model-loads.jsonl says how much), so a waiting developer step runs before a
    waiting judge step while the developer is loaded, and vice versa: §09's
    "batch by role across in-flight beans";
  * unless someone has waited longer than max_wait (FACTORY_MAX_WAIT_MINUTES,
    default 30): then the longest waiter goes, whatever its role, so neither
    role starves;
  * otherwise first come, first served.

A holder whose process has died is dropped, so a crash cannot wedge the line.
Every grant is appended to inference-log.jsonl beside the state log: who, which
role, how long they waited, whether the grant meant a model switch.

usage:
  infergate.py acquire --role <developer|judge> --bean <id> --owner <host:pid>
  infergate.py release --owner <host:pid> [--switched]
  infergate.py status
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import beanstate as bs  # noqa: E402

POLL = float(os.environ.get("FACTORY_GATE_POLL", "1"))


def gate_file(d: Path) -> Path:
    return d / "inference.json"


def load(d: Path) -> dict:
    p = gate_file(d)
    return json.loads(p.read_text()) if p.exists() else {"holder": None, "waiters": [], "resident": None}


def save(d: Path, g: dict) -> None:
    tmp = gate_file(d).with_suffix(".tmp")
    tmp.write_text(json.dumps(g, indent=2) + "\n")
    os.replace(tmp, gate_file(d))


def alive(owner: str) -> bool:
    return bs.pid_alive(owner)


def pick(g: dict, max_wait: float) -> dict | None:
    ws = [w for w in g["waiters"] if alive(w["owner"])]
    g["waiters"] = ws
    if not ws:
        return None
    now = time.time()
    oldest = min(ws, key=lambda w: w["since"])
    if now - oldest["since"] > max_wait:
        return oldest
    same = [w for w in ws if w["role"] == g.get("resident")]
    return min(same or ws, key=lambda w: w["since"])


def cmd_acquire(a) -> int:
    max_wait = float(os.environ.get("FACTORY_MAX_WAIT_MINUTES", "30")) * 60
    me = {"owner": a.owner, "role": a.role, "bean": a.bean, "since": time.time()}
    with bs.locked() as d:
        g = load(d)
        if not any(w["owner"] == a.owner for w in g["waiters"]):
            g["waiters"].append(me)
        save(d, g)
    said = False
    while True:
        with bs.locked() as d:
            g = load(d)
            if g["holder"] and not alive(g["holder"]["owner"]):
                g["holder"] = None  # its process is gone; the gate is free
            if g["holder"] is None:
                nxt = pick(g, max_wait)
                if nxt and nxt["owner"] == a.owner:
                    switched = g.get("resident") not in (None, a.role)
                    waited = round(time.time() - nxt["since"], 1)
                    g["waiters"] = [w for w in g["waiters"] if w["owner"] != a.owner]
                    g["holder"] = dict(nxt, granted=time.time())
                    g["resident"] = a.role
                    save(d, g)
                    with open(d / "inference-log.jsonl", "a") as fh:
                        fh.write(json.dumps({"ts": bs.now(), "bean": a.bean, "role": a.role, "owner": a.owner,
                                             "waited_s": waited, "switch": switched}) + "\n")
                    print(f"GPU    {a.bean} {a.role}: granted after {waited}s"
                          + (" (a model switch)" if switched else ""), file=sys.stderr)
                    return 0
            save(d, g)
            holder = g["holder"]
        if not said and holder:
            print(f"GPU    {a.bean} {a.role}: waiting on {holder['bean']} ({holder['role']})", file=sys.stderr)
            said = True
        time.sleep(POLL)


def cmd_release(a) -> int:
    with bs.locked() as d:
        g = load(d)
        if g["holder"] and g["holder"]["owner"] == a.owner:
            held = round(time.time() - g["holder"]["granted"], 1)
            with open(d / "inference-log.jsonl", "a") as fh:
                fh.write(json.dumps({"ts": bs.now(), "bean": g["holder"]["bean"], "role": g["holder"]["role"],
                                     "owner": a.owner, "held_s": held}) + "\n")
            g["holder"] = None
        g["waiters"] = [w for w in g["waiters"] if w["owner"] != a.owner]
        save(d, g)
    return 0


def cmd_status(a) -> int:
    with bs.locked() as d:
        print(json.dumps(load(d), indent=2))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("acquire"); p.add_argument("--role", required=True); p.add_argument("--bean", required=True)
    p.add_argument("--owner", required=True)
    p = sub.add_parser("release"); p.add_argument("--owner", required=True)
    sub.add_parser("status")
    a = ap.parse_args()
    return {"acquire": cmd_acquire, "release": cmd_release, "status": cmd_status}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
