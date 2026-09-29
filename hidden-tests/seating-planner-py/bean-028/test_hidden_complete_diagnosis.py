"""Hidden tests for bean-028 — an infeasibility report names every cause.

Written from bean-028's criteria, which come from the retroactive review of
bean-010 and bean-011: the one-removal diagnosis named nothing whenever two
things were wrong at once, blamed "the hard rules" for locks, and named no lock
when no single unlock would help.

Everything is checked as the two properties ac4 states, on every scenario,
rather than as one expected list:

  * enough — remove every named rule, release every named lock, lift the
    movement limit if raise_movement_limit is advised, and drop the seat limit if
    a shortfall is counted: the event then solves in the same mode.
  * real — every named rule and lock is part of some conflict: some set of the
    event's hard rules, locks, seat limit and movement limit cannot all hold,
    and can once that one is removed. Found by trying every subset, which the
    scenarios keep small.

A report is allowed to name more than the smallest set (a non-goal), so no test
asks for an exact list beyond what the scenario forces.
"""

from __future__ import annotations

import os
import sys
from itertools import combinations
from pathlib import Path
from typing import Any

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)

SEATS = "<seat limit>"
LIMIT = "<movement limit>"
Spec = dict[str, Any]


def _spec(caps: dict[str, int], n: int, rules: list[tuple[str, str, tuple[str, ...]]],
          locks: dict[str, str] | None = None, current: dict[str, str] | None = None,
          movement_limit: int | None = None) -> Spec:
    return {"caps": caps, "guests": [f"g-{i}" for i in range(n)], "rules": rules,
            "locks": dict(locks or {}), "current": current, "movement_limit": movement_limit}


def _pair(a: str, b: str, prefix: str) -> list[tuple[str, str, tuple[str, ...]]]:
    return [(f"{prefix}-same", "same", (a, b)), (f"{prefix}-diff", "diff", (a, b))]


def _solve(spec: Spec, *, rules: set[str] | None = None, locks: set[str] | None = None,
           seats: bool = True, limit: bool = True) -> Any:
    """Solve the scenario keeping only the given rules and locks (all by default),
    with the seat limit and movement limit either kept or lifted."""
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    kinds = {"same": RuleType.SAME_TABLE, "diff": RuleType.DIFFERENT_TABLE}
    n = len(spec["guests"])
    event = Event(
        id="e", name="E",
        tables=[Table(id=t, name=t, capacity=c if seats else n, shape="round", position=(0.0, float(i)))
                for i, (t, c) in enumerate(spec["caps"].items())],
        guests=[Guest(id=g, name=g, status=RsvpStatus.CONFIRMED) for g in spec["guests"]],
        groups=[],
        rules=[Rule(id=rid, rule_type=kinds[k], hardness=Hardness.HARD, weight=None, guest_ids=gids)
               for rid, k, gids in spec["rules"] if rules is None or rid in rules],
        locks={g: t for g, t in spec["locks"].items() if locks is None or g in locks},
    )
    if spec["current"] is None:
        return solve_event(event, mode="planning")
    return solve_event(event, mode="low_disruption", current=spec["current"],
                       movement_limit=spec["movement_limit"] if limit else n)


def _named(spec: Spec) -> tuple[Any, set[str], set[str]]:
    result = _solve(spec)
    assert result.status == "infeasible", "the scenario is meant to be infeasible as built"
    report = result.infeasibility_report
    assert report is not None
    rule_ids = {rid for rid, _k, _g in spec["rules"]}
    named_rules = set(report.conflict_rule_ids)
    assert named_rules <= rule_ids, f"named rules the event does not have: {named_rules - rule_ids}"
    assert list(report.conflict_rule_ids) == sorted(report.conflict_rule_ids)
    named_locks: set[str] = set()
    for rec in report.recommendations:
        if rec.kind == "unlock":
            guest = getattr(rec, "guest_id", None)
            table = getattr(rec, "table_id", None)
            assert guest in spec["locks"], f"an unlock must carry a locked guest's id as guest_id: {rec!r}"
            assert table == spec["locks"][guest], f"an unlock must carry that lock's table as table_id: {rec!r}"
            named_locks.add(guest)
        if rec.kind == "change_hard_rule":
            assert rec.rule_id in named_rules, (
                f"a change_hard_rule recommendation must name a rule in conflict_rule_ids: {rec!r}")
    unlocks = [rec for rec in report.recommendations if rec.kind == "unlock"]
    assert len(unlocks) == len(named_locks), "one unlock recommendation per named lock"
    return report, named_rules, named_locks


def _check_enough(spec: Spec, report: Any, named_rules: set[str], named_locks: set[str]) -> None:
    kinds = {rec.kind for rec in report.recommendations}
    if report.capacity_shortfall > 0:
        assert "add_capacity" in kinds, "a counted shortfall is recommended add_capacity"
    again = _solve(
        spec,
        rules={rid for rid, _k, _g in spec["rules"]} - named_rules,
        locks=set(spec["locks"]) - named_locks,
        seats=report.capacity_shortfall == 0,
        limit="raise_movement_limit" not in kinds,
    )
    assert again.status == "feasible", (
        f"the report does not explain all of it: rules {sorted(named_rules)}, locks {sorted(named_locks)}, "
        f"shortfall {report.capacity_shortfall}, kinds {sorted(kinds)}; with those gone it is still unsolvable")


def _check_real(spec: Spec, named_rules: set[str], named_locks: set[str]) -> None:
    rule_ids = [rid for rid, _k, _g in spec["rules"]]
    causes = rule_ids + list(spec["locks"]) + [SEATS] + ([LIMIT] if spec["current"] is not None else [])
    cache: dict[frozenset[str], bool] = {}

    def holds(keep: frozenset[str]) -> bool:
        if keep not in cache:
            cache[keep] = _solve(spec, rules={c for c in keep if c in rule_ids},
                                 locks={c for c in keep if c in spec["locks"]},
                                 seats=SEATS in keep, limit=LIMIT in keep).status == "feasible"
        return cache[keep]

    subsets = [frozenset(s) for k in range(1, len(causes) + 1) for s in combinations(causes, k)]
    for cause in sorted(named_rules | named_locks):
        assert any(cause in s and not holds(s) and holds(s - {cause}) for s in subsets), (
            f"{cause!r} is named but is not part of any conflict")


def _check(spec: Spec) -> tuple[Any, set[str], set[str]]:
    report, named_rules, named_locks = _named(spec)
    _check_enough(spec, report, named_rules, named_locks)
    _check_real(spec, named_rules, named_locks)
    return report, named_rules, named_locks


def test_two_independent_conflicts_both_named() -> None:
    spec = _spec({"t-1": 4, "t-2": 4}, 4, _pair("g-0", "g-1", "a") + _pair("g-2", "g-3", "b"))
    _report, rules, _locks = _check(spec)
    assert rules & {"a-same", "a-diff"} and rules & {"b-same", "b-diff"}


def test_shortage_and_rule_conflict_both_named() -> None:
    spec = _spec({"t-1": 2, "t-2": 2}, 5, _pair("g-0", "g-1", "a"))
    report, rules, _locks = _check(spec)
    assert report.capacity_shortfall == 1
    assert "add_capacity" in {rec.kind for rec in report.recommendations}
    assert rules & {"a-same", "a-diff"}, "the rule conflict must be named beside the shortage"


def test_locks_alone_are_named_as_locks_when_no_single_unlock_helps() -> None:
    # Three guests locked to a one-seat table, room elsewhere, no hard rules.
    spec = _spec({"t-1": 1, "t-2": 3}, 3, [], locks={"g-0": "t-1", "g-1": "t-1", "g-2": "t-1"})
    report, rules, locks = _check(spec)
    assert rules == set()
    assert len(locks) >= 2
    assert "change_hard_rule" not in {rec.kind for rec in report.recommendations}, (
        "an event with no hard rules is not told its hard rules are the problem")


def test_a_lock_conflict_and_a_rule_conflict_at_once() -> None:
    spec = _spec({"t-1": 1, "t-2": 4}, 4, _pair("g-2", "g-3", "a"), locks={"g-0": "t-1", "g-1": "t-1"})
    _report, rules, locks = _check(spec)
    assert locks and rules


def test_bystanders_are_not_named() -> None:
    rules = _pair("g-0", "g-1", "a") + [("r-bystander", "diff", ("g-2", "g-3"))]
    spec = _spec({"t-1": 5, "t-2": 5}, 5, rules, locks={"g-4": "t-2"})
    _report, named_rules, named_locks = _check(spec)
    assert "r-bystander" not in named_rules and "g-4" not in named_locks


def test_low_disruption_limit_and_rule_conflict_both_explained() -> None:
    # The lock forces g-0 off its current table, which a limit of 0 forbids;
    # separately, a contradictory pair.
    spec = _spec({"t-1": 3, "t-2": 3}, 4, _pair("g-2", "g-3", "a"), locks={"g-0": "t-2"},
                 current={"g-0": "t-1", "g-1": "t-1"}, movement_limit=0)
    _report, rules, _locks = _check(spec)
    assert rules & {"a-same", "a-diff"}


def test_single_causes_still_named_exactly_as_before() -> None:
    # One contradictory pair with a bystander: bean-010's own case.
    rules = _pair("g-0", "g-1", "a") + [("r-alone", "diff", ("g-2", "g-3"))]
    report, named, _locks = _check(_spec({"t-1": 4, "t-2": 4}, 4, rules))
    assert tuple(report.conflict_rule_ids) == ("a-diff", "a-same")
    # A lock against a hard rule: bean-011's own case, both sides named.
    spec = _spec({"t-1": 1, "t-2": 2}, 2, [("r-same", "same", ("g-0", "g-1"))], locks={"g-0": "t-1"})
    _report, named, locks = _check(spec)
    assert named == {"r-same"} and locks == {"g-0"}
