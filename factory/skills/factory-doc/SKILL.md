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
3. Write `<run-dir>/impl-detail.md`.

That is the whole job. Do not run git, do not commit, do not render anything, do
not touch the code — the change is already accepted and the document must not
alter what it describes.

## Report

What you wrote, anything in the diff you could not explain, and any place the
implementation and the spec disagree that you had to write up as a deviation.
