"""Hidden tests for bean-020 — an adjacent-seat rule is never reported satisfied.

Seat positions are deferred corpus-wide, so no event can configure them and
every adjacent-seat rule is one the system cannot evaluate. bean-020's criteria,
checked here through the public entry point in more shapes than one:

  * ac1 — a soft adjacent-seat rule is reported unevaluable, not satisfied, in
    every mode, alone and next to rules that can be evaluated
  * ac2 — it contributes nothing to the soft score: the score is the same with
    and without it, and equals the weight of the rules reported satisfied
  * ac3 — satisfied, violated and unevaluable account for every active rule,
    each exactly once
  * ac4 — a HARD adjacent-seat rule blocks the solve with an explanation: an
    exception, or a result that is not a feasible chart — never a chart with
    the rule counted as met
  * ac5 — the result says WHY it is unevaluable, and keeps it apart from
    violated

What this does NOT fix, because the bean does not: the name of any new field,
the wording of the reason, or the exception type. Rule states are read from
`rule_states` (bean-008's, present before this bean) as an attribute or its
to_dict() key, and a state counts by the word in it — "unevaluable",
"violat", "satisf" — so a richer state value still reads. The reason (ac5) is
looked for anywhere in the result's serialized form or its public attributes,
as any of the words a reason about unconfigured seats must use: seat,
position, configur(ed/ation), layout. Rule, guest and table ids here are
chosen so none of those words appear in them.

Only enabled rules are used, so "active" cannot be read two ways. min_distance
rules are left out: bean-020 says nothing about them.
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

REASON_WORDS = ("seat", "position", "configur", "layout")


def _adjacent_type() -> Any:
    from seating_planner.rules import RuleType

    found = [m for m in RuleType if "adjacent" in str(m.value).lower()]
    assert found, "bean-003 makes an adjacent-seat rule constructible; RuleType has none"
    return found[0]


def _rule(rid: str, kind: str, hardness: str, weight: int | None, guests: tuple[str, ...]) -> Any:
    from seating_planner.rules import Hardness, Rule, RuleType

    kinds = {"same": RuleType.SAME_TABLE, "diff": RuleType.DIFFERENT_TABLE}
    rule_type = _adjacent_type() if kind == "adjacent" else kinds[kind]
    hard = Hardness.HARD if hardness == "hard" else Hardness.SOFT
    return Rule(id=rid, rule_type=rule_type, hardness=hard, weight=weight, guest_ids=guests)


def _event(caps: list[int], n_guests: int, rules: list[Any]) -> Any:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table

    return Event(
        id="e",
        name="E",
        tables=[Table(id=f"t{i}", name=f"T{i}", capacity=c, shape="round", position=(0.0, float(i)))
                for i, c in enumerate(caps)],
        guests=[Guest(id=f"g{i}", name=f"G{i}", status=RsvpStatus.CONFIRMED) for i in range(n_guests)],
        groups=[],
        rules=rules,
    )


# Mode inputs for a 4-guest event over two tables of 2 and 2; g3 is new on
# event day. None of the rules below needs anyone to move.
_CURRENT = {"g0": "t0", "g1": "t0", "g2": "t1"}
MODES = {
    "planning": {"mode": "planning"},
    "low_disruption": {"mode": "low_disruption", "current": _CURRENT, "movement_limit": 1},
    "event_day": {"mode": "event_day", "current": _CURRENT},
}


def _solve(event: Any, mode: str = "planning") -> Any:
    from seating_planner.solver import solve_event

    return solve_event(event, **MODES[mode])


def _field(obj: Any, name: str) -> Any:
    if isinstance(obj, dict):
        return obj[name]
    if hasattr(obj, name):
        return getattr(obj, name)
    return obj.to_dict()[name]


def _word(state: Any) -> str:
    if isinstance(state, dict):
        state = state.get("state", state.get("status", json.dumps(state, default=str)))
    state = getattr(state, "value", state)
    text = str(state).lower()
    if "unevaluable" in text:
        return "unevaluable"
    if "violat" in text:
        return "violated"
    if "satisf" in text:
        return "satisfied"
    return text


def _states(result: Any) -> dict[str, str]:
    return {rid: _word(s) for rid, s in dict(_field(result, "rule_states")).items()}


def _violated_ids(result: Any) -> set[str]:
    return {_field(v, "rule_id") for v in _field(result, "violations")}


def _result_text(result: Any) -> str:
    parts = [repr(result)]
    try:
        parts.append(json.dumps(result.to_dict(), default=str))
    except Exception:  # noqa: BLE001 - a result without to_dict still has attributes
        pass
    for name in dir(result):
        if name.startswith("_"):
            continue
        try:
            value = getattr(result, name)
        except Exception:  # noqa: BLE001
            continue
        if not callable(value):
            parts.append(repr(value))
    return "\n".join(parts).lower()


# --- ac1: soft adjacent-seat rules are unevaluable, in every mode -----------


@pytest.mark.parametrize("mode", sorted(MODES))
def test_soft_adjacent_rule_is_unevaluable_in_every_mode(mode: str) -> None:
    rules = [
        _rule("r-next", "adjacent", "soft", 50, ("g0", "g1")),
        _rule("r-pair", "same", "soft", 10, ("g0", "g1")),
    ]
    result = _solve(_event([2, 2], 4, rules), mode)
    assert _field(result, "status") == "feasible"
    states = _states(result)
    assert states.get("r-next") == "unevaluable", (
        f"an adjacent-seat rule with no seat positions was reported {states.get('r-next')!r}"
    )
    assert states.get("r-pair") == "satisfied", "the evaluable rule beside it still evaluates"
    assert "r-next" not in _violated_ids(result), "unevaluable is not violated"


def test_adjacent_rule_the_chart_would_trivially_meet_is_still_unevaluable() -> None:
    # The quiet defect the bean describes: a rule that generates no constraint
    # and names guests who happen to share a table looks "met" to code that
    # counts active minus violated. Only two guests, one table of two.
    result = _solve(_event([2], 2, [_rule("r-next", "adjacent", "soft", 100, ("g0", "g1"))]))
    assert _field(result, "status") == "feasible"
    assert _states(result).get("r-next") == "unevaluable"


# --- ac2: it scores nothing -------------------------------------------------


@pytest.mark.parametrize("weights", [(1,), (100,), (40, 60)], ids=["w1", "w100", "two-rules"])
def test_unevaluable_rule_contributes_nothing_to_the_score(weights: tuple[int, ...]) -> None:
    # Three soft pairings over a 2+2 room: at most two can hold, the best pair
    # being 30 + 20. The adjacent rules name the same guests and must not move
    # the score by a point.
    base = [
        _rule("r-a", "same", "soft", 30, ("g0", "g1")),
        _rule("r-b", "same", "soft", 20, ("g2", "g3")),
        _rule("r-c", "same", "soft", 5, ("g0", "g2")),
    ]
    extra = [_rule(f"r-next{i}", "adjacent", "soft", w, ("g0", "g2")) for i, w in enumerate(weights)]
    without = _solve(_event([2, 2], 4, base))
    with_adj = _solve(_event([2, 2], 4, base + extra))
    assert _field(without, "score") == 50
    assert _field(with_adj, "score") == _field(without, "score"), (
        f"adding unevaluable rules of weight {weights} changed the score"
    )
    weight = {r.id: r.weight for r in base + extra}
    states = _states(with_adj)
    counted = sum(weight[rid] for rid, s in states.items() if s == "satisfied")
    assert _field(with_adj, "score") == counted, "the score is the weight of the satisfied rules"


# --- ac3: the three states account for every active rule --------------------


@pytest.mark.parametrize("mode", sorted(MODES))
def test_satisfied_violated_and_unevaluable_cover_every_rule(mode: str) -> None:
    rules = [
        _rule("r-apart", "diff", "hard", None, ("g0", "g2")),
        _rule("r-with", "same", "hard", None, ("g0", "g1")),
        _rule("r-met", "same", "soft", 30, ("g0", "g1")),
        # Forced broken by the hard keep-apart above.
        _rule("r-broken", "same", "soft", 70, ("g0", "g2")),
        _rule("r-next1", "adjacent", "soft", 90, ("g0", "g1")),
        _rule("r-next2", "adjacent", "soft", 5, ("g2", "g3")),
    ]
    result = _solve(_event([2, 2], 4, rules), mode)
    assert _field(result, "status") == "feasible"
    states = _states(result)
    ids = [r.id for r in rules]
    assert sorted(states) == sorted(ids), f"every active rule has exactly one state: {states}"
    counts = {w: sum(1 for s in states.values() if s == w) for w in ("satisfied", "violated", "unevaluable")}
    assert sum(counts.values()) == len(ids), f"a state outside the three: {states}"
    assert states["r-next1"] == states["r-next2"] == "unevaluable"
    assert states["r-broken"] == "violated"
    assert states["r-met"] == "satisfied"
    assert counts == {"satisfied": 3, "violated": 1, "unevaluable": 2}, counts
    assert _violated_ids(result) == {"r-broken"}


# --- ac4: a hard adjacent-seat rule blocks, and says why --------------------


def _blocks(event: Any, mode: str, rid: str) -> None:
    try:
        result = _solve(event, mode)
    except AssertionError:
        raise
    except Exception as exc:  # noqa: BLE001 - the bean fixes no exception type
        text = str(exc).lower()
        assert rid.lower() in text or "adjacent" in text or any(w in text for w in REASON_WORDS), (
            f"a hard adjacent-seat rule stopped the solve, but the error does not explain it: {exc!r}"
        )
        return
    assert _field(result, "status") != "feasible", (
        f"a hard adjacent-seat rule that cannot be evaluated was ignored and a chart returned: "
        f"{_states(result)}"
    )
    assert _states(result).get(rid) != "satisfied"
    text = _result_text(result)
    assert "adjacent" in text or any(w in text for w in REASON_WORDS), (
        "a hard adjacent-seat rule blocked the solve with no explanation in the result"
    )


@pytest.mark.parametrize("mode", sorted(MODES))
def test_hard_adjacent_rule_blocks_the_solve(mode: str) -> None:
    _blocks(_event([2, 2], 4, [_rule("r-must", "adjacent", "hard", None, ("g0", "g1"))]), mode, "r-must")


def test_hard_adjacent_rule_blocks_even_beside_rules_that_evaluate() -> None:
    rules = [
        _rule("r-with", "same", "hard", None, ("g0", "g1")),
        _rule("r-pair", "same", "soft", 40, ("g2", "g3")),
        _rule("r-must", "adjacent", "hard", None, ("g0", "g1")),
        _rule("r-next", "adjacent", "soft", 10, ("g2", "g3")),
    ]
    _blocks(_event([2, 2], 4, rules), "planning", "r-must")


# --- ac5: the reason is stated, and it is not "violated" --------------------


def test_the_result_says_why_the_rule_is_unevaluable() -> None:
    rules = [
        _rule("r-apart", "diff", "hard", None, ("g0", "g1")),
        _rule("r-broken", "same", "soft", 20, ("g0", "g1")),
        _rule("r-next", "adjacent", "soft", 20, ("g0", "g1")),
    ]
    result = _solve(_event([2, 2], 4, rules))
    assert _field(result, "status") == "feasible"
    states = _states(result)
    assert states["r-broken"] == "violated" and states["r-next"] == "unevaluable", (
        f"violated and unevaluable are distinct states: {states}"
    )
    assert _violated_ids(result) == {"r-broken"}
    text = _result_text(result)
    assert any(w in text for w in REASON_WORDS), (
        "the result reports the adjacent-seat rule unevaluable but nowhere says why — that "
        "seat positions are not configured"
    )
