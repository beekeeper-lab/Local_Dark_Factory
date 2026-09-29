"""Hidden tests for bean-029 — a reserved seat is a yes or a no, and every
distance measure a rule carries is a real one.

Written from bean-029's criteria, which come from the retroactive review of
bean-002 and bean-003 (evidence/reviews/retroactive-20260928.md):

  * ac1 — a Guest refuses a reserved_seat that is not a bool at construction,
    and accepts True and False. bean-002 stored "no", which is truthy.
  * ac2 — Guest.eligible is always a bool, True only for a Confirmed guest or a
    Pending guest whose reserved_seat is True, even after reserved_seat was
    set to something else after construction. bean-002 returned 'no'.
  * ac3 — a minimum-distance rule refuses any measure it is given that is not
    valid on its own, even when the other measure is valid, through the
    constructor and through from_dict. bean-003 let a valid min_zones carry
    distance_m="far apart" into storage.

Nothing here solves an event: whether a solve refuses a mutated guest is
bean-030's, and the two must not disagree about it.
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


def _guest(status: Any, reserved_seat: Any) -> Any:
    from seating_planner.domain import Guest

    return Guest(id="g-1", name="Guest One", status=status, reserved_seat=reserved_seat)


# --- ac1 ---------------------------------------------------------------------


@pytest.mark.parametrize("value", ["no", "yes", "false", "", 1, 0, None, 1.0])
def test_a_reserved_seat_that_is_not_a_bool_is_refused(value: Any) -> None:
    from seating_planner.domain import RsvpStatus

    with pytest.raises(ValueError):
        _guest(RsvpStatus.PENDING, value)


def test_a_reserved_seat_of_true_or_false_is_accepted() -> None:
    from seating_planner.domain import RsvpStatus

    assert _guest(RsvpStatus.PENDING, True).reserved_seat is True
    assert _guest(RsvpStatus.PENDING, False).reserved_seat is False
    # And the default still builds: no caller is made to pass one.
    from seating_planner.domain import Guest

    assert Guest(id="g-2", name="Two", status=RsvpStatus.CONFIRMED).reserved_seat is False
    with pytest.raises(ValueError):
        _guest(RsvpStatus.CONFIRMED, "no")


# --- ac2 ---------------------------------------------------------------------


def test_eligible_is_a_bool_for_every_status_and_seat() -> None:
    from seating_planner.domain import RsvpStatus

    for status in RsvpStatus:
        for seat in (True, False):
            expected = status is RsvpStatus.CONFIRMED or (status is RsvpStatus.PENDING and seat)
            assert _guest(status, seat).eligible is expected, (status, seat)


@pytest.mark.parametrize("value", ["no", "yes", 1, "True"])
def test_a_seat_set_after_construction_never_makes_a_pending_guest_eligible(value: Any) -> None:
    from seating_planner.domain import RsvpStatus

    pending = _guest(RsvpStatus.PENDING, False)
    pending.reserved_seat = value
    assert pending.eligible is False, f"reserved_seat={value!r} is not a reserved seat"

    declined = _guest(RsvpStatus.DECLINED, False)
    declined.reserved_seat = value
    assert declined.eligible is False

    confirmed = _guest(RsvpStatus.CONFIRMED, False)
    confirmed.reserved_seat = value
    assert confirmed.eligible is True


# --- ac3 ---------------------------------------------------------------------


def _distance_rule(distance_m: Any, min_zones: Any, hard: bool = False) -> Any:
    from seating_planner.rules import Hardness, Rule, RuleType

    return Rule(
        id="r-far",
        rule_type=RuleType.MIN_DISTANCE,
        hardness=Hardness.HARD if hard else Hardness.SOFT,
        weight=None if hard else 10,
        guest_ids=("g-1", "g-2"),
        distance_m=distance_m,
        min_zones=min_zones,
    )


@pytest.mark.parametrize(
    ("distance_m", "min_zones"),
    [
        ("far apart", 1),
        (-2.0, 1),
        (0.0, 2),
        (True, 1),
        (3.0, 0),
        (3.0, -1),
        (3.0, "2"),
        (3.0, 1.5),
        (3.0, True),
        ("far apart", None),
        (None, 0),
    ],
)
@pytest.mark.parametrize("hard", [False, True])
def test_an_invalid_measure_is_refused_beside_a_valid_one(distance_m: Any, min_zones: Any, hard: bool) -> None:
    with pytest.raises(ValueError):
        _distance_rule(distance_m, min_zones, hard)


@pytest.mark.parametrize(
    ("distance_m", "min_zones"),
    [(3.0, None), (None, 2), (3.0, 2), (0.5, 1)],
)
def test_valid_measures_are_kept(distance_m: Any, min_zones: Any) -> None:
    rule = _distance_rule(distance_m, min_zones)
    assert rule.distance_m == distance_m
    assert rule.min_zones == min_zones
    # One of the refused pairs, in the same test, so this cannot pass on a
    # tree that accepts everything.
    with pytest.raises(ValueError):
        _distance_rule("far apart", 1)


def test_from_dict_refuses_an_invalid_measure_beside_a_valid_one() -> None:
    from seating_planner.rules import Rule

    good = _distance_rule(3.0, 2).to_dict()
    assert Rule.from_dict(good).distance_m == 3.0
    for key, value in (("distance_m", "far apart"), ("min_zones", 0), ("distance_m", -1.0)):
        bad = dict(good)
        bad[key] = value
        with pytest.raises(ValueError):
            Rule.from_dict(bad)
