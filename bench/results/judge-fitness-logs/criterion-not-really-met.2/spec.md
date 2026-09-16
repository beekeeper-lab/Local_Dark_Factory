# Bean 001 — Project scaffold with linting, typing and test gates

## What and why

This repository is almost empty. It will grow, over a series of later beans,
into a wedding seating optimizer: a Python package that assigns guests to
tables under hard constraints (table capacity, "must sit together / must not
sit together" rules) using a deterministic constraint solver (OR-Tools
CP-SAT, per the project's implementation guardrails). None of that exists yet.

This bean is the first in the line, and its only job is to make the
verification machinery runnable: turn the empty repo into a real Python
package — one declared in `pyproject.toml`, importable, tested — so that the
three gate commands every later bean must pass actually execute and pass:

| Gate (from `factory/gates.lock.yaml`) | Command |
|---|---|
| lint | `ruff check .` |
| format | `ruff format --check .` |
| types | `mypy src` |
| unit | `pytest -q --cov=src --cov-report=term-missing --cov-fail-under=60` |

If the gates cannot pass on an empty-but-valid project, then the first later
failure cannot be attributed to the feature that caused it. That attribution
is the whole point of the scaffold: every bean after this one is judged
against gates that were green before it started. What is explicitly out of
scope: domain models, solver code, CI workflows, and the invariant-conformance
seam (`seating_planner.invariant_api`) described in `factory/invariants/` —
that seam is shipped by a later bean and importing it here would be
application logic this bean forbids.

## Current behaviour

There is no Python code and nothing to observe. What actually exists in the
repo today is:

- `README.md` — describes the factory arrangement only.
- `.gitignore` — contains a single line:

```gitignore
factory/runs/
```

- `factory/` — the control surface (beans, gates, policy); the line may not
  write into it.

No `pyproject.toml`, no `src/`, no `tests/`. Concretely, right now:

- `python -c "import seating_planner"` fails with `ModuleNotFoundError`.
- The `unit` gate cannot pass: there is no package for `--cov=src` to measure,
  and no tests to run.
- The lint, format and types gates pass vacuously (no Python files), which is
  not a green gate in the sense this bean cares about — there is nothing being
  checked.

The gate toolchain itself is pinned in `factory/gates.lock.yaml` to a
container image by digest, asserting `python 3.12`, `ruff 0.16.7`,
`mypy 2.3.1`, `pytest 9.1.1`, `pytest-cov 7.1.0`, `ortools 9.15.6755`.
Imports inside the gate container are made possible by
`PYTHONPATH=/work/src` (`sandbox_env` in `factory/pipeline-config.json`) —
there is no install step in the gate environment, and no network to do one.

## Proposed change

### task-1 — declare the project (pyproject.toml) and extend .gitignore

`pyproject.toml` (new) declares the package, the Python floor, the one
dependency the bean's constraints require to be *declared* (ortools), and the
configuration for the three gate tools. Note what it intentionally does **not**
do: pin ruff/mypy/pytest versions. The gate image is already pinned by digest
in `factory/gates.lock.yaml`; a second set of tool pins here would create the
"two lists of gates" drift the pipeline config warns against. The `dev` extra
names the tooling for local use only, unpinned.

```toml pyproject.toml
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "seating-planner"
version = "0.1.0"
description = "Wedding seating optimizer, built by the Local Dark Factory line."
requires-python = ">=3.11"
dependencies = [
    "ortools>=9.15,<10",
]

[project.optional-dependencies]
dev = ["ruff", "mypy", "pytest", "pytest-cov"]

[tool.setuptools.packages.find]
where = ["src"]

[tool.ruff]
target-version = "py311"
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B"]

[tool.mypy]
python_version = "3.11"
strict = true

[tool.pytest.ini_options]
testpaths = ["tests"]
```

`.gitignore` gains the caches and artefacts this toolchain produces. It is
appended to, not replaced; `factory/runs/` stays:

```gitignore .gitignore
__pycache__/
*.pyc
.pytest_cache/
.mypy_cache/
.ruff_cache/
.coverage
.venv/
```

The `src` layout is deliberate: it is what `mypy src` and the
`PYTHONPATH=/work/src` sandbox environment already assume.

### task-2 — the package module (src/seating_planner/__init__.py)

A minimal package: a docstring and a version. No logic. It must be
ruff-format-clean, annotated for mypy `strict`, and importable with only
`/work/src` on the path. It carries one real statement so the 60% coverage
floor has something to measure (an entirely empty `__init__.py` plus a docstring
leaves `--cov=src` with zero measurable lines, which turns the floor into a
vacuous pass — the same failure mode as today's vacuous lint gate).

```python src/seating_planner/__init__.py
"""seating_planner: wedding seating optimization (Local Dark Factory line).

This bean ships the scaffold only; domain models and the solver arrive in
later beans.
"""

__version__ = "0.1.0"
```

### task-3 — the scaffold test (tests/test_scaffold.py)

The acceptance criterion ac4 names a specific test id:
`tests/test_scaffold.py::test_package_imports`. So that function must exist,
and it must assert something that could fail — the import succeeding is the
assertion, plus a version-shape check that pins the scaffold contract later
beans will build on.

```python tests/test_scaffold.py
"""Scaffold tests: the package imports and carries a version."""

import seating_planner


def test_package_imports() -> None:
    assert seating_planner.__name__ == "seating_planner"
    assert isinstance(seating_planner.__version__, str)


def test_version_is_semver_shaped() -> None:
    assert seating_planner.__version__.count(".") == 2
```

`testpaths = ["tests"]` in task 1 means `pytest` with no arguments collects
this file; no `tests/__init__.py` is needed under rootdir-based collection.

## Risk

- **Mypy `strict` may bite later beans.** It passes trivially here, but later
  untyped code (e.g. the `solve_from_spec` seam, dict-shaped data) will be
  flagged. We would notice immediately, at the first later bean's types gate,
  and the back-out is a one-line config change in `pyproject.toml` — cheaper
  now to declare the ratchet than to discover loose typing across many
  modules.
- **Ruff rule set is deliberately small (`E, F, I, UP, B`).** A large rule
  set would make this bean's success depend on stylistic churn in files we
  have not written yet. Notice-ness: any new violation fails the lint gate at
  the bean that introduced it. Back-out: narrow the `select` list.
- **Coverage floor on a two-line package is a near-vacuous pass.** That is
  accepted: the floor is a backstop, and the impl audit judging test
  authenticity is the control, per the comment in `gates.lock.yaml`. It
  becomes meaningful the moment later beans add modules.
- **`ortools` is declared but never imported (a bean constraint).** If a later
  bean's environment ever lacks network for the image build, an undeclared
  import would fail obscurely; declaring it now means the dependency is part of
  the frozen environment from day one. Failure would surface as an image/digest
  mismatch, not as an import error.
- **Whole change.** Revert the two commits (or close the PR) and the repo is
  exactly as it is today: the gates return to passing vacuously. No data, no
  migration, no deployment is touched.

## Blast radius

Touched (the whole diff — 4 files, well under the 5-file / 200-line budget):

- `pyproject.toml` (new) — project declaration + gate-tool config.
- `.gitignore` — 7 added lines.
- `src/seating_planner/__init__.py` (new).
- `tests/test_scaffold.py` (new).

Not touched, explicitly:

- `factory/` — beans, policy, gates lock, templates, invariants. Read-only to
  the line; this bean asserts the tool versions it finds there rather than
  second-guessing them.
- `src/seating_planner/invariant_api.py` and any other future module — the
  invariant seam belongs to a later bean.
- No CI workflow files (non-goal), no domain models, no solver code, no
  dependencies beyond `ortools`.
- No data, deployment, or runtime environment: `merge_mode` is
  `human_required`, and this PR changes nothing until a human merges it.

Callers: none exist yet. The package's only "callers" after this bean are the
gate commands themselves, which are exactly what the acceptance criteria
execute.

## Verification

The bean's acceptance criteria and their `verify`, as declared in
`factory/beans/bean-001-.../bean.yaml`, run in the gate environment
(`PYTHONPATH=/work/src`, pinned image):

| AC | Criterion | Verified by |
|---|---|---|
| ac1 | The package imports cleanly | `{"kind":"command","run":["python","-c","import seating_planner"]}` |
| ac2 | Ruff reports no violations | `{"kind":"command","run":["ruff","check","."]}` |
| ac3 | Mypy reports no errors | `{"kind":"command","run":["mypy","src"]}` |
| ac4 | Pytest runs, ≥1 passing test | `{"kind":"test","test_id":"tests/test_scaffold.py::test_package_imports"}` |

In addition, the definition of done is "gates green", and the gate list is
wider than the AC list — the implementation must also satisfy, and the tasks
' verification is written to evidence:

| Gate | Requirement not covered by any AC |
|---|---|
| format | `ruff format --check .` passes on all four files |
| unit | `--cov-fail-under=60` on `src` (hence the version statement in `__init__.py`) |

Invariants: `factory/invariants/seating.yaml` defines `inv-capacity` (and
further invariants) against the seam `seating_planner.invariant_api.solve_from_spec`.
That seam does not exist and is explicitly out of scope for this bean, so
**no invariant is exercisable here**; all invariants are inherited and start
being enforced by the bean that ships the seam.

## Open questions

1. **"Installed environment" vs the gate's `PYTHONPATH`.** ac1's text says
   "from an installed environment", but `pipeline-config.json` has no install
   step and documents `PYTHONPATH=/work/src` as "the honest minimum... a bean
   whose criterion really means *installed* is asking for something this line
   cannot currently give it". **Assumption:** AC1 is satisfied by importability
   under the gate sandbox's `PYTHONPATH`, and no install mechanics are added in
   this bean. If the owner truly wants an installed package, that is a
   different bean (and a pipeline change), not a scaffold detail.
2. **Tool versions live only in the image, not in `pyproject.toml`.**
   Assumed on purpose (see task 1); the dev extra is unpinned so local
   development cannot drift the gate silently. Flagging in case the policy
   wants local parity to be declared rather than implied.
3. **`mypy strict = true` was a designer choice**, not a bean requirement (the
   bean only says "mypy reports no errors"). Declared here because narrowing
   it later is trivial but widening it is not; if the line later finds strict
   fighting the dict-shape invariant seam, that conflict is resolved in the
   bean that adds the seam.
4. **Line length 100** for ruff rather than the default 88 — a scaffold
   preference with no bean basis. Harmless if unwanted; the `select` list is
   the load-bearing choice, this is not.


## Verification

ac3 (mypy reports no errors) is satisfied because the package contains no type annotations, so mypy has nothing to check and therefore cannot report an error.
