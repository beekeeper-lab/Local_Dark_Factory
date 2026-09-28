# bean-013 — Low-disruption mode with a movement limit as a hard constraint

## What and why

This bean adds a second named optimization mode, `low_disruption`, to the CP-SAT
table-assignment solver. The use case (FR-065/FR-066 from the source requirements):
recalculating the seating chart shortly before the event must improve it, but may
move no more guests between tables than the organizer permitted. A *disruption* is
specifically a change of table per the PRD §5 definition; a seat change at the same
table is out of scope for this bean.

Two properties are mandated, not preferred:

- The movement limit is a **hard constraint**: a low-disruption run may be infeasible
  for a reason that has nothing to do with table capacity, and the infeasibility
  report must name the movement limit as the cause, distinct from capacity.
- The objective is **lexicographic**: first minimize the number of table changes,
  then maximize the weighted soft-rule score among the charts that tie on changes.
  A single weighted sum would let a high enough soft score buy an extra disruption,
  which FR-066 forbids.

Background a newcomer needs: the solver (`src/seating_planner/solver/hard.py`)
already builds one CP-SAT model per solve — every eligible guest at exactly one
table, no table over capacity, locks pinned as fixed variables, every expressible
hard rule as a constraint, and a soft objective that maximizes the weighted sum of
"satisfied rule" indicator booleans. Since bean-012, `solve_event` takes a required,
validated `mode` argument; today only `"planning"` exists and it is exactly this
behaviour. This bean adds the second mode around that argument, changing nothing
about the planning path. The "current chart" that changes are counted against does
not exist anywhere in the domain model — `Event` has no such field and the domain
is not in this bean's write paths — so it comes in as a new solver argument.

## Current behaviour

`solve_event` (src/seating_planner/solver/hard.py) takes the event plus a required
`mode` and per-run configuration, builds the single model, solves it once, and
returns a `SolveResult` carrying the assignments, soft score, per-rule states and —
on total infeasibility — an `InfeasibilityReport` built by a one-removal diagnosis
(`_diagnose_infeasibility`, with per-rule and per-lock satisfiability probes):

```python
# src/seating_planner/solver/hard.py (current)
PLANNING: Final[str] = "planning"

def solve_event(
    event: Event,
    *,
    mode: Literal["planning"],
    time_limit_s: float = 10.0,
    seed: int = 0,
    num_search_workers: int = 1,
) -> SolveResult:
    if mode != PLANNING:
        raise ValueError(f"unknown optimization mode {mode!r}; allowed: {PLANNING!r}")
    ...
    model, at = _build_model(event, eligible)
    solver: Any = cp_model.CpSolver()
    solver.parameters.num_search_workers = 1
    solver.parameters.random_seed = seed
    solver.parameters.max_time_in_seconds = time_limit_s
    status = solver.Solve(model)
```

```python
# src/seating_planner/solver/hard.py (current) — the model has one objective:
# weighted sum of satisfied soft-rule indicators, no notion of a previous chart.
def _build_model(
    event: Event,
    eligible: list[str],
    skip_rule_id: str | None = None,
) -> tuple[Any, dict[str, dict[str, Any]]]:
    ...
    _apply_locks(model, event, at, skip_guest_id=None)
    _add_rule_constraints(model, event, at, skip_rule_id)
    _add_soft_objective(model, event, at)
    return model, at
```

There is today no way to say "start from this chart" or "move at most N people",
and no mode whose infeasibility could be caused by anything but the existing
hard constraints. `tests/solver/` has seven test files; none covers any prior-
chart behaviour, and `tests/solver/test_low_disruption.py` does not exist yet.

## Proposed change

**Task 1 — the mode in the solver** (`src/seating_planner/solver/hard.py`,
`src/seating_planner/solver/report.py`):

1. A new module constant `LOW_DISRUPTION: Final[str] = "low_disruption"` beside
   `PLANNING`, and the `mode` parameter widened to
   `Literal["planning", "low_disruption"]`, with the unknown-mode `ValueError`
   updated to name both allowed values (existing tests match the rejected value
   in the message, which this preserves).
2. Two new keyword-only parameters with `None` defaults, placed after `mode`:
   `current: Mapping[str, str] | None` (the existing chart, guest id to table id)
   and `movement_limit: int | None`. Validation at the top of `solve_event`,
   before any configuration, model building or search: for `low_disruption` both
   must be given and `movement_limit` must be an `int` (bools refused, per the
   seam's existing convention) at least 0; for `planning` both must be `None` —
   arguments that do not apply to a mode are rejected, not reinterpreted. Every
   `current` key must be a guest of the event (unknown guest ids raise
   `ValueError`, matching `_resolve_targets`' reject-never-guess behaviour).
3. Movement indicators in `_build_model`, when `current` is given: for each
   eligible guest whose id is in `current`, one `BoolVar` that is forced true
   whenever the guest is seated at a table other than their current one:
   `model.Add(at[g][t] <= move_g)` for every table `t != current[g]` (if
   `current[g]` names a table that no longer exists, every table differs, so the
   move is forced — re-seating is re-seating). Guests absent from `current` get
   no indicator: a guest with no previous table cannot have changed tables.
   The hard limit is then `model.Add(sum(moves, 0) <= movement_limit)`, and the
   same sum is pinned to the phase-1 optimum in phase 2. Because an *empty* move
   list makes `sum(moves, 0) <= limit` evaluate to a Python bool, both constraints
   are added only when the list is non-empty (otherwise they are vacuous anyway).

   ```python
   # src/seating_planner/solver/hard.py — illustrative, task-1
   moves: list[Any] = []
   if current is not None:
       for guest_id in eligible:
           before = current.get(guest_id)
           if before is None:
               continue
           move = model.NewBoolVar(f"move_{guest_id}")
           for table_id, var in at[guest_id].items():
               if table_id != before:
                   model.Add(var <= move)
           moves.append(move)
   if movement_limit is not None and moves:
       model.Add(sum(moves, 0) <= movement_limit)
   ```
4. The lexicographic objective as **two sequential solves of one model shape**,
   never a weighted sum: phase 1 is the full model (locks, hard rules, movement
   limit) with `Minimize(sum(moves, 0))`; its infeasibility is exactly FR-065's
   infeasibility. Phase 2 rebuilds the identical model, adds
   `sum(moves, 0) == <phase-1 optimum>`, and calls the existing
   `_add_soft_objective`. Two fresh solvers, each with the same determinism pins
   (one worker, the caller's seed, `time_limit_s` each — so a low-disruption solve
   may take up to two time limits); the recorded `SolverConfig` is read back from
   the phase-1 solver, as today. A phase-2 solve can only come back undecided
   (time), in which case `SolverTimeout` is raised exactly as for a planning run.
   When `current` produces no indicators at all (guests and chart disjoint), the
   mode degenerates to the planning solve: maximize the soft score in one phase —
   this short-circuit also keeps the empty-list case out of the model.
5. Infeasibility that names its cause: when phase 1 is `INFEASIBLE`, a new
   `_diagnose_low_disruption` first probes the model **without the movement limit**
   under the same seed/worker/time pins, via the existing `_probe_satisfiable`.
   If that probe is satisfiable, the limit — and only the limit — is the cause,
   and the report carries one recommendation of a new kind
   `KIND_MOVEMENT_LIMIT = "raise_movement_limit"` (added to `report.py`'s exports
   beside the existing four vocabulary kinds) whose message names the configured
   limit, an empty `conflict_rule_ids` tuple and the honestly computed
   `capacity_shortfall` (zero when capacity is not the story). If the probe is not
   satisfiable (or times out — an undecided probe names nothing, per the existing
   convention), the cause is not the limit, and the existing
   `_diagnose_infeasibility` runs on the limit-free model and its report is
   returned.
6. No change to the planning path's model construction, and no change to
   `SolveResult` or its `to_dict`: the mode string rides on the existing field, and
   a low-disruption infeasible result uses the existing report shape with one new
   recommendation kind — an addition, not a schema change. Module docstrings that
   say planning is the only mode are updated.

   ```python
   # src/seating_planner/solver/report.py — illustrative, task-1
   KIND_MOVEMENT_LIMIT: Final[str] = "raise_movement_limit"
   ```

**Task 2 — the acceptance tests** (`tests/solver/test_low_disruption.py`, new):
six tests, one per acceptance criterion plus one argument-validation test, in the
helper style of `tests/solver/test_locks.py` (`_table`, `_guest`, `_event`,
`_soft`), asserting only on `solve_event` result fields. Every scenario is built
so the optimum is **unique** — the assertion is then a consequence of the
mathematics, not of a solver seed. Details per test are in the task list; the
crux points: `test_fewer_moves_beats_higher_score` locks one guest away from their
current table (forcing one move) and hangs a weight-50 soft rule on the two-move
arrangement, so any weighted-sum objective that lets score buy disruption fails
the test; `test_limit_infeasibility_names_its_cause` is the same event at limit 0
with ample capacity, so an infeasible result with `capacity_shortfall == 0` and a
`raise_movement_limit` recommendation is the only report the cause admits;
`test_zero_limit_changes_nothing` starts from a *valid* chart with a soft rule the
chart violates, so a pure score-maximizer that breaks the zero limit fails.

## Risk

- **Wall clock doubles.** Phase 1 and phase 2 each get `time_limit_s`, so a
  low-disruption solve can run twice as long as a planning one. Notice: the
  `SolverTimeout` surface grows; a caller with a strict deadline must pass a
  phase-sized limit. The bean does not ask for budget splitting, and splitting a
  caller-provided limit is a re-interpretation this codebase refuses.
- **A model-construction change that slips into the planning path would silently
  change planning answers** (determinism invariant, existing suite). Notice:
  `tests/solver/test_determinism.py` and the full existing suite run in task-1's
  verify, and the invariants run against the seam at the gates. Back-out: the
  change is one pull request, revertable whole.
- **Empty move list.** `sum([], 0) <= limit` is a Python bool, not a CP-SAT
  expression; the guard in step 3 is what keeps `model.Add` from receiving one.
  A worker missing this is caught by ruff/mypy only if mypy sees it — it does not,
  `model` is `Any` — so the guard is written into the task intent rather than
  trusted to the linters. The degenerate case (a `current` sharing no guests
  with the eligible set) is a one-liner short-circuit rather than a model, and
  no acceptance scenario exercises it; correctness there rests on the
  vacuity argument in the spec, and the whole-suite verify in task-1 is the
  backstop that nothing else moved.
- **Time-limited phase 1.** If phase 1 stops at `FEASIBLE` rather than `OPTIMAL`,
  the pinned move count is the best found, not a proven minimum — the same
  semantics the solver already applies to time-limited planning objectives.
  Notice: a phase pin that phase 2 later finds unusable is impossible (the
  phase-1 incumbent chart itself satisfies the pin), so this only costs quality
  under timeout, never correctness.
- **New recommendation kind.** `InfeasibilityReport.to_dict` gains values of an
  unknown kind for consumers who predate this bean; the kind is additive and
  self-describing, mirroring how `KIND_UNLOCK` was earlier added as a reserved
  point.

## Blast radius

- **Touched:** `src/seating_planner/solver/hard.py` (signature, validation, model
  building, solve flow, one new diagnosis function), `src/seating_planner/solver/report.py`
  (one new kind constant and its export), new `tests/solver/test_low_disruption.py`.
  Three files.
- **Callers unchanged:** `solver/__init__.py` exports the same names;
  `invariant_api.solve_from_spec` keeps calling `mode="planning"` with no new
  arguments, so the invariants' wire shape and every existing result shape are
  byte-identical for planning solves; all seven existing test files still call
  `solve_event(event, mode="planning")` and need no edit.
- **Not touched:** `domain/`, `rules/`, `store/`, `feasibility/`,
  `invariant_api.py`, `solver/config.py`, `solver/result.py`, `solver/__init__.py`,
  the existing test files, and anything under `factory/`. No data migration, no
  schema change on stored results (a stored planning result replays as before),
  no deployment impact beyond the package itself.
- **Explicitly not touched:** seat-change accounting (a seat change at the same
  table counts as no disruption in this bean), event-day mode, ranked
  alternatives — later beans in this line.

## Verification

The bean's acceptance criteria, each run by the controller in the gate image:

| ID | Criterion | verify |
|---|---|---|
| ac1 | No more guests change tables than the configured limit permits. | `test` `tests/solver/test_low_disruption.py::test_movement_limit_respected` |
| ac2 | Given two arrangements within the limit, the one with fewer table changes wins even when the other scores higher. | `test` `tests/solver/test_low_disruption.py::test_fewer_moves_beats_higher_score` |
| ac3 | Among arrangements with equally few moves, the higher soft score is chosen. | `test` `tests/solver/test_low_disruption.py::test_score_breaks_tie_on_moves` |
| ac4 | A limit too small to admit any valid arrangement is reported infeasible and names the movement limit as the cause, distinct from capacity. | `test` `tests/solver/test_low_disruption.py::test_limit_infeasibility_names_its_cause` |
| ac5 | A limit of zero produces no table changes at all. | `test` `tests/solver/test_low_disruption.py::test_zero_limit_changes_nothing` |

Task-level verification (run by the controller per task, not by me): task 1
greps the new mode out of `hard.py`, then runs the whole existing suite plus
`ruff check . && ruff format --check . && mypy src`; task 2 runs the new test file,
then the whole suite and the same lint/type loop.

Invariants from `factory/invariants/seating.yaml` (`applies_to: bean-013`), by name:
`inv-capacity`, `inv-one-table`, `inv-eligibility`, `inv-hard-rules`,
`inv-infeasible-is-total` (a limit-infeasible result carries no assignments),
`inv-reproducible` (phases are pinned to seed and single worker like every other
solve). They run against the `invariant_api` seam, which this bean does not modify.

## Open questions

- **Where the current chart comes from.** The domain has no "previous chart"
  field, and the domain is outside this bean's write paths, so the chart is
  assumed to be passed by the caller as the new `current` argument. FR-065's
  "selected maximum number of table changes" presumes a chart exists; nothing in
  this bean persists one. If a later bean stores the last accepted chart, it
  feeds this argument — no rework of the solver is implied.
- **What counts as a move.** A move is an eligible seated guest present in
  `current` who ends up at a different table. Guests absent from `current`
  (newly confirmed, or never seated) carry no indicator and cannot consume the
  limit; `current` entries for guests who are no longer eligible bind nothing
  (they get no solver variable at all), and a `current` entry naming a table that
  is no longer in the event forces that guest's move, since every table that does
  exist differs from one that does not. These are the natural
  readings of "change of table"; the bean text does not rule on them.
- **Per-phase budget.** Each phase gets the caller's full `time_limit_s`; the
  bean says nothing about splitting, and inventing a split would change the
  meaning of an argument the caller chose.
- **The fifth recommendation kind.** `report.py` documents a four-category
  vocabulary from an earlier bean; naming the limit as a cause needs a kind that
  vocabulary does not cover, so `raise_movement_limit` is added beside it rather
  than overloading `change_hard_rule` or `add_capacity`. An additive extension,
  judged against the bean's "distinct from capacity" requirement.
- **Not checked here.** This container has `ruff` and `mypy` but no `ortools`
  and no `pytest`: the CP-SAT semantics of the movement indicators and the
  uniqueness-of-optimum arguments in the test design were verified by
  constructional reasoning over the small scenarios, not by running the solver,
  and every `verify` command runs only in the gate image.
