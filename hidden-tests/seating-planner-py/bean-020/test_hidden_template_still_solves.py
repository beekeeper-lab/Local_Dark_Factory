"""Hidden test for bean-020's ac7 -- the refusal is for adjacent-seat rules only.

Written after the v2 rebuild's run 1 (PR #21, closed on its pre-merge review):
solve_hard refused EVERY enabled hard rule that was not same/different-table, so
the shipped default wedding template -- whose only hard rule is a group-bound
min_distance ``accessible_seating`` rule -- could no longer be solved at all
(main: feasible; PR: ValueError "... is 'min_distance' and hard, but no seat
posit...").

Asserted behaviourally: an event built from ``default_wedding_rules()`` solves
(status feasible) in every mode, and a lone hard min_distance rule is not
refused. The adjacent-seat refusal itself is test_hidden_unevaluable.py's."""

from __future__ import annotations

import dataclasses
import inspect
import os
import sys
from pathlib import Path
from typing import Any

import pytest

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)

_CURRENT = {"g0": "t0", "g1": "t0", "g2": "t1"}
MODES = {
    "planning": {"mode": "planning"},
    "low_disruption": {"mode": "low_disruption", "current": _CURRENT, "movement_limit": 1},
    "event_day": {"mode": "event_day", "current": _CURRENT},
}


def _event(rules: list[Any]) -> Any:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table

    status_field = "status" if "status" in {f.name for f in dataclasses.fields(Guest)} else "rsvp_status"
    return Event(
        id="e",
        name="E",
        tables=[Table(id=f"t{i}", name=f"T{i}", capacity=2, shape="round", position=(0.0, float(i)))
                for i in range(2)],
        guests=[Guest(id=f"g{i}", name=f"G{i}", **{status_field: RsvpStatus.CONFIRMED}) for i in range(4)],
        groups=[],
        rules=rules,
    )


def _solve(event: Any, mode: str) -> Any:
    from seating_planner import solver

    fn = getattr(solver, "solve_event", None) or solver.solve_hard
    params = inspect.signature(fn).parameters
    aliases = {"current": "current_assignments", "movement_limit": "move_limit"}
    kw = {(k if k in params else aliases.get(k, k)): v for k, v in MODES[mode].items()}
    return fn(event, **kw)


def _status(result: Any) -> Any:
    return result["status"] if isinstance(result, dict) else result.status


@pytest.mark.parametrize("mode", sorted(MODES))
def test_the_default_wedding_template_still_solves(mode: str) -> None:
    from seating_planner.rules import default_wedding_rules

    result = _solve(_event(default_wedding_rules()), mode)
    assert _status(result) == "feasible", _status(result)


def test_a_hard_min_distance_rule_is_not_refused() -> None:
    from seating_planner.rules import default_wedding_rules

    hard_min = [r for r in default_wedding_rules() if str(getattr(r.kind, "value", r.kind)) == "min_distance"]
    assert hard_min, "the default template carries a hard min_distance rule"
    result = _solve(_event(hard_min), "planning")
    assert _status(result) == "feasible"
