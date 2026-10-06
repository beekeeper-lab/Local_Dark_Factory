"""Hidden tests for bean-031: an infeasible event-day report always says what to do.

Written from bean-031's criteria, which come from bean-025 run 2's pre-merge review:
with no enabled hard rule, no seat shortfall and no single lock whose removal is enough,
the report carried no recommendation at all.
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


def _event(caps: dict[str, int], guests: list[str], locks: dict[str, str] | None = None) -> Any:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table

    ev = Event(
        id="e", name="E",
        tables=[Table(id=t, name=t, capacity=c, shape="round", position=(0.0, float(i))) for i, (t, c) in enumerate(caps.items())],
        guests=[Guest(id=g, name=g, status=RsvpStatus.CONFIRMED) for g in guests],
        groups=[],
        rules=[],
    )
    for g, t in (locks or {}).items():
        ev.lock_guest(g, t)
    return ev


def _report(ev: Any, current: dict[str, str]) -> Any:
    from seating_planner.solver import solve_event

    result = solve_event(ev, mode="event_day", current=current)
    report = result.infeasibility_report
    assert report is not None, "this event cannot be seated as pinned"
    return report


def _kinds(report: Any) -> set[str]:
    return {r.kind for r in report.recommendations}


def _three_locked_to_one_free_seat() -> tuple[Any, dict[str, str]]:
    # t-1 holds 2 and the chart puts g-0 there; g-1, g-2 and g-3 are new and all locked
    # to t-1. Any one unlock still leaves two guests for one seat.
    ev = _event({"t-1": 2, "t-2": 4}, ["g-0", "g-1", "g-2", "g-3"],
                locks={"g-1": "t-1", "g-2": "t-1", "g-3": "t-1"})
    return ev, {"g-0": "t-1"}


def _chart_overfills_a_table() -> tuple[Any, dict[str, str]]:
    # The chart seats three guests at a two-seat table; there are seats elsewhere.
    ev = _event({"t-1": 2, "t-2": 4}, ["g-0", "g-1", "g-2"])
    return ev, {"g-0": "t-1", "g-1": "t-1", "g-2": "t-1"}


def test_infeasible_event_day_always_advises() -> None:
    for ev, current in (_three_locked_to_one_free_seat(), _chart_overfills_a_table()):
        report = _report(ev, current)
        assert report.recommendations, "an infeasible report must say what to do"


def test_locks_that_overfill_a_table_are_named() -> None:
    from seating_planner.solver.report import KIND_CHANGE_HARD_RULE, KIND_UNLOCK

    report = _report(*_three_locked_to_one_free_seat())
    unlocks = [r for r in report.recommendations if r.kind == KIND_UNLOCK]
    assert unlocks, f"unlocking is the remedy: {report.recommendations}"
    text = " ".join(r.message for r in unlocks)
    for guest in ("g-1", "g-2", "g-3"):
        assert guest in text, f"{guest} is one of the locks filling t-1: {text}"
    assert KIND_CHANGE_HARD_RULE not in _kinds(report), "the event has no hard rule"


def test_a_chart_that_overfills_a_table_asks_for_capacity() -> None:
    from seating_planner.solver.report import KIND_ADD_CAPACITY, KIND_ADD_TABLE, KIND_CHANGE_HARD_RULE

    report = _report(*_chart_overfills_a_table())
    kinds = _kinds(report)
    assert kinds & {KIND_ADD_CAPACITY, KIND_ADD_TABLE}, f"the table needs room: {report.recommendations}"
    capacity = [r for r in report.recommendations if r.kind in (KIND_ADD_CAPACITY, KIND_ADD_TABLE)]
    assert any("t-1" in r.message for r in capacity), f"name the overfilled table: {capacity}"
    assert KIND_CHANGE_HARD_RULE not in kinds, "the event has no hard rule"
