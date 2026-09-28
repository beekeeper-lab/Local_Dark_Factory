# bean-009 — Reproducible optimization via persisted solver configuration

## What and why

The bean implements FR-048 ("repeated optimization using identical guests,
tables, rules, locks, mode, and solver settings SHALL produce the same
assignment") plus Implementation Guardrail #3 ("persist the solver
configuration or seed needed to reproduce an assignment").

For the reader with no context: this project is a wedding-seating optimizer
built atop Google OR-Tools' CP-SAT constraint solver. Today a solve is called
as `solve_event(event, time_limit_s=..., seed=...)`, and the solver already
pins two things inside OR-Tools' parameter block: one search worker and the
caller's random seed (done for bean-006). CP-SAT searches in parallel by
default, and parallel search is *not* deterministic — whichever worker finds
an equally-good answer first decides which one you get — so those two pins are
what make a run repeatable at all. The reproducible invariant
(`inv-reproducible` in `factory/invariants/seating.yaml`) already checks
repeated runs through the conformance seam, and it runs green (66/66 in the
bean-007 gate run).

What is missing, and what this bean adds, is that the configuration is
*implicit*: nothing in the result records how the chart was produced. A chart
stored by a caller today can be replayed only if the caller separately
remembered the seed, worker count and time limit. This bean makes the
configuration an explicit named object, records the values *actually used* on
every result (so the record survives whatever OR-Tools does to a request),
serializes it with the result, and adds the four named acceptance tests that
pin the claim. It deliberately does **not** change the defaults (seed 0, one
worker, 10 s): the background records a real tension between pinning workers
and NFR-001's 15-second wall-clock target, and the manifest leaves that an
open owner decision — making the configuration explicit is this bean,
resolving the trade-off is not.

## Current behaviour

`solve_event` in `src/seating_planner/solver/hard.py` takes the configuration
as two loose keyword arguments and hands each to OR-Tools one line at a time:

```python src/seating_planner/solver/hard.py  # as it stands today, abridged
def solve_event(event: Event, *, time_limit_s: float = 10.0, seed: int = 0) -> SolveResult:
    ...
    solver: Any = cp_model.CpSolver()
    # One worker plus the caller's seed: the reproducible invariant needs both.
    solver.parameters.num_search_workers = 1
    solver.parameters.random_seed = seed
    solver.parameters.max_time_in_seconds = time_limit_s
    status = solver.Solve(model)
```

The result type, `SolveResult` in `src/seating_planner/solver/result.py`, is a
frozen dataclass whose fields are `status`, `assignments`, `assigned_count`,
`unassigned_count`, `score`, `rule_states` and `violations`, with a `to_dict()`
that writes JSON-safe primitives under those keys. There is **no field for the
configuration in either place** — the caller's seed never appears in
`result.to_dict()`, and the worker count never appears anywhere outside the
four parameter lines above, where it is hardcoded to `1`. `SolveResult` is
constructed only in `hard.py` (four sites: the two early returns, and the
feasible and infeasible exits after the solve). The conformance seam
`src/seating_planner/invariant_api.py` calls `solve_event` with the
`time_limit_s=` and `seed=` keywords and is **not** writable by this bean
(only `src/seating_planner/solver/**` is), so those two keyword names are
frozen by the boundary, not just by courtesy. No other code (store,
feasibility, tests) depends on the result's shape beyond reading fields back.

## Proposed change

**Task 1 — the configuration becomes explicit and ride on every result.**
Three source files:

New module `src/seating_planner/solver/config.py` (no imports from anywhere in
`seating_planner`; it must stay importable on its own):

```python src/seating_planner/solver/config.py
from dataclasses import dataclass
from typing import Final

@dataclass(frozen=True)
class SolverConfig:
    seed: int
    num_search_workers: int
    time_limit_s: float

    def to_dict(self) -> dict[str, object]:
        return {
            "seed": self.seed,
            "num_search_workers": self.num_search_workers,
            "time_limit_s": self.time_limit_s,
        }

DEFAULT_SOLVER_CONFIG: Final[SolverConfig] = SolverConfig(
    seed=0, num_search_workers=1, time_limit_s=10.0
)
```

with `__post_init__` rejecting `num_search_workers < 1` and non-positive
`time_limit_s` (a worker count the solver would reinterpret machine-dependently
is exactly the kind of implicit 0-default that breaks FR-048 silently).

`src/seating_planner/solver/result.py` — one new final field and one new
key, so the stored result is also the persisted configuration:

```python src/seating_planner/solver/result.py
# SolveResult, abridged
    violations: tuple[Violation, ...]
    solver_config: SolverConfig  # the configuration that actually produced it

    def to_dict(self) -> dict[str, object]:
        return {
            ...,
            "solver_config": self.solver_config.to_dict(),
        }
```

`src/seating_planner/solver/hard.py` — the signature gains one keyword
(everything pre-existing kept, so `invariant_api.py` keeps working untouched):

```python src/seating_planner/solver/hard.py
# abridged
def solve_event(
    event: Event,
    *,
    time_limit_s: float = 10.0,
    seed: int = 0,
    num_search_workers: int = 1,
) -> SolveResult:
    config = SolverConfig(seed=seed, num_search_workers=num_search_workers,
                          time_limit_s=time_limit_s)
    ...
    status = solver.Solve(model)
    used = SolverConfig(
        seed=solver.parameters.random_seed,
        num_search_workers=solver.parameters.num_search_workers,
        time_limit_s=solver.parameters.max_time_in_seconds,
    )
```

The early returns (no eligible guests / no tables) attach the requested
`config` — nothing ran, so the request is the configuration used. The
feasible and infeasible exits attach `used`, read back out of
`solver.parameters` *after* `Solve`: the honesty of "actually used" is the
read-back, because the guarantee FR-048 needs is a claim about what ran, not
what was typed. Model, constraints, objective, report helpers and
`SolverTimeout` all stay where they are; determinism stays a property of
configuration — nothing post-processes or sorts the output (the bean's
constraint).

**Task 2 — the four named acceptance tests** in a new
`tests/solver/test_determinism.py`, one function per criterion, in the builder
style of `tests/solver/test_result.py`, all solves passing an explicit config
so every configuration is visible in the test itself:

- `test_repeat_run_is_identical` (ac1): solve one soft-rule event twice with
  the identical explicit config; assert the two `json.dumps(result.to_dict(),
  sort_keys=True)` payloads are equal — byte-identical serialized results,
  which subsumes byte-identical assignments.
- `test_result_records_configuration` (ac2): solve with a distinctive config
  (e.g. seed 42, one worker, 2.5 s) on a feasible event and assert
  `result.solver_config` and `to_dict()["solver_config"]` carry it; also on
  the infeasible path (guests, no tables), since the configuration must ride
  on every result, not just the lucky ones.
- `test_stored_config_reproduces_result` (ac3): take only the serialized
  payload, rebuild `SolverConfig(**payload["solver_config"])`, re-solve the
  identical event with exactly the stored values, and assert the payloads
  agree — replay is read through `to_dict`, never through the in-memory
  object, so the test exercises the persistence contract itself.
- `test_seed_change_is_visible` (ac4): two seeds, same worker count and time
  limit. Assert same-seed runs are byte-identical, that each result's
  recorded config names the seed that produced it, and that **if** the
  assignments differ between seeds, the only differing key in the two
  recorded configs is `"seed"` — a different chart is attributable to the
  visible recorded change. It does *not* assert that a seed change must
  change the chart, for the reason stated under Open questions.

## Risk

- **OR-Tools parameter rewrite.** If `Solve` mutated any of
  `random_seed` / `num_search_workers` / `max_time_in_seconds` in place, the
  read-back would record that, and the ac2 test (which asserts the recorded
  values equal the distinctive request) would fail loudly rather than the
  record silently lying. That is the right direction of failure, and it is
  why the test asserts equality with the request on a pinned gate image.
- **Frozen-dataclass field addition.** `SolveResult` is constructed only in
  `hard.py` in-tree (verified by grep: no other constructor, no other
  reader); the new field is appended last, so in-repo positional construction
  is the only thing that edits, and task-1's verify re-runs the whole
  `tests/solver` suite plus the invariants to catch anything the grep missed.
- **Seam compatibility.** `invariant_api.py` is outside the write paths and
  calls the old keyword names; task-1 keeps both names and both defaults
  byte-stable, and task-1's verify includes the invariants suite (66 tests),
  which drives the seam end-to-end.
- **Diff-line budget (300).** Two new files (config ~50 lines, tests ~180)
  plus small edits to two existing modules is close to the cap, so the task
  intents cap the test file at roughly 180 lines. If task-2 lands over, that
  is an attempt-level problem, not a spec change: trim test comments, not
  assertions.
- **Back-out** is a single-PR revert: the change adds a field and one
  `to_dict` key, and nothing stores solver results on disk yet (the store is
  an audit log that does not touch results), so there is no persisted shape
  to migrate in either direction.

## Blast radius

Touches exactly four files, all inside `src/seating_planner/solver/**` and
`tests/solver/**`: new `solver/config.py`, edited `solver/result.py` (one
field, one key, docstrings), edited `solver/hard.py` (signature, read-back,
result construction sites) and new `tests/solver/test_determinism.py`.
Callers: `invariant_api.py` and the existing solver tests keep working
unchanged. No data or deployment surface is touched: the store is an audit
log, `feasibility/preflight.py` does not call the solver, and no result is
persisted by anything in-tree yet. Explicitly **not** touched: `domain/`,
`rules/`, `store/`, `feasibility/`, `invariant_api.py`,
`solver/__init__.py` (a re-export would be a fifth file, over the 4-file
budget — tests import `SolverConfig` from `seating_planner.solver.config`
directly), and `factory/invariants/**` (tier 3, outside this line's reach by
construction).

## Verification

The four bean acceptance criteria, each pinned to its named test:

| ID | Criterion | verify |
|---|---|---|
| ac1 | Two runs over identical inputs and configuration produce byte-identical assignments. | `pytest -q tests/solver/test_determinism.py::test_repeat_run_is_identical` |
| ac2 | The result carries the solver seed, worker count and time limit actually used. | `pytest -q tests/solver/test_determinism.py::test_result_records_configuration` |
| ac3 | Replaying a stored configuration against the same inputs reproduces the stored assignment. | `pytest -q tests/solver/test_determinism.py::test_stored_config_reproduces_result` |
| ac4 | Changing only the seed may change the assignment, and that is reported rather than hidden. | `pytest -q tests/solver/test_determinism.py::test_seed_change_is_visible` |

Invariants from `factory/invariants/seating.yaml` (id `seating-core`), which
`invariants_ref` binds to this bean and which run through the unchanged seam:
**`inv-reproducible`** (same spec twice → byte-identical assignments) plus
`inv-capacity`, `inv-one-table`, `inv-eligibility`, `inv-hard-rules` and
`inv-infeasible-is-total` as regression, all via
`pytest -q --no-header factory/invariants/test_seating_invariants.py`. Task
verification is task-1: ruff check + format, `mypy src`, both greps above,
the existing `tests/solver` suite and the invariants suite; task-2: ruff on
`tests/solver`, the four named tests individually, then the whole
`tests/solver` directory. None of it is runnable in this planning container
(no ortools, no pytest — see Open questions); it runs in the gate image and
a green there is the only verdict that counts.

## Open questions

Assumptions, declared rather than hidden:

1. **"Byte-identical" is read as byte-identical serialized results.** The
   ac1 test compares `json.dumps(result.to_dict(), sort_keys=True)` across
   the two runs — strictly stronger than comparing the assignment maps alone,
   and it also proves the newly recorded configuration is itself stable
   across runs. If the owner meant "assignment maps equal only," the test
   is a superset and still passes when they do.
2. **ac4 pins the reporting mechanism, not a forced difference.** Under
   sequential search (one worker — the determinism requirement), CP-SAT's
   seed matters mainly once the search does stochastic work, and on the
   small test events several seeds will frequently return the *same* chart;
   no instance can be guaranteed to flip. The test therefore asserts: each
   result faithfully records its own seed; same-seed runs are identical; and
   *if* the charts differ, the recorded configs differ only in `seed`. A
   test that forces a difference would be brittle across gate images. If the
   owner wants a guaranteed divergence demonstrated, that needs a larger /
   time-limited instance and a flakiness budget, which this bean's
   non-goals (no performance work) do not cover.
3. **The read-back is the definition of "actually used."** The plan assumes
   OR-Tools leaves the parameters it is given intact after `Solve` (this
   planning container cannot run ortools to confirm; the pinned gate image
   will). The ac2 test asserting the recorded values equal the distinctive
   request is the check that catches a rewrite, and it would fail loudly,
   which is the desired failure mode.
4. **Defaults are deliberately unchanged** (seed 0, one worker, 10 s).
   Resolving the NFR-001 wall-clock tension the background names is the
   owner's open decision; this bean makes the choice visible and replayable
   in either outcome.
5. **`solver/__init__.py` is not re-exporting `SolverConfig`** because a
   fifth file would break the 4-file budget. The module path
   `seating_planner.solver.config` is stable and importable; a later bean can
   add the re-export when the budget allows.
6. **Environment note, stated for the record:** this planning container has
   ruff and mypy, which were run against the plan's code shapes (clean) and
   the current tree (clean baseline), but no ortools and no pytest. Nothing
   here about CP-SAT behaviour is a self-check of this session; the
   determinism evidence is the invariants suite passing 66/66 in the
   bean-007 gate run against the current pins.
