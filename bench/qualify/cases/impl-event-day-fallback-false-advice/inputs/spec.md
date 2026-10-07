# Bean-031 — An infeasible event-day report always says what to do

## What and why

This repo is a wedding seating planner. Every guest sits at exactly one table, no
table seats more than its capacity, and "hard rules" (like "keep these two guests
at different tables") are constraints the solver must never violate. The
`event_day` mode is the day-of-the-event re-solve: every guest already on the
current chart is implicitly pinned to their current table (that pinning is the
whole point of the mode), and the only free variables are genuinely new guests
plus any guest the caller explicitly unlocked.

When an event-day solve comes back infeasible, the result carries an
`InfeasibilityReport` with a list of corrective-action recommendations
(`unlock`, `add_capacity`, `add_table`, `change_hard_rule`). A long-standing
requirement (bean-010's lineage) is that **at least one recommendation is always
named** — a report with zero advice is unusable on the day of the event.

Bean-025 deliberately tightened the diagnosis: with no enabled hard rule, the
generic "review the hard rules" note is now withheld (there is nothing to
review), and a lock is named only when removing *that one lock alone* restores
feasibility. Both changes are correct on their own — but together they open a
hole. There are infeasible event-day solves where no single removal helps,
there is no seat shortfall, and there are no rules to review, and the report
then comes back with an **empty** recommendation list. Two cases were measured
on the merged main and both reproduce the empty report today:

1. Three new guests are each stored-locked to a table that has one free seat
   (removing any one lock still leaves two locked guests for one seat).
2. The chart itself seats three guests at a two-seat table (chart capacity is
   not checked on input, so this chart is legal to pass in).

This bean closes the hole: when the existing diagnosis names nothing, the
report still names what fills the table — the stored locks that pin guests to
it (recommend unlocking, each locked guest named), or the chart that seats
more guests there than it holds (recommend capacity for that table).

## Current behaviour

The event-day diagnosis lives in `_diagnose_event_day`
(`src/seating_planner/solver/hard.py`). It builds the report from three pieces:
one-removal probes for each enabled hard rule (`conflict`), one-removal probes
for each stored lock (`_probe_event_day_lock_removals`, only locks whose single
removal restores feasibility are named), and the shared
`build_recommendations` helper (`src/seating_planner/solver/report.py`):

```python
src/seating_planner/solver/hard.py   # tail of _diagnose_event_day, today
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
```

Every branch that can fire is conditional: the capacity advice needs
`capacity_shortfall > 0`, the rule advice needs a rule that a single-removal
probe exonerates, the unlock advice needs a single lock whose removal alone
works, and the generic note is suppressed exactly when `rules` is empty. With
no rules, zero shortfall, and no single lock or rule removal sufficient — the
two measured cases — the `recommendations` tuple is empty. The report still
exists (status is `infeasible`, `shortfall` 0, `conflict_rule_ids` empty);
only the corrections list is nothing.

## Proposed change

Two tasks. Task 1 writes the red tests; task 2 implements the fallback in the
solver. The code below was checked against this repo's ruff lint/format
settings and mypy strict before being written down.

### Task 1 — red tests in `tests/solver/test_event_day_advice.py`

A new test file, following the conventions of `tests/solver/test_event_day_repairs.py`
(same small `_table`/`_guest`/`_event`/`_hard` helpers, asserts only on
`solve_event` result fields, never solver internals). Three tests, backed by
four scenario helpers:

- `_locked_scenario()` — ac2's measured case: tables `t-1` (capacity 3) and
  `t-2` (capacity 3); chart pins `g-0`, `g-1` at `t-1` and `g-4` at `t-2`; new
  guests `n-1`, `n-2`, `n-3` each stored-locked to `t-1`; no rules. Six guests,
  six seats, so `capacity_shortfall == 0`. Infeasible, because `t-1` must hold
  two pinned plus three locked guests. No single lock removal helps: two
  locked guests still crowd one seat.
- `_overfull_chart_scenario()` — ac3's measured case: tables `t-1` (capacity 2)
  and `t-2` (capacity 2); chart pins `g-0`, `g-1`, `g-2` at `t-1` and `g-3` at
  `t-2`; no rules, no locks. Four guests, four seats. Infeasible because the
  day pins force three guests onto a two-seat table.
- `_rule_conflict_scenario()` and `_shortfall_scenario()` — the two infeasible
  shapes that *already* advised before this bean (a hard `different_table`
  rule whose removal seats the new guest; and a pure one-seat shortfall). They
  are in the "always" battery so the property is regression-pinned on both
  old and new paths.

```python
tests/solver/test_event_day_advice.py
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
    assert "n-1" in messages
    assert "n-2" in messages
    assert "n-3" in messages
    assert all("t-1" in rec.message for rec in unlocks)
    # The event has no hard rules, so the report says nothing about reviewing
    # any.
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
```

(Plus the four scenario helpers and the standard import/helper block from
`tests/solver/test_event_day_repairs.py`; the full file is sketched here in
full in the task's own session context — the worker writes it exactly as this
section and `task-1`'s intent describe.)

These tests are red today: in the two new scenarios the report exists but its
`recommendations` is the empty tuple, so the assertions fail on project output
— not on test setup — which is what the red-test helper requires.

### Task 2 — the fallback in `src/seating_planner/solver/hard.py`

Capture what `_diagnose_event_day` already computes, and only when that tuple
is empty (the hole), fill it from a new pure helper. Nothing else in the file
changes; the solver gains **no extra solve calls** — the fallback is arithmetic
over the event, chart and locks only:

```python
src/seating_planner/solver/hard.py   # _diagnose_event_day, after
    recommendation = (
        build_recommendations(
            {rule.id: rule.rule_type for rule in rules},
            conflict,
            capacity_shortfall=shortfall,
            has_tables=bool(event.tables),
            suppress_generic_note=not rules,
        )
        + tuple(unlock),
    )
    if not recommendation:
        # The corner this bean exists for: no rule whose removal alone works,
        # no shortfall to name, no lock a single removal exonerates, and no
        # enabled hard rule to send the reader to. The infeasibility is then
        # pinned by arithmetic alone, and the advice names what fills it.
        recommendation = _event_day_fallback_advice(event, eligible, current, unlocked)
    return InfeasibilityReport(conflict, shortfall, recommendation)
```

```python
src/seating_planner/solver/hard.py   # new private helper (add the KIND_ADD_CAPACITY import)
def _event_day_fallback_advice(
    event: Event,
    eligible: list[str],
    current: Mapping[str, str],
    unlocked: set[str],
) -> tuple[Recommendation, ...]:
    # Empty-report corner: the one-removal probes named nothing, the seat
    # shortfall is zero, and the generic note is suppressed because the event
    # has no enabled hard rule. The infeasibility is then pinned by
    # arithmetic, not by any single lock or rule: it is a stored lock that
    # points a chart guest to a table different from the chart, and/or a
    # table whose pinned demand exceeds its capacity. Name what fills it —
    # one unlock recommendation per responsible lock, or capacity for the
    # table the chart alone overfills — so the report is never empty.
    eligible_ids = set(eligible)
    contradictions: list[tuple[str, str, str]] = []
    day_pinned: dict[str, int] = {}
    lockers: dict[str, list[str]] = {}
    for guest_id in eligible:
        chart = current.get(guest_id)
        if chart is None:
            continue
        day_pinned[chart] = day_pinned.get(chart, 0) + 1
    for guest_id in sorted(event.locks):
        if guest_id not in eligible_ids or guest_id in unlocked:
            continue
        locked_to = event.locks[guest_id]
        if current.get(guest_id) == locked_to:
            # A lock consistent with the chart: the day lock already pins this
            # guest here, so removing it changes nothing and the lock is not
            # named (matches the single-removal probes).
            continue
        lockers.setdefault(locked_to, []).append(guest_id)
        if guest_id in current:
            contradictions.append((guest_id, current[guest_id], locked_to))
    advice: list[Recommendation] = []
    for guest_id, chart_at, locked_to in contradictions:
        advice.append(
            Recommendation(
                KIND_UNLOCK,
                f"Guest {guest_id} is seated at {chart_at} by the chart but "
                f"locked to {locked_to}; unlocking their lock resolves the "
                "conflict.",
            )
        )
    for table in event.tables:
        table_id = table.id
        demand = day_pinned.get(table_id, 0) + len(lockers.get(table_id, ()))
        if demand <= table.capacity:
            continue
        # Contradiction locks are already named above; only locks the table
        # itself overfills with get the overfull-table advice.
        responsible = [g for g in lockers.get(table_id, ()) if g not in current]
        if responsible:
            for guest_id in responsible:
                advice.append(
                    Recommendation(
                        KIND_UNLOCK,
                        f"Guest {guest_id} is locked to table {table_id}, which "
                        f"already holds {day_pinned.get(table_id, 0)} pinned "
                        "chart guests; unlocking it is needed to clear this "
                        "table.",
                    )
                )
        else:
            advice.append(
                Recommendation(
                    KIND_ADD_CAPACITY,
                    f"The chart seats {day_pinned.get(table_id, 0)} guests at "
                    f"table {table_id}, which holds {table.capacity}; add "
                    "capacity to that table.",
                )
            )
    return tuple(advice)
```

The classification, checked out before writing: every eligible guest is either
pinned by the chart, pinned by a lock, both (a contradiction when the two names
different tables), or free. With no rules, zero shortfall, and no table whose
pinned demand exceeds capacity, a valid assignment exists by construction
(fix the pinned guests; free guests face only per-table upper bounds with
enough total slack), so when the pinned model is infeasible the fallback must
find either a contradiction lock or an overfull table — the recommendation
list cannot be empty. A lock consistent with the chart is never named: the day
lock pins the guest there anyway, exactly as the single-removal probe
behaviour in `_probe_event_day_lock_removals` already treats it.

## Risk

What could break:

- **Reports that already advise must not change** (a bean constraint). The
  fallback runs only in the `if not recommendation` branch, which is precisely
  the currently-empty report; every other byte of `_diagnose_event_day` is
  untouched, so no existing recommendation list gains or loses an entry.
- **False advice.** The fallback names a lock only when the arithmetic says
  demand at that table exceeds capacity, or the lock contradicts the chart —
  and the message deliberately says the unlock is "needed to clear this
  table", not "restores feasibility" (that claim is reserved for the probed,
  proven single-removal case). The risk accepted is that in a mixed case the
  report may name a lock whose removal is necessary but not sufficient; the
  bean's own wording ("names what fills the table") asks for exactly that.
- **Performance.** None: the helper is pure counting, no CP-SAT calls, no new
  imports beyond the existing `report` module.
- **Notice.** `pytest -q tests/solver` (ac4) pins every existing solver test,
  the new file pins the property, and the run's hidden-test gate was written
  from the same acceptance criteria. **Back out:** the change is one file
  (`hard.py`) plus one new test file; reverting both restores today's behaviour
  exactly.

## Blast radius

Touched:

- `src/seating_planner/solver/hard.py` — one new private function and a three
  line change at the end of `_diagnose_event_day` (event-day path only).
- `tests/solver/test_event_day_advice.py` — new test file.

Not touched: `report.py` and `result.py` (the `Recommendation`/
`InfeasibilityReport` shapes and `build_recommendations` are unchanged), the
`solve_event` signature, all other modes (planning, low_disruption) and their
diagnosis, pre-flight/feasibility, the store, the rules model, and all
existing tests. No data migrations, no API change, no deployment surface.

## Verification

| AC | Criterion | Verify |
|---|---|---|
| ac1 | An infeasible event-day solve always carries at least one recommendation | `pytest tests/solver/test_event_day_advice.py::test_infeasible_event_day_always_advises` |
| ac2 | Locks that overfill a table beside its chart guests are named (each locked guest, per unlock recommendation), no hard-rule advice when there are no rules | `pytest tests/solver/test_event_day_advice.py::test_locks_that_overfill_a_table_are_named` |
| ac3 | A chart that overfills a table earns a capacity recommendation for that table, no hard-rule advice when there are no rules | `pytest tests/solver/test_event_day_advice.py::test_a_chart_that_overfills_a_table_asks_for_capacity` |
| ac4 | Every existing solver test still passes unchanged | `pytest -q tests/solver` |

Invariants (by name, from `factory/invariants/seating.yaml`, `seating-core`):
untouched by this change — `inv-capacity` binds assignment answers, and this
bean only appends advice text to infeasible reports; no assignment is ever
produced or altered.

## Open questions

Assumptions I had to make, declared here rather than hidden:

- **"Always" is guaranteed by the arithmetic argument in Proposed change**,
  not by an exhaustive case split: the fallback is proven non-empty whenever
  the pinned model is infeasible and the existing diagnosis is empty. I assume
  the solver never returns `infeasible` from a model that is actually
  satisfiable-but-unknown (it raises `SolverTimeout` for undecided instead).
- **One `unlock` recommendation per responsible locked guest** (so ac2 asserts
  exactly three in the measured case), and one `add_capacity` recommendation
  per overfull chart-only table. The bean says "names each locked guest" and
  "recommends capacity for that table"; per-guest recommendations are the most
  direct reading and match how the probed single-removal case already formats
  unlock advice.
- **A stored lock on an ineligible guest and a lock the `unlocked` set
  releases are ignored** in the fallback, mirroring `_apply_locks`.
- **I could not run the scenarios in this session**: this container has no
  ortools, so `solve_event` cannot be executed here. The arithmetic of all
  four scenarios was checked by hand against `_build_event_day_model` and
  `_apply_locks`, and the two measured cases are taken from the bean
  background's own measurements; task 1's red-test verify (which runs in the
  gate image) will confirm the tests fail on project output, not setup, before
  task 2 ever runs.
- **Message wording** ("…already holds N pinned chart guests; unlocking it is
  needed to clear this table") is mine; the acceptance criteria and tests pin
  the kinds, the guest/table ids in the message, and the absence of
  kind `change_hard_rule`, not prose.
