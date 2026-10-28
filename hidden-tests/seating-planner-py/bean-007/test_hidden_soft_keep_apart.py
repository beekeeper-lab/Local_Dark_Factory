"""Hidden tests for bean-007 — added 2026-09-28, after bean-007 had merged.

bean-007's intent is "the one with the highest weighted total of satisfied soft
constraints". The code it shipped let every soft different-table rule score as
satisfied whatever the chart did, and nothing visible or hidden asked. This is
the same suite as bean-021's, the bean that repairs it: a heavier keep-apart
preference must beat a lighter sit-together one, and the returned chart must be
optimal against every valid chart of small events, scored here from the chart.

It cannot have gated bean-007, which had merged. It is here for the next run of
this corpus, where bean-007 is built again and this is what would have caught
it. Against bean-007's own merged tree (043e705) it fails 3 of 3, which is the
point; verify.sh's "passes against the real tree" holds only against a tree
with bean-021's fix, and hidden-tests/verified/ records which tree that was.

The entry point had no `mode` at bean-007; bean-012 made it required. `mode` is
passed only when the signature has it, so this runs against either.

2026-10-28 UPDATE: discovers the rule-kind enum's class name (RuleType or
RuleKind), the solve entry point's name (solve_event or solve_hard), and the
Guest/Rule constructor field names that carry an RSVP status, a rule kind and
a rule's guest bindings, instead of assuming one build's specific names for
them. A second from-scratch build of this corpus (seating-planner-py-v2) named
every one of these differently from the original (RuleKind not RuleType,
rsvp_status not status, kind/guests not rule_type/guest_ids, solve_hard not
yet renamed to solve_event) while being behaviourally identical where the bean
text actually specifies behaviour — none of those names are in any bean's
acceptance criteria. A hidden test that fails for a naming reason costs a
build cycle and teaches nobody anything, which is the same principle this
file already states for guessing between `capacity` and `seats` elsewhere in
this corpus. Confirmed this rewrite still fails 3 of 3 against bean-007's own
original merged tree (043e705, before bean-021's fix) and still passes
against the current main (with bean-021's fix) — the regression-detection
property this suite exists for is unchanged.
"""

from __future__ import annotations

import dataclasses
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


def _first_field(cls: type, candidates: tuple[str, ...]) -> str:
    """The first of ``candidates`` that is an actual field of ``cls``."""
    names = {f.name for f in dataclasses.fields(cls)}
    for candidate in candidates:
        if candidate in names:
            return candidate
    raise AssertionError(
        f"none of {candidates} is a field of {cls.__name__} (has {sorted(names)})"
    )


def _first_attr(module: Any, candidates: tuple[str, ...]) -> Any:
    """The first attribute of ``module`` named one of ``candidates``."""
    for candidate in candidates:
        found = getattr(module, candidate, None)
        if found is not None:
            return found
    raise AssertionError(f"none of {candidates} is an attribute of {module.__name__}")


def _api() -> tuple[Any, ...]:
    from seating_planner import domain as domain_mod
    from seating_planner import rules as rules_mod
    from seating_planner import solver as solver_mod

    Event = domain_mod.Event
    Guest = domain_mod.Guest
    RsvpStatus = domain_mod.RsvpStatus
    Table = domain_mod.Table
    Hardness = rules_mod.Hardness
    Rule = rules_mod.Rule
    # The same/different-table rule-kind enum, under whichever class name
    # this build chose for it.
    kind_enum = _first_attr(rules_mod, ("RuleType", "RuleKind"))
    # The entry point that returns a chart, under whichever name this build's
    # history has given it so far.
    solve_fn = _first_attr(solver_mod, ("solve_event", "solve_hard"))
    return Event, Guest, RsvpStatus, Table, Hardness, Rule, kind_enum, solve_fn


def _solve(event: Any) -> dict[str, str]:
    *_, solve_fn = _api()
    kwargs: dict[str, Any] = {}
    if "mode" in inspect.signature(solve_fn).parameters:
        kwargs["mode"] = "planning"
    result = solve_fn(event, **kwargs)
    assert result.status == "feasible", f"a valid chart exists, solver said {result.status!r}"
    return dict(result.assignments)


def _event(capacities: list[int], n_guests: int, rules: list[tuple[str, str, int, tuple[str, ...]]]) -> Any:
    Event, Guest, RsvpStatus, Table, Hardness, Rule, kind_enum, _ = _api()
    status_field = _first_field(Guest, ("rsvp_status", "status"))
    rule_kind_field = _first_field(Rule, ("kind", "rule_type", "type"))
    rule_guests_field = _first_field(Rule, ("guests", "guest_ids"))

    tables = [
        Table(id=f"t{i}", name=f"T{i}", capacity=c, shape="round", position=(0.0, float(i)))
        for i, c in enumerate(capacities)
    ]
    guests = [
        Guest(id=f"g{i}", name=f"G{i}", **{status_field: RsvpStatus.CONFIRMED})
        for i in range(n_guests)
    ]
    kinds = {"same": kind_enum.SAME_TABLE, "diff": kind_enum.DIFFERENT_TABLE}
    built = [
        Rule(
            id=rid,
            hardness=Hardness.SOFT,
            weight=w,
            **{rule_kind_field: kinds[kind], rule_guests_field: gids},
        )
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
