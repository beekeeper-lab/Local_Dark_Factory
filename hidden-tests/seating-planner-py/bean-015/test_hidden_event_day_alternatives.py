"""Hidden tests for bean-015 — ranked alternatives when no event-day seat exists.

Written from bean-015's criteria before its code existed:

  * ac1 — with no valid seat the new guest is left unassigned and no existing
    assignment changes.
  * ac3 — alternatives are ordered by disruption count, then violated-rule weight.
  * ac5 / constraint — generating alternatives changes no saved state; they are
    proposals and none is applied automatically.

What the bean does NOT fix, and this file therefore never assumes: where the
alternatives live (a field on the solve result, the infeasibility report, or a
separate function), what they are called, or how an alternative spells its
fields. So:

  * ac1 and ac5 are checked through the stable `solve_event(mode="event_day")`
    entry point, in three shapes of "no seat": a full room, a hard rule that
    points at a full table, and hard rules that rule out every table (with an
    explicit lock in the event). Whatever else the implementation returns, the
    new guest is not seated, nobody on the chart is moved, and neither the
    event nor the chart handed in is altered — probing "what if we added a
    table / unlocked this guest / raised this capacity" on the real objects is
    exactly the automatic application the constraint forbids.
  * ac3 is checked on the result's to_dict() only IF it carries a list of
    entries that each state a disruption count (any key containing "disrupt").
    If none is there the alternatives live elsewhere, which the bean allows,
    and the check has nothing to say. It never asserts where they must be.

The weight tie-break is compared only between two entries that both state a
numeric weight: a hard rule has no weight, and the bean does not say where a
hard-rule exception ranks against a numeric one.
"""

from __future__ import annotations

import dataclasses
import inspect
import os
import sys
from collections.abc import Iterator, Mapping
from pathlib import Path
from typing import Any

import pytest

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)

NEW = "g-new"


def _first_field(cls: type, candidates: tuple[str, ...]) -> str:
    """The first of ``candidates`` that is an actual field of ``cls``."""
    names = {f.name for f in dataclasses.fields(cls)}
    for candidate in candidates:
        if candidate in names:
            return candidate
    raise AssertionError(f"none of {candidates} is a field of {cls.__name__} (has {sorted(names)})")


def _first_attr(module: Any, candidates: tuple[str, ...]) -> Any:
    """The first attribute of ``module`` named one of ``candidates``."""
    for candidate in candidates:
        found = getattr(module, candidate, None)
        if found is not None:
            return found
    raise AssertionError(f"none of {candidates} is an attribute of {module.__name__}")


def _event(caps: dict[str, int], guests: list[str], rules: list[tuple[str, str, str, int | None, tuple[str, ...]]],
           locks: dict[str, str] | None = None) -> Any:
    from seating_planner import rules as rules_mod
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule

    # Names differ between builds: RuleType/RuleKind, status/rsvp_status,
    # rule_type/kind, guest_ids/guests. Take whichever this build has.
    kind_enum = _first_attr(rules_mod, ("RuleType", "RuleKind"))
    status_field = _first_field(Guest, ("status", "rsvp_status"))
    rule_kind_field = _first_field(Rule, ("rule_type", "kind", "type"))
    rule_guests_field = _first_field(Rule, ("guest_ids", "guests"))
    kinds = {"same": kind_enum.SAME_TABLE, "diff": kind_enum.DIFFERENT_TABLE}
    hard = {"hard": Hardness.HARD, "soft": Hardness.SOFT}
    ev = Event(
        id="e", name="E",
        tables=[Table(id=t, name=t, capacity=c, shape="round", position=(0.0, float(i)))
                for i, (t, c) in enumerate(caps.items())],
        guests=[Guest(id=g, name=g, **{status_field: RsvpStatus.CONFIRMED}) for g in guests],
        groups=[],
        rules=[Rule(id=rid, hardness=hard[h], weight=w, **{rule_kind_field: kinds[k], rule_guests_field: gids})
               for rid, k, h, w, gids in rules],
    )
    for g, t in (locks or {}).items():
        ev.lock_guest(g, t)
    return ev


# Three rooms in which the new guest has no valid seat without breaking something.
SHAPES: dict[str, tuple[dict[str, int], dict[str, str], list[Any], dict[str, str]]] = {
    # Every seat is taken and there are no rules at all.
    "full_room": ({"t-1": 2, "t-2": 1}, {"g-0": "t-1", "g-1": "t-1", "g-2": "t-2"}, [], {}),
    # A free seat exists at t-2, but a hard rule says the new guest sits with
    # g-0 at t-1, which is full. A soft rule gives the room a weight.
    "hard_rule_to_full_table": (
        {"t-1": 2, "t-2": 2},
        {"g-0": "t-1", "g-1": "t-1", "g-2": "t-2"},
        [("r-with", "same", "hard", None, ("g-0", NEW)),
         ("r-soft", "same", "soft", 5, ("g-1", "g-2"))],
        {},
    ),
    # Seats are free at both tables, but hard rules keep the new guest away from
    # whoever sits at each; g-1 is also explicitly locked.
    "hard_rules_rule_out_every_table": (
        {"t-1": 2, "t-2": 2},
        {"g-0": "t-1", "g-1": "t-2"},
        [("r-apart-0", "diff", "hard", None, ("g-0", NEW)),
         ("r-apart-1", "diff", "hard", None, ("g-1", NEW))],
        {"g-1": "t-2"},
    ),
}


def _build(shape: str) -> tuple[Any, dict[str, str]]:
    caps, current, rules, locks = SHAPES[shape]
    return _event(caps, [*current, NEW], rules, locks), dict(current)


def _solve(ev: Any, current: Mapping[str, str]) -> Any:
    from seating_planner import solver as solver_mod

    # The entry point and the baseline argument are named differently by build.
    solve_fn = _first_attr(solver_mod, ("solve_event", "solve_hard"))
    params = inspect.signature(solve_fn).parameters
    baseline = "current" if "current" in params else "current_assignments"
    return solve_fn(ev, mode="event_day", **{baseline: current})


def _snapshot(ev: Any) -> tuple[Any, ...]:
    def rule(r: Any) -> Any:
        to_dict = getattr(r, "to_dict", None)
        return repr(sorted(to_dict().items())) if callable(to_dict) else repr(r)

    return (
        [(t.id, t.name, t.capacity, t.shape, tuple(t.position)) for t in ev.tables],
        [(g.id, g.name, str(getattr(g, "status", None) or getattr(g, "rsvp_status", None))) for g in ev.guests],
        [repr(g) for g in ev.groups],
        [rule(r) for r in ev.rules],
        sorted(dict(ev.locks).items()) if hasattr(ev, "locks")
        else sorted((g.id, g.locked_to_table) for g in ev.guests),
    )


@pytest.mark.parametrize("shape", sorted(SHAPES))
def test_no_seat_leaves_the_new_guest_out_and_nobody_moves(shape: str) -> None:
    ev, current = _build(shape)
    result = _solve(ev, current)
    assignments = dict(result.to_dict()["assignments"])
    assert NEW not in assignments, f"{shape}: the new guest was seated although no valid seat exists"
    assert result.unassigned_count >= 1, f"{shape}: the new guest must be counted as unassigned"
    if assignments:
        # A chart came back: it must be the chart that was already there, whole.
        assert assignments == current, (
            f"{shape}: an existing assignment changed to make room: {assignments} vs {current}"
        )


@pytest.mark.parametrize("shape", sorted(SHAPES))
def test_no_seat_applies_nothing_to_the_event_or_the_chart(shape: str) -> None:
    ev, current = _build(shape)
    before_event, before_chart = _snapshot(ev), dict(current)
    _solve(ev, current)
    assert _snapshot(ev) == before_event, (
        f"{shape}: working out alternatives changed the event itself (a table, a capacity, "
        "a rule or a lock); alternatives are proposals and none is applied"
    )
    assert dict(current) == before_chart, f"{shape}: the chart handed in was modified"


def _walk(node: Any) -> Iterator[Any]:
    yield node
    if isinstance(node, Mapping):
        for v in node.values():
            yield from _walk(v)
    elif isinstance(node, list | tuple):
        for v in node:
            yield from _walk(v)


def _field(entry: Mapping[str, Any], word: str) -> Any:
    keys = [k for k in entry if isinstance(k, str) and word in k.lower()]
    return entry[keys[0]] if len(keys) == 1 else None


def _count(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, list | tuple):
        return len(value)
    return None


def _ranked_lists(payload: Any) -> list[list[Mapping[str, Any]]]:
    """Every non-empty list whose entries each state a disruption count."""
    found = []
    for node in _walk(payload):
        if isinstance(node, list | tuple) and node and all(isinstance(e, Mapping) for e in node):
            if all(_count(_field(e, "disrupt")) is not None for e in node):
                found.append(list(node))
    return found


@pytest.mark.parametrize("shape", sorted(SHAPES))
def test_any_alternatives_on_the_result_are_ranked_cheapest_first(shape: str) -> None:
    ev, current = _build(shape)
    payload = _solve(ev, current).to_dict()
    for entries in _ranked_lists(payload):
        costs = [_count(_field(e, "disrupt")) for e in entries]
        assert all(c is not None and c >= 0 for c in costs), f"{shape}: a disruption count is not a count: {costs}"
        assert costs == sorted(costs), f"{shape}: alternatives are not ordered by disruption count: {costs}"
        for a, b in zip(entries, entries[1:]):
            wa, wb = _field(a, "weight"), _field(b, "weight")
            same = _count(_field(a, "disrupt")) == _count(_field(b, "disrupt"))
            if same and isinstance(wa, int | float) and isinstance(wb, int | float) \
                    and not isinstance(wa, bool) and not isinstance(wb, bool):
                assert wa <= wb, f"{shape}: equal disruption, but a heavier rule ranks first: {entries}"
        if shape == "full_room":
            # With no rules and no free seat, the only applicable options add
            # seats; seating the guest in a new seat moves nobody.
            assert costs[0] == 0, f"full room: the cheapest honest option moves nobody, got {costs}"
