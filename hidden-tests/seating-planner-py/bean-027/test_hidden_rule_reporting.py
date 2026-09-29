"""Hidden tests for bean-027 — hard-rule reporting and unique rule ids.

Written from bean-027's criteria, which come from the retroactive review of
bean-008 (evidence/reviews/retroactive-20260928.md):

  * ac1 — a hard rule whose targets include fewer than two eligible guests is
    unevaluable, as its soft twin is, never satisfied. bean-008 reported every
    hard rule on a feasible result satisfied.
  * ac2 — an event refuses two rules with one id, at construction and when a
    rule is added, naming the id, enabled or not.
  * ac3 — solve_event refuses an event whose rules share an id, in every mode,
    however the rules got there, naming the id.
  * ac4 — one state per enabled rule, and the score and violations agree with
    the states.
  * constraint — a hard rule with two or more eligible targets is still
    satisfied.

The error messages are checked only for the id, never for wording.
"""

from __future__ import annotations

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


def _rule(rid: str, kind: str, hardness: str, weight: int | None, guests: tuple[str, ...] = (),
          groups: tuple[str, ...] = (), **kw: Any) -> Any:
    from seating_planner.rules import Hardness, Rule, RuleType

    kinds = {"same": RuleType.SAME_TABLE, "diff": RuleType.DIFFERENT_TABLE, "dist": RuleType.MIN_DISTANCE}
    hard = {"hard": Hardness.HARD, "soft": Hardness.SOFT}
    return Rule(id=rid, rule_type=kinds[kind], hardness=hard[hardness], weight=weight,
                guest_ids=guests, group_ids=groups, **kw)


def _event(rules: list[Any], *, caps: tuple[int, ...] = (2, 2), groups: dict[str, tuple[str, ...]] | None = None) -> Any:
    # g-1, g-3 and g-4 are seated; g-2 declined and g-5 is pending without a
    # reserved seat, so neither is ever eligible.
    from seating_planner.domain import Event, Group, Guest, RsvpStatus, Table

    guests = [
        Guest(id="g-1", name="g-1", status=RsvpStatus.CONFIRMED),
        Guest(id="g-2", name="g-2", status=RsvpStatus.DECLINED),
        Guest(id="g-3", name="g-3", status=RsvpStatus.CONFIRMED),
        Guest(id="g-4", name="g-4", status=RsvpStatus.CONFIRMED),
        Guest(id="g-5", name="g-5", status=RsvpStatus.PENDING),
    ]
    return Event(
        id="e", name="E",
        tables=[Table(id=f"t-{i}", name=f"t-{i}", capacity=c, shape="round", position=(0.0, float(i)))
                for i, c in enumerate(caps, start=1)],
        guests=guests,
        groups=[Group(id=gid, name=gid, member_ids=m) for gid, m in (groups or {}).items()],
        rules=rules,
    )


# Parametrizing would hide a failing mode: verify.sh reads a test as passed
# if any of its parameters passed. Each test loops over the modes instead.
MODES = ("planning", "low_disruption", "event_day")


def _solve(ev: Any, mode: str = "planning") -> Any:
    from seating_planner.solver import solve_event

    if mode == "low_disruption":
        return solve_event(ev, mode=mode, current={"g-1": "t-1"}, movement_limit=5)
    if mode == "event_day":
        return solve_event(ev, mode=mode, current={"g-1": "t-1"})
    return solve_event(ev, mode=mode)


# --- ac1 and the constraint ------------------------------------------------

def test_hard_rule_with_one_eligible_guest_is_unevaluable_like_its_soft_twin() -> None:
    from seating_planner.solver.result import UNEVALUABLE

    rules = [
        _rule("hard-same", "same", "hard", None, ("g-1", "g-2")),
        _rule("soft-same", "same", "soft", 5, ("g-1", "g-2")),
        _rule("hard-diff", "diff", "hard", None, ("g-3", "g-5")),
        _rule("soft-diff", "diff", "soft", 5, ("g-3", "g-5")),
    ]
    for mode in MODES:
        result = _solve(_event(rules), mode)
        assert result.status == "feasible", mode
        states = dict(result.rule_states)
        assert states["soft-same"] == UNEVALUABLE and states["soft-diff"] == UNEVALUABLE, mode
        assert states["hard-same"] == UNEVALUABLE, f"{mode}: one seated guest cannot be evaluated: {states}"
        assert states["hard-diff"] == UNEVALUABLE, f"{mode}: one seated guest cannot be evaluated: {states}"


def test_hard_rule_with_no_eligible_guest_is_unevaluable() -> None:
    from seating_planner.solver.result import UNEVALUABLE

    result = _solve(_event([_rule("hard-none", "same", "hard", None, ("g-2", "g-5"))]))
    assert result.status == "feasible"
    assert result.rule_states["hard-none"] == UNEVALUABLE


def test_hard_rule_on_a_group_with_one_eligible_member_is_unevaluable() -> None:
    from seating_planner.solver.result import SATISFIED, UNEVALUABLE

    rules = [_rule("hard-fam", "same", "hard", None, groups=("fam",))]
    result = _solve(_event(rules, groups={"fam": ("g-1", "g-2", "g-5")}))
    assert result.status == "feasible"
    assert result.rule_states["hard-fam"] == UNEVALUABLE
    assert result.rule_states["hard-fam"] != SATISFIED


def test_hard_rule_with_two_eligible_guests_is_still_satisfied() -> None:
    from seating_planner.solver.result import SATISFIED

    rules = [
        _rule("hard-same", "same", "hard", None, ("g-1", "g-2", "g-3")),
        _rule("hard-diff", "diff", "hard", None, ("g-1", "g-4")),
    ]
    result = _solve(_event(rules))
    assert result.status == "feasible"
    assert result.assignments["g-1"] == result.assignments["g-3"]
    assert result.rule_states["hard-same"] == SATISFIED
    assert result.rule_states["hard-diff"] == SATISFIED


# --- ac2 ------------------------------------------------------------------

def test_building_an_event_with_two_rules_sharing_an_id_is_refused() -> None:
    twins = [_rule("r-twin-7", "same", "soft", 10, ("g-1", "g-3")),
             _rule("r-twin-7", "diff", "soft", 1, ("g-1", "g-3"))]
    with pytest.raises(ValueError, match="r-twin-7"):
        _event(twins)


def test_adding_a_rule_whose_id_is_taken_is_refused_and_leaves_the_rules_alone() -> None:
    ev = _event([_rule("r-twin-8", "same", "soft", 10, ("g-1", "g-3"))])
    with pytest.raises(ValueError, match="r-twin-8"):
        ev.add_rule(_rule("r-twin-8", "diff", "hard", None, ("g-1", "g-4")))
    assert len(ev.rules) == 1
    ev.add_rule(_rule("r-other", "diff", "hard", None, ("g-1", "g-4")))
    assert len(ev.rules) == 2


def test_a_disabled_rule_still_owns_its_id() -> None:
    off = _rule("r-twin-9", "same", "soft", 10, ("g-1", "g-3"), enabled=False)
    on = _rule("r-twin-9", "diff", "soft", 1, ("g-1", "g-3"))
    with pytest.raises(ValueError, match="r-twin-9"):
        _event([off, on])
    ev = _event([off])
    with pytest.raises(ValueError, match="r-twin-9"):
        ev.add_rule(on)


# --- ac3 ------------------------------------------------------------------

def test_solve_refuses_rules_sharing_an_id_that_bypassed_the_event() -> None:
    for mode in MODES:
        ev = _event([_rule("r-twin-10", "same", "soft", 10, ("g-1", "g-3"))])
        # Appended straight to the list, past construction and add_rule.
        ev.rules.append(_rule("r-twin-10", "diff", "soft", 1, ("g-1", "g-3")))
        with pytest.raises(ValueError, match="r-twin-10"):
            _solve(ev, mode)


def test_solve_refuses_a_duplicate_id_on_a_disabled_rule() -> None:
    ev = _event([_rule("r-twin-11", "same", "soft", 10, ("g-1", "g-3"))])
    ev.rules.append(_rule("r-twin-11", "diff", "hard", None, ("g-1", "g-3"), enabled=False))
    with pytest.raises(ValueError, match="r-twin-11"):
        _solve(ev)


# --- ac4 ------------------------------------------------------------------

def _check_agreement(rules: list[Any], result: Any) -> None:
    from seating_planner.rules import Hardness
    from seating_planner.solver.result import SATISFIED, VIOLATED

    enabled = [r for r in rules if r.enabled]
    assert sorted(result.rule_states) == sorted(r.id for r in enabled), "one state per enabled rule"
    by_id = {r.id: r for r in enabled}
    satisfied_weight = sum(
        by_id[rid].weight for rid, state in result.rule_states.items()
        if state == SATISFIED and by_id[rid].hardness is Hardness.SOFT
    )
    assert result.score == satisfied_weight, f"score {result.score} vs states {dict(result.rule_states)}"
    violated = sorted(rid for rid, state in result.rule_states.items() if state == VIOLATED)
    assert sorted(v.rule_id for v in result.violations) == violated
    for v in result.violations:
        assert v.weight == by_id[v.rule_id].weight


def test_states_score_and_violations_agree() -> None:
    # One-seat tables force g-1, g-3 and g-4 apart, so the soft same-table
    # rule must break and the soft different-table rule must hold.
    rules = [
        _rule("hard-apart", "diff", "hard", None, ("g-1", "g-3")),
        _rule("hard-lonely", "same", "hard", None, ("g-4", "g-2")),
        _rule("soft-with", "same", "soft", 40, ("g-1", "g-4")),
        _rule("soft-apart", "diff", "soft", 7, ("g-3", "g-4")),
        _rule("soft-lonely", "same", "soft", 11, ("g-3", "g-5")),
        _rule("soft-dist", "dist", "soft", 13, ("g-1", "g-3"), min_zones=2),
        _rule("soft-off", "same", "soft", 17, ("g-1", "g-3"), enabled=False),
    ]
    for mode in MODES:
        result = _solve(_event(rules, caps=(1, 1, 1)), mode)
        assert result.status == "feasible", mode
        _check_agreement(rules, result)
        assert result.rule_states["soft-with"] == "violated", mode
        assert result.score == 7, mode


def test_states_agree_on_an_infeasible_result() -> None:
    from seating_planner.solver.result import SATISFIED

    rules = [
        _rule("hard-with", "same", "hard", None, ("g-1", "g-3")),
        _rule("hard-apart", "diff", "hard", None, ("g-1", "g-3")),
        _rule("soft-with", "same", "soft", 9, ("g-1", "g-4")),
    ]
    result = _solve(_event(rules))
    assert result.status == "infeasible"
    _check_agreement(rules, result)
    assert SATISFIED not in result.rule_states.values()
