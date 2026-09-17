# QUESTIONS — bean-002: stopped at `spec` — dependency bean-001 missing from the working tree

- Run directory: `factory/runs/bean-002-20260916T104745Z`
- Tier: full
- Stopped: 2026-09-16T10:56:12Z

## The conflict, both sides quoted

**Side 1 — the bean, which assumes bean-001's output exists in this tree**
(`factory/beans/bean-002-core-domain-models-for-events-tables-gue/bean.yaml`):

```yaml
dependencies: [bean-001]
context:
  read_paths:
    - src/seating_planner/__init__.py
    - pyproject.toml
```

`context.read_paths` names two files the bean's own reading list lives on. `allowed_write_paths`
(`src/seating_planner/domain/**`, `tests/domain/**`) sits inside the package and test layout that
bean-001 is the one that created.

**Side 2 — the working tree the run will build in (repo root `/work`)**

A full listing of `/work` outside `factory/` shows only:

```
/work/README.md
/work/.gitignore
```

- No `pyproject.toml`.
- No `src/` — so no `src/seating_planner/__init__.py`, and no place for `src/seating_planner/domain/`.
- No `tests/` — so no `tests/domain/`, and no `tests/test_scaffold.py`.
- `/work/.gitignore` is still the one-line pre-scaffold state (`factory/runs/`), not the
  extended version bean-001's diff produced (`__pycache__/`, `*.pyc`, `.pytest_cache/`,
  `.mypy_cache/`, `.ruff_cache/`, `.coverage`, `.venv/`).

So the tree is in its **pre-bean-001 state**, not a state that contains bean-001.

## Where I read each thing

- Bean: `factory/beans/bean-002-core-domain-models-for-events-tables-gue/bean.yaml` (read in full).
- Working tree: direct listing of `/work` (`ls -la /work`, `find /work -maxdepth 3`) from this
  session; `/work/.gitignore` read directly.
- Bean-001 completion: `factory/runs/bean-001-20260915T192025Z/`
  - `gate.json` — `"overall": "pass"`, all four gates pass, all four ACs pass.
  - `steps.jsonl` — `pr` step FAIL on attempt 1, `sync` PASS and `pr` PASS on attempt 2 at
    2026-09-15T23:46:23Z.
  - `diff.txt` — its diff adds exactly `.gitignore` (extended), `pyproject.toml`,
    `src/seating_planner/__init__.py`, `tests/test_scaffold.py`.
- Gate sandbox location: `factory/pipeline-config.json` — `sandbox_env.PYTHONPATH=/work/src` and the
  comment "Points ... there is no install step"; the bean-001 spec itself
  (`factory/runs/bean-001-20260915T192025Z/spec.md`) documents `/work/src` as the source root the
  gates run against. So `/work` is the correct tree to be looking at — this is not a wrong-directory
  reading on my part.

## One aggravating detail I could not resolve from inside this session

`/work/.git` is a **read-only, empty `tmpfs` mount** (`mount` shows
`tmpfs on /work/.git type tmpfs (ro,...)`; `ls /work/.git` → "Permission denied", every `git`
command → "fatal: not a git repository"). I cannot check out, list, or inspect any branch from here,
so I cannot verify which commit this tree claims to be at or whether bean-001's branch tip is
recoverable locally.

## Why I stopped rather than worked around it

- Creating `pyproject.toml` or `src/seating_planner/__init__.py` is **outside this bean's
  `allowed_write_paths`**, so no task in `tasks.yaml` could legally produce them.
- Every task this bean needs (`src/seating_planner/domain/**` importing and extending the package,
  `tests/domain/**` running under a 60%-coverage-gate package) presupposes the scaffold. Specifying
  around a missing foundation is exactly the workaround the spec process is told never to invent.

## Questions for a human

1. Should the `/work` tree for this run contain bean-001's work (merged into `main`, or the
   run branch rebased onto bean-001's tip)? If so, what sync/checkout step restores it — the
   current tree looks pre-bean-001 even though bean-001's PR passed at 2026-09-15T23:46Z.
2. Is it expected that `/work/.git` is an empty read-only tmpfs in this stage? Git is unusable from
   the spec session, which rules out self-checking the branch state.
3. Once the tree is correct, `spec` should simply be re-run; nothing in this run directory needs
   rework on the bean's merit — I stopped before writing `spec.md` or `tasks.yaml`.
