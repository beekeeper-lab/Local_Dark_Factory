"""Hidden tests for bean-033 (run 2): a cause named via the keep-set probe must be
part of a MINIMAL infeasible keep-set, and the shortage-only branch must not probe
lock removal once curing the shortfall alone already restores feasibility.

Written from ac4 and ac5, which run 1's pre-merge review produced
(evidence/reviews/bean-033-20261013T082950Z.md): run 1 added a "keep-set" probe
(hold just a candidate combo, remove every other rule and lock, name every member
if the result is still proven infeasible) because its removal-probe search alone
could not satisfy its own red tests. Keeping a larger combo is monotonically MORE
constrained than keeping a smaller one, so once a single item is infeasible kept
entirely alone, every pair containing it is trivially infeasible too -- one bad
item drags in an unrelated partner as a named "cause" (ac4). Separately, the
shortage-only branch kept probing lock removal even when nothing needed removing,
so every lock in the event got named as part of a fix it never needed (ac5).
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


def test_a_keep_set_cause_is_never_named_through_a_partner_that_already_fails_alone() -> None:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    # 3 tables of 2 seats each (6 seats), 6 guests, no shortfall.
    #
    # r-big needs 3 guests at one table -- impossible on ANY table here, since
    # every table's capacity is 2. This is a genuine, capacity-independent
    # conflict: r-big is infeasible kept entirely alone (every other rule and
    # the lock removed), so a keep-set probe that does not check minimality
    # will also call {r-big, r-ok} and {r-big, lock-of-g5} infeasible, and
    # falsely name the unrelated partner too.
    #
    # r-ok (2 guests, same table) and the lock on g5 are both harmless: either
    # one, alone or together, fits trivially once r-big is out of the way.
    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0)),
                Table(id="t3", name="t3", capacity=2, shape="round", position=(0.0, 2.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(6)],
        groups=[],
        rules=[
            Rule(id="r-big", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g0", "g1", "g2")),
            Rule(id="r-ok", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g3", "g4")),
        ],
        locks={"g5": "t3"},
    )
    for mode, kwargs in (("planning", {}), ("low_disruption", {"current": {"g0": "t1"}, "movement_limit": 100})):
        result = solve_event(ev, mode=mode, time_limit_s=10.0, seed=0, num_search_workers=1, **kwargs)
        report = result.infeasibility_report
        assert report is not None, f"{mode}: r-big alone cannot be satisfied at any 2-seat table"
        assert report.capacity_shortfall == 0, f"{mode}: 6 guests at 6 seats, no shortfall expected"
        assert report.conflict_rule_ids == ("r-big",), (
            f"{mode}: only r-big conflicts with anything; r-ok is harmless and must not "
            f"be named: {report.conflict_rule_ids}"
        )
        unlocked_guests = {
            rec.guest_id for rec in report.recommendations if rec.kind == "unlock"
        }
        assert not unlocked_guests, (
            f"{mode}: g5's lock conflicts with nothing and must not be named: {unlocked_guests}"
        )


def test_dropping_only_r_big_restores_feasibility() -> None:
    # The property check: r-big really is the whole cause. Removing it (with
    # r-ok and the lock still in place) restores feasibility in both modes.
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0)),
                Table(id="t3", name="t3", capacity=2, shape="round", position=(0.0, 2.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(6)],
        groups=[],
        rules=[
            Rule(id="r-ok", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g3", "g4")),
        ],
        locks={"g5": "t3"},
    )
    for mode, kwargs in (("planning", {}), ("low_disruption", {"current": {"g0": "t1"}, "movement_limit": 100})):
        result = solve_event(ev, mode=mode, time_limit_s=10.0, seed=0, num_search_workers=1, **kwargs)
        assert result.infeasibility_report is None, (
            f"{mode}: with r-big removed, r-ok plus g5's lock should be solvable"
        )


def test_a_lock_is_not_named_when_the_shortfall_alone_already_cures_it() -> None:
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.solver import solve_event

    # 2 tables of 2 seats (4 seats), 5 guests, shortfall 1, no rules. The lock
    # on g0 does not block anything -- curing the shortfall alone (any extra
    # seat, anywhere) already restores feasibility with the lock kept, so no
    # lock should be probed for removal or named.
    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(5)],
        groups=[],
        rules=[],
        locks={"g0": "t1"},
    )
    for mode, kwargs in (("planning", {}), ("low_disruption", {"current": {"g0": "t1"}, "movement_limit": 100})):
        result = solve_event(ev, mode=mode, time_limit_s=10.0, seed=0, num_search_workers=1, **kwargs)
        report = result.infeasibility_report
        assert report is not None, f"{mode}: 5 guests at 4 seats is infeasible"
        assert report.capacity_shortfall == 1, f"{mode}: expected a 1-seat shortfall"
        unlocked_guests = {
            rec.guest_id for rec in report.recommendations if rec.kind == "unlock"
        }
        assert not unlocked_guests, (
            f"{mode}: g0's lock does not need releasing -- the shortfall alone cures "
            f"this, and a lock must not be named just because releasing it is also, "
            f"trivially, sufficient: {unlocked_guests}"
        )


def test_releasing_the_lock_alone_does_not_help() -> None:
    # The property check: if g0's lock really were part of a conflict,
    # releasing it (with no extra seat) would restore feasibility. It does
    # not -- proving it was never the cause, only the seat shortage was.
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.solver import solve_event

    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(5)],
        groups=[], rules=[], locks={},
    )
    result = solve_event(ev, mode="planning", time_limit_s=10.0, seed=0, num_search_workers=1)
    assert result.infeasibility_report is not None, "still short a seat with the lock already gone"


def _any_placement_restores_feasibility(
    event: Any, drop_ids: set, extra_total: int, mode: str, **kwargs: Any
) -> bool:
    """True if SOME way to add `extra_total` seats across the event's tables, after
    dropping the named rules, makes it solvable. ac3's own property: a diagnosis's
    advice only counts if some real placement of it actually works.
    """
    from itertools import combinations_with_replacement

    from seating_planner.domain import Event, Table
    from seating_planner.solver import solve_event

    table_ids = [t.id for t in event.tables]
    for combo in combinations_with_replacement(table_ids, extra_total):
        bump = {tid: combo.count(tid) for tid in table_ids}
        new_tables = [
            Table(id=t.id, name=t.name, capacity=t.capacity + bump[t.id],
                  shape=t.shape, position=t.position)
            for t in event.tables
        ]
        new_rules = [r for r in event.rules if r.id not in drop_ids]
        new_event = Event(
            id=event.id, name=event.name, tables=new_tables,
            guests=event.guests, groups=event.groups, rules=new_rules,
            locks=dict(event.locks),
        )
        result = solve_event(new_event, mode=mode, time_limit_s=10.0, seed=0,
                              num_search_workers=1, **kwargs)
        if result.infeasibility_report is None:
            return True
    return False


def test_a_bystander_is_never_named_when_the_shortfall_needs_slack_the_keep_set_omits() -> None:
    """Run 2's pre-merge review (evidence/reviews/bean-033-20261013T151028Z.md): the
    keep-set probe never applied the shortfall's slack bound, building its model at
    real capacities only. ac4's minimality rule silently assumes the EMPTY keep-set
    (everything removed) is itself feasible -- when an uncured shortfall makes it
    infeasible instead, every item fails "kept alone" too and gets named, whether or
    not it is really a cause.
    """
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    # 7 guests, three 2-seat tables (6 seats, shortfall 1). r-a/r-b are a real,
    # capacity-independent contradiction (same-table vs different-table on the
    # same pair). r-ok is a harmless same-table pair, and g6 is harmlessly
    # locked. Only r-a and r-b may be named; r-ok and the lock must not be.
    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0)),
                Table(id="t3", name="t3", capacity=2, shape="round", position=(0.0, 2.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(7)],
        groups=[],
        rules=[
            Rule(id="r-a", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g0", "g1")),
            Rule(id="r-b", rule_type=RuleType.DIFFERENT_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g0", "g1")),
            Rule(id="r-ok", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g2", "g3")),
        ],
        locks={"g6": "t3"},
    )
    for mode, kwargs in (("planning", {}), ("low_disruption", {"current": {"g0": "t1"}, "movement_limit": 100})):
        result = solve_event(ev, mode=mode, time_limit_s=10.0, seed=0, num_search_workers=1, **kwargs)
        report = result.infeasibility_report
        assert report is not None, f"{mode}: 7 guests at 6 seats is infeasible"
        assert report.capacity_shortfall == 1, f"{mode}: expected a 1-seat shortfall"
        assert report.conflict_rule_ids == ("r-a", "r-b"), (
            f"{mode}: only the real contradiction may be named; r-ok is harmless: "
            f"{report.conflict_rule_ids}"
        )
        unlocked_guests = {
            rec.guest_id for rec in report.recommendations if rec.kind == "unlock"
        }
        assert not unlocked_guests, (
            f"{mode}: g6's lock conflicts with nothing and must not be named: {unlocked_guests}"
        )
        assert _any_placement_restores_feasibility(
            ev, {"r-a", "r-b"}, report.capacity_shortfall, mode, **kwargs
        ), f"{mode}: dropping the real pair plus the shortfall must restore feasibility"


def test_a_bystander_is_never_named_when_keeping_nothing_is_already_infeasible() -> None:
    """Run 2's pre-merge review, second case: a frozen low-disruption chart that
    itself violates a table's capacity (three guests already charted onto a
    two-seat table) is infeasible at movement_limit=0 no matter which rules or
    locks are kept -- the keep-set search must not run at all here, or every
    harmless rule and lock in the event gets swept in as a false "cause."
    """
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0)),
                Table(id="t3", name="t3", capacity=2, shape="round", position=(0.0, 2.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(6)],
        groups=[],
        rules=[
            Rule(id="r-ok", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g3", "g4")),
        ],
        locks={"g5": "t3"},
    )
    # g0, g1 and g2 are all charted onto t1 (capacity 2) -- already overfull,
    # and movement_limit=0 forbids moving any of them out of it.
    chart = {"g0": "t1", "g1": "t1", "g2": "t1", "g3": "t2", "g4": "t2", "g5": "t3"}
    result = solve_event(
        ev, mode="low_disruption", current=chart, movement_limit=0,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    )
    report = result.infeasibility_report
    assert report is not None, "three guests frozen onto a two-seat table is infeasible"
    assert report.capacity_shortfall == 0, "six guests at six seats: no shortfall"
    assert report.conflict_rule_ids == (), (
        f"r-ok is already satisfied by the chart and changes nothing: "
        f"{report.conflict_rule_ids}"
    )
    unlocked_guests = {
        rec.guest_id for rec in report.recommendations if rec.kind == "unlock"
    }
    assert not unlocked_guests, (
        f"g5's lock already matches the chart and changes nothing: {unlocked_guests}"
    )


def test_a_plain_shortage_is_never_blamed_on_the_movement_limit() -> None:
    """Run 3's pre-merge review (evidence/reviews/bean-033-20261013T184336Z.md): the
    pre-existing low-disruption movement-limit probe picked up the shortfall's slack
    bound, so a plain seat shortage trivially passed it and the report blamed the
    movement limit instead of recommending add_capacity -- even with a generous
    limit that raising would not actually help.
    """
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.solver import solve_event

    # 5 guests, two 2-seat tables (shortfall 1), no rules, no locks. A generous
    # movement limit (100) is nowhere near the actual cause -- the real capacities
    # are one seat short, full stop. Raising the limit to any value never helps:
    # there is nowhere to put the fifth guest.
    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(5)],
        groups=[], rules=[], locks={},
    )
    result = solve_event(
        ev, mode="low_disruption", current={"g0": "t1"}, movement_limit=100,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    )
    report = result.infeasibility_report
    assert report is not None, "5 guests at 4 seats is infeasible"
    assert report.capacity_shortfall == 1, "expected a 1-seat shortfall"
    kinds = {rec.kind for rec in report.recommendations}
    assert "add_capacity" in kinds, (
        f"a plain shortage must still recommend add_capacity: {kinds}"
    )
    assert "raise_movement_limit" not in kinds, (
        f"the movement limit (100) is nowhere near the real cause (a 1-seat "
        f"shortage) and must not be named: {kinds}"
    )


def test_raising_the_movement_limit_alone_does_not_help_the_plain_shortage() -> None:
    # The property check: if the movement limit really were part of the cause,
    # lifting it entirely (no limit at all) would restore feasibility. It does
    # not -- proving the shortage, not the limit, is the whole story.
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.solver import solve_event

    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(5)],
        groups=[], rules=[], locks={},
    )
    result = solve_event(
        ev, mode="low_disruption", current={"g0": "t1"}, movement_limit=1000,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    )
    assert result.infeasibility_report is not None, (
        "still short a seat no matter how high the movement limit goes"
    )


def test_a_rule_contradiction_is_still_named_when_the_chart_alone_is_also_infeasible() -> None:
    """Run 4's pre-merge review (evidence/reviews/bean-033-20261014T023159Z.md): when the
    frozen chart (or the movement limit) is already infeasible on its own -- here, three
    guests charted onto a two-seat table at movement_limit=0 -- every pass-1 probe at the
    real limit fails and the empty-keep-set gate (ac6) skips the whole keep-set search, so
    a genuine, unrelated rule contradiction elsewhere must still be found and named (ac8),
    not dropped to the generic note.
    """
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    # t1 charted with 3 guests (cap 2) -- infeasible on its own at limit=0,
    # regardless of rules. r-a/r-b (a direct same/different contradiction on
    # two OTHER guests) is a second, independent cause that must still surface.
    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0)),
                Table(id="t3", name="t3", capacity=2, shape="round", position=(0.0, 2.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(6)],
        groups=[],
        rules=[
            Rule(id="r-a", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g3", "g4")),
            Rule(id="r-b", rule_type=RuleType.DIFFERENT_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g3", "g4")),
        ],
        locks={},
    )
    chart = {"g0": "t1", "g1": "t1", "g2": "t1", "g3": "t2", "g4": "t3", "g5": "t2"}
    result = solve_event(
        ev, mode="low_disruption", current=chart, movement_limit=0,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    )
    report = result.infeasibility_report
    assert report is not None, "three guests charted onto a two-seat table is infeasible"
    assert report.capacity_shortfall == 0, "six guests at six real seats: no shortfall"
    assert report.conflict_rule_ids, (
        "r-a and r-b directly contradict each other and must be named even though "
        "the chart's own capacity violation makes every real-limit probe fail"
    )
    kinds = {rec.kind for rec in report.recommendations}
    assert "raise_movement_limit" in kinds, (
        f"the chart's own capacity violation at t1 cannot be cured without moving "
        f"someone, so the limit must be named too: {kinds}"
    )
    # Property check: dropping the named rules and raising the limit together
    # restores feasibility; raising the limit alone (rules kept) does not.
    cured = Event(
        id="e", name="e", tables=ev.tables, guests=ev.guests, groups=[],
        rules=[r for r in ev.rules if r.id not in report.conflict_rule_ids], locks={},
    )
    assert solve_event(
        cured, mode="low_disruption", current=chart, movement_limit=99,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    ).infeasibility_report is None, "dropping the named rules plus raising the limit must cure it"
    assert solve_event(
        ev, mode="low_disruption", current=chart, movement_limit=99,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    ).infeasibility_report is not None, "raising the limit alone, rules kept, must not cure it"


def test_a_timed_out_keep_set_probe_never_gets_named() -> None:
    """Run 5's pre-merge review (evidence/reviews/bean-033-20261014T113644Z.md): the
    keep-set probe treated a solve that ran out of time (UNKNOWN) the same as one
    proven INFEASIBLE, so a harmless item whose keep-set probe simply couldn't finish
    in the time given got named anyway. A tight time budget must never turn an
    undecided probe into a false name, no matter how large the event: nothing may be
    named here but the one real contradictory pair.
    """
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    # 30 tables of 5 (150 real seats, no shortfall). Ten harmless same-table
    # pairs (b00-b09) on the first 20 guests, trivially satisfiable two at a
    # time. Six locks, five of them packed onto one 5-seat table exactly at
    # capacity and the sixth on another -- tight, legitimately feasible
    # packing (not a bystander-by-coincidence spread-out case), which is what
    # makes their own keep-set sub-probes genuinely hard to decide quickly.
    # ra/rb (same vs different table on the same pair) is the one real,
    # capacity-independent contradiction.
    n_tables = 30
    n_guests = n_tables * 5
    tables = [
        Table(id=f"t{i + 1}", name=f"t{i + 1}", capacity=5, shape="round", position=(0.0, float(i)))
        for i in range(n_tables)
    ]
    guests = [Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(n_guests)]
    rules = [
        Rule(id=f"b{i:02d}", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
             weight=None, guest_ids=(f"g{2 * i}", f"g{2 * i + 1}"))
        for i in range(10)
    ]
    rules.append(
        Rule(id="ra", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
             weight=None, guest_ids=(f"g{n_guests - 2}", f"g{n_guests - 1}"))
    )
    rules.append(
        Rule(id="rb", rule_type=RuleType.DIFFERENT_TABLE, hardness=Hardness.HARD,
             weight=None, guest_ids=(f"g{n_guests - 2}", f"g{n_guests - 1}"))
    )
    locks = {f"g{i}": f"t{i // 5 + 1}" for i in range(40, 46)}
    ev = Event(id="e", name="e", tables=tables, guests=guests, groups=[], rules=rules, locks=locks)

    # A tight time budget: large enough that the top-level solve proves the
    # event infeasible, small enough that the many keep-set sub-probes over
    # this many rules and locks cannot all finish and decide. Whatever probes
    # go UNKNOWN, none may be named for it -- confirmed stable over repeated
    # runs in the gate image.
    result = solve_event(ev, mode="planning", time_limit_s=0.2, seed=0, num_search_workers=1)
    report = result.infeasibility_report
    assert report is not None, "the real pair makes this infeasible regardless of the time budget"
    assert report.conflict_rule_ids == ("ra", "rb"), (
        f"only the real contradictory pair may be named, time pressure or not: "
        f"{report.conflict_rule_ids}"
    )
    unlocked_guests = {
        rec.guest_id for rec in report.recommendations if rec.kind == "unlock"
    }
    assert not unlocked_guests, (
        f"none of the six harmless locks may be named just because their probe "
        f"could not finish in time: {unlocked_guests}"
    )


def test_a_rule_is_still_named_when_only_relaxing_the_limit_would_cure_the_shortage() -> None:
    """Run 6's pre-merge review (evidence/reviews/bean-033-20261016T032049Z.md): the
    low-disruption shortage short-circuit probed with the movement limit RELAXED
    (movement_limit=None) instead of the real one, so it fired whenever relaxing the
    limit -- not just adding a seat -- would help, even though the real limit
    forbids exactly that. The report then named only add_capacity, whose fix does
    not actually restore feasibility at the real limit: a real rule conflict got
    silently dropped behind a shortage-only report.
    """
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    # 2 one-seat tables, 3 guests, one hard rule forcing g0 and g1 together --
    # impossible at either one-seat table. Chart: g0@t1, g1@t2, g2@t1 (3 guests
    # on 2 seats, shortfall 1). movement_limit=0 freezes every guest in place.
    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=1, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=1, shape="round", position=(0.0, 1.0))],
        guests=[Guest(id="g0", name="g0", status=RsvpStatus.CONFIRMED),
                Guest(id="g1", name="g1", status=RsvpStatus.CONFIRMED),
                Guest(id="g2", name="g2", status=RsvpStatus.CONFIRMED)],
        groups=[],
        rules=[
            Rule(id="r0", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
                 weight=None, guest_ids=("g0", "g1")),
        ],
        locks={},
    )
    chart = {"g0": "t1", "g1": "t2", "g2": "t1"}
    result = solve_event(
        ev, mode="low_disruption", current=chart, movement_limit=0,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    )
    report = result.infeasibility_report
    assert report is not None, "3 guests on 2 one-seat tables, frozen, is infeasible"
    assert report.capacity_shortfall == 1, "expected a 1-seat shortfall"
    assert report.conflict_rule_ids == ("r0",), (
        f"r0 genuinely conflicts at the real (zero) movement limit and must be "
        f"named -- a report naming only capacity is not enough to cure this "
        f"event: {report.conflict_rule_ids}"
    )
    kinds = {rec.kind for rec in report.recommendations}
    assert "add_capacity" in kinds, f"the real shortfall must still be reported: {kinds}"

    # Property check: adding the one extra seat ANYWHERE, real limit held, r0
    # still in force, never restores feasibility -- the bug's own report (just
    # add_capacity) names a fix that does not work.
    for grown_cap in (("t1", 2), ("t2", 2)):
        grown_tables = [
            Table(id=t.id, name=t.name,
                  capacity=t.capacity + (1 if t.id == grown_cap[0] else 0),
                  shape=t.shape, position=t.position)
            for t in ev.tables
        ]
        grown = Event(id="e", name="e", tables=grown_tables, guests=ev.guests,
                       groups=[], rules=ev.rules, locks={})
        assert solve_event(
            grown, mode="low_disruption", current=chart, movement_limit=0,
            time_limit_s=10.0, seed=0, num_search_workers=1,
        ).infeasibility_report is not None, (
            "add_capacity alone, real limit held, r0 kept, must still fail -- "
            "proving r0 had to be named too"
        )
    # Dropping r0 AND adding the seat together does restore feasibility.
    cured_tables = [
        Table(id=t.id, name=t.name, capacity=t.capacity + (1 if t.id == "t1" else 0),
              shape=t.shape, position=t.position)
        for t in ev.tables
    ]
    cured = Event(id="e", name="e", tables=cured_tables, guests=ev.guests, groups=[], rules=[], locks={})
    assert solve_event(
        cured, mode="low_disruption", current=chart, movement_limit=0,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    ).infeasibility_report is None, "dropping r0 plus the extra seat together must cure it"


def test_the_diagnosis_honours_a_tight_requested_time_budget() -> None:
    """Run 6's pre-merge review (evidence/reviews/bean-033-20261016T032049Z.md): the
    diagnosis silently replaced the caller's own time_limit_s with a hard-coded 2.0s
    budget for every internal probe, so a request for a much smaller budget had no
    effect at all -- the same large event took ~22 seconds regardless of whether
    0.2s, 0.05s or 0.02s was asked for. The requested budget must actually bound how
    long the many internal probes are allowed to run.
    """
    import time

    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.rules import Hardness, Rule, RuleType
    from seating_planner.solver import solve_event

    # The same large, tightly-packed event as the timed-out-keep-set-probe test:
    # enough rules and locks that the many internal probes add up to real time,
    # so a budget that is actually honoured finishes well under the ~22s the
    # hard-coded-budget bug always took, no matter what was requested.
    n_tables = 30
    n_guests = n_tables * 5
    tables = [
        Table(id=f"t{i + 1}", name=f"t{i + 1}", capacity=5, shape="round", position=(0.0, float(i)))
        for i in range(n_tables)
    ]
    guests = [Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(n_guests)]
    rules = [
        Rule(id=f"b{i:02d}", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
             weight=None, guest_ids=(f"g{2 * i}", f"g{2 * i + 1}"))
        for i in range(10)
    ]
    rules.append(
        Rule(id="ra", rule_type=RuleType.SAME_TABLE, hardness=Hardness.HARD,
             weight=None, guest_ids=(f"g{n_guests - 2}", f"g{n_guests - 1}"))
    )
    rules.append(
        Rule(id="rb", rule_type=RuleType.DIFFERENT_TABLE, hardness=Hardness.HARD,
             weight=None, guest_ids=(f"g{n_guests - 2}", f"g{n_guests - 1}"))
    )
    locks = {f"g{i}": f"t{i // 5 + 1}" for i in range(40, 46)}
    ev = Event(id="e", name="e", tables=tables, guests=guests, groups=[], rules=rules, locks=locks)

    t0 = time.time()
    result = solve_event(ev, mode="planning", time_limit_s=0.02, seed=0, num_search_workers=1)
    elapsed = time.time() - t0
    assert result.infeasibility_report is not None, "the real pair makes this infeasible regardless of budget"
    assert elapsed < 15.0, (
        f"a 0.02s time budget must actually bound the internal probes -- this took "
        f"{elapsed:.1f}s, close to the ~22s a hard-coded 2.0s-per-probe budget always "
        f"takes on this event regardless of what was requested"
    )


def test_a_plain_shortage_curable_only_by_relaxing_the_limit_still_names_it() -> None:
    """Run 7's pre-merge review (evidence/reviews/bean-033-20261017T154346Z.md): this
    round rewrote the diagnosis as one pooled rule-and-lock search shared by both passes
    of the low-disruption two-pass movement-limit search, and the shortage-only
    short-circuit -- now inside that shared search -- silently absorbed the
    movement-limit cause. When a plain capacity shortfall is curable only once the real
    limit is relaxed (no rule, no lock involved at all), pass 1's shortage check
    correctly fails at the real limit, but pass 2's own copy of the same shortage check
    succeeds once the limit is relaxed and returns before the caller's "pass 2 found
    something" flag can ever be set -- so the report recommends add_capacity alone,
    which does not actually restore feasibility at the real limit.
    """
    from seating_planner.domain import Event, Guest, RsvpStatus, Table
    from seating_planner.solver import solve_event

    # 3 tables of capacity 2 (6 real seats), 7 guests, no rules, no locks. The chart
    # packs 4 guests onto t1 (overfull by 2) and 2 onto t2, 1 onto t3 -- a global
    # shortfall of 1, but at movement_limit=0 no guest may be reseated, so the only way
    # to cure it is to both add a seat AND raise the limit enough to let someone move
    # into it. Capacity alone, at the real (zero) limit, can never cure a chart this
    # frozen, and raising the limit alone (no capacity change) is a genuine shortfall
    # too -- only both together restore feasibility.
    ev = Event(
        id="e", name="e",
        tables=[Table(id="t1", name="t1", capacity=2, shape="round", position=(0.0, 0.0)),
                Table(id="t2", name="t2", capacity=2, shape="round", position=(0.0, 1.0)),
                Table(id="t3", name="t3", capacity=2, shape="round", position=(0.0, 2.0))],
        guests=[Guest(id=f"g{i}", name=f"g{i}", status=RsvpStatus.CONFIRMED) for i in range(7)],
        groups=[], rules=[], locks={},
    )
    chart = {"g0": "t1", "g1": "t1", "g2": "t1", "g3": "t1", "g4": "t2", "g5": "t2", "g6": "t3"}
    result = solve_event(
        ev, mode="low_disruption", current=chart, movement_limit=0,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    )
    report = result.infeasibility_report
    assert report is not None, "4 guests frozen onto a 2-seat table, real limit zero, is infeasible"
    assert report.capacity_shortfall == 1, "7 guests at 6 real seats: expected a 1-seat shortfall"
    assert report.conflict_rule_ids == (), "no rules in this event; none may be named"
    unlocked_guests = {
        rec.guest_id for rec in report.recommendations if rec.kind == "unlock"
    }
    assert not unlocked_guests, f"no locks in this event; none may be named: {unlocked_guests}"
    kinds = {rec.kind for rec in report.recommendations}
    assert "add_capacity" in kinds, f"the real shortfall must still be reported: {kinds}"
    assert "raise_movement_limit" in kinds, (
        f"capacity alone, real limit held, never restores feasibility here -- the limit "
        f"must be named alongside it: {kinds}"
    )

    # Property check: adding the one extra seat ANYWHERE, real limit held, never
    # restores feasibility -- the bug's own report (just add_capacity) names a fix that
    # does not work.
    for grown_cap in ("t1", "t2", "t3"):
        grown_tables = [
            Table(id=t.id, name=t.name,
                  capacity=t.capacity + (1 if t.id == grown_cap else 0),
                  shape=t.shape, position=t.position)
            for t in ev.tables
        ]
        grown = Event(id="e", name="e", tables=grown_tables, guests=ev.guests, groups=[], rules=[], locks={})
        assert solve_event(
            grown, mode="low_disruption", current=chart, movement_limit=0,
            time_limit_s=10.0, seed=0, num_search_workers=1,
        ).infeasibility_report is not None, (
            f"add_capacity alone at {grown_cap}, real limit held, must still fail -- "
            "proving the limit had to be named too"
        )
    # Raising the limit alone, no capacity change, also fails -- it is a genuine
    # shortfall too, not purely a movement-limit problem.
    assert solve_event(
        ev, mode="low_disruption", current=chart, movement_limit=99,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    ).infeasibility_report is not None, "raising the limit alone, no extra seat, must still fail"
    # Only the limit AND capacity together cure it.
    cured_tables = [
        Table(id=t.id, name=t.name, capacity=t.capacity + (1 if t.id == "t1" else 0),
              shape=t.shape, position=t.position)
        for t in ev.tables
    ]
    cured = Event(id="e", name="e", tables=cured_tables, guests=ev.guests, groups=[], rules=[], locks={})
    assert solve_event(
        cured, mode="low_disruption", current=chart, movement_limit=99,
        time_limit_s=10.0, seed=0, num_search_workers=1,
    ).infeasibility_report is None, "dropping the limit plus the extra seat together must cure it"
