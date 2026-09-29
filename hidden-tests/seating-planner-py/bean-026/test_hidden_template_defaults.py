"""Hidden tests for bean-026 — a template event can be solved.

Written from bean-026's criteria, which come from the retroactive review of
2026-09-28: bean-003's default wedding template enabled a hard min_distance
rule the solver refuses, so every event built from the template raised.

  * ac1 — an event whose rules are the template as it comes, with a group per
    category and enough seats, solves in planning mode with everyone seated.
    Checked in more than one room shape, and with the categories' groups
    overlapping, because a template event's guests belong to several at once.
  * ac2 — the accessible-seating rule is still there, disabled, and otherwise
    the same hard min_distance rule, so flipping `enabled` alone restores it;
    and it stays disabled through to_dict/from_dict, which is how an event is
    saved and loaded.
  * ac3 — the other six rules are the rules bean-003 shipped, each enabled.
  * the first non-goal — the solver still refuses an enabled hard
    min_distance rule. A fix that taught the solver to skip it would make ac1
    pass and would be exactly the silent "feasible" bean-006 forbids.

The expected field values in ac2 and ac3 are the template's values on the
main branch before this bean, which the bean's criteria name.
"""

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

ACCESSIBLE = "template-accessible_seating"

# bean-003's template, as shipped: id -> (kind, weight, groups); all soft.
OTHERS = {
    "template-couples": ("same_table", 80, ("couples",)),
    "template-households": ("same_table", 50, ("households",)),
    "template-immediate_family": ("same_table", 90, ("immediate_family",)),
    "template-wedding_party": ("same_table", 70, ("wedding_party",)),
    "template-children": ("same_table", 60, ("children",)),
    "template-vendors": ("different_table", 40, ("vendors",)),
}


def _template() -> list[Any]:
    from seating_planner.rules.template import default_wedding_rules

    return default_wedding_rules()


def _by_id(rules: list[Any]) -> dict[str, Any]:
    return {rule.id: rule for rule in rules}


def _event(rules: list[Any], tables: list[int], members: dict[str, tuple[str, ...]]) -> Any:
    from seating_planner.domain import Event, Group, Guest, RsvpStatus, Table
    from seating_planner.rules.template import TEMPLATE_CATEGORIES

    guest_ids = sorted({g for ids in members.values() for g in ids} | {f"x-{i}" for i in range(3)})
    return Event(
        id="wedding",
        name="Wedding",
        tables=[
            Table(id=f"t-{i}", name=f"Table {i}", capacity=cap, shape="round", position=(float(i), 0.0))
            for i, cap in enumerate(tables)
        ],
        guests=[Guest(id=g, name=g, status=RsvpStatus.CONFIRMED) for g in guest_ids],
        groups=[Group(id=slug, name=name, member_ids=members.get(slug, ())) for slug, name in TEMPLATE_CATEGORIES.items()],
        rules=rules,
    )


def _solve(event: Any) -> Any:
    from seating_planner.solver import solve_event

    if "mode" in inspect.signature(solve_event).parameters:
        return solve_event(event, mode="planning")
    return solve_event(event)


def _disjoint_members() -> dict[str, tuple[str, ...]]:
    from seating_planner.rules.template import TEMPLATE_CATEGORIES

    return {slug: (f"{slug}-a", f"{slug}-b") for slug in TEMPLATE_CATEGORIES}


def _overlapping_members() -> dict[str, tuple[str, ...]]:
    return {
        "couples": ("ann", "bob"),
        "households": ("ann", "bob", "cal", "dee"),
        "immediate_family": ("ann", "cal", "eve"),
        "wedding_party": ("bob", "fay", "gus"),
        "children": ("cal", "dee", "hal"),
        "vendors": ("v-1", "v-2", "v-3"),
        "accessible_seating": ("eve", "gus"),
    }


@pytest.mark.parametrize(
    ("tables", "members"),
    [([8, 8, 8], _disjoint_members()), ([6, 6, 6], _overlapping_members()), ([20, 20, 20, 20], _overlapping_members())],
    ids=["disjoint-groups", "overlapping-groups", "roomy"],
)
def test_template_event_solves_with_everyone_seated(tables: list[int], members: dict[str, tuple[str, ...]]) -> None:
    event = _event(_template(), tables, members)
    result = _solve(event)
    assert result.status == "feasible", f"a template event with enough seats must solve: {result.status!r}"
    seated = set(result.assignments)
    assert seated == {g.id for g in event.guests}, "every guest is seated"
    capacity = {t.id: t.capacity for t in event.tables}
    for table_id in set(result.assignments.values()):
        assert list(result.assignments.values()).count(table_id) <= capacity[table_id]


def test_accessible_rule_is_present_and_disabled() -> None:
    from seating_planner.rules import Hardness, RuleType

    rules = _by_id(_template())
    assert ACCESSIBLE in rules, "the accessible-seating rule stays in the template"
    rule = rules[ACCESSIBLE]
    assert rule.enabled is False
    assert rule.rule_type is RuleType.MIN_DISTANCE
    assert rule.hardness is Hardness.HARD
    assert rule.weight is None
    assert tuple(rule.group_ids) == ("accessible_seating",)
    assert rule.target == "dance_floor"
    assert rule.min_zones == 2


def test_enabling_the_accessible_rule_is_one_field() -> None:
    from seating_planner.rules import Rule

    rule = _by_id(_template())[ACCESSIBLE]
    as_shipped = Rule(
        id=ACCESSIBLE,
        rule_type=rule.rule_type,
        hardness=rule.hardness,
        weight=None,
        group_ids=("accessible_seating",),
        target="dance_floor",
        min_zones=2,
    )
    assert dataclasses.replace(rule, enabled=True) == as_shipped, (
        "apart from enabled, the rule must be the one bean-003 shipped"
    )
    rule.enabled = True
    assert rule == as_shipped


def test_accessible_rule_stays_disabled_through_a_round_trip() -> None:
    from seating_planner.rules import Rule

    rule = _by_id(_template())[ACCESSIBLE]
    again = Rule.from_dict(rule.to_dict())
    assert again.enabled is False
    assert again == rule


def test_other_six_rules_are_unchanged_and_enabled() -> None:
    rules = _template()
    assert len(rules) == 7
    by_id = _by_id(rules)
    assert set(by_id) == set(OTHERS) | {ACCESSIBLE}
    for rid, (kind, weight, groups) in OTHERS.items():
        rule = by_id[rid]
        assert rule.rule_type.value == kind, rid
        assert rule.hardness.value == "soft", rid
        assert rule.weight == weight, rid
        assert tuple(rule.group_ids) == groups, rid
        assert rule.enabled is True, rid


def test_the_template_is_fresh_on_every_call() -> None:
    first = _by_id(_template())
    first[ACCESSIBLE].enabled = True
    assert _by_id(_template())[ACCESSIBLE].enabled is False, "one event's edit must not leak into the next"


def test_an_enabled_hard_min_distance_rule_is_still_refused() -> None:
    rules = _template()
    _by_id(rules)[ACCESSIBLE].enabled = True
    event = _event(rules, [8, 8, 8], _disjoint_members())
    with pytest.raises(ValueError):
        _solve(event)
