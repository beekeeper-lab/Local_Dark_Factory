"""Hidden tests for bean-024 — the requested worker count is the one used.

Written from bean-024's criteria. The result's solver_config is bean-009's
record of the configuration a solve ran with; it is read back from the solver,
so it is the evidence of what was used. Every path is exercised that a small
event can reach: an ordinary feasible solve, an infeasible one, and a
low-disruption solve.
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


def _event(capacity: int, n: int) -> Any:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table

    tables = [Table(id="t0", name="T0", capacity=capacity, shape="round", position=(0.0, 0.0)),
              Table(id="t1", name="T1", capacity=capacity, shape="round", position=(0.0, 1.0))]
    guests = [Guest(id=f"g{i}", name=f"G{i}", status=RsvpStatus.CONFIRMED) for i in range(n)]
    return Event(id="e", name="E", tables=tables, guests=guests, groups=[], rules=[])


def _workers(result: Any) -> int:
    return int(result.solver_config.num_search_workers)


def test_a_feasible_solve_runs_with_the_requested_workers() -> None:
    from seating_planner.solver import solve_event

    for n in (2, 3):
        result = solve_event(_event(2, 4), mode="planning", num_search_workers=n)
        assert result.status == "feasible"
        assert _workers(result) == n, f"asked for {n} workers, ran with {_workers(result)}"


def test_the_default_is_still_one() -> None:
    from seating_planner.solver import solve_event

    assert _workers(solve_event(_event(2, 4), mode="planning")) == 1


def test_an_infeasible_solve_records_the_request() -> None:
    from seating_planner.solver import solve_event

    result = solve_event(_event(1, 3), mode="planning", num_search_workers=2)
    assert result.status != "feasible"
    assert _workers(result) == 2


def test_a_low_disruption_solve_records_the_request() -> None:
    from seating_planner.solver import solve_event

    current = {"g0": "t0", "g1": "t0", "g2": "t1", "g3": "t1"}
    result = solve_event(_event(2, 4), mode="low_disruption", current=current, movement_limit=1, num_search_workers=2)
    assert result.status == "feasible"
    assert _workers(result) == 2
