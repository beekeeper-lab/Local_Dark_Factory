"""Hidden tests for bean-021 — a soft keep-apart rule counts only when it holds.

Written from bean-021's criteria, which were written from a defect: bean-007's
objective let every soft different-table rule score as satisfied whatever the
chart did. The bean fixes the objective and nothing else, so these ask only
what the objective must produce, through the public entry point:

  * a heavier keep-apart preference beats a lighter sit-together one (ac1),
    in more than the one shape the visible test will use
  * the returned chart is optimal, checked by enumerating every valid chart of
    small events and scoring each one here (ac2)

The score is computed in this file from the chart and the rules. It does not
read the result's own score or violation report: bean-008 computes those from
the chart and was right all along, so reading them would test bean-008. What is
under test is which chart the solver chooses.

The entry point gained a required `mode` in bean-012. bean-021 fixes no
signature and forbids changing it, so `mode="planning"` is passed when the
signature has the parameter and left out when it does not.
"""

from __future__ import annotations

import inspect
import itertools
import os
import random
import sys
from pathlib import Path
from typing import Any

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)


def _api() -> tuple[Any, ...]:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    return Event, Guest, RsvpStatus, Table, Hardness, Rule, RuleType, solve_event


def _solve(event: Any) -> dict[str, str]:
    *_, solve_event = _api()
    kwargs: dict[str, Any] = {}
    if "mode" in inspect.signature(solve_event).parameters:
        kwargs["mode"] = "planning"
    result = solve_event(event, **kwargs)
    assert result.status == "feasible", f"a valid chart exists, solver said {result.status!r}"
    return dict(result.assignments)


def _event(capacities: list[int], n_guests: int, rules: list[tuple[str, str, int, tuple[str, ...]]]) -> Any:
    Event, Guest, RsvpStatus, Table, Hardness, Rule, RuleType, _ = _api()
    tables = [
        Table(id=f"t{i}", name=f"T{i}", capacity=c, shape="round", position=(0.0, float(i)))
        for i, c in enumerate(capacities)
    ]
    guests = [Guest(id=f"g{i}", name=f"G{i}", status=RsvpStatus.CONFIRMED) for i in range(n_guests)]
    kinds = {"same": RuleType.SAME_TABLE, "diff": RuleType.DIFFERENT_TABLE}
    built = [
        Rule(id=rid, rule_type=kinds[kind], hardness=Hardness.SOFT, weight=w, guest_ids=gids)
        for rid, kind, w, gids in rules
    ]
    return Event(id="e", name="E", tables=tables, guests=guests, groups=[], rules=built)


def _score(chart: dict[str, str], rules: list[tuple[str, str, int, tuple[str, ...]]]) -> int:
    total = 0
    for _rid, kind, weight, gids in rules:
        seats = [chart[g] for g in gids]
        if kind == "same" and len(set(seats)) == 1:
            total += weight
        if kind == "diff" and len(set(seats)) == len(seats):
            total += weight
    return total


def _best(capacities: list[int], n_guests: int, rules: list[tuple[str, str, int, tuple[str, ...]]]) -> int:
    ids = [f"t{i}" for i in range(len(capacities))]
    best = -1
    for combo in itertools.product(ids, repeat=n_guests):
        if any(combo.count(t) > c for t, c in zip(ids, capacities)):
            continue
        best = max(best, _score({f"g{i}": t for i, t in enumerate(combo)}, rules))
    return best


def test_heavier_keep_apart_beats_lighter_sit_together() -> None:
    rules = [("apart", "diff", 100, ("g0", "g1")), ("near", "same", 1, ("g0", "g1"))]
    chart = _solve(_event([2, 2], 2, rules))
    assert chart["g0"] != chart["g1"], "a weight-100 keep-apart lost to a weight-1 sit-together"


def test_keep_apart_is_weighed_against_a_group_of_preferences() -> None:
    # Three guests who would all like to sit together (three weight-20 rules, 60
    # in all), and one weight-70 reason to keep g0 and g2 apart. Every chart
    # that keeps them apart can still honour one of the pairings, so apart
    # scores at least 90 against together's 60.
    rules = [
        ("a", "same", 20, ("g0", "g1")),
        ("b", "same", 20, ("g1", "g2")),
        ("c", "same", 20, ("g0", "g2")),
        ("split", "diff", 70, ("g0", "g2")),
    ]
    chart = _solve(_event([3, 3], 3, rules))
    assert chart["g0"] != chart["g2"], "a weight-70 keep-apart lost to 60 of sit-together"
    assert _score(chart, rules) == _best([3, 3], 3, rules)


def test_returned_chart_is_optimal_on_random_small_events() -> None:
    rng = random.Random(20260928)
    checked = 0
    for _ in range(12):
        n = rng.randint(3, 5)
        capacities = [rng.randint(2, 3) for _ in range(rng.randint(2, 3))]
        if sum(capacities) < n:
            continue
        rules = []
        for r in range(rng.randint(2, 4)):
            a, b = rng.sample(range(n), 2)
            kind = rng.choice(["same", "diff"])
            rules.append((f"r{r}", kind, rng.randint(1, 100), (f"g{a}", f"g{b}")))
        if not any(k == "diff" for _, k, _, _ in rules):
            rules.append(("rd", "diff", rng.randint(1, 100), ("g0", "g1")))
        chart = _solve(_event(capacities, n, rules))
        assert _score(chart, rules) == _best(capacities, n, rules), (
            f"not optimal: capacities {capacities}, rules {rules}, chart {chart}"
        )
        checked += 1
    assert checked >= 8, "too few random events were solvable to say anything"
