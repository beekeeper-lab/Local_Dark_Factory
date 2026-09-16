# Implementation detail — bean 001: project scaffold with linting, typing and test gates

## Summary

This bean turned a near-empty repository (a `README.md`, a one-line `.gitignore`,
and the read-only `factory/` control surface) into a real, importable Python
package: a new `pyproject.toml` declares `seating-planner` 0.1.0 with its single
runtime dependency (`ortools`, declared but never imported) and the ruff/mypy/
pytest configuration the four gate commands consume, `src/seating_planner/__init__.py`
is a two-line package — docstring plus `__version__` — and
`tests/test_scaffold.py` holds two scaffold tests, one of which is the exact id
ac4 names. Against the post-rebase base all four gates and all four acceptance
criteria pass, and the test-integrity check confirms the new test file pins the
change: the unit-gate command passes on the tree as-is and fails when the
source is reverted.

## Walkthrough by task

All three tasks were verified on their first attempt — `tasks.jsonl` records a
verified result with a single attempt for each of task-1, task-2 and task-3,
with worker sessions of 947 s, 89 s and 95 s respectively. The
`failed-attempts/` directory holds only advisory and spec-review artefacts from
audits, not task failures, so there is no failure history to explain here.

### task-1 — `pyproject.toml` and `.gitignore`

The package declaration comes first so that every later file is written into an
environment where the lint, types, format and test configuration already
exists — otherwise each task would have to guess the tool setup, and the gates
would be asserting against different things per task. For a reader new to
Python packaging: `pyproject.toml` is the single declarative file from which
build tools (`pip`, `setuptools`) and tooling (ruff, mypy, pytest) all read
their settings. Nothing here installs anything — the gate sandbox has no
network and no install step; it puts `/work/src` on `PYTHONPATH` and runs the
commands.

```toml
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
```

`[build-system]` declares how a tool would build an installable distribution
if one ever is built. `[project]` is the identity and dependency block:
`requires-python = ">=3.11"` sets the interpreter floor for any environment
that installs the package. The one runtime dependency, `ortools`, is declared
but deliberately never imported anywhere in this diff: the bean forbids solver
code, but declaring the range `>=9.15,<10` now means the future dependency is
frozen into the environment from day one, so a later bean adding
`import ortools` cannot fail on an undeclared dependency. The `dev` extra names
the four tooling packages with **no version pins**, deliberately: the gate
toolchain is pinned by image digest in `factory/gates.lock.yaml`, and a second
set of pins here would create the "two lists of gates" drift the pipeline
config warns against. The `dev` extra means `pip install .[dev]` pulls the
tools for local use; a bare `pip install .` does not.

```toml
[tool.setuptools.packages.find]
where = ["src"]

[tool.ruff]
target-version = "py311"
line-length = 100
# Project gates lint and format project code (src/ and tests/). factory/ is
# pipeline infrastructure (beans, policy, gates lock, templates, invariants)
# and is read-only to this line; its files are not subject to project tooling.
extend-exclude = ["factory"]

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B"]

[tool.mypy]
python_version = "3.11"
strict = true

[tool.pytest.ini_options]
testpaths = ["tests"]
```

Line by line: `where = ["src"]` tells setuptools to discover packages under the
`src/` layout — the same layout the gates assume (`mypy src` addresses `src/`
directly, and it is what makes `import seating_planner` work under
`PYTHONPATH=/work/src` once the package exists). `target-version = "py311"`
tells ruff to parse and lint against Python 3.11 semantics; `line-length = 100`
sets both the lint line limit and the formatter's wrap width (100 rather than
ruff's default 88 — a scaffold preference the spec flags as an open question,
not a bean requirement). **`extend-exclude = ["factory"]` and the three comment
lines above it are not in the spec's code block** — that is a deviation,
written up in the Deviations section; in short, it stops the repo-wide
`ruff check .` and `ruff format --check .` commands from reaching into the
pipeline infrastructure the line is forbidden to modify. `select = ["E", "F",
"I", "UP", "B"]` enables a deliberately small rule set — pycodestyle errors (E),
pyflakes (F), import sorting (I), pyupgrade (UP), bugbear (B); a larger set
would make this scaffold's success depend on stylistic churn in modules that
do not exist yet. `[tool.mypy]` sets the checking version and turns on
`strict = true`, the strictest mypy preset: it passes trivially on a two-line
package, and its real role is a ratchet that bites the first later bean
shipping untyped code, where the back-out the spec names is a one-line config
change. `testpaths = ["tests"]` means bare `pytest` with no arguments
collects `tests/` by default; pytest's rootdir-based collection finds test files
there without a `tests/__init__.py`.

The `.gitignore` hunk is purely additive. The file previously held one line;
the diff keeps it and appends seven entries for the caches and build artefacts
this exact toolchain produces:

```
factory/runs/   # pre-existing, unchanged — the pipeline's own run records, never committed
__pycache__/    # Python bytecode cache, one per directory
*.pyc           # compiled bytecode files
.pytest_cache/  # pytest's cache (last-failure state and friends)
.mypy_cache/    # mypy's cached type analysis
.ruff_cache/    # ruff's cache
.coverage       # the coverage data file the unit gate's --cov writes
.venv/          # a local virtual environment
```

Task-1 teaching note: *"The declaration comes first so every later file is
written into an environment where the lint, types, format, and test
configurations already exist — otherwise each task would have to guess the tool
setup and the gates would be asserting against different things, which is
exactly what this bean is trying to end. Tool versions are intentionally
absent from this file; gates.lock.yaml owns them."*

### task-2 — `src/seating_planner/__init__.py`

This small file is the entire module the diff adds:

```python
"""seating_planner: wedding seating optimization (Local Dark Factory line).

This bean ships the scaffold only; domain models and the solver arrive in
later beans.
"""

__version__ = "0.1.0"
```

An `__init__.py` is what makes `src/seating_planner/` a package rather than a
plain directory: importing `seating_planner` locates and executes this file,
which is why `python -c "import seating_planner"` (ac1's check) is meaningful
at all. The docstring states the line's provenance and scopes the bean.
The single statement, `__version__ = "0.1.0"`, looks decorative but is
load-bearing: the unit gate enforces `--cov-fail-under=60`, and coverage counts
measured lines — a docstring-only module has zero measurable lines, which would
let the floor pass on *nothing* (the vacuous-green failure mode this bean
exists to remove, relocated inside a green number). With one real statement,
the floor measures 100% on the one line the test file imports and asserts on.
There are no imports, no `ortools` use, no logic anywhere in the package: the
bean forbids application code, and the invariant seam
`seating_planner.invariant_api` described under `factory/invariants/` belongs to
a later bean.

Task-2 teaching note: *"The smallest possible package that is still a real
package: importable, versioned, type-checked, and covered. The version
statement exists so the coverage floor measures something instead of passing
vacuously on zero lines — the scaffold is not allowed to reproduce the
vacuous-green failure mode it was built to remove."*

### task-3 — `tests/test_scaffold.py`

```python
"""Scaffold tests: the package imports and carries a version."""

import re

import seating_planner


def test_package_imports() -> None:
    assert seating_planner.__name__ == "seating_planner"
    assert isinstance(seating_planner.__version__, str)


def test_version_is_semver_shaped() -> None:
    assert re.fullmatch(r"\d+\.\d+\.\d+", seating_planner.__version__)
```

`test_package_imports` is the exact test id that ac4's verify runs, so it
exists with exactly that name. The import itself is the load-bearing part in
spirit: the module-level `import seating_planner` makes the whole file fail
collection if the package is missing or broken, which is precisely the failure
the acceptance criterion must catch. The two `assert`s then pin that the
imported object is the package it claims to be (by `__name__`) and that it
carries a string version. `test_version_is_semver_shaped` pins the
version-shape contract later beans build on: `re.fullmatch` against the pattern
`\d+\.\d+\.\d+` requires the *entire* string to be exactly three
dot-separated groups of digits. **That is stricter than the
`count(".") == 2` snippet the spec shows** — it accepts `0.1.0` but rejects
`1.2.3-beta` and `..1` (each has exactly two dots, so the dot-count test would
have passed them) — and it required adding the `import re` line the spec snippet
does not show. Both functions are annotated `-> None`, which mypy `strict` requires on
every definition, and `import re` (standard library) sits in its own group
above the first-party `import seating_planner`, satisfying ruff's `I`
import-sort rule. There is deliberately no `tests/__init__.py`: with
`testpaths = ["tests"]`, pytest's rootdir-based collection finds the module
without it, and the task's write list contains only `tests/test_scaffold.py`.

Task-3 teaching note: *"The test exists to make ac4's verify a named, stable id
and to give the line its first assertion that the scaffold does what its
declaration says. Running the full unit gate command inside verify catches a
test that would pass pytest but fail the coverage floor."*

## Deviations from the spec

How it was checked: `diff.txt` (the accepted change — 4 files, 64 changed
lines per `gate.json`'s diff record) was compared hunk by hunk against the
three code blocks in `spec.md` (task-1's `pyproject.toml` and `.gitignore`
blocks, task-2's module, task-3's test file) and against each task's `intent`,
`write_paths` and `verify` in `tasks.yaml`. Two differences, both in the
direction of stricter or more contained behaviour:

1. **`pyproject.toml` adds `extend-exclude = ["factory"]` plus a three-line
   comment in `[tool.ruff]`; the spec's code block omits both.** The spec never
   says the ruff gates should scan `factory/`, and its blast-radius section
   explicitly declares `factory/` read-only to the line — `factory/` also
   contains a Python file (`factory/invariants/test_seating_invariants.py`), so
   without the exclusion the repo-wide `ruff check .` and `ruff format --check
   .` commands would reach into infrastructure the line has no permission to
   modify. The added lines land inside task-1's `write_paths` (`pyproject.toml`)
   and change nothing about what the gates check in project code; they only
   stop project tooling from claiming jurisdiction over read-only
   infrastructure. (This is also the source of the format-gate file-count
   oddity flagged in the Risk section, which the record does not resolve.)

2. **`test_version_is_semver_shaped` uses
   `re.fullmatch(r"\d+\.\d+\.\d+", seating_planner.__version__)` instead of
   the spec snippet's `seating_planner.__version__.count(".") == 2`, and adds
   `import re` to the file, which the snippet does not show.** Task-3's intent
   phrases the requirement as "a semver-shaped string like `0.1.0`" and offers
   the dot count as a way to check it, so the implemented check satisfies the
   stated intent while being stricter (see the task-3 walkthrough for what it
   additionally rejects). No verify command in `tasks.yaml` prescribes the
   dot-count form.

Nothing else differs. The `.gitignore` additions match the spec block entry for
entry and keep the pre-existing `factory/runs/` line (exactly what task-1's own
grep-based verify asserts); `src/seating_planner/__init__.py` matches the
spec's module line for line; both test functions exist under the
names the spec and ac4 require; and every other `pyproject.toml` key matches
the spec block, including the values task-1's tomllib-based verify asserts
(name, `requires-python`, an `ortools` dependency, `mypy` python_version and
`strict`, ruff `target-version`, pytest `testpaths`). The diff touches no file
outside the spec's four-file blast-radius list, stays well inside the 5-file /
200-line budget at 64 changed lines, and every acceptance outcome the spec's
Verification table predicted is recorded as passing in `gate.json`.

## Risk & blast radius, as built

**Risk, as built.** The spec's risk list holds against the actual diff. Mypy
`strict` is declared with the config in the tree: it will bite the first later
bean that ships untyped code, with the spec's one-line `pyproject.toml`
back-out available at that point. The ruff rule set is the small E/F/I/UP/B
set, so a new violation surfaces at the bean that introduces it rather than as
stylistic churn inherited from elsewhere. The 60% coverage floor on a
one-statement package is a near-vacuous pass, accepted in the spec with the
test-integrity check as the real control — and the integrity check did run and
pass (revert-failing, no deleted tests, no new skips, no removed assertions;
see Evidence). `ortools` is declared in `pyproject.toml` and imported nowhere
in the diff, as the bean constraint requires. Two of the spec's open questions
stand as assumptions in what was built: AC1's "installed environment" is
satisfied by importability under the sandbox's `PYTHONPATH` — nothing in the
diff installs the package, and the `[build-system]` table is inert until some
environment actually builds one; and local tool versions are intentionally
unpinned, so a local run may use tools different from the gate image's.

**One record inconsistency I could not resolve.** `gate.json` records the
format gate's output tail as `3 files already formatted`, but the accepted
diff's `pyproject.toml` excludes `factory/` from ruff, and the working tree
contains exactly three Python files in total: the two project files plus
`factory/invariants/test_seating_invariants.py`. If the exclusion were in
force, the format gate should count 2 files; the recorded count of 3 matches a
scan *without* the exclusion. The run directory does not record which file set
the gate's ruff actually scanned, and the gate image is not available to this
step, so the record cannot tell us whether the exclusion was in force at gate
time or the count means something else. This is flagged, not explained away;
it does not affect the verdict, since the gate exited 0 in either reading, and
it does not change what the accepted diff contains.

**Blast radius, as built.** Four files, 64 changed lines — `.gitignore`
(modified), `pyproject.toml`, `src/seating_planner/__init__.py` and
`tests/test_scaffold.py` (all new). `gate.json` containment confirms nothing
else changed (`contained: true`, zero violations), so all of `factory/` is
untouched, as is the README. The one behaviour change beyond "new files" is
that the gates stop passing vacuously: from the next bean, a red gate can be
attributed to that bean rather than to an empty scaffold, which is the stated
design aim. No CI, no deployment, no data, no migration: the merge mode is
`human_required`, so the change takes effect only once a human merges it, and
at the point of this run record the run had halted at the doc step with no PR
opened.

## Evidence

All values below are copied from `gate.json` (`schema: gate-run/1.0.0`,
`bean: bean-001`); `test-integrity.json`, `test-integrity.out` and `run.json`
agree with it on the base SHA and the integrity results. The gate run started
`2026-09-15T22:19:48Z` and finished `2026-09-15T22:19:53Z` with
`overall: "pass"`.

**Provenance.** Base: `e9a5b33e9482f0b23d5678e96622f2c5a92a2a83`. Candidate
history came via one rebase recorded in `run.json` at `2026-09-15T22:19:24Z`:
`origin/main` had moved from base
`5c12522497ae7a94a448c030cc9b013c98674244` to the current base (base was 1
commit ahead of the original fork point), the branch head moved from old head
`29a468ba44aa8b48a9232674c7995f141c5288ba` to new head
`ca950efaec565e821fe1bf6ad294f7fac86c14de`, and the gate step re-ran against
the new base (gate step, attempt 2, verdict PASS per `steps.jsonl`). The
gate results and integrity check quoted below are that post-rebase run.
Branch: `bean/bean-001-project-scaffold-with-linting-typing-and`. Accepted
diff: `diff.txt` — files `.gitignore`, `pyproject.toml`,
`src/seating_planner/__init__.py`, `tests/test_scaffold.py`; 4 files, 64
changed lines. Gate image (from `factory/gates.lock.yaml`; `gate.json` does not
restate the digest): `localhost/factory-gate-python:20260914@sha256:b78227887bd97a01bce072f4bc868fa83c1c2cbd44d232d2cbfda0e665deae20`, whose pinned
versions match the gate's observed environment: ruff 0.16.7, mypy 2.3.1, pytest
9.1.1, pytest-cov 7.1.0, ortools 9.15.6755, python 3.12 (the unit gate log
records the interpreter as python 3.12.14-final-0). Tier: `final_tier: 2`,
`binding_term: ["policy"]`, `policy_version: "risk/2026-09-14"`, terms
`policy: 2`, `bean_suggested: 1`, `judge_suggested: null`,
`never_auto_merged: false`. Per-path, the tier-2 file is `pyproject.toml`
under rule `{pyproject.toml,*.lock,uv.lock,poetry.lock,requirements*.txt}`
("dependencies change what the gates are running"); the other three files are
default tier 1. Containment: `contained: true`, no violations. Secret scan:
no suspicious lines. Invariants: `null` — `factory/invariants/` targets the
`seating_planner.invariant_api.solve_from_spec` seam, which this bean does not
ship, so no invariant was exercisable, exactly as the spec's Verification
section predicted.

**Gates** (all `kind: command`, `status: pass`, exit code 0, `ran_in:
sandbox`):

| Gate | Command | Duration | Output tail |
|---|---|---|---|
| lint | `ruff check .` | 0.247 s | `All checks passed!` |
| format | `ruff format --check .` | 0.243 s | `3 files already formatted` |
| types | `mypy src` | 0.648 s | `Success: no issues found in 1 source file` |
| unit | `pytest -q --cov=src --cov-report=term-missing --cov-fail-under=60` | 0.441 s | `Required test coverage of 60% reached. Total coverage: 100.00%` / `2 passed in 0.02s` |

Unit-gate coverage table from `gate-unit.log`, verbatim: `src/seating_planner/__init__.py` — Stmts 1, Miss 0, Cover 100%; TOTAL 1 / 0 / 100.00%.

**Acceptance criteria** (all `status: pass`, exit code 0, `ran_in: sandbox`):

| AC | Verified by | Duration | Output tail |
|---|---|---|---|
| ac1 | `python -c 'import seating_planner'` | 0.243 s | (none — silent success) |
| ac2 | `ruff check .` | 0.249 s | `All checks passed!` |
| ac3 | `mypy src` | 0.308 s | `Success: no issues found in 1 source file` |
| ac4 | `pytest -q tests/test_scaffold.py::test_package_imports` | 0.373 s | `1 passed in 0.00s` |

**Test integrity** (from `gate.json`'s `test_integrity` block; `test-integrity.json` and `test-integrity.out` agree). `fails_on_revert: yes` — the unit-gate command was run twice, once on the tree as-is (control exit 0) and once with the source files reverted (exit 1), proving at least one test depends on the change. Recorded caveat: a test that fails on revert only because of an import error still counts as pinning — weaker than proving an assertion tests behaviour, and the strongest thing a run can decide. Counts: `deleted_tests: 0`, `new_skips: 0`, `removed_asserts: 0`, `added_asserts: 3` (counted from the diff text; these counts cannot catch an assertion hollowed out in place). One test file (`tests/test_scaffold.py`), two source files (`pyproject.toml`, `src/seating_planner/__init__.py`), one prose file (`.gitignore`). Overall: TEST INTEGRITY PASS.

## How to verify locally

The gates ran inside the pinned image with `PYTHONPATH=/work/src` and no install
step. From a checkout of the candidate tree, the equivalent commands a human
would type are:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"   # sets up ruff, mypy, pytest, pytest-cov locally

ruff check .
ruff format --check .
mypy src
pytest -q --cov=src --cov-report=term-missing --cov-fail-under=60
python -c "import seating_planner; print(seating_planner.__version__)"
```

(`pip install -e .` puts the `src/` package on the path, which is the local
substitute for the sandbox's `PYTHONPATH=/work/src`; if you skip the editable
install, prefix the pytest and python commands with `PYTHONPATH=src` instead.)
The two single-test commands ac4 and the integrity check run, exactly:

```bash
pytest -q tests/test_scaffold.py::test_package_imports
pytest -q --cov=src --cov-report=term-missing --cov-fail-under=60
```

(Local tools will not match the gate image's pinned versions — ruff 0.16.7,
mypy 2.3.1, pytest 9.1.1, pytest-cov 7.1.0, python 3.12 — so a clean local run
is evidence, but the binding result is the gate's.)

## Rollback

Nothing in this change has yet taken effect: the merge mode is `human_required`
and `run.json` shows the run halted at the doc step with no pull request
opened, so the branch `bean/bean-001-project-scaffold-with-linting-typing-and`
(head `ca950efaec565e821fe1bf6ad294f7fac86c14de`, based on
`e9a5b33e9482f0b23d5678e96622f2c5a92a2a83`) exists only locally. Rollback as
of now is simply *not merging it* — and deleting the branch if desired:

```bash
git branch -D bean/bean-001-project-scaffold-with-linting-typing-and
```

If the change is ever merged first, revert the merge commit — the change is a
single coherent addition, so one revert undoes it:

```bash
git revert -m 1 <merge-sha>
```

There is nothing else that happened that would need undoing: no data, no
migration, no deployment, no `factory/` modification, and no installed artefact
to clean up — the package was never installed; it was imported via
`PYTHONPATH`, not placed in `site-packages`, so nothing lingers in a Python
environment. After rollback the repo is exactly its pre-bean state, with one
consequence worth knowing: the lint, format and types gates go back to passing
vacuously (no Python project files for them to check) and the unit gate fails
for lack of a package — so the attribution property this bean built (a red
gate is caused by the bean that made it red) is itself undone until the
scaffold lands again. The pipeline's own record in
`factory/runs/bean-001-20260915T192025Z/` is git-ignored by the very
`factory/runs/` line this bean preserves, and survives any rollback as
history.
