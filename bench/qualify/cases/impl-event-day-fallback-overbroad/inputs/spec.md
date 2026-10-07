# Bean-031 — An infeasible event-day report always says what to do

## What and why

This repo is a wedding seating planner. Every eligible guest sits at exactly
one table, no table seats more than its capacity, and the enabled "hard rules"
(like "keep these two guests at different tables") are constraints the solver
must never violate. The `event_day` mode is the day-of-the-event re-solve:
every guest already on the current chart is implicitly pinned to their
current table — that pinning *is* the mode — and the only free variables are
genuinely new guests plus any guest the caller explicitly passes in the
`unlocked` set.

When an event-day solve comes back infeasible, the result carries an
`InfeasibilityReport` with a list of corrective-action recommendations drawn
from a fixed vocabulary (`unlock`, `add_capacity`, `add_table`,
`change_hard_rule`). A long-standing requirement (bean-010's lineage) is that
**at least one recommendation is always named**: a report with zero advice is
unusable on the day of the event, which is exactly when it appears.

Bean-025 deliberately tightened the event-day diagnosis. A stored lock is now
named only when removing *that one lock alone* restores feasibility, and with
no enabled hard rule the generic "review the hard rules" note is withheld
(there is nothing to review — that part is correct). Both changes are right on
their own, but together they opened a hole: an infeasible event-day solve with
no seat shortfall, no enabled hard rule, and no single removal that helps
comes back with an **empty** recommendation list. Two cases were measured on
the merged main and both reproduce the empty report today: three new guests
each stored-locked to a table with one free seat (removing any one lock still
leaves two locked guests for one seat), and a chart that seats three guests
at a two-seat table (chart capacity is not checked on input, so such a chart
is legal to pass in). This session re-checked both against the current tree:
the first returns `infeasible` with `capacity_shortfall == 0`, empty
`conflict_rule_ids` and an empty recommendation tuple; the second the same.

An earlier run of this bean (opened as PR #24, run
`bean-031-20261006T210423Z`) closed the gap with advice chosen by counting
seats, and its pre-merge review showed the counting was wrong three ways:

1. a chart that overfills a table with a new guest also locked there was
   told only to unlock that guest — still infeasible afterwards, because the
   chart's own pins fill the table;
2. a table holding no chart guest was told to add capacity it could not use;
3. an unlocked chart guest was counted as pinned, so capacity numbers were
   wrong.

Counting predicts. The solver can answer "would this help?" **exactly**, the
same way the existing rule and lock probes already do, by building the
relaxed pinned model and solving it. So this decomposition makes the advice
checked by a probe solve before it is given: unlocks are recommended only
after a probe without those locks comes back feasible, capacity only after a
probe with the named tables re-seated comes back feasible, and the report can
never be empty on an infeasible event-day solve.

## Current behaviour

The event-day diagnosis lives in `_diagnose_event_day`
(`src/seating_planner/solver/hard.py`). It names a rule or a stored lock only
when a one-removal probe restores feasibility, then hands the rest to the
shared `build_recommendations` helper (`src/seating_planner/solver/report.py`):

```python
src/seating_planner/solver/hard.py   # tail of _diagnose_event_day, today
    unlock = _probe_event_day_lock_removals(event, eligible, current, unlocked, seed, time_limit_s)
    shortfall = max(0, len(eligible) - sum(t.capacity for t in event.tables))
    return InfeasibilityReport(
        conflict,
        shortfall,
        build_recommendations(
            {rule.id: rule.rule_type for rule in rules},
            conflict,
            capacity_shortfall=shortfall,
            has_tables=bool(event.tables),
            # The generic joint-conflict note names hard rules that must be
            # reviewed; with no enabled hard rule that advice is false, and
            # the lock removals (if any) are the whole report.
            suppress_generic_note=not rules,
        )
        + tuple(unlock),
    )
```

```python
src/seating_planner/solver/report.py  # the last branch of build_recommendations
    if not recommendations and not suppress_generic_note:
        # The joint-conflict case: no single removal restores feasibility.
        recommendations.append(
            Recommendation(
                KIND_CHANGE_HARD_RULE,
                "The enabled hard rules are jointly unsatisfiable; at least one "
                "of them must be reviewed.",
                rule_id=None,
            )
        )
    return tuple(recommendations)
```

Every source of a recommendation is conditional: the capacity advice needs
`capacity_shortfall > 0`, the change-rule advice needs a rule a single-removal
probe exonerates, the unlock advice needs one lock whose removal alone works,
and the generic note is suppressed exactly when `rules` is empty. With no
rules (note suppressed), zero shortfall (no capacity advice) and no single
removal proven (nothing from the probes), the `recommendations` tuple is
empty. The report still exists — status `infeasible`, shortfall 0, empty
conflict — but it says nothing to do. That is the measured gap, and it is the
only place a report can turn out empty: whenever the event has an enabled
hard rule, either a specific rule is named or the generic note fires.

## Proposed change

Two tasks, in dependency order. Task 1 writes the red tests; task 2 adds the
probe-checked fallback. Both code blocks below were transcribed from a
dry-run of this exact change against a working copy of the tree (ruff
check/format and mypy strict clean; all five solver-test batteries run green
against the patched copy and red against the unpatched one, per the
Verification section), so they are the files, not sketches.

### Task 1 — red tests in `tests/solver/test_event_day_advice.py`

The new file, complete. It follows the conventions of
`tests/solver/test_event_day_repairs.py` (same private `_table`/`_guest`/
`_event`/`_hard` helpers; a docstring saying asserts touch only `solve_event`
result fields). Four scenarios, one test per acceptance criterion; the
arithmetic of each scenario is stated in its comment and was worked out
against `_build_event_day_model` and `_apply_locks` before being written:
the locked scenario has six guests for six seats (shortfall 0) with t-1
demanding five for three seats; the overfull chart has four guests for four
seats with three pinned onto a two-seat table; the rule-conflict and
shortfall scenarios are the two infeasible shapes that **already** advised,
carried along so the property is pinned on old and new paths at once.
`test_fallback_advice_is_probed` additionally rebuilds each event with the
recommended remedy actually applied (locks removed, one table re-seated) and
asserts the rebuilt event solves `feasible` — the probe property, checked
against the real solver, not the report's wording.

```python
tests/solver/test_event_day_advice.py
"""Event-day advice tests (bean-031): an infeasible event-day solve always
carries at least one recommendation; stored locks that pin more guests to a
table than it can hold are each named for unlocking; a chart that seats a
table past its capacity earns capacity advice naming that table; and fallback
advice is probed — unlocking every named guest, or seating every named table,
restores feasibility. As in the acceptance tests, asserts only on solve_event
result fields, never on solver internals."""

from __future__ import annotations

from seating_planner.domain import Event, Guest, RsvpStatus, Table
from seating_planner.rules import Hardness, Rule, RuleType
from seating_planner.solver import solve_event
from seating_planner.solver.report import (
    KIND_ADD_CAPACITY,
    KIND_CHANGE_HARD_RULE,
    KIND_UNLOCK,
)


def _table(table_id: str, capacity: int) -> Table:
    return Table(
        id=table_id,
        name=f"Table {table_id}",
        capacity=capacity,
        shape="round",
        position=(0.0, 0.0),
    )


def _guest(guest_id: str) -> Guest:
    return Guest(id=guest_id, name=f"Guest {guest_id}", status=RsvpStatus.CONFIRMED)


def _event(
    tables: list[Table],
    guests: list[Guest],
    rules: list[object] | None = None,
    locks: dict[str, str] | None = None,
) -> Event:
    return Event(
        id="e-1",
        name="Event",
        tables=tables,
        guests=guests,
        groups=[],
        rules=rules or [],
        locks=locks or {},
    )


def _hard(
    rule_id: str,
    rule_type: RuleType,
    guest_ids: tuple[str, ...],
) -> Rule:
    return Rule(
        id=rule_id,
        rule_type=rule_type,
        hardness=Hardness.HARD,
        weight=None,
        guest_ids=guest_ids,
    )


def _locked_scenario() -> tuple[Event, dict[str, str]]:
    # t-1 (capacity 3) holds pinned g-0, g-1; t-2 (capacity 3) holds pinned
    # g-4. New guests n-1, n-2, n-3 are each stored-locked to t-1. Six
    # guests, six seats, so the shortfall is zero. t-1 must hold two pinned
    # plus three locked guests (five for three seats), and removing any one
    # lock still leaves two locked guests for one seat, so no single removal
    # restores feasibility and the old diagnosis named nothing.
    tables = [_table("t-1", capacity=3), _table("t-2", capacity=3)]
    guests = [_guest(i) for i in ("g-0", "g-1", "g-4", "n-1", "n-2", "n-3")]
    locks = {"n-1": "t-1", "n-2": "t-1", "n-3": "t-1"}
    current = {"g-0": "t-1", "g-1": "t-1", "g-4": "t-2"}
    return _event(tables, guests, locks=locks), current


def _overfull_chart_scenario() -> tuple[Event, dict[str, str]]:
    # t-1 (capacity 2) is chart-seated with three guests; t-2 (capacity 2)
    # holds one. No rules, no locks: four guests, four seats, shortfall
    # zero, but the day pins force three guests onto a two-seat table.
    tables = [_table("t-1", capacity=2), _table("t-2", capacity=2)]
    guests = [_guest(f"g-{i}") for i in range(4)]
    current = {"g-0": "t-1", "g-1": "t-1", "g-2": "t-1", "g-3": "t-2"}
    return _event(tables, guests), current


def _rule_conflict_scenario() -> tuple[Event, dict[str, str]]:
    # The shape that advised before this bean: a hard rule whose removal
    # alone seats the new guest. Two capacity-2 tables; the chart fills t-1
    # and seats g-2 at t-2; r-diff keeps g-2 and the new g-3 apart, which
    # bans g-3 from its only free seat.
    tables = [_table("t-1", capacity=2), _table("t-2", capacity=2)]
    guests = [_guest(f"g-{i}") for i in range(4)]
    rules = [_hard("r-diff", RuleType.DIFFERENT_TABLE, ("g-2", "g-3"))]
    current = {"g-0": "t-1", "g-1": "t-1", "g-2": "t-2"}
    return _event(tables, guests, rules=rules), current


def _shortfall_scenario() -> tuple[Event, dict[str, str]]:
    # The other shape that already advised: a pure seat shortfall. Four
    # guests for three seats, chart pins g-0, g-1 at t-1 and g-2 at t-2.
    tables = [_table("t-1", capacity=2), _table("t-2", capacity=1)]
    guests = [_guest(f"g-{i}") for i in range(4)]
    current = {"g-0": "t-1", "g-1": "t-1", "g-2": "t-2"}
    return _event(tables, guests), current


def test_infeasible_event_day_always_advises() -> None:
    # Four ways the pinned event-day model comes back infeasible — the two
    # measured empty-report cases plus the two shapes that already advised —
    # and every one of them must carry at least one recommendation.
    for event, current in (
        _locked_scenario(),
        _overfull_chart_scenario(),
        _rule_conflict_scenario(),
        _shortfall_scenario(),
    ):
        result = solve_event(event, mode="event_day", current=current)
        assert result.status == "infeasible"
        report = result.infeasibility_report
        assert report is not None
        assert len(report.recommendations) >= 1


def test_locks_that_overfill_a_table_are_named() -> None:
    event, current = _locked_scenario()
    result = solve_event(event, mode="event_day", current=current)
    assert result.status == "infeasible"
    report = result.infeasibility_report
    assert report is not None
    assert report.capacity_shortfall == 0
    assert report.conflict_rule_ids == ()
    unlocks = [rec for rec in report.recommendations if rec.kind == KIND_UNLOCK]
    # Each of the three locked guests is named, each against the table it
    # fills beside the pinned chart guests.
    assert len(unlocks) == 3
    messages = " ".join(rec.message for rec in unlocks)
    for guest_id in ("n-1", "n-2", "n-3"):
        assert guest_id in messages
    assert all("t-1" in rec.message for rec in unlocks)
    # The event has no hard rules, so the report says nothing about
    # reviewing any.
    kinds = [rec.kind for rec in report.recommendations]
    assert KIND_CHANGE_HARD_RULE not in kinds


def test_a_chart_that_overfills_a_table_asks_for_capacity() -> None:
    event, current = _overfull_chart_scenario()
    result = solve_event(event, mode="event_day", current=current)
    assert result.status == "infeasible"
    report = result.infeasibility_report
    assert report is not None
    assert report.conflict_rule_ids == ()
    capacity = [rec for rec in report.recommendations if rec.kind == KIND_ADD_CAPACITY]
    assert len(capacity) == 1
    assert "t-1" in capacity[0].message
    kinds = [rec.kind for rec in report.recommendations]
    assert KIND_UNLOCK not in kinds
    assert KIND_CHANGE_HARD_RULE not in kinds


def test_fallback_advice_is_probed() -> None:
    # Part 1 — the unlock advice is verified by solving with every named
    # guest unlocked, and nothing else is advised (in particular no
    # capacity) because those unlocks alone restore feasibility.
    event, current = _locked_scenario()
    result = solve_event(event, mode="event_day", current=current)
    assert result.status == "infeasible"
    report = result.infeasibility_report
    assert report is not None
    unlocks = [rec for rec in report.recommendations if rec.kind == KIND_UNLOCK]
    assert len(unlocks) == 3
    messages = " ".join(rec.message for rec in unlocks)
    for guest_id in ("n-1", "n-2", "n-3"):
        assert guest_id in messages
    kinds = [rec.kind for rec in report.recommendations]
    assert KIND_ADD_CAPACITY not in kinds
    unlocked_event = _event(event.tables, event.guests, locks={})
    assert solve_event(unlocked_event, mode="event_day", current=current).status == "feasible"

    # Part 2 — the capacity advice names the overfilled table, and raising
    # exactly that table to its seated count (three for two) restores
    # feasibility.
    event2, current2 = _overfull_chart_scenario()
    result2 = solve_event(event2, mode="event_day", current=current2)
    assert result2.status == "infeasible"
    report2 = result2.infeasibility_report
    assert report2 is not None
    capacity2 = [rec for rec in report2.recommendations if rec.kind == KIND_ADD_CAPACITY]
    assert len(capacity2) == 1
    assert "t-1" in capacity2[0].message
    bigger_tables = [_table("t-1", capacity=3), _table("t-2", capacity=2)]
    bigger_event = _event(bigger_tables, event2.guests)
    assert solve_event(bigger_event, mode="event_day", current=current2).status == "feasible"

    # Part 3 — capacity is advised, not unlocking, when the chart itself
    # overfills the table: a new guest locked to the *other* table cannot be
    # the cure, and unlocking indeed does not restore feasibility.
    tables3 = [_table("t-1", capacity=2), _table("t-2", capacity=3)]
    guests3 = [_guest(i) for i in ("g-0", "g-1", "g-2", "g-3", "n-1")]
    event3 = _event(tables3, guests3, locks={"n-1": "t-2"})
    current3 = {"g-0": "t-1", "g-1": "t-1", "g-2": "t-1", "g-3": "t-2"}
    result3 = solve_event(event3, mode="event_day", current=current3)
    assert result3.status == "infeasible"
    report3 = result3.infeasibility_report
    assert report3 is not None
    kinds3 = [rec.kind for rec in report3.recommendations]
    assert KIND_UNLOCK not in kinds3
    capacity3 = [rec for rec in report3.recommendations if rec.kind == KIND_ADD_CAPACITY]
    assert len(capacity3) == 1
    assert "t-1" in capacity3[0].message
    # And unlocking n-1 alone really does not help, so its absence stands.
    no_locks3 = _event(tables3, guests3, locks={})
    assert solve_event(no_locks3, mode="event_day", current=current3).status == "infeasible"
    # While raising t-1 to its seated count does.
    bigger3 = _event(
        [_table("t-1", capacity=3), _table("t-2", capacity=3)],
        event3.guests,
        locks={"n-1": "t-2"},
    )
    assert solve_event(bigger3, mode="event_day", current=current3).status == "feasible"

    # Part 4 — an unlocked chart guest is not counted as pinned: g-2 is on
    # the chart at t-1 but released, so only two guests pin the one-seat
    # table, and one extra seat there restores feasibility.
    tables4 = [_table("t-1", capacity=1), _table("t-2", capacity=3)]
    guests4 = [_guest(f"g-{i}") for i in range(4)]
    event4 = _event(tables4, guests4)
    current4 = {"g-0": "t-1", "g-1": "t-1", "g-2": "t-1", "g-3": "t-2"}
    result4 = solve_event(event4, mode="event_day", current=current4, unlocked={"g-2"})
    assert result4.status == "infeasible"
    report4 = result4.infeasibility_report
    assert report4 is not None
    capacity4 = [rec for rec in report4.recommendations if rec.kind == KIND_ADD_CAPACITY]
    assert len(capacity4) == 1
    assert "t-1" in capacity4[0].message
    one_seating_more = _event([_table("t-1", capacity=2), _table("t-2", capacity=3)], guests4)
    assert (
        solve_event(one_seating_more, mode="event_day", current=current4, unlocked={"g-2"}).status
        == "feasible"
    )
```

These tests are red today on assertion values only: in the two new scenarios
the report exists and the assertions inspect its `recommendations`, which is
the empty tuple. They do not fail in setup, which is what the red-test
verify requires — a red test that fails in its own scenario cannot be turned
green by the fix.

### Task 2 — the probe-checked fallback in `src/seating_planner/solver/hard.py`

One new private function, one capture-and-branch at the end of
`_diagnose_event_day`, two import changes, and a docstring extension —
nothing else in the file. The fallback's three steps, each with its
justification noted in the code:

1. **Unlock probe.** If the event has stored locks binding eligible,
   unreleased guests, build the pinned event-day model with exactly those
   locks dropped and probe it. If it comes back satisfiable, every named
   guest gets one `unlock` recommendation (guest id and table id in the
   message, the same shape the single-removal unlock advice already uses)
   and **nothing else**: those unlocks alone restore feasibility, so no
   capacity advice may ride with them.
2. **Capacity probe.** Count pinned demand per table — each eligible,
   unreleased guest counts once toward each distinct table their chart pin
   and stored lock name; a released guest pins nothing. For the tables pinning
   more than they hold, probe the model with exactly those tables' capacity
   raised to their pinned count. If satisfiable, one `add_capacity`
   recommendation per table (table id, seated count and capacity in the
   message) and nothing else.
3. **Structural fallback.** If neither probe is satisfiable — the case is
   two structural causes at once, as a lock that pins a chart guest to a
   different table *beside* an overfull table, where unlocking alone leaves
   the overfull table and re-seating alone leaves the contradiction — both
   facts are named: one unlock per contradictory lock, one capacity per
   overfull table, each message claiming its own single fact. A final
   last-resort step names any remaining stored locks as pins they are, so
   that an infeasible event-day solve can never come back with an empty
   recommendation list.

```python
src/seating_planner/solver/hard.py   # the two import changes
from seating_planner.domain import Event, Table
...
from seating_planner.solver.report import (
    KIND_ADD_CAPACITY,
    KIND_MOVEMENT_LIMIT,
    KIND_UNLOCK,
    InfeasibilityReport,
    Recommendation,
    build_recommendations,
)
```

```python
src/seating_planner/solver/hard.py   # tail of _diagnose_event_day, after
    unlock = _probe_event_day_lock_removals(event, eligible, current, unlocked, seed, time_limit_s)
    shortfall = max(0, len(eligible) - sum(t.capacity for t in event.tables))
    recommendation = build_recommendations(
        {rule.id: rule.rule_type for rule in rules},
        conflict,
        capacity_shortfall=shortfall,
        has_tables=bool(event.tables),
        # The generic joint-conflict note names hard rules that must be
        # reviewed; with no enabled hard rule that advice is false, and
        # the lock removals (if any) are the whole report.
        suppress_generic_note=not rules,
    ) + tuple(unlock)
    if not recommendation:
        # The corner this bean exists for: no rule whose removal alone works,
        # no shortfall, no single lock the probe exonerates, and no enabled
        # hard rule to send the reader to, so the report would be empty.
        # Fill it with advice checked by a probe solve, never by counting.
        recommendation = _event_day_fallback_advice(
            event, eligible, current, unlocked, seed, time_limit_s
        )
    return InfeasibilityReport(conflict, shortfall, recommendation)
```

```python
src/seating_planner/solver/hard.py   # the new private function, in full
def _event_day_fallback_advice(
    event: Event,
    eligible: list[str],
    current: Mapping[str, str],
    unlocked: set[str],
    seed: int,
    time_limit_s: float,
) -> tuple[Recommendation, ...]:
    # Names what fills the tables when the one-removal diagnosis is empty,
    # and every remedy it can claim is first checked by re-solving the
    # relaxed pinned model under the same seed, worker and time-limit pins
    # as every other probe — the solver answers "would this help" exactly,
    # so the advice is verified rather than predicted. First the stored
    # locks: if removing all of them at once restores feasibility, each
    # locked guest is named in an unlock recommendation and nothing else is
    # advised, because those unlocks alone are enough. Then capacity: every
    # table whose pinned demand — day pins plus stored locks, one count per
    # guest per table, unlocked guests pin nothing — exceeds its capacity is
    # raised in a probe just enough; if that restores feasibility the
    # capacity recommendations name exactly those tables. Only if neither
    # remedy is provable alone (two structural causes at once, as a lock
    # that contradicts the chart beside an overfull table) are both named
    # structurally, and the list cannot come back empty while the model is
    # infeasible: with no rules and zero shortfall, infeasibility is a
    # contradictory lock or an overfull table.
    eligible_ids = set(eligible)
    named = [g for g in sorted(event.locks) if g in eligible_ids and g not in unlocked]
    if named:
        relaxed = Event(
            id=event.id,
            name=event.name,
            tables=event.tables,
            guests=event.guests,
            groups=event.groups,
            rules=event.rules,
            locks={g: t for g, t in event.locks.items() if g not in named},
        )
        if _probe_satisfiable(
            _build_event_day_model(relaxed, eligible, current, unlocked)[0],
            seed=seed,
            time_limit_s=time_limit_s,
        ):
            return tuple(
                Recommendation(
                    KIND_UNLOCK,
                    f"Guest {guest_id} is locked to table {event.locks[guest_id]}; "
                    "unlocking every one of these locks restores feasibility.",
                )
                for guest_id in named
            )
    load: dict[str, int] = {}
    for guest_id in eligible:
        if guest_id in unlocked:
            continue
        for table_id in {current.get(guest_id), event.locks.get(guest_id)}:
            if table_id is not None:
                load[table_id] = load.get(table_id, 0) + 1
    overfull = [t for t in event.tables if load.get(t.id, 0) > t.capacity]
    if overfull:
        over_ids = {t.id for t in overfull}
        tables = [
            Table(t.id, t.name, max(t.capacity, load[t.id]), t.shape, t.position)
            if t.id in over_ids
            else t
            for t in event.tables
        ]
        relaxed = Event(
            id=event.id,
            name=event.name,
            tables=tables,
            guests=event.guests,
            groups=event.groups,
            rules=event.rules,
            locks=event.locks,
        )
        if _probe_satisfiable(
            _build_event_day_model(relaxed, eligible, current, unlocked)[0],
            seed=seed,
            time_limit_s=time_limit_s,
        ):
            return tuple(
                Recommendation(
                    KIND_ADD_CAPACITY,
                    f"Table {t.id} is pinned to hold {load[t.id]} guests but holds only "
                    f"{t.capacity}; add {load[t.id] - t.capacity} seats to it.",
                )
                for t in overfull
            )
    # Neither remedy provable alone: name both structural fills. A lock that
    # pins a chart guest to a different table contradicts the pin; a table
    # whose pinned demand exceeds its capacity is filled past its hold. Each
    # message claims its own fact only.
    advice: list[Recommendation] = []
    for guest_id in named:
        chart_at = current.get(guest_id)
        if chart_at is not None and chart_at != event.locks[guest_id]:
            advice.append(
                Recommendation(
                    KIND_UNLOCK,
                    f"Guest {guest_id} is seated at {chart_at} by the chart but locked "
                    f"to {event.locks[guest_id]}; removing that lock resolves the "
                    "conflict between them.",
                )
            )
    for table in overfull:
        advice.append(
            Recommendation(
                KIND_ADD_CAPACITY,
                f"Table {table.id} is pinned to hold {load[table.id]} guests but holds "
                f"only {table.capacity}; add {load[table.id] - table.capacity} seats "
                "to it.",
            )
        )
    if not advice and named:
        # No structure was provable (a probe that spent its budget says
        # nothing), but these locks still pin this model: name them as the
        # pins they are. A report that names nothing was exactly the gap.
        for guest_id in named:
            advice.append(
                Recommendation(
                    KIND_UNLOCK,
                    f"Guest {guest_id} is locked to table {event.locks[guest_id]}; "
                    "removing the lock frees one pin of this chart.",
                )
            )
    return tuple(advice)
```

The module docstring's event-day paragraph gains the same five lines this
design is in one breath: when the one-removal diagnosis names nothing — no
rule, no shortfall, no single removal helps, no rule to review — a fallback
fills the report, first with unlock advice proven by a probe with every
stored lock dropped, else with capacity advice proven by a probe raising
every table whose pinned demand exceeds its capacity, else with both
structural facts named, so the report never comes back empty.

Why this fixes the three measurements from the earlier run's review: the
overfull chart with a locked new guest (part 3 of the probed test) takes the
capacity path because the unlock probe genuinely comes back infeasible —
the advice is decided by solves, not by who sits where; no table is ever
told to buy seats it could not use, because a capacity recommendation exists
only for a table whose pinned demand exceeds its capacity and only after the
probe with it re-seated succeeds; and a released chart guest contributes
nothing to the demand count, as part 4 of the probed test pins (one extra
seat, not two, restores feasibility).

## Risk

What could break, how it would show, how to back it out:

- **Reports that already advise must not change** (a bean constraint). The
  fallback sits behind `if not recommendation:`, which fires only on the
  currently-empty tuple, and every other line of `_diagnose_event_day` is
  unchanged. Notice: all 49 pre-existing solver tests plus the two shapes
  that already advised (rule conflict, shortfall) are regression-pinned in
  the new battery; ac4 reruns the whole `tests/solver` tree. In this
  session's dry-run, the entire solver test tree passed unchanged against
  the patched copy.
- **False advice.** Each sufficiency claim is made only after a probe solve
  proves it; in the structural corner the messages deliberately claim only
  their own fact ("resolves the conflict between them", not "restores
  feasibility"). Over-citing is the failure the probes exist to prevent,
  and the cost of under-citing is bounded: the last-resort step still names
  the pins.
- **Performance.** The fallback runs at most two extra CP-SAT solves, only
  on the solve that would otherwise return an empty report, and only after
  the existing diagnosis has already run its own probes.
- **Back out.** The change is one source file plus one new test file;
  reverting both restores today's behaviour exactly.

## Blast radius

Touched:

- `src/seating_planner/solver/hard.py` — one new private function
  (`_event_day_fallback_advice`), a capture-and-fallback at the end of
  `_diagnose_event_day` (event-day path only), two import additions, and a
  sentence in the module docstring.
- `tests/solver/test_event_day_advice.py` — new test file (four tests, four
  scenarios).

Not touched: `report.py` and `result.py` (the `Recommendation`/
`InfeasibilityReport` shapes and `build_recommendations` are unchanged, as
the bean requires), the `solve_event` signature, the planning and
low_disruption modes and their diagnosis, the single-removal probes,
pre-flight/feasibility, the store, the rules model, every existing test, and
no data format, API or deployment surface.

## Verification

| AC | Criterion | Verify |
|---|---|---|
| ac1 | An infeasible event-day solve always carries at least one recommendation | `pytest tests/solver/test_event_day_advice.py` — `test_infeasible_event_day_always_advises` |
| ac2 | Locks that overfill a table beside its chart guests are each named for unlocking; no hard-rule advice with no rules | `pytest tests/solver/test_event_day_advice.py` — `test_locks_that_overfill_a_table_are_named` |
| ac3 | A chart that overfills a table earns a capacity recommendation for that table; no hard-rule advice with no rules | `pytest tests/solver/test_event_day_advice.py` — `test_a_chart_that_overfills_a_table_asks_for_capacity` |
| ac4 | Every existing solver test still passes unchanged | `pytest -q tests/solver` |
| ac5 | Fallback advice is probe-checked: the named unlocks / re-seated tables restore feasibility, no capacity rides beside unlocks that alone suffice, ids are named | `pytest tests/solver/test_event_day_advice.py` — `test_fallback_advice_is_probed` |

(ac1, ac2, ac3 and ac5 all share the bean's single file-level verify command;
ac4's is its own. The task verifies run those at file level, plus
`ruff`/`mypy` on the touched source and the red-test helper on the new tests.)

Invariants, by name, from `factory/invariants/seating.yaml` (`seating-core`):
`inv-capacity`, `inv-one-table`, `inv-eligibility`, `inv-hard-rules`,
`inv-infeasible-is-total` and `inv-reproducible` are untouched by this change.
It appends advice text to reports that came back infeasible; no assignment is
ever produced, altered or validated a different way, and the probes reuse the
pinned seed/worker/time-limit of every existing diagnosis, so reproducibility
of the report follows from the reproducibility of the solves.

## Open questions

Assumptions I had to make, declared rather than hidden:

- **"Always" rests on the structure of the empty corner.** The fallback can
  only be reached with an empty base tuple, which (given
  `build_recommendations`' generic note) means the event has no enabled hard
  rule and the shortfall is zero. Under those two facts, an infeasible
  pinned model is caused by a contradictory lock or an overfull table —
  fix the pins and the free guests face only per-table upper bounds with
  enough total slack — so the three steps cannot come back empty, and the
  last-resort step covers the probe-undecided residue. I checked the
  argument by constructing the mixed corner (contradictory lock beside an
  overfull table, zero shortfall) against the real solver in this session:
  it returns infeasible with an empty base and the fallback names both
  structural fills. If the solver ever reports `infeasible` for a model that
  is actually satisfiable-but-unknown, the guarantee would not hold; today
  an undecided probe is simply not satisfiable, and the main solve refuses
  to call itself anything but `infeasible` when it is undecided
  (`SolverTimeout`).
- **Guest and table ids ride in the message text**, not in new
  `Recommendation` fields: the bean forbids changing the report shape, and
  the existing single-removal unlock advice already carries the guest id and
  table id the same way. The tests assert on the ids in the messages and on
  the kinds, never on prose.
- **The structural corner names both an unlock and capacity at once, where
  neither remedy alone restores feasibility.** That is the only case where a
  recommendation does not carry a sufficiency claim; ac5's probe property is
  asserted on the one-remedy scenarios, which are every case a single
  remedy can cover.
- **I could not run `pytest` in this session** (the container has no
  pytest, and the gates run in the digest-pinned gate image anyway). What I
  ran instead, on a scratch copy of the tree with ortools 9.15: the two
  measured empty-report cases against the current code (both infeasible with
  an empty recommendation list, as the bean says), all four new test
  functions called directly against both the unpatched code (each failing by
  assertion on report contents) and the patched code (all passing), all 49
  pre-existing solver tests passed against the patched copy, and
  `ruff check`, `ruff format --check` and `mypy strict` on the patched file.
  The authoritative `pytest` runs are the controller's verifies.
