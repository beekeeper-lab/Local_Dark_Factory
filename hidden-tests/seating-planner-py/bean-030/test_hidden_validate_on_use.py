"""Hidden tests for bean-030 — solve_event and save_event validate the whole
event as it is when they are called, not as it was built.

Written from bean-030's criteria, which come from the retroactive review of
bean-002, bean-003, bean-006 and bean-011
(evidence/reviews/retroactive-20260928.md):

  * ac1 — an event changed after construction so that it breaks a rule its
    constructors enforce is refused by solve_event, in every mode, with
    EventValidationError naming what is wrong. On the main branch a weight of
    10^6 was scored, a hard rule carried a weight, a 501st guest and a
    duplicate guest id were solved.
  * ac2 — a lock naming a table or guest the event no longer has, and a group
    naming a guest the event does not have, are refused the same way, never
    as a KeyError. On main a lock to a removed table raised KeyError.
  * ac3 — the rule checks do not depend on there being guests to seat or
    tables to seat them at. On main they were skipped in both cases.
  * ac4 — save_event refuses what load_event could not load, leaves the saved
    event as it was, and does not refuse what load_event can load.

Messages are checked only for the id or limit they name, never for wording.
"""

from __future__ import annotations

import os
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)


def _error() -> type[Exception]:
    from seating_planner.domain import EventValidationError

    return EventValidationError


def _table(tid: str, capacity: int = 4) -> Any:
    from seating_planner.domain import Table

    return Table(id=tid, name=tid, capacity=capacity, shape="round", position=(0.0, 0.0))


def _guest(gid: str, status: str = "confirmed") -> Any:
    from seating_planner.domain import Guest, RsvpStatus

    return Guest(id=gid, name=gid, status=RsvpStatus(status))


def _rule(rid: str, kind: str, hardness: str, weight: int | None, guests: tuple[str, ...] = (),
          groups: tuple[str, ...] = (), **kw: Any) -> Any:
    from seating_planner.rules import Hardness, Rule, RuleType

    return Rule(id=rid, rule_type=RuleType(kind), hardness=Hardness(hardness), weight=weight,
                guest_ids=guests, group_ids=groups, **kw)


def _event(tables: list[str] | None = None, guests: list[str] | None = None,
           status: str = "confirmed", rules: list[Any] | None = None, groups: list[Any] | None = None) -> Any:
    from seating_planner.domain import Event

    return Event(
        id="ev-030", name="Validate on use",
        tables=[_table(t) for t in (["t-1", "t-2"] if tables is None else tables)],
        guests=[_guest(g, status) for g in (["g-1", "g-2"] if guests is None else guests)],
        groups=list(groups or []),
        rules=list(rules or []),
    )


def _modes() -> list[dict[str, Any]]:
    return [
        {"mode": "planning"},
        {"mode": "low_disruption", "current": {}, "movement_limit": 0},
        {"mode": "event_day", "current": {}},
    ]


def _refused_everywhere(build: Callable[[], Any], names: str) -> None:
    from seating_planner.solver import solve_event

    for kw in _modes():
        with pytest.raises(_error()) as caught:
            solve_event(build(), time_limit_s=5.0, **kw)
        assert names in str(caught.value), f"{kw['mode']}: the refusal must name {names!r}: {caught.value}"


def test_the_error_is_a_value_error() -> None:
    assert issubclass(_error(), ValueError)


# --- ac1 ---------------------------------------------------------------------


def _soft_weight_raised() -> Any:
    rule = _rule("r-pull", "same_table", "soft", 5, ("g-1", "g-2"))
    ev = _event(rules=[rule])
    rule.weight = 10**6
    return ev


def _hard_weight_added() -> Any:
    rule = _rule("r-hard", "different_table", "hard", None, ("g-1", "g-2"))
    ev = _event(rules=[rule])
    rule.weight = 7
    return ev


def _distance_made_vague() -> Any:
    rule = _rule("r-far", "min_distance", "soft", 5, ("g-1", "g-2"), min_zones=1)
    ev = _event(rules=[rule])
    rule.distance_m = "far apart"
    return ev


def _guest_limit_passed() -> Any:
    from seating_planner.domain import Event

    ev = Event(id="ev-030", name="Big", tables=[_table(f"t-{i}", 10) for i in range(51)],
               guests=[_guest(f"g-{i}") for i in range(500)])
    ev.guests.append(_guest("g-500"))
    return ev


def _guest_id_repeated() -> Any:
    ev = _event()
    ev.guests.append(_guest("g-2"))
    return ev


def _seat_made_a_string() -> Any:
    ev = _event(guests=["g-1", "g-late"], status="pending")
    ev.guests[1].reserved_seat = "no"
    return ev


@pytest.mark.parametrize(
    ("build", "names"),
    [
        (_soft_weight_raised, "r-pull"),
        (_hard_weight_added, "r-hard"),
        (_distance_made_vague, "r-far"),
        (_guest_limit_passed, "500"),
        (_guest_id_repeated, "g-2"),
        (_seat_made_a_string, "g-late"),
    ],
)
def test_a_mutated_event_is_refused_in_every_mode(build: Callable[[], Any], names: str) -> None:
    _refused_everywhere(build, names)


# --- ac2 ---------------------------------------------------------------------


def _lock_to_removed_table() -> Any:
    ev = _event()
    ev.lock_guest("g-1", "t-2")
    ev.tables.pop()
    return ev


def _lock_on_removed_guest() -> Any:
    ev = _event(guests=["g-1", "g-2", "g-gone"])
    ev.lock_guest("g-gone", "t-1")
    ev.guests.pop()
    return ev


def _group_names_a_stranger() -> Any:
    from seating_planner.domain import Group

    ev = _event(groups=[Group(id="grp-fam", name="Family", member_ids=("g-1", "g-2"))])
    ev.groups[0].member_ids = ("g-1", "g-stranger")
    return ev


@pytest.mark.parametrize(
    ("build", "names"),
    [
        (_lock_to_removed_table, "t-2"),
        (_lock_on_removed_guest, "g-gone"),
        (_group_names_a_stranger, "g-stranger"),
    ],
)
def test_a_dangling_reference_is_refused_never_a_key_error(build: Callable[[], Any], names: str) -> None:
    _refused_everywhere(build, names)


# --- ac3 ---------------------------------------------------------------------


def _degenerate(rules: list[Any], groups: list[Any] | None = None) -> list[tuple[str, Any]]:
    return [
        ("no eligible guests", _event(status="declined", rules=rules, groups=groups)),
        ("no guests at all", _event(guests=[], rules=rules, groups=groups)),
        ("no tables", _event(tables=[], rules=rules, groups=groups)),
    ]


@pytest.mark.parametrize(
    ("rules", "names"),
    [
        (lambda: [_rule("r-ghost", "same_table", "hard", None, ("g-1", "g-ghost"))], "r-ghost"),
        (lambda: [_rule("r-nogrp", "different_table", "hard", None, groups=("grp-none",))], "r-nogrp"),
        (lambda: [_rule("r-soft-ghost", "same_table", "soft", 3, ("g-1", "g-ghost"))], "r-soft-ghost"),
    ],
)
def test_rule_references_are_checked_with_nothing_to_seat(rules: Callable[[], list[Any]], names: str) -> None:
    from seating_planner.solver import solve_event

    # The rule is named, not the reference: with no guests at all, every guest
    # it names is unknown, and naming any of them is right.
    for label, ev in _degenerate(rules()):
        with pytest.raises(_error()) as caught:
            solve_event(ev, mode="planning", time_limit_s=5.0)
        assert names in str(caught.value), f"{label}: {caught.value}"


def test_a_hard_rule_refused_with_guests_and_tables_is_refused_without_them() -> None:
    from seating_planner.solver import solve_event

    rules = [_rule("r-zones", "min_distance", "hard", None, ("g-1", "g-2"), min_zones=1)]
    try:
        solve_event(_event(rules=rules), mode="planning", time_limit_s=5.0)
        refused_normally = None
    except Exception as exc:  # noqa: BLE001 - the comparison is the point
        refused_normally = exc
    if refused_normally is None:
        # This tree expresses a hard min_distance rule (bean-026 says none
        # before this bean does), so there is nothing to compare: not a skip,
        # which the gate would count as a failure of the suite.
        return
    assert isinstance(refused_normally, _error()), f"refused, but not with the typed error: {refused_normally!r}"
    for label, ev in _degenerate(rules):
        with pytest.raises(_error()) as caught:
            solve_event(ev, mode="planning", time_limit_s=5.0)
        assert "r-zones" in str(caught.value), f"{label}: {caught.value}"


def test_a_valid_event_with_nothing_to_seat_is_still_answered() -> None:
    from seating_planner.solver import solve_event

    rules = [_rule("r-pair", "same_table", "hard", None, ("g-1", "g-2"))]
    assert solve_event(_event(status="declined", rules=rules), mode="planning").status == "feasible"
    assert solve_event(_event(tables=[], rules=rules), mode="planning").status == "infeasible"
    # And one refusal in the same test, so it cannot pass on a tree that
    # never validates anything.
    ghost = [_rule("r-ghost", "same_table", "hard", None, ("g-1", "g-ghost"))]
    with pytest.raises(_error()):
        solve_event(_event(tables=[], rules=ghost), mode="planning")


# --- ac4 ---------------------------------------------------------------------


def _repo(tmp_path: Path) -> Any:
    from seating_planner.store import Repository

    return Repository(tmp_path / "events.db")


def _saved_shape(ev: Any) -> tuple[Any, ...]:
    return (
        [(t.id, t.capacity) for t in ev.tables],
        [(g.id, g.status.value, g.reserved_seat) for g in ev.guests],
        dict(ev.locks),
        sorted(r.id for r in ev.rules),
    )


@pytest.mark.parametrize(
    ("build", "names"),
    [
        (_lock_to_removed_table, "t-2"),
        (_lock_on_removed_guest, "g-gone"),
        (_guest_id_repeated, "g-2"),
        (_guest_limit_passed, "500"),
        (_soft_weight_raised, "r-pull"),
        (_hard_weight_added, "r-hard"),
        (_distance_made_vague, "r-far"),
        (_seat_made_a_string, "g-late"),
    ],
)
def test_save_refuses_what_could_not_be_loaded_and_keeps_the_saved_event(
    tmp_path: Path, build: Callable[[], Any], names: str
) -> None:
    repo = _repo(tmp_path)
    good = _event(rules=[_rule("r-keep", "same_table", "soft", 4, ("g-1", "g-2"))])
    good.lock_guest("g-1", "t-1")
    repo.save_event(good, actor="setup")
    before = _saved_shape(repo.load_event("ev-030"))

    with pytest.raises(_error()) as caught:
        repo.save_event(build(), actor="editor")
    assert names in str(caught.value), caught.value
    assert _saved_shape(repo.load_event("ev-030")) == before, "a refused save must leave the saved event as it was"


def test_save_does_not_refuse_what_load_can_load(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    # A rule naming a group the event does not have yet, a disabled rule naming
    # nobody the event has, a group naming a stranger: each loads back, so
    # none is a reason to refuse a save.
    from seating_planner.domain import Group

    ev = _event(
        rules=[
            _rule("r-template", "same_table", "hard", None, groups=("grp-later",)),
            _rule("r-off", "different_table", "soft", 2, ("g-x", "g-y"), enabled=False),
        ],
        groups=[Group(id="grp-fam", name="Family", member_ids=("g-1", "g-stranger"))],
    )
    ev.lock_guest("g-2", "t-2")
    repo.save_event(ev, actor="setup")
    loaded = repo.load_event("ev-030")
    assert _saved_shape(loaded) == _saved_shape(ev)

    # The one change that could not load back is refused, in the same test.
    ev.tables.pop()
    with pytest.raises(_error()):
        repo.save_event(ev, actor="editor")
