# bean-025 — Event-day unlock releases explicit locks, and a missing seat is not blamed on unrelated rules

## What and why

This repository is a wedding-seating optimizer. A `solve_event` call takes an
`Event` (tables, guests, hard and soft rules, per-guest locks) and returns a
chart — one table per eligible guest — or an infeasibility report naming what
is to blame. The solver has three modes, and this bean repairs two defects in
the third, `event_day`, which seats the wedding day in place: every guest who
is already on today's chart is implicitly pinned ("day-lock") to their table,
genuinely new guests are seated around them, and a guest can be released from
their pin by naming them in the `unlocked` argument of the call.

The two defects came out of bean-014's pre-merge review and were accepted into
this bean instead of blocking the merge. **First**: the day-lock pin is
correctly skipped for a guest in `unlocked`, but the model also applies every
entry of `event.locks`, so a guest who is both explicitly locked *and*
explicitly unlocked still cannot move and nothing says why. Measured on the
current tree: g-2 locked to t-2 and unlocked, with a weight-100 same-table
reason to join t-1 which has one open seat, stays at t-2 and the score stays
0. **Second**: when the event-day solve cannot seat a new guest, it hands its
infeasibility to the ordinary one-removal diagnosis, whose probe models are
built without the day-lock pins. A probe without the pins is a looser
problem — with almost every rule removable it stays solvable — so unrelated
hard rules (including ones the chart already satisfies) get named as the
cause, and the recommendation to relax one would not have freed a seat.
"Can't seat the new guest" is the most common failure of this mode, so the
diagnosis it reports matters.

The repairs are small and local: the unlock must beat an explicit lock when
applying locks in the event-day model, and the event-day diagnosis must probe
models that carry the same pins the main solve had.

## Current behaviour

Both code paths live in `src/seating_planner/solver/hard.py`. Today
`_solve_event_day` builds the base model and adds the day-lock pins itself,
but `_build_model` — the shared constructor — also applies every explicit
lock, and the `unlocked` argument never reaches the lock pass:

```python
# src/seating_planner/solver/hard.py, _solve_event_day (today)
model, at, _moves = _build_model(event, eligible)
# _build_model ends in: _apply_locks(model, event, at, skip_guest_id=None),
# i.e. EVERY event.locks entry is pinned, locked or unlocked alike.
# The day-lock skips the unlocked guests…
for guest_id, table_id in current.items():
    if guest_id in unlocked or guest_id not in at:
        continue
    model.Add(at[guest_id][table_id] == 1)
_add_soft_objective(model, event, at)
return _solve_model(
    ...,
    diagnose=_diagnose_infeasibility,   # …but the diagnosis is the ordinary one
)
```

and the diagnosis whose probes are missing the pins is:

```python
# src/seating_planner/solver/hard.py, _diagnose_infeasibility (today)
conflict: tuple[str, ...] = tuple(
    sorted(
        rule.id
        for rule in rules
        if _probe_satisfiable(
            _build_model(event, eligible, rule.id)[0],   # ← no day-lock pins
            seed=seed,
            time_limit_s=time_limit_s,
        )
    )
)
```

Reproduced from this tree before planning:

- ac1 scenario (`g-2` locked to t-2 **and** in `unlocked`, weight-100 pull
  toward t-1, one open seat at t-1) → `feasible`, `{'g-0': 't-1', 'g-1': 't-1',
  'g-2': 't-2'}`, rule `violated`, score 0. Same event without `unlocked` →
  identical chart: the unlock does nothing.
- ac2 scenario (new guest blocked by one hard rule that actually explains the
  missing seat, plus a bystander hard rule the chart already satisfies) →
  infeasible with `conflict_rule_ids == ('r-bystander', 'r-diff')`: the
  bystander is named beside the true cause, and the report recommends relaxing
  a rule that would not have helped.

## Proposed change

**task-1 — write the red tests** (`tests/solver/test_event_day_repairs.py`, a
new file; nothing under `src/` is touched). Two test functions, named exactly
as the bean's `test_id`s, in the style of `tests/solver/test_event_day.py`
(module docstring, `_table`/`_guest`/`_event`/`_soft`/`_hard` helpers,
assertions on result fields only). Both must fail today, by assertion on the
solve result — verified against this tree before this spec was written.

```python
# tests/solver/test_event_day_repairs.py (new file, task-1; scenarios condensed)

def test_unlock_releases_an_explicit_lock() -> None:
    # tables t-1 (cap 3) with g-0, g-1; t-2 (cap 1) with g-2; soft r-same
    # same_table weight 100 over (g-0, g-2); event.locks = {"g-2": "t-2"}.
    result = solve_event(event, mode="event_day", current=current, unlocked={"g-2"})
    assert result.assignments == {"g-0": "t-1", "g-1": "t-1", "g-2": "t-1"}
    assert result.rule_states["r-same"] == SATISFIED
    assert result.score == 100
    # …and the lock without an unlock still holds:
    held = solve_event(event, mode="event_day", current=current)
    assert held.assignments == current

def test_no_seat_blames_only_rules_that_explain_it() -> None:
    # A: 4 guests / 4 seats, g-3's only free seat next to g-2, hard r-diff
    #    (g-2, g-3) explains it, hard r-bystander (g-0, g-1) already holds.
    assert report.conflict_rule_ids == ("r-diff",)          # red today:
    assert [rec.rule_id for rec in fixes] == ["r-diff"]     # ("r-bystander", "r-diff")
    # B: capacity is the cause (one less seat, same bystander):
    assert tight_report.conflict_rule_ids == ()
    assert tight_report.capacity_shortfall == 1
    assert KIND_ADD_CAPACITY in kinds and KIND_CHANGE_HARD_RULE not in kinds
```

**task-2 — the fix in the solver** (`src/seating_planner/solver/hard.py` only;
`depends_on: task-1`). Two defects, one structural idea: the event-day model
has one shape, and its diagnosis probes that same shape.

1. Thread the `unlocked` set through `_build_model` (new optional keyword,
   defaulting to none) into `_apply_locks`, which skips a locked guest named
   in it. Planning/low-disruption call sites pass nothing, so a lock without
   an unlock still holds everywhere; `solve_event`'s signature is untouched.

2. Add `_event_day_model(event, eligible, current, unlocked,
   skip_rule_id=None)`, which moves the day-lock pin loop out of
   `_solve_event_day` and combines it with the (unlock-aware) base model.
   The main solve and the diagnosis probes both build through it, so a probe's
   satisfiability means what the main solve's infeasibility means.

3. Add `_diagnose_event_day`, mirroring `_diagnose_infeasibility` but
   probing the pinned model (`_event_day_model(..., skip_rule_id=rule.id)`)
   under the same seed/worker/time-limit pins, with the shortfall and
   `build_recommendations` exactly as today — so when no single removal helps,
   the report is capacity advice, not a rule-relaxation that would not help.
   `_solve_event_day` passes it to `_solve_model` as the `diagnose` callback
   bound to this run's `current` and `unlocked`, replacing the bare
   `_diagnose_infeasibility` reference in the event-day hand-off only.

```python
# src/seating_planner/solver/hard.py (task-2; new code, condensed)

def _event_day_model(event, eligible, current, unlocked, skip_rule_id=None):
    model, at, _moves = _build_model(event, eligible, skip_rule_id, unlocked=unlocked)
    for guest_id, table_id in current.items():      # the day-lock, moved here
        if guest_id in unlocked or guest_id not in at:
            continue
        model.Add(at[guest_id][table_id] == 1)
    return model, at

# in _apply_locks, the new release for defect 1:
        if unlocked is not None and guest_id in unlocked:
            continue   # an explicit unlock beats the stored lock

# in _solve_event_day, the diagnosis now probes the pinned model:
    model, at = _event_day_model(event, eligible, current, unlocked)
    _add_soft_objective(model, event, at)
    return _solve_model(
        ...,
        diagnose=lambda event_, eligible_, seed_, limit_s: _diagnose_event_day(
            event_, eligible_, seed_, limit_s, current=current, unlocked=unlocked,
        ),
    )
```

Against a private copy of the patched module, both scenarios came back as the
bean requires: the ac1 solve returns `g-2` at t-1 with the rule satisfied and
score 100 (nobody else moved); the ac2 scenario names exactly `('r-diff',)`
with a single `change_hard_rule` recommendation, and the capacity case keeps
`conflict_rule_ids == ()`, `capacity_shortfall == 1` and
`add_capacity`/`add_table` recommendations. The patched file also passes
`ruff check`/`ruff format --check` under the project settings and `mypy
--strict` in this container.

## Risk

What could break. The one function that gains a parameter, `_apply_locks`, is
shared by the whole model constructor — but the new parameter defaults to
none, and the two other modes reject `unlocked` at the validation door before
any model builds, so the planning and low-disruption paths are structurally
unaffected; `tests/solver/test_locks.py` exercises lock behaviour in planning
mode and is the tripwire. The diagnosis change only rewrites an infeasible
event-day result's report; the existing event-day tests all assert on
feasible solves, so the new infeasible-path code is covered by the new tests.
How you would notice: task-2's verifies run the new repair tests together
with `tests/solver/test_locks.py` (the lock-without-unlock constraint), then
the full `tests/solver` suite, so the fix is accepted only if the red tests
turn green without moving established lock behaviour; and the red-test check
fails if task-1's tests fail for any reason other than the two defects
(setup error, wrong-scenario assertion).
Back out: the diff is confined to `src/seating_planner/solver/hard.py` plus
one new test file — deleting the test file and reverting the one source file
restores the previous behaviour in full; there are no data, schema or
deployment effects to undo.

## Blast radius

Touched: exactly two files — `src/seating_planner/solver/hard.py` (internal
helpers `_build_model`, `_apply_locks`, `_solve_event_day` plus new
`_event_day_model` and `_diagnose_event_day`; the event-day path only) and the
new `tests/solver/test_event_day_repairs.py`. No other solver function, and
nothing in `domain/`, `rules/`, `report.py`, `result.py`, `store/` or
`feasibility/`, changes. The `solve_event` signature and `SolveResult` shape
are unchanged per the bean's constraints, and the planning/low-disruption
diagnoses are explicit non-goals, verified structurally (their call sites
pass no `unlocked` and keep `_diagnose_infeasibility`). Not touched: no API or
persistence format, no persisted data, no configuration, no deployment — this
is a library whose changes land through a human-merged pull request. Budget:
2 of 3 tasks, 2 of 3 files, roughly 260 of 350 diff lines (measured on the
private prototype: ~100 changed lines in `hard.py`, 160-line new test file).

## Verification

The gates (digest-pinned image) run `ruff check .`, `ruff format --check .`,
`mypy src`, and
`pytest -q --cov=src --cov-report=term-missing --cov-fail-under=60`. The bean
carries no `invariants_ref`, so no named invariants apply beyond the ACs; the
bean's constraints ("an explicit lock without an unlock still holds in every
mode"; "the `solve_event` signature and the result shape are unchanged") are
covered by the second solve in task-1's first test, `tests/solver/test_locks.py`
in the suite, and by the untouched public surface respectively.

| AC | Criterion | Verify |
|---|---|---|
| ac1 | A guest explicitly locked and also in `unlocked` may move when it raises the soft score, and nobody else moves | `pytest tests/solver/test_event_day_repairs.py::test_unlock_releases_an_explicit_lock` (bean's `kind: test`; task-2's first verify runs the whole file) |
| ac2 | A no-seat event-day solve names only hard rules whose removal alone solves it with every chart guest in place; recommends capacity when no removal helps | `pytest tests/solver/test_event_day_repairs.py::test_no_seat_blames_only_rules_that_explain_it` (bean's `kind: test`; task-2's first verify runs the whole file) |
| ac3 | Every existing solver test still passes unchanged | `pytest -q tests/solver` (task-2's second verify, run by the controller in the gate image) |

What I could not check from this container: pytest itself is absent here, so
the red-test verdict and the task verifies were not run as gates — I
executed both scenario functions manually with the container's Python and the
pinned `ortools` (red against `/work/src` by assertion, green against the
private patched copy), and ran `ruff`/`mypy --strict` at the gated versions on
the changed source. The controller's gate runs remain the verdict.

## Open questions

- **No `unlock` recommendations in the event-day diagnosis — assumed, not
  mandated.** `_diagnose_infeasibility` also probes *lock* removals and emits
  `KIND_UNLOCK` advice. In event-day, every chart guest is pinned by the
  day-lock irrespective of `event.locks`, and an unlocked guest's lock is
  already released in the main model — so removing a stored lock can never be
  what restores feasibility, and I assumed the event-day diagnosis probes hard
  rules only, matching ac2's "names only hard rules whose removal alone makes
  it solvable". If the owner wants lock advice in this mode too,
  `_diagnose_event_day` would need a pinned lock-removal probe.
- **"Recommends capacity when no rule removal would help" is satisfied via the
  existing `build_recommendations` vocabulary** — with an empty conflict and a
  positive shortfall it emits `add_capacity` and `add_table`, both of which
  the ac2 test asserts in some form. I assumed keeping the full vocabulary
  (rather than emitting a single capacity-only recommendation) is the intent.
- **The new test file carries the same `list[Rule]`-into-`list[object] | None`
  argument pattern as the existing test files**, which `mypy --strict` flags
  in tests but not in `src/`; the gate types `mypy src`, so this is
  consistent with the suite, not a new class of finding. Declared so it is a
  choice, not an oversight.
- I assumed the bean's "measured" numbers transfer verbatim to its scenarios —
  they did: both defects reproduced from this exact tree before the spec was
  written, using the bean's own measurements (locked g-2 with a weight-100
  reason to join t-1; a chart-satisfying hard `different_table` rule named
  beside the real cause).
