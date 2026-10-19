"""Hidden test for bean-032 (run 2): rule-conflict probing must use the event's own
table capacities, never a model enlarged to test for a seat shortage.

Written from ac5, which run 1's pre-merge review produced
(evidence/reviews/bean-032-20261012T143638Z.md): run 1 decided whether a shortage alone
explained an infeasible event by solving on every table enlarged to hold all eligible
guests, then ran every rule-removal probe on that SAME enlarged model. With every table
able to seat everyone, removing any rule at all trivially succeeded, so a rule with no
real conflict was named anyway -- a regression from main, which reports a plain shortage
correctly.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)


def _report(mode: str = "planning") -> Any:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    # 5 guests, two 2-seat tables (one short of a seat), one hard rule that holds two
    # guests already seated together on every chart worth considering -- it never
    # conflicts with anything, whether or not the shortage is also present.
    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(5)],
        groups=[],
        rules=[Rule(id="r-ok", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                    weight=None, guest_ids=("g0", "g1"))],
    )
    kwargs = {"current": {"g0": "t1"}, "movement_limit": 100} if mode == "low_disruption" else {}
    result = solve_event(ev, mode=mode, time_limit_s=10.0, seed=0, num_search_workers=1, **kwargs)
    report = result.infeasibility_report
    assert report is not None, "5 guests at 4 seats is infeasible"
    return report


def test_a_harmless_rule_is_not_named_alongside_a_shortage() -> None:
    for mode in ("planning", "low_disruption"):
        report = _report(mode)
        assert report.capacity_shortfall == 1, f"{mode}: expected a 1-seat shortfall"
        assert "r-ok" not in report.conflict_rule_ids, (
            f"{mode}: r-ok conflicts with nothing and must not be named: "
            f"{report.conflict_rule_ids}"
        )


def test_dropping_the_harmless_rule_alone_does_not_help() -> None:
    # The property check: if r-ok really were part of a conflict, removing it (with no
    # extra seat) would restore feasibility. It does not -- proving it was never the cause.
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.solver import solve_event

    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(5)],
        groups=[], rules=[],
    )
    result = solve_event(ev, mode="planning", time_limit_s=10.0, seed=0, num_search_workers=1)
    assert result.infeasibility_report is not None, "still short a seat with r-ok already gone"


def test_a_group_rule_naming_depends_on_where_the_seat_goes_not_which_table() -> None:
    """Run 2's pre-merge review (evidence/reviews/bean-032-20261012T213344Z.md):
    curing the shortfall was tested on one specific placement of the extra seats
    (split evenly, or piled on one table), so a same-table group that only fits once
    a SPECIFIC table gains room was told the shortage alone did not explain it, and
    the group's own rule was blamed. Every table must get the full shortfall as
    slack when asking whether a placement exists at all -- not a share of it.
    """
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    # 5 guests, t1 holds 3, t2 holds 1 (shortfall 1). A needs 3 seats together,
    # B needs 2 together. One more seat AT T2 (not t1) solves it with both rules
    # kept, so neither rule may be named.
    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=3, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=1, shape="round", position=(0.0, 1.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(5)],
        groups=[],
        rules=[
            Rule(id="A", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g0", "g1", "g2")),
            Rule(id="B", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g3", "g4")),
        ],
    )
    for mode, kwargs in (("planning", {}), ("low_disruption", {"current": {"g0": "t1"}, "movement_limit": 100})):
        result = solve_event(ev, mode=mode, time_limit_s=10.0, seed=0, num_search_workers=1, **kwargs)
        report = result.infeasibility_report
        assert report is not None, f"{mode}: 5 guests at 4 seats is infeasible"
        assert report.capacity_shortfall == 1, f"{mode}: expected a 1-seat shortfall"
        assert not report.conflict_rule_ids, (
            f"{mode}: neither A nor B conflicts with anything once the right table "
            f"gains a seat, so neither may be named: {report.conflict_rule_ids}"
        )


def _any_placement_restores_feasibility(
    event: Any, drop_ids: set, extra_total: int, mode: str, **kwargs: Any
) -> bool:
    """True if SOME way to add `extra_total` seats across the event's tables, after
    dropping the named rules, makes it solvable. This is ac3's own property check: a
    diagnosis's advice only counts if some real placement of it actually works, not
    just a model that was more generous than any one placement could ever be.
    """
    from itertools import combinations_with_replacement

    from seating_planner.domain import Event, Table
    from seating_planner.solver import solve_event

    table_ids = [t.id for t in event.tables]
    for combo in combinations_with_replacement(table_ids, extra_total):
        bump = {tid: combo.count(tid) for tid in table_ids}
        new_tables = [
            Table(id=t.id, name=t.name, capacity=t.capacity + bump[t.id],
                  shape=t.shape, position=t.position)
            for t in event.tables
        ]
        new_rules = [r for r in event.rules if r.id not in drop_ids]
        new_event = Event(
            id=event.id, name=event.name, tables=new_tables,
            guests=event.guests, groups=event.groups, rules=new_rules,
        )
        result = solve_event(new_event, mode=mode, time_limit_s=10.0, seed=0,
                              num_search_workers=1, **kwargs)
        if result.infeasibility_report is None:
            return True
    return False


def test_the_shortfall_cure_is_checked_against_one_real_placement_of_it() -> None:
    """Run 3's pre-merge review (evidence/reviews/bean-032-20261013T002611Z.md):
    bounding each table's slack at the shortfall, without also bounding the SUM used
    across tables, let a probe accept up to n times the shortfall in total across n
    tables -- not one real placement of it. Two groups that each needed a DIFFERENT
    table to grow were both judged seatable by capacity alone, though no single real
    placement of the shortfall restores feasibility with both rules kept.
    """
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    # 6 guests, t1 holds 2, t2 holds 2, t3 holds 1 (shortfall 1). A needs 3 seats
    # together, B needs 3 seats together -- in different, disjoint groups. No single
    # extra seat placed anywhere lets both 3-seat groups each reach a 3-capacity table,
    # so the shortfall alone cannot cure this and a rule must be named.
    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0)),
                Table(id="t3", name="t3", capacity=1, shape="round", position=(0.0, 2.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(6)],
        groups=[],
        rules=[
            Rule(id="A", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g0", "g1", "g2")),
            Rule(id="B", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g3", "g4", "g5")),
        ],
    )
    for mode, kwargs in (("planning", {}), ("low_disruption", {"current": {"g0": "t1"}, "movement_limit": 100})):
        result = solve_event(ev, mode=mode, time_limit_s=10.0, seed=0, num_search_workers=1, **kwargs)
        report = result.infeasibility_report
        assert report is not None, f"{mode}: 6 guests at 5 seats is infeasible"
        assert report.capacity_shortfall == 1, f"{mode}: expected a 1-seat shortfall"

        # Sanity: the shortfall alone, by any real placement, truly cannot cure this.
        assert not _any_placement_restores_feasibility(ev, set(), 1, mode, **kwargs), (
            f"{mode}: sanity check failed -- some placement of 1 seat cured it with "
            "both groups' rules kept, so the test fixture itself is wrong"
        )
        # So a rule must be named -- capacity alone is not a valid diagnosis here.
        assert report.conflict_rule_ids, (
            f"{mode}: a rule must be named; no real placement of the 1-seat shortfall "
            f"seats both 3-guest groups, so capacity alone is not enough: "
            f"{report.conflict_rule_ids}"
        )
        # And dropping exactly the named rules, plus some real placement of the
        # shortfall, must actually restore feasibility (ac3).
        assert _any_placement_restores_feasibility(
            ev, set(report.conflict_rule_ids), report.capacity_shortfall, mode, **kwargs
        ), (
            f"{mode}: dropping the named rules {report.conflict_rule_ids} plus the "
            "shortfall, by some real placement, must restore feasibility"
        )
