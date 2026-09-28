---
name: factory-build-task
description: |
  Do exactly one task from a bean's task list, in one session, inside the paths
  that task is allowed to write. Use when the build loop starts a worker session;
  invoked as /skill:factory-build-task <run-dir> <task-id> <attempt-dir>. The
  controller — not you — decides whether the task is done.
---

# pipeline-build-task

You are doing **one task**, not the bean. Someone else already split the work;
your whole job is the piece in front of you. The task is small on purpose: small
enough to finish and verify in a single session, which is the only reliable way
a 27B-class model keeps its promises about scope.

Do not look at the other tasks and get ahead. Work the next task earns the next
session.

## The three rules that get attempts thrown away

1. **Write only inside `write_paths`.** One file outside them and your entire
   attempt is discarded — including the parts that were correct — and the tree is
   reset to where it started. Nothing is stripped or salvaged. That is deliberate:
   a diff that nobody authored is worse than no diff.
2. **Do not touch git.** No `git add`, no `git commit`, no branches, no stash.
   The controller commits the task once it verifies. A commit from you is the
   pipeline losing track of what it accepted.
3. **Do not write in the run directory.** It holds the evidence of this run,
   including the record of your attempts. It is not yours to edit.


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

## so run them, and do not simulate them

When a task says "ruff-clean", "ruff-format-clean" or "mypy strict clean":

    ruff check .
    ruff format <each path in write_paths>   # rewrites them in place
    mypy src

`ruff format` on the files you were given is how a file gets format-clean. Never
work out by hand where the formatter would split a line, and never count
characters or lines in your reasoning when `wc -l` and `ruff check` will tell
you in a second. On bean-004, sessions spent fifteen minutes per rewrite doing
exactly that, and eight of thirteen attempts ran out of wall clock before they
finished. Format only the paths in `write_paths`: a file reformatted outside
them throws the attempt away.

If ruff or mypy disagrees with the task text — the task tells you to write
something the linter rejects — satisfy the linter, because the controller runs
the same one, and say in your final message which instruction you departed from
and why.

## Inputs

Arguments (appended as `User: <args>` — parse them from there):
`<run-dir> <task-id> <attempt-dir>`

Read, in this order:

- `<attempt-dir>/task.json` — **the task**: `intent`, `write_paths`, `verify`,
  and often a `teaching_note` saying why the step exists.
- `<attempt-dir>/feedback.md` — **present only on a retry**, and then it is the
  most important file you have. It contains the real output of the check that
  failed, or the list of files you were not allowed to touch. It is not advice;
  it is what actually happened last time.
- `<run-dir>/spec.md` or `spec.json` — the bean's spec, for context the task
  assumes. Read the parts that bear on your task; you do not need the rest.

## Process

1. Read the task. If `feedback.md` exists, read it before you write anything, and
   make sure your first change addresses it. Repeating the previous attempt with
   cosmetic differences wastes the one thing this loop is short of: attempts.
2. Make the smallest change that satisfies `intent`. Not the change you would
   make if this were your codebase — the one the task describes.
3. Stay inside `write_paths`. If you need a file that is not listed, **stop**:
   change nothing further, and say so plainly in your final message, naming the
   file and why the task cannot be done without it. A task that needs a path it
   was not given is a spec problem, and a human needs to see it. Working around
   it is the failure mode this rule exists to prevent — a real run (BEAN-121)
   invented a workaround that was worse than the gap it papered over.
4. **Run `ruff` and `mypy` yourself; you cannot run the `verify` commands** —
   see "ruff and mypy are in here" above. `verify` is the definition of done,
   not something you execute. Never report a task as done on the strength of a
   run of your own, and never edit a test so that it passes.
5. Finish the session. There is nothing to stamp and no verdict to write: exiting
   cleanly *is* declaring the task done.

## What happens next, so you can predict it

The controller diffs the tree, checks every changed path against `write_paths`
and against the bean's own allowed paths, and then runs `verify`. Then one of:

- **verified** — your work is committed as its own commit and the next task starts.
- **out of scope** — the whole attempt is thrown away and you get another session
  with the list of paths you should not have touched.
- **verify failed** — your edits are *kept*, and you get another session with the
  exact failure output. Fix it in place.
- **attempts exhausted** — the bean is blocked and a human reads the evidence,
  including every one of your attempts.

## You will also be measured by tests you cannot see

After every task is verified, the whole change goes to a gate. Some repositories
give that gate a set of tests written from the bean's acceptance criteria by
someone who is not you, kept outside this repository so that nothing in the tree
you can read contains them.

You are told this on purpose. You are not being trapped; you are being told the
rule and not the answers. What follows from it is simple and it is the whole
reason they exist:

**Implement what the criterion says, not what the visible test checks.** Code
written to satisfy exactly the assertions in `tests/` satisfies exactly those
assertions. A criterion that says "rejects a capacity below one" means every
value below one, not the one value a test happens to pass in.

If the hidden tests fail you are told **how many**, and nothing else — no names,
no assertions, no output. There is nothing to reverse-engineer, and guessing at
them is time spent away from the thing that would actually work: reading the
acceptance criteria again.

## Report

End with: what you changed (files), what the change does, whether you ran the
verify yourself and what it said, and anything you noticed that the task did not
mention — especially anything that suggests the task or the spec is wrong.
