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
