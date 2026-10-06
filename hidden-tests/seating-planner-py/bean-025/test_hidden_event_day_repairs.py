"""Hidden tests for bean-025 — event-day unlock and event-day diagnosis.

Written from bean-025's criteria, which come from bean-014's pre-merge review:

  * ac1 — an explicit unlock releases a guest in event-day mode even when an
    explicit lock also names them. bean-014 honoured `unlocked` only for the
    day-lock and still pinned every event.locks entry.
  * ac2 — when a new guest cannot be seated, the report blames only a hard rule
    whose removal alone would let the event solve with the chart still in place,
    and recommends capacity. bean-014's diagnosis probed models without the
    day-lock pins, so every hard rule looked guilty.

  * ac4 (added 2026-10-06, from run 1's pre-merge review) — a stored lock can
    be what makes an event-day solve infeasible: a new guest locked to a full
    table, or a chart guest whose lock names another table and who is not
    unlocked. The report then recommends unlocking that guest, and with no hard
    rule in the event it does not blame the hard rules.

ac2 is checked as a property, not as one expected list: every rule the report
names is removed on its own and the solve re-run in event-day mode with the same
chart; it must then be feasible.
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


def _event(caps: dict[str, int], guests: list[str], rules: list[tuple[str, str, str, int | None, tuple[str, ...]]],
           locks: dict[str, str] | None = None) -> Any:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType

    kinds = {"same": RuleType.SAME_TABLE, "diff": RuleType.DIFFERENT_TABLE}
    hard = {"hard": Hardness.HARD, "soft": Hardness.SOFT}
    ev = Event(
        id="e", name="E",
        tables=[Table(id=t, name=t, capacity=c, shape="round", position=(0.0, float(i))) for i, (t, c) in enumerate(caps.items())],
        guests=[Guest(id=g, name=g, status=RsvpStatus.CONFIRMED) for g in guests],
        groups=[],
        rules=[Rule(id=rid, rule_type=kinds[k], hardness=hard[h], weight=w, guest_ids=gids) for rid, k, h, w, gids in rules],
    )
    for g, t in (locks or {}).items():
        ev.lock_guest(g, t)
    return ev


def _solve(ev: Any, current: dict[str, str], **kw: Any) -> Any:
    from seating_planner.solver import solve_event

    return solve_event(ev, mode="event_day", current=current, **kw)


def test_unlock_releases_a_guest_who_is_also_explicitly_locked() -> None:
    rules = [("pull", "same", "soft", 100, ("g-0", "g-2"))]
    current = {"g-0": "t-1", "g-1": "t-1", "g-2": "t-2"}
    ev = _event({"t-1": 3, "t-2": 3}, ["g-0", "g-1", "g-2"], rules, locks={"g-2": "t-2"})
    result = _solve(ev, current, unlocked={"g-2"})
    assert result.status == "feasible"
    assert result.assignments["g-2"] == "t-1", "an explicit unlock must release the explicit lock too"
    assert result.assignments["g-0"] == "t-1" and result.assignments["g-1"] == "t-1", "nobody else moves"


def test_a_lock_without_an_unlock_still_holds() -> None:
    rules = [("pull", "same", "soft", 100, ("g-0", "g-2"))]
    current = {"g-0": "t-1", "g-1": "t-1", "g-2": "t-2"}
    ev = _event({"t-1": 3, "t-2": 3}, ["g-0", "g-1", "g-2"], rules, locks={"g-2": "t-2"})
    assert _solve(ev, current).assignments["g-2"] == "t-2"


def _named_rules_each_explain_it(caps: dict[str, int], guests: list[str], rules: list[Any], current: dict[str, str]) -> Any:
    result = _solve(_event(caps, guests, rules), current)
    assert result.status == "infeasible"
    report = result.infeasibility_report
    assert report is not None
    for rid in report.conflict_rule_ids:
        without = [r for r in rules if r[0] != rid]
        again = _solve(_event(caps, guests, without), current)
        assert again.status == "feasible", (
            f"the report blames {rid!r}, but removing it alone leaves the event unsolvable "
            f"with the chart in place: {list(report.conflict_rule_ids)}"
        )
    return report


def test_no_seat_blames_only_rules_that_explain_it() -> None:
    # t-1 is full with g-0 and g-2; g-1 sits alone at t-2. The new guest g-3 must
    # sit with g-0 (hard), which cannot happen without moving someone. A second
    # hard rule keeping g-0 and g-1 apart is already satisfied and irrelevant.
    rules = [("r-with-g0", "same", "hard", None, ("g-0", "g-3")),
             ("r-unrelated", "diff", "hard", None, ("g-0", "g-1"))]
    current = {"g-0": "t-1", "g-2": "t-1", "g-1": "t-2"}
    report = _named_rules_each_explain_it({"t-1": 2, "t-2": 2}, ["g-0", "g-1", "g-2", "g-3"], rules, current)
    assert "r-unrelated" not in report.conflict_rule_ids


def test_no_seat_at_all_recommends_capacity_and_blames_no_rule() -> None:
    rules = [("r-apart", "diff", "hard", None, ("g-0", "g-1"))]
    current = {"g-0": "t-1", "g-1": "t-2"}
    report = _named_rules_each_explain_it({"t-1": 1, "t-2": 1}, ["g-0", "g-1", "g-2"], rules, current)
    assert report.conflict_rule_ids == () or list(report.conflict_rule_ids) == []
    kinds = {r.kind for r in report.recommendations}
    assert kinds & {"add_capacity", "add_table"}, f"a full room needs capacity: {kinds}"


def _lock_advice(report: Any, guest: str) -> list[Any]:
    from seating_planner.solver.report import KIND_UNLOCK

    return [r for r in report.recommendations if r.kind == KIND_UNLOCK and guest in r.message]


def _blames_rules(report: Any) -> bool:
    from seating_planner.solver.report import KIND_CHANGE_HARD_RULE

    return any(r.kind == KIND_CHANGE_HARD_RULE for r in report.recommendations)


def test_a_lock_that_leaves_a_new_guest_no_seat_is_named() -> None:
    # g-3 is new and locked to t-1, which the chart already fills; t-2 has a free seat.
    ev = _event({"t-1": 2, "t-2": 2}, ["g-0", "g-1", "g-2", "g-3"], [], locks={"g-3": "t-1"})
    result = _solve(ev, {"g-0": "t-1", "g-1": "t-1", "g-2": "t-2"})
    report = result.infeasibility_report
    assert report is not None, "a guest locked to a full table cannot be seated"
    assert _lock_advice(report, "g-3"), f"unlocking g-3 is the remedy: {report.recommendations}"
    assert not report.conflict_rule_ids, "the event has no hard rule to blame"
    assert not _blames_rules(report), f"no hard rule exists to review: {report.recommendations}"


def test_a_lock_that_contradicts_the_chart_is_named() -> None:
    # g-2 is locked to t-2, the chart seats g-2 at t-1, and g-2 is not unlocked.
    ev = _event({"t-1": 2, "t-2": 2}, ["g-0", "g-1", "g-2"], [], locks={"g-2": "t-2"})
    result = _solve(ev, {"g-0": "t-1", "g-2": "t-1"})
    report = result.infeasibility_report
    assert report is not None, "a lock and a chart pin that disagree cannot both hold"
    assert _lock_advice(report, "g-2"), f"unlocking g-2 is the remedy: {report.recommendations}"
    assert not report.conflict_rule_ids, "the event has no hard rule to blame"
    assert not _blames_rules(report), f"no hard rule exists to review: {report.recommendations}"
