---
name: factory-spec
description: |
  Write the plan for one bean: a structured Markdown spec a newcomer can read,
  and a task list the controller will build from one task at a time. Use at the
  specify step; invoked as /skill:factory-spec <bean-id> <run-dir>. You write
  content, never HTML — the controller owns the rendering.
---

# pipeline-spec

You are turning an approved bean into two things: a document a person will read
before agreeing to the change, and a task list a machine will execute one step
at a time. They are written together because they constrain each other — a task
you cannot describe is a task you should not have invented, and a section you
cannot fill is usually a sign the decomposition is wrong.

Write Markdown and YAML. **Never write HTML.** The controller renders your
Markdown into a fixed template; a model writing raw HTML turns a content problem
into a lint problem, and the content problem is the one worth having.

## Rules

- **Fresh context.** Everything is on disk: the bean, the repo, the run dir.
  Never assume a prior conversation.
- **The bean is the contract, and it is narrower than your judgement.** Its
  `allowed_write_paths` bound every task. If the change genuinely cannot be done
  inside them, say so and stop — do not plan around it.
- If the bean conflicts with what is actually in the code, or something needed is
  missing: **write `<run_dir>/QUESTIONS.md`** (the conflict, both sides quoted,
  where you read each) and stop. Do not invent the missing instruction. A real
  run once invented a workaround that was worse than the gap it papered over.
- On a retry you are given a findings file as a final argument, and one of two
  things is in it.
  - `<run_dir>/verdicts/spec.attempt-*.json` — the judge's verdict. Read the
    latest and fix **every** finding before rewriting.
  - `<run_dir>/spec-check-findings.md` — the controller's own checks. These are
    not opinions: each line is something a script measured, and the run cannot
    continue while any of them says FAIL. Fix what it names. Do not satisfy a
    length complaint by padding, and do not satisfy a coverage complaint by
    deleting the thing that was not covered.

  Either way: a retry that re-submits the same plan with different words spends
  an attempt and teaches nobody anything.


## git is not available in here, and that is not a fault to report

`/work/.git` is an empty read-only mount. Every `git` command answers *"fatal:
not a git repository"*, `ls /work/.git` answers *"Permission denied"*, and both
are working as intended: the real worktree stays outside this boundary so that
history cannot be read or rewritten from inside, and the controller makes every
commit after it decides an attempt is worth one.

**So do not spend a session establishing what branch you are on.** A worker on
bean-002 did, carefully and correctly, and reported it as an unresolved
aggravating detail — which is a session spent on a fact that could have been one
paragraph. Everything git would have told you is already in the tree, as files:

- `factory/runs/<run>/diff.txt` — exactly what an earlier bean changed.
- `factory/runs/<run>/gate.json` — whether its gates passed, gate by gate.
- `factory/runs/<run>/steps.jsonl` — how that run ended, step by step.
- `factory/runs/<run>/run.json` — which bean, which commit it started from.

**What the tree contains is the answer, not what git would say about it.** If a
dependency's work is missing from `/work`, it is missing — that is a real finding
and stopping to say so is right. Say it from the listing, which is evidence, and
do not qualify it with what you could not check in git.

## ruff and mypy are in here, and the rest of the toolchain is not

This container has node, git's binary, pi, and `python3` with `ruff`, `mypy` and
the project's runtime dependency (ortools) — at exactly the versions the gate
image pins, so that code written here can be checked here. It has no `pytest`
and no project venv. The gates and the task `verify` commands still run in a
separate, digest-pinned image, from a clean state, by the controller, so that
every "it passed" in this repository is a claim about one known toolchain rather
than about whatever happened in the session that wrote the code.

**So run ruff and mypy rather than reasoning about what they would say, and do
not go looking for anything else.** A clean run of your own is a self-check,
not a verdict, and not something to report as one. For everything you cannot
run — `pytest`, the `verify` commands — read them as the definition of done and
say plainly what you could not check. Calling that a defect in your environment
is not right, and neither is softening a conclusion because of it.

## Inputs

`<bean-id> <run-dir>`. Read, in this order:

- the bean YAML (`factory/beans/<id>-<slug>/bean.yaml`) — intent, background,
  `allowed_write_paths`, `acceptance_criteria` with their `verify`, `constraints`,
  `non_goals`, `size_budget`, and `invariants_ref` if it has one;
- the repo's own instructions (root `CLAUDE.md`/`AGENTS.md`) and conventions;
- **the code the change will touch.** Read it before describing it. "Current
  behaviour" is a section about the real repository, not about what you assume a
  repository like this contains.

## What to write

### `<run_dir>/spec.md`

These seven sections, in this order, each with real content. The controller lints
them and a thin section fails the step before a judge ever sees it.

**"Thin" is measured, not judged: under 80 characters of prose fails.** That is a
low bar and it is not the target — it is the floor below which a section is a
fragment rather than a paragraph. A real run failed on a Proposed change section
of 77 characters, which is the kind of near miss that happens when the writer
does not know the number. Now you do. Two or three sentences per section clears
it comfortably; aim at the reader, not at the count.

- **What and why** — the bean's intent in plain language, plus the background a
  newcomer needs. Assume no knowledge of this codebase, this stack, or this domain.
- **Current behaviour** — how the relevant code works today, with a short
  annotated code block taken from the real repo. If the file does not exist yet,
  say that plainly; do not invent a "before".
- **Proposed change** — per task: what changes, where, and an illustrative code
  block labelled with its file path (```python src/pkg/thing.py).
- **Risk** — what could break, how you would notice, how you would back it out.
- **Blast radius** — files, modules, callers, data, deployments touched, and
  explicitly what is **not** touched.
- **Verification** — a table of the bean's acceptance criteria with the `verify`
  for each, plus any invariants by name.
- **Open questions** — anything you had to assume. Non-empty here is a signal to
  the judge, not a failure: an assumption you declared is cheaper than one you hid.

### `<run_dir>/tasks.yaml`

The unit of the build loop. Each task gets its own worker session with no memory
of the others, so each must stand alone.

```yaml
schema_version: tasks/1.0.0
bean_id: bean-001
tasks:
  - id: task-1
    title: Short imperative title
    intent: One outcome, finishable and verifiable in a single session.
    write_paths: [src/pkg/thing.py]      # a SUBSET of the bean's allowed_write_paths
    depends_on: []                        # task ids that must be verified first
    satisfies: [ac1]                      # acceptance criteria this contributes to
    verify:                               # run by the CONTROLLER, not by you
      - { kind: command, run: ["sh", "-c", "grep -q thing src/pkg/thing.py"] }
    max_attempts: 3
    teaching_note: Why this step exists, for the implementation document later.
```

What the controller checks, so you may as well get it right:

- **Every acceptance criterion is claimed by at least one task** (`satisfies`).
  An unclaimed AC means the bean can pass its tasks and still fail its criteria.
- **`write_paths` ⊆ the bean's `allowed_write_paths`.** An edit outside a task's
  paths throws the whole attempt away, so a task with paths it does not need is a
  trap you set for yourself.
- **Every `verify` must be able to fail.** `test -f` on a file the task itself
  creates proves the task ran, not that it worked. Prefer a check of behaviour.
  `kind: manual` and `kind: judge` are refused in a task list — the controller
  cannot run them, and a criterion it cannot run is not a criterion.
- **`depends_on` is real.** Tasks run in dependency order; a task that silently
  needs an earlier one's output but does not say so will run first and fail.
- **Stay inside `size_budget`.** Over `max_tasks` and the bean goes back to a
  human to be split, which costs a day. Fewer, larger-but-still-verifiable tasks
  beat many trivial ones.

## Process

1. Read the bean, the conventions, and the code.
2. Decompose first, on paper: what are the tasks, what does each one finish, how
   would a machine know it worked? Then write `tasks.yaml`.
3. Write `spec.md` describing that decomposition. If a section is hard to fill
   honestly, the decomposition is probably wrong — fix the tasks, not the prose.

That is the whole job. Do not record the step, do not run git, do not render
anything: the controller opens and closes the attempt, validates both artifacts,
and renders the HTML. Write the two files and finish the session.

**Write them with the write tool before describing them.** A real doc session
ended its turn with "From now on, I'll create the documentation" and stopped,
having produced nothing after thirty-seven minutes — the announcement replaced
the act. If you find yourself describing a file you are about to produce, produce
it instead; the report at the end is where you say what you did.

## Report

What the change is, the task list with each task's verification, anything you had
to assume, and anything about the bean that struck you as wrong. The last one
matters: you are the first thing to read the bean closely since a human approved
it.
