---
name: factory-intake
description: |
  Turn a requirements conversation into work items, questions and draft beans
  for one target repository. Invoked as /skill:factory-intake <mode>, where mode
  is `extract` or `draft`. Everything you need is under /work; write only under
  /work/intake.
---

# factory-intake

A person described, in their own words, software they want built. Your job is to
turn what they said into work the line can build one bean at a time, and to ask
about what they did not say, instead of guessing. The person reviews everything you
write before any of it is built, so an honest question is worth more than a confident
invention.

## What is where

| Path | What it is | May you write it? |
| --- | --- | --- |
| `/work/source.md` | The transcript: what the person said. | no |
| `/work/repo/` | A snapshot of the target repository as it is today. | no, it is read-only |
| `/work/reference/bean.schema.json` | The schema every bean must satisfy. | no |
| `/work/reference/example-bean.yaml` | One real approved bean from another project, for its shape only. | no |
| `/work/intake/` | Your output, and the inputs from earlier rounds. | **yes, and only here** |

There is no git in here, and no network. Do not spend the session establishing that.

## Mode `extract`

Read `/work/source.md` and the repository. Write two files.

**`/work/intake/work-items.yaml`**, a list under `items:`. Each item is one thing the
person asked for:

```yaml
items:
  - id: wi-1                      # wi-1, wi-2, ... in the order they arise
    title: Human places an X by clicking a cell
    summary: >
      One or two sentences, in plain words, of what the person wants and why.
    excerpts:                     # the person's own words, copied EXACTLY from source.md
      - "click on an area inside the grid to perform an X"
```

- Every excerpt is copied character for character from `source.md`. The controller
  checks that each one is in the source, and an excerpt that is not there is rejected.
  Quote a short phrase or sentence, never a paraphrase.
- One item is one behaviour a person could check. "Build the app" is not an item;
  "the board is drawn as a 3 by 3 grid" is.
- Include what the setup needs, such as a GUI entry point, even when the person said
  it only in passing. Do not add features they did not ask for.

**`/work/intake/questions.yaml`**, a list under `questions:`. Each question is about
something a builder would have to decide, where the transcript does not decide it:

```yaml
questions:
  - id: q-1
    about: [wi-4]                 # the work items it affects
    question: What should happen when the board fills with no winner?
    why: The transcript names a win and a loss but not a draw, and every game can end in one.
    recommendation: Show "It's a draw." and offer a new game.
```

- Every question carries a `recommendation`, which is the answer you would pick and
  that you think the person is most likely to accept. The person may just say yes.
- Ask only about what changes what gets built. Four good questions beat twelve.

## Mode `draft`

Read `source.md`, `intake/work-items.yaml`, `intake/questions.yaml`,
`intake/answers.yaml` (the person's answers; an answer of `accept` means your
recommendation stands), the repository, and `intake/instructions.md` if it exists.
Write one bean per file: `/work/intake/drafts/bean-001.yaml`, `bean-002.yaml` and so on.

If `intake/instructions.md` exists, this is a revision round. It says which beans
to change, split, merge or leave alone. Do exactly what it says, rewrite only the
files it names (plus any new ones a split needs), and delete the file of a bean
that a merge removes. If `intake/check-findings.md` exists, the controller rejected
the last drafts, and each line names a file and what is wrong with it. Fix every
finding.

Each bean must satisfy `/work/reference/bean.schema.json`. The rules that matter
most:

- `schema_version: bean/2.0.0`, `id: bean-NNN` matching the file name, and
  `repo:` set to the repository named in `intake/session.json`.
- `status: draft`. Never write `approved`, and never write an `approval` block.
  Only the person approves.
- `source: { kind: transcript, ref: source.md, date: <session date>, excerpt: ... }`.
  The excerpt is copied exactly from `source.md`, as in extract mode.
- `acceptance_criteria`: each has an `id` (`ac1`, `ac2`, ...), `text`, and a
  `verify` that a machine can run:
  - `{kind: test, test_id: "tests/test_board.py::test_three_in_a_row_wins"}`, where
    the test is one the bean itself will write. Prefer this.
  - `{kind: command, run: ["ruff", "check", "."]}`, an argv array; exit 0 means met.
  - `{kind: manual, note: "..."}` only for what no headless test can see, like how a
    window looks. It forces a human review, so use it sparingly and say why in the note.
- Keep game logic separate from the GUI so that almost every criterion is a
  headless test. Tests run in a container with no display **and no Tk library**:
  `import tkinter` fails there with `libtk8.6.so: cannot open shared object file`.
  So a module that imports `tkinter` (or any GUI toolkit) cannot be imported by
  any test. Put every rule of the program in modules that import no GUI, test
  those, and keep the GUI module a thin layer whose own criteria are `manual`.
- `allowed_write_paths`: the narrowest globs the bean needs. Two beans should not
  both own the same file unless one depends on the other.
- `dependencies`: the ids of beans that must land first.
- `size_budget: { max_tasks: N, max_files: N, max_diff_lines: N }`. Size each bean to
  fit about four tasks and a few hundred lines. If it would not fit, split it into two
  beans instead of raising the budget.
- `definition_of_done`: `["all AC verify pass", "gates green", "spec and impl-detail docs accepted"]`.
- `context.background`: explain the bean to a competent engineer who has never seen
  this repository. Say what exists, what this bean adds, and why.
- The first bean may need to set up the project (package layout, tooling). Read
  `/work/repo/` first and set up only what is missing.

Beans are ordered so each one can be built on the ones before it. Bean 001 has no
dependencies.

## Before you stop

Re-read every file you wrote against these rules. A file the controller rejects
costs the person a round. Then stop. There is nothing to report beyond the files.
