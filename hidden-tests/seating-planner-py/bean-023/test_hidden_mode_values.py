"""Hidden tests for bean-023 — a mode is chosen by its value.

Written from bean-023's criteria. A mode string that is equal to the literal but
is not the same object — decoded from JSON, or joined at run time — must behave
exactly as the literal does. Low-disruption is the mode bean-023 names; planning
is checked too, and any other mode the entry point accepts when the suite runs
gets the same equal-but-not-identical treatment.
"""

from __future__ import annotations

import json
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


def _fresh(s: str) -> str:
    out = "".join([s[:1], s[1:]])
    assert out == s
    return out


def _event() -> Any:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType

    tables = [Table(id=f"t{i}", name=f"T{i}", capacity=2, shape="round", position=(0.0, float(i))) for i in range(2)]
    guests = [Guest(id=f"g{i}", name=f"G{i}", status=RsvpStatus.CONFIRMED) for i in range(4)]
    # A strong reason to move g0 next to g2, which a movement limit of 0 forbids.
    rules = [Rule(id="pair", rule_type=RuleType.SAME_TABLE, hardness=Hardness.SOFT, weight=100, guest_ids=("g0", "g2"))]
    return Event(id="e", name="E", tables=tables, guests=guests, groups=[], rules=rules)


CURRENT = {"g0": "t0", "g1": "t0", "g2": "t1", "g3": "t1"}


def _solve(**kw: Any) -> Any:
    from seating_planner.solver import solve_event

    return solve_event(_event(), **kw)


@pytest.mark.parametrize("make", [_fresh, lambda s: json.loads(json.dumps(s))], ids=["joined", "json"])
def test_runtime_low_disruption_respects_the_limit(make: Any) -> None:
    literal = _solve(mode="low_disruption", current=CURRENT, movement_limit=0)
    runtime = _solve(mode=make("low_disruption"), current=CURRENT, movement_limit=0)
    assert literal.status == runtime.status == "feasible"
    assert dict(runtime.assignments) == CURRENT, "a limit of 0 moves nobody"
    assert dict(runtime.assignments) == dict(literal.assignments)


@pytest.mark.parametrize("extra", [{}, {"movement_limit": 1}], ids=["bare", "with-limit"])
def test_runtime_low_disruption_without_a_chart_is_refused(extra: dict[str, Any]) -> None:
    # Measured on bean-013's code: the joined string with neither a chart nor a
    # limit was accepted and ran a planning solve labelled low_disruption.
    with pytest.raises((ValueError, TypeError)):
        _solve(mode="low_disruption", **extra)
    with pytest.raises((ValueError, TypeError)):
        _solve(mode=_fresh("low_disruption"), **extra)


def test_runtime_planning_is_planning() -> None:
    literal = _solve(mode="planning")
    runtime = _solve(mode=_fresh("planning"))
    assert literal.status == runtime.status == "feasible"
    assert dict(runtime.assignments) == dict(literal.assignments)
