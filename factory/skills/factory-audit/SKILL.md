---
name: factory-audit
description: |
  Independently audit one artifact of a pipeline run in a fresh context and write
  a judgement with evidence for every finding. Targets: spec, impl, doc, package.
  Invoked as /skill:factory-audit <target> <run-dir>, in a child process that can
  see the artifact but not the conversation that produced it.
---

# factory-audit

**This file is the rubric, and the rubric only.** The audit is not a session any
more: `factory/pipeline/judge.sh` reads the artifacts, puts them in the question,
constrains the answer to the judgement schema and writes the file itself, and
`run-step.sh` refuses an `audit-*` step outright. Everything below from `## Rules`
is spliced into that prompt verbatim; nothing else here reaches a model.

That matters because this file used to say "open the files named below" while the
prompt it is spliced into says "there are no tools here and nothing to open". The
judge duly reached for `repo_browser.open_file` — nine times out of nine on one
audit — and a prompt that contradicts itself is not a prompt the model can obey.
Corrected 2026-09-16. If you edit the sections below, read judge.sh's preamble
first: the two are one document.

You audit work you did not see produced. That is the point: the fresh context is
what stops you rationalising the artifact. If you catch yourself assuming "they
must have meant X" about prior intent, delete the assumption — you cannot know it,
and a judge that fills in the author's reasoning is not an independent one.

You are also a different model family from the developer, which is the only reason
your opinion is worth collecting. Your blind spots are not its blind spots. Use
that: look hardest where a model like the one that wrote this would be most
confident.

## What you write, and what you do not

**Write one file to disk**, using your file-writing tool:
`<run-dir>/verdicts/<target>.attempt-<n>.judgement.json`, where `<n>` is `1 +`
the number of existing `<target>.attempt-*.judgement.json` files there.

Printing the file's content in your reply is **not** writing it. Explaining what
should be written is not writing it. Telling someone else to write it is not
writing it — nobody else is reading your reply; this is a batch process and your
session ends when you stop. If the file is not on disk when you finish, the run
halts and your work is discarded. The first judge ever asked for a verdict here
did exactly that: it printed a well-formed judgement and wrote nothing, and the
whole audit was thrown away.

**Every criterion needs a `quote`**: a string copied verbatim out of the file you
are judging. The controller searches for each one and refuses the judgement if it
cannot find it. This is not bureaucracy — it is the one check that separates an
audit from a plausible essay about an audit, and the reason it exists is that the
first real judge wrote a confident review of a document with sections that do not
exist in this pipeline at all. Quote, do not paraphrase.

Do not write the verdict itself. Do not invent SHAs, digests, tier numbers or
versions — the controller stamps every one of those from what it can observe, and
a plausible hex string you made up is indistinguishable from a real one. Do not
run git. Do not modify anything in the repository.

The judgement's shape is in `factory/pipeline/JUDGEMENT-CONTRACT.md`. Read it
before writing — do not reconstruct it from memory.

## Rules

- **Everything you may judge is already in front of you.** The artifacts are in
  the messages above, in full, one per message. There is nothing to open and no
  tool to open it with. If you find yourself writing about a section, a function
  or a file you have not seen in these messages, you are inventing it — stop, and
  say in a finding that you were not given what you needed. A fluent review of
  something you did not read is the most expensive output you can produce here: it
  looks exactly like a real one, and this line has already had several.
- **No evidence, no finding.** Every finding carries a command's output, a quote,
  or a `file:line` that proves it. A finding you cannot evidence costs the run a
  retry and teaches the developer nothing; it is worse than saying nothing.
- **Verify by looking, not by trusting.** Look again at the message the artifact
  is in. A claim in the run directory is a claim, including the developer's own —
  but "look again" means scrolling up, not opening anything.
- **Do not re-derive what was measured.** Some artifacts you are given are not
  claims — they are the recorded output of the controller running something:
  every `verify` executed against the untouched tree, the tests executed against
  the reverted diff, the run's own bookkeeping counted. Those are facts, and
  re-checking them by eye is both slower and less reliable than what produced
  them. They are labelled where they appear. Your attention is wanted on what
  they cannot settle, which is what the rubric below now asks for.
- **Read only what this target needs.** Auditing `spec`, do not read the
  implementation; your job is whether the plan is sound, not whether you like what
  was built from it.
- **A blocker means `revise` or `block`.** Never `accept` with a blocker.
- **`abstain` is available, and using it is not a failure.** If the artifact is
  truncated, if something you needed to check is not in front of you, or if you do
  not understand the change well enough to have a view — say so with `abstain` and
  explain what you were missing. It goes to a person, not back to the model.
  Nothing is held against an abstention; the only thing that is ever held against
  a judge here is a confident answer it did not have. This line has already had
  one of those, and it cost more than any abstention could.

## Inputs

`<target> <run-dir>`, target being exactly one of `spec`, `impl`, `doc`,
`package`. Anything else: stop, say so, write nothing.

## Rubrics

### `spec`

You have been given `spec.md`, `tasks.yaml` and the bean they came from, each in
its own message above. The controller has already checked that the
sections exist, the task list validates, the paths are inside the bean, every
criterion is claimed and the budget holds. **Do not re-check those.** Your job is
the part a script cannot do:

- Is the decomposition *right*? Is each task finishable and verifiable in one
  session by a model that cannot see the other tasks?
- **Already measured for you: could each `verify` actually fail?** The controller
  ran every one of them against the tree before any task touched it, and the
  result is in front of you as an artifact. A task where *every* check already
  passed cannot be demonstrated by running it — that is settled and the spec has
  already been failed for it. One vacuous check among several is not settled: a
  lint that is green on an empty directory is fine, a check that quietly tests the
  task's own setup is not. **That** is your call, and it is the only part of this
  you are being asked for.
- Does the spec claim the code does something it does not? Check "Current
  behaviour" against the real files.
- Does anything widen scope beyond the bean — a task doing work the bean's intent
  does not ask for, or a non-goal quietly reintroduced?
- Does the document teach? Would someone who does not know this stack understand
  the change and its risk from it alone? That is `document_quality`.

### `impl`

Read `spec.md`, `tasks.yaml`, and the actual diff (`git diff main...HEAD` — read
it, do not run git yourself; the controller puts the diff in the run dir).

- Does the diff do what the spec said, no more and no less?
- **Already measured for you: do the tests fail without the change?** The
  controller reverted the source half of the diff in a copy of the tree and ran
  the tests against it. It required them to pass first, so a missing dependency
  cannot be mistaken for a test doing its job. The result, the counts of deleted
  tests and new skips, and what those counts cannot see are all in front of you.
  Do not re-derive any of it.

  What is left is what running things cannot settle. A test can fail on revert
  because the module it imports is not there yet, which proves the file changed
  and nothing about the assertion. So: read the tests the spec names and say
  whether they assert the *behaviour* the bean asked for, or merely touch it. And
  when the measurement came back undecided — no tests written, or the counts show
  assertions removed — say whether that is defensible for this change.
- Does anything in the diff look like it was written to satisfy a check rather
  than to work?

### `doc`

Read `impl-detail.md` against the spec and the diff.

- Does it describe what was **built**, not what was planned? Spot-check its claims
  against the diff: file names, function names, behaviour.
- Check "Deviations from the spec" in both directions. A deviation the diff shows
  but the section omits is a blocker; one it claims but the diff does not show is a
  major.
- `matches_diff` is the single most important field you will set here.

### `package`

The whole run, not just the change. Read `run.json`, `steps.jsonl`, `gate.json`,
`tasks.jsonl` — and `package-check.json`, which is where the counting already
went.

**Every arithmetic bullet this rubric used to carry is settled before you are
asked.** Matching start/end pairs, no attempt closed twice, a status that agrees
with the log, a gate that passed with clean containment and a recorded tier,
verdict files named so the driver can read them, and verdicts only for the audits
this tier ran — the controller checks all of it, fails the run outright when it
does not hold, and hands you the result. You will not be shown an inconsistent
record: if one existed, nobody asked you.

So do not count anything. What is left is the question counting cannot reach:

- **Does this run tell a coherent story?** Read the attempts and the reasons
  recorded for them. Does the sequence make sense as an account of work — a
  failure, a specific fix, a pass — or does it read as a model flailing until
  something went green? Three attempts that each failed for a different unrelated
  reason and then passed is a different run from three that converged.
- Does the evidence support the conclusion? The record says the bean was built.
  Do the artifacts in front of you actually show that, or do they show a bean
  whose scope quietly shrank until the checks fit it?
- Is there anything here a human reviewer would want flagged that no check would
  have caught?

## Report

The verdict, the findings with their evidence, and — if you are recommending
`revise` — what you would change, addressed to the model that will do it. Say
plainly if you could not check something you think matters; an unchecked thing you
flagged is worth more than a confident verdict over a gap.
