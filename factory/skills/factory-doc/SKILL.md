---
name: factory-doc
description: |
  Write the implementation-detail document from the diff that was actually
  accepted — what was built, not what was planned. Invoked as
  /skill:factory-doc <run-dir>. Markdown only; the controller renders it.
---

# factory-doc

You are writing the document a person reads to understand a change they did not
make. It is the last thing between this work and a reviewer's attention, and it
is judged against the diff — not against the spec, and not against how sensible
it sounds.

The one rule that matters: **describe what was built.** The spec is what someone
intended. You have the actual diff. Where they differ, the diff is what happened,
and saying so is the job rather than an embarrassment.

Write Markdown. Never HTML — the controller renders it.


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

## the toolchain is not in here either, and that is not a fault to report

This container has node, git's binary, and pi. It has no `python3`, no `pytest`,
no `mypy`, no `ruff`, no venv, and nothing else on PATH that could run a project
of this kind. Deliberately: the gates and the task `verify` commands run in a
separate, digest-pinned image, from a clean state, by the controller — so that
every "it passed" in this repository is a claim about one known toolchain rather
than about whatever happened to be in the session that wrote the code.

**So do not go looking for an interpreter.** Real sessions have spent turns
discovering it is not there and then reporting it as an environment constraint
they had to work around. Read the `verify` commands as the definition of done,
write what would satisfy them, and finish. Saying plainly what you could not
check is right; calling it a defect in your environment is not, and neither is
softening a conclusion because of it.

## Inputs

`<run-dir>`. Read:

- `<run-dir>/diff.txt` — **the accepted change**. Read this first and read it
  properly. Everything you write is a claim about this file.
- `<run-dir>/spec.md` and `<run-dir>/tasks.yaml` — what was planned, and each
  task's `teaching_note`, which exists for exactly this moment.
- `<run-dir>/gate.json` — gate results, acceptance criteria outcomes, the binding
  tier, invariants. Your Evidence section comes from here, not from memory.
- `<run-dir>/tasks.jsonl` — how many attempts each task took, and what failed on
  the way. A task that took three attempts is worth a sentence.

## The seven sections

**Thin is measured, not judged: under 80 characters of prose fails the check**
before anyone reads the document. A low floor, not a target — below it a section
is a fragment rather than a paragraph. The spec step has failed a real run on a
77-character section, which is the near miss that happens when the writer does
not know the number.

The controller lints these. A thin one fails the step before a judge sees it.

- **Summary** — what was done, in two sentences, matching the diff.
- **Walkthrough by task** — per task: the diff hunks that matter, explained line
  by line as a teaching block, plus that task's `teaching_note`. This is the bulk
  of the document and the part a reviewer actually uses.
- **Deviations from the spec** — anything that differs from the plan, and why.
  If nothing differs, say what you compared and how you checked, not just "None":
  the pre-PR audit's `matches_diff` needs a claim it can agree or disagree with,
  and a bare "None" gives it nothing.
- **Risk & blast radius, as built** — restate both against the real change.
  Anything wider than the spec said is a finding; write it down yourself rather
  than leaving it to be discovered.
- **Evidence** — gate results, each acceptance criterion's outcome, coverage if
  recorded, test-integrity counts, and provenance: base and candidate SHAs, the
  gate image digest, the tier. Copy these from `gate.json`; do not retype them
  from memory and do not round them.
- **How to verify locally** — the commands a human can run, exactly as a human
  would type them.
- **Rollback** — the concrete steps. "Revert the commit" is only a rollback if
  nothing else happened; say what else happened.

## What makes this document good

- **Code blocks teach.** A hunk pasted without explanation is not a walkthrough.
  Say what the code does and why it is shaped that way; a reader who does not know
  this stack should still follow it.
- **No assumed knowledge.** Not of the codebase, the stack, or the domain.
- **Honest about what you do not know.** If a task failed twice before passing and
  you cannot tell why from the record, say that. It is more useful than a tidy
  narrative, and the judge is reading the same record you are.

## Process

1. Read the diff.
2. Read the spec, the tasks and the gate results.
3. **Write `<run-dir>/impl-detail.md`.** With the write tool, now, before you say
   anything about what you are going to write. A real run spent thirty-seven
   minutes reading, ended its turn with "From now on, I'll create the
   documentation", and stopped — the session closed with no file on disk and the
   whole step was wasted. Announcing the write is not the write. If you find
   yourself describing the document you are about to produce, produce it instead;
   you can say what you did afterwards.
4. **Write it in pieces, not in one call.** Create the file as soon as you have
   the Summary — the seven headings and whatever prose you have is enough for a
   first write — then fill the sections in with further writes or edits. A
   finished document here runs to sixteen kilobytes, and a session that tries to
   compose the whole of it before its first tool call is holding the entire thing
   in one turn. Three real doc sessions have died exactly there: one said "From
   now on, I'll create the documentation", one said "I am currently writing the
   documentation", and one said "Now writing the full document" four times in four
   consecutive turns and then exited, twenty-eight minutes in, with nothing
   written. A file that exists and is half-finished can be finished. A file that
   does not exist cannot.

That is the whole job. Do not run git, do not commit, do not render anything, do
not touch the code — the change is already accepted and the document must not
alter what it describes.

## Report

What you wrote, anything in the diff you could not explain, and any place the
implementation and the spec disagree that you had to write up as a deviation.
