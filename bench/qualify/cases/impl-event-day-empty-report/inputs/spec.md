# bean-025 — Event-day unlock releases explicit locks, and a missing seat is not blamed on unrelated rules

## What and why

This repository is a wedding-seating optimizer. A `solve_event` call takes an
`Event` (tables with capacities, guests with RSVP status, hard and soft rules,
and per-guest locks) and returns a chart — one table per eligible guest — or,
when no chart satisfies the hard constraints, an infeasibility report that
names what is to blame: the enabled hard rules whose removal alone would
restore feasibility, the seat shortfall, and recommendations drawn from a
fixed vocabulary (add capacity / table, relax a hard rule, unlock a guest).
The solver has three modes. This bean repairs the third, `event_day`, which
seats the wedding day in place: every guest who is already on today's chart is
implicitly pinned to their table — the "day-lock", which exists whether or not
`event.locks` names them — genuinely new guests are seated around the pinned
ones, and a pinned guest can be released by naming them in the call's
`unlocked` argument.

Three defects, each measured against this tree. **First**: the day-lock pin
correctly skips a guest in `unlocked`, but the base model still applies every
entry of `event.locks`, so a guest who is both explicitly locked *and*
explicitly unlocked still cannot move, and nothing says why — the measured
case, g-2 locked to t-2 and unlocked with a weight-100 reason to join a
nearby table, simply stays put. **Second**: when the event-day solve cannot
seat a new guest, it reports infeasibility through the ordinary diagnosis,
whose probe models are built *without* the day-lock pins. Unpinned, removing
almost any hard rule leaves something solvable, so a hard rule the chart
already satisfies gets named beside the rule that actually explains the
missing seat, and the advice to relax it would not have freed a seat.
"No seat for the new guest" is the most common way this mode fails. **Third**
— found by the previous run's repair and now folded into this bean
(acceptance criterion ac4): a stored lock can be the *only* thing making the
event-day solve infeasible (a new guest locked to a table the chart already
fills, or a chart guest whose lock names a different table and who is not
unlocked), and the diagnosis must say so — recommend unlocking that guest —
and when the event has no hard rule it must not advise reviewing hard rules
that do not exist. The repairs are local: the unlock must beat an explicit
lock when the event-day model is built, and the event-day diagnosis must
probe models pinned exactly like the solve, rules *and* locks alike.

## Current behaviour

All three code paths live in `src/seating_planner/solver/hard.py`. The
event-day solve builds the shared base model and adds the day-lock pins
itself, but `_build_model` — the constructor every mode and every diagnosis
probe uses — already applies every explicit lock, and the `unlocked`
argument only reaches the pin loop:

```python
# src/seating_planner/solver/hard.py — _solve_event_day (today)
model, at, _moves = _build_model(event, eligible)   # applies EVERY event.locks entry
# The day-lock skips the unlocked guests…
for guest_id, table_id in current.items():
    if guest_id in unlocked or guest_id not in at:
        continue
    model.Add(at[guest_id][table_id] == 1)
_add_soft_objective(model, event, at)
return _solve_model(
    ...,
    diagnose=_diagnose_infeasibility,   # …but the diagnosis probes the UNpinned model
)
```

and `_apply_locks` — called by `_build_model` at the end of construction —
only knows how to skip one guest for the lock probe, never the unlocked set:

```python
# src/seating_planner/solver/hard.py — _apply_locks (today)
for guest_id, table_id in event.locks.items():
    if skip_guest_id is not None and guest_id == skip_guest_id:
        continue
    if guest_id not in at:
        continue
    model.Add(at[guest_id][table_id] == 1)
```

The diagnosis both defects of the second kind share is the ordinary
one-removal one: rule probes drop one hard rule from an **unpinned** model,
lock probes drop one lock from an **unpinned** model, and the recommendation
builder that follows is shared:

```python
# src/seating_planner/solver/hard.py — _diagnose_infeasibility (today, excerpt)
conflict: tuple[str, ...] = tuple(
    sorted(
        rule.id
        for rule in rules
        if _probe_satisfiable(_build_model(event, eligible, rule.id)[0], ...)   # no day-lock pins
    )
)
unlock = _probe_lock_removals(event, eligible, seed, time_limit_s)              # no pins either
```

```python
# src/seating_planner/solver/report.py — build_recommendations (today, tail)
if not recommendations:
    # The joint-conflict case: no single removal restores feasibility.
    recommendations.append(
        Recommendation(
            KIND_CHANGE_HARD_RULE,
            "The enabled hard rules are jointly unsatisfiable; at least one "
            "of them must be reviewed.",
            ...)
    )
```

Reading these against the three measured scenarios (arithmetic worked out
from this code; the container has no runnable solver, so this is by
inspection, not execution — see Verification):

- **Defect 1** — g-2 locked to t-2 and passed in `unlocked`: `_build_model`
  pins `at[g-2][t-2] == 1`, the pin loop skips g-2, and the objective cannot
  move them: the chart comes back unchanged, the soft rule violated, score 0.
- **Defect 2** — new guest whose only free seat is forbidden by one hard
  rule, with a second hard rule the chart already satisfies: both rule
  probes are sat on the unpinned model (unpinned, the pinned-away seat is
  free again), so `conflict_rule_ids` names the bystander beside the real
  cause, and the report recommends relaxing the bystander.
- **Defect 3** — a no-rule event made infeasible by a stored lock alone
  (e.g. new guest locked to the table the chart fills): `conflict_rule_ids`
  is empty and the shortfall is zero, so `build_recommendations` falls into
  its generic branch and advises reviewing *the enabled hard rules* — of
  which there are none — while the unpinned lock probe happens to name the
  unlock next to it.

## Proposed change

Three tasks, in order; only `hard.py`, `report.py` and the new test file are
touched.

**task-1 — the red tests**
(`tests/solver/test_event_day_repairs.py`, a new file; nothing under `src/`).
Three test functions, named exactly as the bean's `test_id`s, in the style of
`tests/solver/test_event_day.py` (module docstring, `_table`/`_guest`/
`_event`/`_soft`/`_hard` helpers, assertions on result fields only). Scenarios
condensed:

```python
# tests/solver/test_event_day_repairs.py (new file, task-1; scenarios condensed)

def test_unlock_releases_an_explicit_lock() -> None:
    # t-1 cap 3: g-0, g-1 · t-2 cap 1: g-2 · soft same_table w100 (g-0, g-2)
    # event.locks == {"g-2": "t-2"}, chart as above, solved with unlocked={"g-2"}
    assert result.assignments == {"g-0": "t-1", "g-1": "t-1", "g-2": "t-1"}
    assert result.rule_states["r-same"] == SATISFIED
    assert result.score == 100
    # same event and chart again, WITHOUT unlocked: the lock still holds
    assert held.assignments == current
    assert held.score == 0

def test_no_seat_blames_only_rules_that_explain_it() -> None:
    # A: 4 guests / 4 seats, pinned g-0,g-1 at t-1, g-2 at t-2, new g-3;
    # hard r-diff (g-2, g-3) explains the missing seat; hard r-bystander
    # (g-0, g-1) already satisfied by the chart.
    assert report.capacity_shortfall == 0
    assert report.conflict_rule_ids == ("r-diff",)
    cr = [r.rule_id for r in report.recommendations if r.kind == KIND_CHANGE_HARD_RULE]
    assert cr == ["r-diff"]
    # B: same chart, 3 seats, only r-bystander — the shortfall is the cause
    assert tight_report.conflict_rule_ids == ()
    assert tight_report.capacity_shortfall == 1
    # A and B both: add capacity is on the table when the shortfall says so,
    # and no change_hard_rule advice rides along where it would not help.

def test_a_lock_that_causes_no_seat_is_named() -> None:
    # A: no rules; g-3 NEW, locked to t-1, which the chart already fills.
    # B: no rules; chart guest g-2 locked to t-1 while the chart has t-2,
    #    not unlocked — the day-lock and the lock pin one guest twice.
    assert no_rules_report.conflict_rule_ids == ()
    unlock_recs = [r for r in no_rules_report.recommendations if r.kind == KIND_UNLOCK]
    assert len(unlock_recs) == 1            # the locked guest, their table named
    assert not any(r.kind == KIND_CHANGE_HARD_RULE for r in no_rules_report.recommendations)
```

**task-2 — the unlock releases the lock** (`hard.py` only). One keyword, one
skip: `_build_model` gains an optional set-valued keyword (absent by default)
carrying the unlocked ids; `_apply_locks` receives it and skips a lock whose
guest it names; `_solve_event_day` passes its `unlocked` through. Planning
and low_disruption call sites — every diagnosis probe included — pass the
default, so a lock nobody released still pins in every mode, `solve_event`'s
signature is untouched, and this task does not restructure anything else.
Verified red by task-1's helper, this test goes green on the first solve
taking g-2 to t-1; the second solve (no unlock) was green all along and stays
the tripwire for the lock-without-unlock constraint.

**task-3 — the diagnosis probes the pinned model** (`hard.py` + one addition
in `report.py`).

1. The event-day model shape gathers into one builder — base model
   (unlocked-aware via task-2) plus the day-lock pin loop moved out of
   `_solve_event_day`, plus the same optional skipped-rule id the probes use:

```python
# src/seating_planner/solver/hard.py (task-3; condensed)
def _event_day_model(event, eligible, current, unlocked, skip_rule_id=None):
    model, at, _moves = _build_model(event, eligible, skip_rule_id, unlocked=unlocked)
    for guest_id, table_id in current.items():       # the day-lock, moved here
        if guest_id in unlocked or guest_id not in at:
            continue
        model.Add(at[guest_id][table_id] == 1)
    return model, at
```

2. A new event-day diagnosis mirrors `_diagnose_infeasibility` against that
   builder under the same seed/single-worker/time-limit pins: a hard rule is
   named only when the **pinned** model without it is sat — so the bystander
   rule stops being named, and when nothing helps the existing shortfall
   computation yields the capacity advice — and, the half the run-1 repair
   dropped, each stored lock on an eligible guest is probed the same way with
   the model built from all other event data and only that lock removed
   (reconstructed exactly as `_probe_lock_removals` already does), and the
   unlock is recommended only when that pinned probe is sat. A lock
   consistent with the chart is never named (the day-lock still pins the
   guest), and an unlocked guest's already-released lock never is.
3. The generic "the enabled hard rules are jointly unsatisfiable" note in
   `build_recommendations` gains one optional keyword, defaulted so
   planning, low-disruption and the zero-tables shortcut keep byte-identical
   output; the event-day diagnosis suppresses the note only when the event
   has no enabled hard rule — the exact case in which it is false.
4. Only `_solve_event_day`'s hand-off changes: its `diagnose` callback
   becomes the new diagnosis bound to this run's chart and unlocked set
   (same callback type as today); planning and low_disruption keep their
   diagnoses. Docstrings updated to state the pinned probing.

I could not execute any scenario from this container — see Verification —
but the arithmetic of each red point was worked through against the code
quoted above: post-fix, scenario A names exactly `("r-diff",)` because the
pinned probe without r-diff can seat g-3 in t-2 while the pinned probe
without r-bystander still forbids it; scenario B's probes are all
infeasible (a seat short) so the report is shortfall advice; the lock
scenarios' pinned removal probes are sat, so the unlock is the sole named
cause in rule-less events.

## Risk

What could break. `_build_model` is the shared constructor of every mode and
every diagnosis probe, so the new unlocked keyword is the highest-leverage
line in the change; it is mitigated twice — the keyword defaults to absent,
and the planning/low_disruption paths reject an `unlocked` argument at the
validation door before any model builds, so no non-event-day call site can
pass it, while `tests/solver/test_locks.py` (lock-holds in planning mode, and
the lock-versus-rule conflict that must keep naming *both* sides) is the
behavioural tripwire wired into both fix tasks' verifies. The diagnosis
change only rewrites the report attached to *infeasible* event-day results,
and every existing event-day test asserts on feasible solves, so the new
infeasible-path code is exercised by the three new tests and the full
suite. The `report.py` keyword is additive with a default that preserves
every existing call site's output byte-for-byte, so it cannot change
planning or low-disruption reports absent an error the suite would catch.
How you would notice: the verifies are sequenced so each fails before the
work — task-1's red-test helper refuses a file whose tests pass or fail in
setup, task-2's verify is red on the assignment the lock outlives, task-3's
is red on the bystander rule and the generic no-rule note — and green only
behaviourally, with the full `tests/solver` run last. Back out: two source
files plus one new test file; restoring the two and deleting the third puts
the tree back in full, with no data, schema, API or deployment effects to
undo.

## Blast radius

Touched: three files — `src/seating_planner/solver/hard.py` (the
`_build_model`/`_apply_locks` keyword, an `_event_day_model` builder, an
event-day diagnosis with pinned rule and lock probes, `_solve_event_day`'s
hand-off, and docstrings), `src/seating_planner/solver/report.py` (one
additive keyword on `build_recommendations` and its docstring), and the new
`tests/solver/test_event_day_repairs.py`. Not touched, explicitly: the
planning and low_disruption solves and diagnoses (their call sites pass no
unlocked set and keep their current `diagnose` callbacks — the bean's
non-goals), everything in `domain/`, `rules/`, `store/`, `feasibility/` and
`invariant_api.py`, the `solve_event` signature and the `SolveResult`
shape (the bean's constraints), any persisted data, configuration or
deployment artifact — this is a library delivered through a human-merged
pull request. Budget: 3 of 3 tasks, 3 of 3 files; the measured run of this
plan's predecessor (this bean, previous revision) cost 294 diff lines for two
less tests and no `report.py` change, and this plan targets roughly 330
lines — under the 350 ceiling, with the task intents directed at compact
tests because the margin is the new third test plus the lock probes.

## Verification

| AC | Criterion | Verify |
|---|---|---|
| ac1 | A guest explicitly locked and also in `unlocked` may move when it raises the soft score, and nobody else moves | `pytest tests/solver/test_event_day_repairs.py::test_unlock_releases_an_explicit_lock` (bean's `kind: test`); task-1's red-test verify and task-2's `pytest` (together with `test_locks.py`) |
| ac2 | A no-seat event-day solve names only hard rules whose removal alone solves it with every chart guest in place; recommends capacity when no removal helps | `pytest tests/solver/test_event_day_repairs.py::test_no_seat_blames_only_rules_that_explain_it` (bean's `kind: test`); task-3's first verify runs the whole new file |
| ac3 | Every existing solver test still passes unchanged | `pytest -q tests/solver` (task-3's second verify) |
| ac4 | A stored lock that alone makes the event-day solve infeasible is recommended for unlocking, and a rule-less event is not advised to review hard rules | `pytest tests/solver/test_event_day_repairs.py::test_a_lock_that_causes_no_seat_is_named` (bean's `kind: test`); task-3's first verify |

The gates (digest-pinned image) additionally run `ruff check .`, `ruff
format --check .`, `mypy src` and the coverage-floor suite; the bean carries
no `invariants_ref`, so no named invariants apply beyond the ACs. The bean's
constraints ride structurally: `solve_event` and `SolveResult` are never
re-declared, the lock-without-unlock behaviour is pinned by
`tests/solver/test_locks.py` in both fix tasks' verifies, and the
non-goals by the untouched planning/low-disruption call sites.

What I could not check from this container: there is no pytest and no
installable solver runtime here (the container has `python3`, `ruff` and
`mypy`, but not the project's `ortools` dependency in its path), so none of
the three scenarios was executed — not pre-fix, not against a patched copy —
and the red points were established by reading the code paths quoted in
Current behaviour and computing each model's pins and seat arithmetic by
hand, including each probe's satisfiability. That is exactly what task-1's
`red-test.py` verify re-establishes mechanically in the gate image before
any fix attempt runs; the gate verdict remains the verdict.

## Open questions

- **The suppression of the generic note is an additive keyword on
  `build_recommendations`, assumed not precluded.** I assumed adding a
  defaulted keyword to a shared pure helper — with every existing call site
  left exactly as it is — respects the non-goal "no change to the planning or
  low-disruption diagnosis"; filtering the note back out inside `hard.py`
  after the fact was the alternative and was rejected as roundabout. The
  note's text is unchanged.
- **"No hard rule" is read as no hard rule *enabled*.** A disabled hard rule
  is out of the model entirely, and the note itself speaks of "enabled hard
  rules", so the suppression condition is `not _hard_rules(event)` (the
  existing enabled-hard-rule reading), not "the locks-free rules list is
  empty of any hardness".
- **ac4 is asserted on recommendation kinds and ids, not message prose.**
  The test follows `tests/solver/test_locks.py` precedent in checking that
  the unlock recommendation's message names the guest id and the table id;
  I assumed the exact wording ("Guest … is locked to table …; unlocking them
  restores feasibility") is not part of the contract, only its presence and
  referents.
- **The pinned lock probe may name more than ac4's two scenarios require —
  by design, per the bean's "whose removal alone"** phrasing: an
  unlocked guest's released lock is a no-op probe and a chart-consistent
  lock stays pinned by the day-lock, so in practice only locks that break
  feasibility are named; I did not add extra negative assertions beyond the
  bean's text because the scenarios already leave no lock to false-positive.
- **Nothing here was executed** (no pytest, no ortools in this container):
  declared in Verification rather than hidden; the only unverified claims are
  the pre-fix red points and the post-fix outcomes, both mechanical
  consequences of the quoted code plus the seat arithmetic stated in
  task-1's intent.
