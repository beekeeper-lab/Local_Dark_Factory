# bean-014 — Event-day mode seats new guests without moving anyone

## What and why

The seating planner today has two optimization modes on one entry point,
`solve_event`: **planning** re-solves every eligible guest from scratch
(locked guests pinned), and **low_disruption** re-solves against a given chart
with a hard cap on how many guests may change tables. Neither answers the
on-the-day question. On the day, the room is full of people; "which table does
Aunt Mary move to?" is a phone call from the floor, and moving an already-seated
guest means walking up to them mid-reception.

So this bean adds a third mode, `event_day`, which inverts the default: every
guest who already has a table is treated as locked — whether or not the
organizer ever set an explicit lock — and only genuinely new guests are free
variables. The acceptance criteria cover the two things that actually happen on
the day: a new guest arrives (they must take an open seat, hard rules intact,
and nobody else moves) and a guest cancels (their seat must free up with **no**
one shuffled into it). The cancellation case is the trap: a freed seat is an
improvement opportunity, and a solver that takes it — even to satisfy a soft
rule — has broken the mode. An automatic improvement on the day is a defect, not
a feature.

## Current behaviour

`solve_event` in `src/seating_planner/solver/hard.py` validates the mode
up-front and refuses arguments that do not apply to the given mode, never
reinterpreting them:

```python
# src/seating_planner/solver/hard.py (abridged)
PLANNING: Final[str] = "planning"
LOW_DISRUPTION: Final[str] = "low_disruption"

def solve_event(
    event: Event,
    *,
    mode: Literal["planning", "low_disruption"],
    current: Mapping[str, str] | None = None,
    movement_limit: int | None = None,
    time_limit_s: float = 10.0,
    seed: int = 0,
    num_search_workers: int = 1,
) -> SolveResult:
    if mode not in (PLANNING, LOW_DISRUPTION):
        raise ValueError(
            f"unknown optimization mode {mode!r}; allowed: {PLANNING!r} or {LOW_DISRUPTION!r}"
        )
    ...
```

Explicit locks are already pinned as fixed variables before any rule constraint:

```python
# src/seating_planner/solver/hard.py
def _apply_locks(
    model, event, at, skip_guest_id: str | None
) -> None:
    for guest_id, table_id in event.locks.items():
        if skip_guest_id is not None and guest_id == skip_guest_id:
            continue
        if guest_id not in at:
            continue
        model.Add(at[guest_id][table_id] == 1)
```

And `low_disruption` turns `current` into *movement indicators* — one boolean
per guest in the chart, forced true whenever they sit anywhere but their
current table — which the solver then **minimizes**, subject to
`movement_limit`. That is a count of how much motion is allowed, not a promise
that no one moves: a low-disruption solve happily moves g-2 to bank a soft-rule
score if the limit allows it. There is no mode in this tree where being on the
chart freezes a guest, and no notion of a guest who was explicitly let off that
freeze. `tests/solver/test_event_day.py` does not exist yet.

## Proposed change

**task-1 — the `event_day` mode and its three new-guest/hard-rule tests.**
`src/seating_planner/solver/hard.py` gains an `EVENT_DAY: Final[str] =
"event_day"` constant, the `mode` Literal is widened to the three spelled
modes, and `solve_event` gains one keyword argument:

```python
# src/seating_planner/solver/hard.py (illustrative)
def solve_event(
    event: Event,
    *,
    mode: Literal["planning", "low_disruption", "event_day"],
    current: Mapping[str, str] | None = None,
    movement_limit: int | None = None,
    unlocked: set[str] | None = None,  # event_day only: guests let off the day-lock
    time_limit_s: float = 10.0,
    seed: int = 0,
    num_search_workers: int = 1,
) -> SolveResult: ...
```

Validation follows the existing refuse-never-reinterpret style: in
`event_day`, `current` is required; a `current` entry naming a guest the event
does not have, or a table that no longer exists, is a `ValueError` (a table
that is gone cannot be pinned to); every id in `unlocked` must be a known
guest; `movement_limit` is rejected as not applying to the mode; and
`unlocked` is rejected in the other two modes. The new helper reuses the
existing single-phase machinery and adds a pin loop:

```python
# src/seating_planner/solver/hard.py (illustrative)
def _solve_event_day(event, eligible, current, unlocked, seed, time_limit_s) -> SolveResult:
    model, at, _ = _build_model(event, eligible)  # base model, no movement indicators
    for guest_id, table_id in current.items():
        if guest_id in unlocked or guest_id not in at:
            continue  # an explicit release, or an ineligible guest with no variables
        model.Add(at[guest_id][table_id] == 1)  # the day-lock: a fixed variable
    _add_soft_objective(model, event, at)
    return _solve_model(
        model, event, eligible, at,
        mode=EVENT_DAY, seed=seed, time_limit_s=time_limit_s,
        diagnose=_diagnose_infeasibility,
    )
```

The pins apply **regardless of `event.locks`** — the implicit day-lock is the
point — and there is deliberately no shortcut (no "everyone is pinned, so just
return the chart" early exit, no hand-off to planning) for the fully-pinned
case: the pinned model is solved, which by construction can only return the
frozen chart plus whatever the new guests were assigned. `tests/solver/test_event_day.py`
is created with the standard helpers and three tests:

```python
# tests/solver/test_event_day.py (illustrative — test_new_guest_respects_hard_rules)
def test_new_guest_respects_hard_rules() -> None:
    tables = [_table("t-1", capacity=3), _table("t-2", capacity=1)]
    guests = [_guest("g-0"), _guest("g-1"), _guest("g-3")]  # g-3 is new
    rules = [_hard("r-split", RuleType.DIFFERENT_TABLE, ("g-0", "g-3"))]
    event = _event(tables, guests, rules=rules)
    current = {"g-0": "t-1", "g-1": "t-1"}
    result = solve_event(event, mode="event_day", current=current)
    assert result.status == "feasible"
    assert result.assignments == {"g-0": "t-1", "g-1": "t-1", "g-3": "t-2"}
```

`test_new_guest_takes_open_seat` fills t-1 to capacity and leaves one seat open
at t-2, so the placement of the new guest is forced and asserted exactly,
nobody else moving. `test_existing_assignments_implicitly_locked` runs with
`event.locks == {}` and a heavy soft `same_table` rule that a move would
satisfy; it asserts the chart comes back unchanged, the rule reported violated,
score 0.

**task-2 — the cancellation trap and the explicit unlock.** One shared
scenario: t-1 capacity 3 holding g-0 and g-1, t-2 capacity 1 holding g-2, and a
soft `same_table(g-0, g-2)` rule whose full weight is won if g-2 moves into the
open seat at t-1. `test_cancellation_moves_nobody` cancels g-1 (status
`CANCELLED`, dropped from the chart) and asserts the remaining chart comes back
exactly as it was, score 0 — the freed seat is not an invitation.
`test_explicit_unlock_permits_move` is its mirror image: the full chart is
solved with `unlocked={"g-2"}`, and g-2 does move, banking the weight. Same
inputs, one argument apart, together they pin the mode's contract. If task-1's
implementation turns out to re-plan in the fully-pinned case, task-2 fixes
`hard.py`; it does not weaken either assertion.

## Risk

- *Shifting the shared validation dispatch.* The mode check and the per-mode
  argument checks live in one place that both existing modes already depend on;
  a slip could change planning or low_disruption behaviour. We would notice
  immediately: the existing suites (`test_modes.py`, `test_locks.py`,
  `test_low_disruption.py`, `test_determinism.py`, `test_infeasible.py`,
  `test_objective.py`) pin all of those modes and run in the unit gate, and the
  task-1 verify commands plus `mypy src` run before the gates do.
- *The fully-pinned model as a solver input.* When every variable is fixed, the
  soft objective is a constant and CP-SAT returns a fixed-status solve rather
  than raising `SolverTimeout`; the ac3/ac4 pair exercises exactly this shape,
  so a surprise there fails in-task, against a known chart.
- *Infeasibility misdiagnosis.* If the current chart itself breaks capacity or
  a hard rule, `event_day` is infeasible (nobody may move), but
  `_diagnose_infeasibility` probes pin-free models, so the report may blame the
  rule or capacity without naming the frozen chart. See open questions — this
  is a declared limit, not one of the five criteria.
- *Back-out.* The change is two files with no schema, store or wire-format
  impact (`SolveResult.mode` is a free-form string and the invariant seam never
  calls the new mode); reverting both files restores the prior tree.

## Blast radius

- **Touched — code:** `src/seating_planner/solver/hard.py` only: the mode
  constants, `solve_event`'s signature and validation, one new private helper,
  and the docstrings that describe the modes.
- **Touched — tests:** `tests/solver/test_event_day.py`, a new file; five
  acceptance test functions plus the module's standard helpers.
- **Not touched:** `solver/__init__.py` (exports unchanged — `solve_event` was
  always the entry point), `solver/result.py` (the `mode` field and `to_dict`
  already carry any spelled mode), `solver/report.py`, `solver/config.py`,
  `domain/` (no new field; "explicitly unlocked" is a solver argument, not
  stored data), `invariant_api.py` (still calls `mode="planning"`), `store/`,
  `tests/` beyond the new file, and every other bean's acceptance tests.
- **Callers:** the only in-repo caller of `solve_event` is `solve_from_spec`,
  and it hardcodes `planning`, so no existing behaviour changes for existing
  callers; the new mode has no callers outside the new tests.
- **Data and deployments:** none — no persisted shape, no wire format, no new
  dependency.

## Verification

The bean's acceptance criteria, claimed by tasks and verified by the controller:

| AC | Claim | verify | task |
|---|---|---|---|
| ac1 | Adding a guest with an open seat assigns them and moves nobody else | `python -m pytest tests/solver/test_event_day.py::test_new_guest_takes_open_seat` | task-1 |
| ac2 | Existing assignments are treated as locked even when no explicit lock was set | `python -m pytest tests/solver/test_event_day.py::test_existing_assignments_implicitly_locked` | task-1 |
| ac3 | Cancelling a guest frees their seat and moves no other guest | `python -m pytest tests/solver/test_event_day.py::test_cancellation_moves_nobody` | task-2 |
| ac4 | An explicitly unlocked guest may be moved in Event-day mode | `python -m pytest tests/solver/test_event_day.py::test_explicit_unlock_permits_move` | task-2 |
| ac5 | A new guest is placed only where every hard constraint holds | `python -m pytest tests/solver/test_event_day.py::test_new_guest_respects_hard_rules` | task-1 |

Per-task verify also runs `mypy src`; the gates then run on the finished tree:
`ruff check .`, `ruff format --check .`, `mypy src`, and the full suite
`pytest -q --cov=src --cov-fail-under=60`, which includes every pre-existing
mode test named in the Risk section. The bean declares no `invariants_ref`,
and the seated invariants from `factory/invariants/seating.yaml`
(`inv-capacity`, `inv-one-table`, `inv-eligibility`, `inv-hard-rules`,
`inv-infeasible-is-total`, `inv-reproducible`) run through the unchanged
`planning` seam, so they exercise this change only insofar as the shared model
code is shared.

## Open questions

- **"Explicitly unlocked" needs a home, and this bean cannot give it the domain.**
  FR-067 speaks of the *user* explicitly unlocking a guest; no domain field
  records such a release (`Event` has only explicit `locks`, and `domain/` is
  not a write path). The mode therefore takes a solver-level `unlocked` set —
  the honest mapping — and reading ac4 as "the guest's explicit `Event.locks`
  entry was removed" was rejected, because under that reading the guest stays
  day-locked and "may be moved" is unsatisfiable. A later UI/store bean can
  persist the release list and pass it down.
- **A `current` chart that names a deleted table** is rejected with a
  `ValueError` in `event_day`, unlike `low_disruption`, which degrades to "the
  move is forced". Pinning to a table that no longer exists has no model
  meaning, and rejecting fits the mode's refuse-never-reinterpret style.
- **Infeasible `event_day` diagnoses are approximate in one direction:** the
  one-removal probes are built without the pins, so a chart that conflicts with
  its own capacity or rules is reported infeasible with the cause possibly
  attributed to a rule or the capacity shortfall rather than "the current
  chart is unworkable as-is". No acceptance criterion covers it, and the
  recommendation vocabulary has no kind for pin conflicts; declaring it rather
  than probing pins into the diagnosis keeps the bean at its stated size.
- **An empty `current` chart is admitted** (and degrades to a plain placement
  of all new guests, recorded as `event_day`): consistent with the way
  `low_disruption` degrades when no chart guest is eligible, and the rejection
  of `None` keeps the "there is a chart on the day" contract.
