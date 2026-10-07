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


# ac5 (added 2026-10-06, from run 1's pre-merge review): fallback advice is checked
# before it is given. Run 1 advised unlocking a guest when the chart itself overfilled
# the table, capacity at a table no extra seat could help, and capacity where the
# unlocks alone were enough. Each case below is solved again with the advice applied.

import re  # noqa: E402

_CASES: dict[str, tuple[dict[str, int], int, dict[str, str], dict[str, str], set[str]]] = {
    # chart puts 3 at a 2-seat t-1 and a new guest is locked there too
    "chart-overfill-plus-lock": ({"t-1": 2, "t-2": 4}, 4, {"g-3": "t-1"},
                                 {"g-0": "t-1", "g-1": "t-1", "g-2": "t-1"}, set()),
    # two chart guests at t-1 are locked to an empty one-seat t-2
    "locks-contradict-chart": ({"t-1": 2, "t-2": 1, "t-3": 2}, 2, {"g-0": "t-2", "g-1": "t-2"},
                               {"g-0": "t-1", "g-1": "t-1"}, set()),
    # t-1 is overfilled only if g-2 is counted, and g-2 is unlocked; two contradictions elsewhere
    "unlocked-guest-is-free": ({"t-1": 2, "t-2": 4, "t-3": 4}, 5, {"g-3": "t-3", "g-4": "t-3"},
                               {"g-0": "t-1", "g-1": "t-1", "g-2": "t-1", "g-3": "t-2", "g-4": "t-2"},
                               {"g-2"}),
    # locks overfill two tables at once
    "locks-overfill-two-tables": ({"t-1": 1, "t-2": 1, "t-3": 6}, 6,
                                  {"g-2": "t-1", "g-3": "t-1", "g-4": "t-2", "g-5": "t-2"},
                                  {"g-0": "t-1", "g-1": "t-2"}, set()),
}


def _build(caps: dict[str, int], n: int, locks: dict[str, str]) -> Any:
    return _event(caps, [f"g-{i}" for i in range(n)], locks)


def _solve_case(caps: dict[str, int], n: int, locks: dict[str, str], current: dict[str, str],
                unlocked: set[str]) -> Any:
    from seating_planner.solver import solve_event

    return solve_event(_build(caps, n, locks), mode="event_day", current=current, unlocked=unlocked)


def _named(pattern: str, recs: list[Any]) -> set[str]:
    return {m for r in recs for m in re.findall(pattern, r.message)}


def test_every_fallback_recommendation_restores_feasibility() -> None:
    from seating_planner.solver.report import KIND_ADD_CAPACITY, KIND_ADD_TABLE, KIND_UNLOCK

    for name, (caps, n, locks, current, unlocked) in _CASES.items():
        report = _solve_case(caps, n, locks, current, unlocked).infeasibility_report
        assert report is not None, f"{name}: the case must be infeasible as given"
        assert report.recommendations, f"{name}: an infeasible report must say what to do"
        unlocks = [r for r in report.recommendations if r.kind == KIND_UNLOCK]
        if unlocks:
            guests = _named(r"\bg-\d+\b", unlocks)
            freed = {g: t for g, t in locks.items() if g not in guests}
            after = _solve_case(caps, n, freed, current, unlocked)
            assert after.infeasibility_report is None, (
                f"{name}: unlocking {sorted(guests)} as advised leaves it infeasible: {unlocks}")
        capacity = [r for r in report.recommendations if r.kind in (KIND_ADD_CAPACITY, KIND_ADD_TABLE)]
        tables = _named(r"\bt-\d+\b", capacity)
        if tables:
            roomier = {t: c + 10 if t in tables else c for t, c in caps.items()}
            after = _solve_case(roomier, n, locks, current, unlocked)
            assert after.infeasibility_report is None, (
                f"{name}: more seats at {sorted(tables)} as advised leaves it infeasible: {capacity}")


def test_a_chart_overfill_with_a_lock_still_asks_for_capacity() -> None:
    from seating_planner.solver.report import KIND_ADD_CAPACITY, KIND_ADD_TABLE

    report = _solve_case(*_CASES["chart-overfill-plus-lock"]).infeasibility_report
    capacity = [r for r in report.recommendations if r.kind in (KIND_ADD_CAPACITY, KIND_ADD_TABLE)]
    assert "t-1" in _named(r"\bt-\d+\b", capacity), f"the chart overfills t-1: {report.recommendations}"


def test_capacity_is_not_advised_when_the_unlocks_alone_suffice() -> None:
    from seating_planner.solver.report import KIND_ADD_CAPACITY, KIND_ADD_TABLE

    for name in ("locks-contradict-chart", "unlocked-guest-is-free"):
        report = _solve_case(*_CASES[name]).infeasibility_report
        kinds = {r.kind for r in report.recommendations}
        assert not kinds & {KIND_ADD_CAPACITY, KIND_ADD_TABLE}, (
            f"{name}: unlocking alone restores it, so capacity is not the remedy: {report.recommendations}")
