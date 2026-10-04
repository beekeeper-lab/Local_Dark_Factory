#!/usr/bin/env python3
"""beanstate.py — the bean state machine (§09), its leases, and its event log.

Until Phase 4 a bean's state was inferred: a branch meant "started", a pull
request meant "done", and a halted run was a QUESTIONS.md somebody had to find.
That is enough for one operator typing one bean at a time. It is not enough for a
line that runs for 48 hours, gets stopped three different ways and must come back
up knowing which bean was where.

So state is an append-only log, one JSON event per transition, validated against
schemas/event.schema.json before it is written:

  * **Transitions** are the §09 table below and nothing else. An edge that is not
    in it is refused, never written.
  * **Idempotency keys.** Every event carries one. Writing a key that is already
    in the log is a no-op that reports the earlier event, so a step re-run after a
    crash cannot move a bean twice.
  * **Leases.** A bean is worked on only under a lease, taken under an exclusive
    lock: `ready -> leased` and the lease record are one critical section, so two
    controllers cannot both take the same bean. A lease has an owner (host:pid), an
    expiry, and is free again when it expires or its owner process is gone.
  * **Provenance.** Each event's `detail.provenance` says which host, process and
    pipeline version wrote it.

The log lives with the target repository's run records, in
factory/runs/.state/, which is already ignored by git and excluded from the
worker's tree. FACTORY_STATE_DIR overrides it.

usage:
  beanstate.py state [<bean>] [--json]
  beanstate.py transition <bean> --to <state> --key <k> [--from <state>] [--attempt n]
                          [--task <id>] [--candidate <sha>] [--detail <json>]
  beanstate.py lease <bean> --owner <id> [--ttl <seconds>]
  beanstate.py release <bean> --owner <id>
  beanstate.py clear <bean> --by <who>          # blocked -> ready, a person's call
  beanstate.py step <run_dir> <step> start|end [verdict]   # the step.sh hook
  beanstate.py edges                            # the transition table
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
import socket
import subprocess
import sys
from collections import deque
from pathlib import Path

PIPELINE = Path(__file__).resolve().parent
ROOT = PIPELINE.parent.parent
# FACTORY_SCHEMAS for a copied pipeline (the suites run one from a temp dir).
SCHEMA = Path(os.environ.get("FACTORY_SCHEMAS") or ROOT / "schemas") / "event.schema.json"

# -- the §09 table -----------------------------------------------------------------
#
# Written out edge by edge, because the design document's arrows are the spec and a
# generated table would be a second spec. `revise` edges go back to the authoring
# state; `blocked` and `cancelled` are reachable from every non-terminal state and
# are added below rather than listed 30 times.
EDGES: dict[str, set[str]] = {
    "ready": {"leased"},
    "leased": {"specifying", "ready"},
    "specifying": {"spec_committing", "specifying"},
    # specifying too: spec-check (the controller's half of specify) refusing a
    # spec sends it straight back, and without this edge the walk recorded a spec
    # audit that never ran (bean-026, 2026-10-04).
    "spec_committing": {"spec_auditing", "specifying"},
    "spec_auditing": {"spec_accepted", "specifying"},
    "spec_accepted": {"building"},
    "building": {"task_started", "containing"},
    "task_started": {"task_verified", "task_failed"},
    "task_verified": {"task_started", "containing"},
    "task_failed": {"task_started"},
    "containing": {"gating", "building"},
    "gating": {"committing_candidate", "building"},
    "committing_candidate": {"impl_auditing"},
    "impl_auditing": {"impl_accepted", "building"},
    "impl_accepted": {"documenting"},
    "documenting": {"doc_committing", "documenting"},
    "doc_committing": {"pre_pr_auditing"},
    "pre_pr_auditing": {"accepted", "documenting", "pre_pr_auditing"},
    "accepted": {"pushing"},
    "pushing": {"pushed"},
    "pushed": {"pr_open"},
    "pr_open": {"ci_pending"},
    "ci_pending": {"ci_failed", "ci_timeout", "stale", "merge_conflict", "merge_pending"},
    "ci_failed": {"building"},
    "ci_timeout": {"ci_pending"},
    "stale": {"gating"},
    "merge_conflict": set(),
    "merge_pending": {"merging", "merged"},
    "merging": {"merged"},
    "merged": {"deploying_test"},
    "deploying_test": {"deployed_test", "deploy_failed"},
    "deployed_test": set(),
    "deploy_failed": set(),
    "blocked": {"ready"},
    "cancelled": set(),
}
TERMINAL = {"deployed_test", "deploy_failed", "blocked", "cancelled", "merged"}
# merged is terminal for a repo with no post-merge deploy, and still has an edge on.
for _s, _to in EDGES.items():
    if _s not in {"deployed_test", "deploy_failed", "blocked", "cancelled", "merged"}:
        _to |= {"blocked", "cancelled"}
# A small tier skips the spec audit and the documents; the hook walks through the
# skipped states as implied hops rather than inventing edges that skip them.
NOT_PASSED_THROUGH = {"ready", "leased", "blocked", "cancelled"}

# -- where the log is ---------------------------------------------------------------


def repo_root() -> Path:
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(r.stdout.strip()) if r.returncode == 0 else Path.cwd()


def state_dir() -> Path:
    d = Path(os.environ.get("FACTORY_STATE_DIR") or repo_root() / "factory" / "runs" / ".state")
    d.mkdir(parents=True, exist_ok=True)
    return d


@contextlib.contextmanager
def locked():
    """One exclusive lock around every read-decide-write. The log and the leases
    are only ever changed while it is held, which is what makes a lease atomic."""
    d = state_dir()
    with open(d / "lock", "a+") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield d
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def read_events(d: Path) -> list[dict]:
    p = d / "events.jsonl"
    if not p.exists():
        return []
    out = []
    for line in p.read_text().splitlines():
        line = line.strip()
        if line:
            out.append(json.loads(line))
    return out


def fold(events: list[dict]) -> dict[str, dict]:
    """bean -> {state, last event}. The log is the truth; this is a view of it."""
    st: dict[str, dict] = {}
    for e in events:
        st[e["bean_id"]] = {"state": e["to_state"], "ts": e["ts"], "key": e["idempotency_key"]}
    return st


def current(events: list[dict], bean: str) -> str:
    # A bean with no events has never been touched by the state machine, which for
    # an approved bean the queue offers means ready.
    return fold(events).get(bean, {}).get("state", "ready")


_validator = None


def validate(ev: dict) -> None:
    global _validator
    if _validator is None:
        import jsonschema
        _validator = jsonschema.Draft202012Validator(json.loads(SCHEMA.read_text()))
    errs = sorted(_validator.iter_errors(ev), key=lambda e: list(e.path))
    if errs:
        raise SystemExit("event does not validate: " + "; ".join(
            f"{'/'.join(map(str, e.path)) or '<root>'}: {e.message}" for e in errs))


def provenance() -> dict:
    ver = (PIPELINE / "VERSION").read_text().strip() if (PIPELINE / "VERSION").exists() else ""
    return {"host": socket.gethostname(), "pid": os.getppid(), "pipeline_version": ver}


def append(d: Path, events: list[dict], ev: dict, resume: bool = False) -> dict:
    """Write one event, unless its key is already in the log. Caller holds the lock."""
    for e in events:
        if e["idempotency_key"] == ev["idempotency_key"]:
            return {"already": True, "event": e}
    frm, to = ev["from_state"], ev["to_state"]
    resumable = resume and frm == "leased" and to not in TERMINAL and to not in ("ready",)
    if to not in EDGES.get(frm, set()) and not resumable:
        raise SystemExit(f"refused: {ev['bean_id']} {frm} -> {to} is not a transition in §09")
    ev.setdefault("detail", {})["provenance"] = provenance()
    validate(ev)
    with open(d / "events.jsonl", "a") as fh:
        fh.write(json.dumps(ev, separators=(",", ":")) + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    events.append(ev)
    return {"already": False, "event": ev}


def path_to(frm: str, to: str) -> list[str] | None:
    """Shortest walk frm -> to through the table, never through a state a bean only
    reaches by a decision (ready, leased, blocked, cancelled)."""
    if to in EDGES.get(frm, set()):
        return [to]
    seen = {frm}
    q = deque([(frm, [])])
    while q:
        s, p = q.popleft()
        for n in sorted(EDGES.get(s, ())):
            if n in seen or (n in NOT_PASSED_THROUGH and n != to):
                continue
            if n == to:
                return p + [n]
            seen.add(n)
            q.append((n, p + [n]))
    return None


def walk(d: Path, events: list[dict], bean: str, to: str, key: str, **extra) -> list[dict]:
    """Move a bean to `to`, recording every hop. Hops the step did not name are marked
    `implied`, so a reader can tell "the small tier skipped the spec audit" from "the
    spec audit ran"."""
    frm = current(events, bean)
    if frm == to:
        return []
    hops = path_to(frm, to)
    if frm == "leased" and os.environ.get("FACTORY_RESUME") == "1" and to not in EDGES["leased"]:
        # A resumed run picks up at the step it stopped in. Walking there from
        # `leased` would record every earlier step as having run again; the honest
        # record is one hop that says it is a resume.
        ev = {"ts": now(), "bean_id": bean, "from_state": frm, "to_state": to, "idempotency_key": key}
        ev.update({k: v for k, v in extra.items() if v is not None and k != "detail"})
        ev["detail"] = dict(extra.get("detail") or {}, resume=True)
        return [append(d, events, ev, resume=True)]
    if hops is None:
        raise SystemExit(f"refused: {bean} has no path {frm} -> {to} in §09")
    out = []
    for i, h in enumerate(hops):
        ev = {"ts": now(), "bean_id": bean, "from_state": frm, "to_state": h,
              "idempotency_key": key if i == len(hops) - 1 else f"{key}#via-{h}"}
        ev.update({k: v for k, v in extra.items() if v is not None and k != "detail"})
        ev["detail"] = dict(extra.get("detail") or {})
        if i < len(hops) - 1:
            ev["detail"]["implied"] = True
        r = append(d, events, ev)
        out.append(r)
        frm = h
    return out


# -- leases -------------------------------------------------------------------------


def leases(d: Path) -> dict:
    p = d / "leases.json"
    return json.loads(p.read_text()) if p.exists() else {}


def save_leases(d: Path, ls: dict) -> None:
    tmp = d / "leases.json.tmp"
    tmp.write_text(json.dumps(ls, indent=2) + "\n")
    os.replace(tmp, d / "leases.json")


def pid_alive(owner: str) -> bool:
    host, _, pid = owner.rpartition(":")
    if host != socket.gethostname() or not pid.isdigit():
        return True  # another host's process: only its expiry can free it
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def lease_live(lease: dict) -> bool:
    exp = dt.datetime.fromisoformat(lease["expires_at"].replace("Z", "+00:00"))
    return exp > dt.datetime.now(dt.timezone.utc) and pid_alive(lease["owner"])


def cmd_lease(a) -> int:
    with locked() as d:
        ls = leases(d)
        held = ls.get(a.bean)
        if held and lease_live(held) and held["owner"] != a.owner:
            print(f"refused: {a.bean} is leased to {held['owner']} until {held['expires_at']}")
            return 3
        events = read_events(d)
        st = current(events, a.bean)
        if held and held["owner"] != a.owner:
            # Expired or orphaned. The bean's state is still wherever the dead
            # owner left it; this releases the lease only. Rolling the bean back is
            # reconciliation's job (§09), not something a new owner does in passing.
            print(f"note: {a.bean}'s lease from {held['owner']} has lapsed; taking it", file=sys.stderr)
        if st == "blocked" and a.resume:
            # Resuming a halted run is the person's answer to its question: the
            # operator chose to carry on from where it stopped. Recorded as a clear.
            walk(d, events, a.bean, "ready", f"{a.bean}:clear-by-resume:{a.owner}:{now()}",
                 detail={"cleared_by": "resume", "owner": a.owner})
            st = "ready"
        if st == "blocked":
            print(f"refused: {a.bean} is blocked (a run halted); a person clears it first: factory clear {a.bean}")
            return 3
        if st in TERMINAL:
            print(f"refused: {a.bean} is {st}")
            return 3
        if st not in ("ready", "leased") and not a.resume:
            # Mid-flight with no live lease: a run stopped without finishing. A new
            # run would start over on top of it; resuming is the only way in.
            print(f"refused: {a.bean} is {st} from an earlier run that did not finish; resume that run")
            return 3
        if st == "ready":
            key = f"{a.bean}:lease:{a.owner}:{now()}"
            walk(d, events, a.bean, "leased", key, detail={"owner": a.owner})
        exp = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=a.ttl)).strftime("%Y-%m-%dT%H:%M:%SZ")
        ls[a.bean] = {"owner": a.owner, "taken_at": now(), "expires_at": exp}
        save_leases(d, ls)
        print(f"leased {a.bean} to {a.owner} until {exp}")
        return 0


def cmd_release(a) -> int:
    with locked() as d:
        ls = leases(d)
        held = ls.get(a.bean)
        if not held:
            print(f"{a.bean} holds no lease")
            return 0
        if held["owner"] != a.owner:
            print(f"refused: {a.bean} is leased to {held['owner']}, not {a.owner}")
            return 3
        events = read_events(d)
        if current(events, a.bean) == "leased":
            # Leased and never started: give it back to the queue.
            walk(d, events, a.bean, "ready", f"{a.bean}:release:{a.owner}:{held['taken_at']}")
        del ls[a.bean]
        save_leases(d, ls)
        print(f"released {a.bean}")
        return 0


# -- the step.sh hook ----------------------------------------------------------------
#
# Step boundaries -> states. A start puts the bean in the state the step works in;
# a passing end moves it to the state the step hands on. A failing end moves
# nothing: the line either retries the step (whose start is a legal revise edge) or
# halts, and a halt is `blocked`, written by the halt itself.
ON_START = {
    "spec": "specifying", "audit-spec": "spec_auditing", "build": "building",
    "gate": "gating", "audit-impl": "impl_auditing", "doc": "documenting",
    "audit-doc": "pre_pr_auditing", "audit-package": "pre_pr_auditing",
    "pr": "pushing", "ci": "ci_pending",
}
ON_PASS = {
    "spec": "spec_committing", "audit-spec": "spec_accepted", "build": "containing",
    "gate": "committing_candidate", "audit-impl": "impl_accepted", "doc": "doc_committing",
    "audit-package": "accepted", "pr": "pr_open", "ci": "merge_pending",
}
ON_FAIL = {"ci": "ci_failed"}


def cmd_step(a) -> int:
    run = Path(a.run_dir)
    try:
        rj = json.loads((run / "run.json").read_text())
    except (OSError, ValueError):
        return 0  # not a run directory the controller made; nothing to track
    bean, run_id = rj.get("bean_id") or rj.get("bean"), rj.get("run_id")
    if not bean:
        return 0
    # The log sits beside the runs it describes: <repo>/factory/runs/.state.
    os.environ.setdefault("FACTORY_STATE_DIR", str(run.resolve().parent / ".state"))
    if a.event == "start":
        to = ON_START.get(a.step)
    elif (a.verdict or "").upper() in ("PASS", "ACCEPT", "OK", ""):
        to = ON_PASS.get(a.step)
    else:
        to = ON_FAIL.get(a.step)
    if not to:
        return 0
    n = a.attempt
    key = f"{run_id}:{a.step}:{a.event}:{n}"
    with locked() as d:
        events = read_events(d)
        frm = current(events, bean)
        # A failed attempt that the line retries re-enters the step's own state; a
        # revise from an audit goes back to the authoring state. Both are edges.
        try:
            rs = walk(d, events, bean, to, key, attempt=n, detail={"run_id": run_id, "step": a.step,
                                                                   "event": a.event, "verdict": a.verdict})
        except SystemExit as e:
            if os.environ.get("FACTORY_STATE_STRICT", "0") == "1":
                raise
            print(f"STATE  warning: {e} (from {frm}; run continues, FACTORY_STATE_STRICT=0)", file=sys.stderr)
            return 0
    for r in rs:
        if not r["already"]:
            print(f"STATE  {bean}: {r['event']['from_state']} -> {r['event']['to_state']}", file=sys.stderr)
    return 0


def cmd_block(a) -> int:
    with locked() as d:
        events = read_events(d)
        frm = current(events, a.bean)
        if frm in TERMINAL:
            print(f"{a.bean} is already {frm}")
            return 0
        walk(d, events, a.bean, "blocked", a.key, detail={"why": a.why})
        ls = leases(d)
        ls.pop(a.bean, None)
        save_leases(d, ls)
        print(f"{a.bean}: {frm} -> blocked")
        return 0


def cmd_clear(a) -> int:
    with locked() as d:
        events = read_events(d)
        frm = current(events, a.bean)
        if frm != "blocked":
            print(f"refused: {a.bean} is {frm}; only a blocked bean is cleared")
            return 3
        walk(d, events, a.bean, "ready", f"{a.bean}:clear:{a.by}:{now()}", detail={"cleared_by": a.by})
        print(f"{a.bean}: blocked -> ready (cleared by {a.by})")
        return 0


def cmd_transition(a) -> int:
    extra = {"attempt": a.attempt, "task_id": a.task, "candidate_sha": a.candidate,
             "detail": json.loads(a.detail) if a.detail else {}}
    with locked() as d:
        events = read_events(d)
        frm = current(events, a.bean)
        if a.from_state and a.from_state != frm:
            print(f"refused: {a.bean} is {frm}, not {a.from_state}")
            return 3
        if a.to not in EDGES.get(frm, set()):
            # An explicit transition is one edge; walking is the step hook's business.
            dup = [e for e in events if e["idempotency_key"] == a.key]
            if dup:
                print(json.dumps({"already": True, "event": dup[0]}))
                return 0
            print(f"refused: {a.bean} {frm} -> {a.to} is not a transition in §09")
            return 3
        ev = {"ts": now(), "bean_id": a.bean, "from_state": frm, "to_state": a.to, "idempotency_key": a.key}
        ev.update({k: v for k, v in extra.items() if v is not None and k != "detail"})
        ev["detail"] = extra["detail"]
        r = append(d, events, ev)
        print(json.dumps(r))
        return 0


def cmd_state(a) -> int:
    with locked() as d:
        st = fold(read_events(d))
        ls = leases(d)
    if a.bean:
        st = {a.bean: st.get(a.bean, {"state": "ready"})}
    for b, v in st.items():
        if b in ls:
            v["lease"] = dict(ls[b], live=lease_live(ls[b]))
    if a.json:
        print(json.dumps(st, indent=2))
    else:
        for b in sorted(st):
            v = st[b]
            lease = f"  leased to {v['lease']['owner']}{'' if v['lease']['live'] else ' (lapsed)'}" if "lease" in v else ""
            print(f"{b:10} {v['state']}{lease}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("state"); p.add_argument("bean", nargs="?"); p.add_argument("--json", action="store_true")
    p = sub.add_parser("transition"); p.add_argument("bean"); p.add_argument("--to", required=True)
    p.add_argument("--key", required=True); p.add_argument("--from", dest="from_state")
    p.add_argument("--attempt", type=int); p.add_argument("--task"); p.add_argument("--candidate")
    p.add_argument("--detail")
    p = sub.add_parser("lease"); p.add_argument("bean"); p.add_argument("--owner", required=True)
    p.add_argument("--ttl", type=int, default=6 * 3600)
    p.add_argument("--resume", action="store_true", help="the run resumes a bean mid-flight")
    p = sub.add_parser("release"); p.add_argument("bean"); p.add_argument("--owner", required=True)
    p = sub.add_parser("block"); p.add_argument("bean"); p.add_argument("--key", required=True)
    p.add_argument("--why", default="")
    p = sub.add_parser("clear"); p.add_argument("bean"); p.add_argument("--by", required=True)
    p = sub.add_parser("step"); p.add_argument("run_dir"); p.add_argument("step")
    p.add_argument("event", choices=["start", "end"]); p.add_argument("verdict", nargs="?", default="")
    p.add_argument("--attempt", type=int, default=1)
    sub.add_parser("edges")
    a = ap.parse_args()
    if a.cmd == "edges":
        for s in EDGES:
            print(f"{s:22} -> {', '.join(sorted(EDGES[s])) or '(terminal)'}")
        return 0
    return {"state": cmd_state, "transition": cmd_transition, "lease": cmd_lease, "release": cmd_release,
            "block": cmd_block, "clear": cmd_clear, "step": cmd_step}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
