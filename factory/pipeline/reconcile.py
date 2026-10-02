#!/usr/bin/env python3
"""reconcile.py — after a crash, make the state log agree with the world (§09).

A controller that dies with `kill -9`, a power cut or an OOM runs none of its
traps. It leaves a lease naming a dead process, a bean whose last event says
`building`, a worktree holding half of a task attempt, and possibly a pull
request that merged, or a CI run that finished, while nothing was watching.
Startup reconciliation is the step that runs before anything else on the next
start, and re-derives each bean's true position from the things that cannot lie
about it: GitHub (the pull request, its state, its checks, its head), the run
directories, and the working tree.

What it does, per bean, in this order:

  1. a lease whose owner is gone, or has expired, is dropped
  2. a bean with a pull request is moved to what GitHub says: merged, open with
     checks green (merge_pending), red (ci_failed), or still running (ci_pending)
  3. a bean whose newest run halted, but which the log does not show as blocked,
     is blocked: the run asked a person something
  4. a bean in flight with no live lease (the crash case) is rolled back to its
     last candidate: the uncommitted edits of the interrupted attempt are saved
     into its run directory, the tree is reset to the bean branch's HEAD (the last
     commit the controller made), and the resume command is printed

GitHub's answer is an observation, not a transition anyone chose, so it is
written as one recorded hop (`detail.reconciled`), not walked through the
table. Without --apply it prints the plan and changes nothing. Re-running it
changes nothing more: every write carries an idempotency key.

usage: reconcile.py [--apply] [--json]
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import beanstate as bs  # noqa: E402

IN_FLIGHT = set(bs.EDGES) - {"ready", "blocked", "cancelled", "merged", "deployed_test",
                             "deploy_failed", "merge_pending", "merging"}
GH = os.environ.get("FACTORY_GH", "gh")


def git(*a: str) -> str:
    r = subprocess.run(["git", *a], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def runs_root(state_dir: Path) -> Path:
    return state_dir.parent


def runs_for(root: Path, bean: str) -> list[Path]:
    rs = [d for d in root.glob(f"{bean}-*") if (d / "run.json").is_file()]
    return sorted(rs, key=lambda d: d.name, reverse=True)


def pr_url(root: Path, bean: str) -> str:
    for d in runs_for(root, bean):
        try:
            u = json.loads((d / "run.json").read_text()).get("pr_url")
        except ValueError:
            continue
        if u:
            return u
    return ""


def pr_facts(url: str) -> dict | None:
    r = subprocess.run([GH, "pr", "view", url, "--json", "state,headRefOid,statusCheckRollup"],
                       capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except ValueError:
        return None


def checks_say(rollup: list) -> str:
    if not rollup:
        return "pending"
    concl = [(c.get("conclusion") or c.get("state") or "").upper() for c in rollup]
    if any(c in ("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED") for c in concl):
        return "failed"
    if all(c in ("SUCCESS", "NEUTRAL", "SKIPPED") for c in concl):
        return "green"
    return "pending"


def observe(d: Path, events: list, bean: str, to: str, why: str, apply: bool) -> dict:
    frm = bs.current(events, bean)
    act = {"bean": bean, "action": "observe", "from": frm, "to": to, "why": why}
    if frm == to or not apply:
        act["applied"] = False if frm != to else None
        return act
    ev = {"ts": bs.now(), "bean_id": bean, "from_state": frm, "to_state": to,
          "idempotency_key": f"{bean}:reconcile:{frm}->{to}:{why}",
          "detail": {"reconciled": True, "why": why}}
    # Written past the table on purpose: this is GitHub reporting a fact, and the
    # table is about what the line may choose to do next.
    ev["detail"]["provenance"] = bs.provenance()
    bs.validate(ev)
    if any(e["idempotency_key"] == ev["idempotency_key"] for e in events):
        act["applied"] = None
        return act
    with open(d / "events.jsonl", "a") as fh:
        fh.write(json.dumps(ev, separators=(",", ":")) + "\n")
    events.append(ev)
    act["applied"] = True
    return act


def bean_branch(bean: str) -> str:
    out = git("for-each-ref", "--format=%(refname:short)", f"refs/heads/bean/{bean}-*")
    return out.splitlines()[0] if out else ""


def roll_back(bean: str, run: Path | None, apply: bool) -> dict:
    """The interrupted attempt's edits go into the run directory; the tree goes back
    to the last commit on the bean's branch."""
    act = {"bean": bean, "action": "roll_back", "run": str(run) if run else None}
    br = bean_branch(bean)
    cur = git("rev-parse", "--abbrev-ref", "HEAD")
    dirty = git("status", "--porcelain", "--untracked-files=all")
    dirty = "\n".join(l for l in dirty.splitlines() if "factory/runs/" not in l and "/.state/" not in l)
    act.update(branch=br, on_branch=(cur == br), dirty=bool(dirty))
    if run is not None:
        act["resume"] = f"factory run {bean} --resume {run}"
    if dirty and not apply and cur == br:
        act["applied"] = False
    if not apply or not dirty or cur != br:
        if dirty and cur != br:
            act["note"] = f"the tree is dirty on {cur}, not on {br}; left alone for a person"
        return act
    stamp = bs.now().replace(":", "").replace(".", "")
    keep = (run or Path(".")) / f"rolled-back-{stamp}.diff"
    diff = subprocess.run(["git", "diff", "HEAD"], capture_output=True, text=True).stdout
    untracked = git("ls-files", "--others", "--exclude-standard")
    keep.write_text(diff + ("\n# untracked at the crash:\n" + untracked + "\n" if untracked else ""))
    subprocess.run(["git", "reset", "-q", "--hard", "HEAD"], check=True)
    subprocess.run(["git", "clean", "-fdq", "-e", "factory/runs/"], check=True)
    act.update(applied=True, saved=str(keep))
    return act


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    actions: list[dict] = []
    with bs.locked() as d:
        root = runs_root(d)
        events = bs.read_events(d)
        ls = bs.leases(d)

        # 1. leases whose owner is gone
        for bean, lease in list(ls.items()):
            if not bs.lease_live(lease):
                actions.append({"bean": bean, "action": "drop_lease", "owner": lease["owner"],
                                "applied": a.apply})
                if a.apply:
                    del ls[bean]
        if a.apply:
            bs.save_leases(d, ls)

        beans = sorted(set(bs.fold(events)) | {p.name.rsplit("-", 1)[0] for p in root.glob("bean-*-*")
                                               if (p / "run.json").is_file()})
        for bean in beans:
            st = bs.current(events, bean)
            if st in ("merged", "deployed_test", "deploy_failed", "cancelled"):
                continue
            # 2. what GitHub says
            url = pr_url(root, bean)
            if url:
                f = pr_facts(url)
                if f is None:
                    actions.append({"bean": bean, "action": "unknown", "why": f"gh could not read {url}"})
                elif f.get("state") == "MERGED":
                    actions.append(observe(d, events, bean, "merged", "github: pull request merged", a.apply))
                    continue
                elif f.get("state") == "OPEN" and st not in ("blocked",):
                    to = {"green": "merge_pending", "failed": "ci_failed",
                          "pending": "ci_pending"}[checks_say(f.get("statusCheckRollup") or [])]
                    if st != to and (st in IN_FLIGHT or st in ("merge_pending", "ci_pending", "ready")):
                        actions.append(observe(d, events, bean, to, f"github: open, checks {to}", a.apply))
                    continue
            runs = runs_for(root, bean)
            newest = runs[0] if runs else None
            rj = json.loads((newest / "run.json").read_text()) if newest else {}
            # 3. a halt the log does not know about
            if rj.get("status") == "halted" and st not in ("blocked",):
                actions.append(observe(d, events, bean, "blocked",
                                       f"run {newest.name} halted at {rj.get('halted_at_step')}", a.apply))
                continue
            # 4. in flight, nobody holding it: the crash
            if st in IN_FLIGHT and bean not in ls:
                actions.append(roll_back(bean, newest, a.apply))

    if a.json:
        print(json.dumps(actions, indent=2))
    else:
        if not actions:
            print("reconcile: the log agrees with the world; nothing to do")
        for x in actions:
            tag = "applied" if x.get("applied") else ("planned" if x.get("applied") is False else "-")
            if x["action"] == "drop_lease":
                print(f"{tag:8} {x['bean']:10} drop the lease held by {x['owner']} (gone or expired)")
            elif x["action"] == "observe":
                print(f"{tag:8} {x['bean']:10} {x['from']} -> {x['to']}  ({x['why']})")
            elif x["action"] == "roll_back":
                what = (f"saved the interrupted attempt to {x['saved']} and reset the tree" if x.get("saved")
                        else ("roll back the interrupted attempt's edits" if x.get("dirty") else "tree is clean"))
                print(f"{tag:8} {x['bean']:10} in flight with no lease: {what}"
                      + (f"; resume: {x['resume']}" if x.get("resume") else "")
                      + (f" ({x['note']})" if x.get("note") else ""))
            else:
                print(f"?        {x['bean']:10} {x.get('why')}")
        if not a.apply and any(x.get("applied") is False for x in actions):
            print("\n(planned only; factory reconcile --apply to do it)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
