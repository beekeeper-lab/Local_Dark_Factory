"""Hidden tests for bean-022 — a group's pre-flight size counts only guests who will be seated.

Written from bean-022's criteria. The pre-flight entry point is bean-005's
run_preflight(event) -> list of findings, each with a message; the finding's code
is not fixed by any bean, so these read the message only, for the group's id and
the size it reports. Eligibility is the domain's own Guest.eligible: confirmed,
or pending with a reserved seat.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from typing import Any

WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"
_SRC = str(WORK / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)


def _event(statuses: list[str], capacity: int) -> Any:
    from seating_planner.domain import Event, Group, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType

    guests = []
    for i, s in enumerate(statuses):
        if s == "reserved":
            guests.append(Guest(id=f"g{i}", name=f"G{i}", status=RsvpStatus.PENDING, reserved_seat=True))
        else:
            guests.append(Guest(id=f"g{i}", name=f"G{i}", status=RsvpStatus(s)))
    tables = [Table(id="t1", name="T1", capacity=capacity, shape="round", position=(0.0, 0.0))]
    group = Group(id="fam", name="Family", member_ids=tuple(g.id for g in guests))
    rule = Rule(id="keep", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD, weight=None, group_ids=("fam",))
    return Event(id="e", name="E", tables=tables, guests=guests, groups=[group], rules=[rule])


def _group_findings(event: Any) -> list[str]:
    from seating_planner.feasibility import run_preflight

    return [f.message for f in run_preflight(event) if "fam" in f.message]


def test_declined_members_do_not_make_a_group_oversized() -> None:
    event = _event(["confirmed"] * 6 + ["declined"] * 4, capacity=8)
    assert _group_findings(event) == [], "6 seated members fit a table of 8"


def test_unreserved_pending_members_do_not_count_either() -> None:
    event = _event(["confirmed"] * 5 + ["pending"] * 5, capacity=6)
    assert _group_findings(event) == [], "5 seated members fit a table of 6"


def test_reserved_pending_members_do_count() -> None:
    event = _event(["confirmed"] * 5 + ["reserved"] * 2 + ["declined"] * 3, capacity=6)
    found = _group_findings(event)
    assert found, "7 seated members do not fit a table of 6"


def test_the_reported_size_is_the_seated_members() -> None:
    event = _event(["confirmed"] * 9 + ["declined"] * 3, capacity=8)
    found = _group_findings(event)
    assert len(found) == 1, found
    numbers = {int(n) for n in re.findall(r"\b\d+\b", found[0])}
    assert 9 in numbers, f"the size reported should be the 9 seated members: {found[0]!r}"
    assert 12 not in numbers, f"12 counts the declined members: {found[0]!r}"
