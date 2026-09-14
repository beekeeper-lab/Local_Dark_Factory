---
name: pipeline-implement
description: |
  Build the change an approved pipeline spec describes: implement it on the
  current branch, prove with revert-checks that the spec's tests pin the change
  where possible, and run the pipeline quality gates. Use when the user asks to
  implement a spec (implement step of the pipeline). Reports success only after
  checks.sh passes.
---

# pipeline-implement

The implement step. You build exactly what the spec says. Scope beyond the spec
is a finding the package audit will report — do not "helpfully" widen it.

## Rules

- Fresh context: read the spec and the code; do not assume prior conversation.
- Project specifics come from `ai/pipeline/config.json` in the current working
  directory. Never hardcode repo paths.
- If the spec conflicts with what is actually in the code, or an instruction
  appears missing: **stop and write `<run_dir>/QUESTIONS.md`** (the conflict,
  both sides quoted, where you saw each). Do not work around it and do not
  invent the missing instruction from unrelated code. This rule exists because a
  real run (BEAN-121) invented a workaround that was worse than the gap.

## Inputs

Arguments: `<run-dir>` — e.g. `ai/runs/BEAN-124-20260101T000000Z`.

## Process

1. Read `<run_dir>/spec.json`. Confirm the latest
   `<run_dir>/verdicts/spec.attempt-*.json` verdict is `PASS`; otherwise stop
   and write QUESTIONS.md saying the spec was not cleared.
2. Start the step: `bash ai/pipeline/step.sh <run-dir> implement start`.
3. Implement `changes` file by file. Tests named by the spec must exist and pass.
4. Prove the tests pin the change. For each acceptance-criterion test whose
   source file already exists on `main`:

   ```
   bash ai/pipeline/fails-on-revert.sh <source-file> <test-command>
   ```

   Every one must PASS (test fails with source reverted, file restored).
   **Known limitation:** `fails-on-revert.sh` requires the source file to exist
   on `main`, so it cannot pin a test for a brand-new file. For those, skip the
   revert-check and record a line in `<run_dir>/run-notes.md` saying which test
   and why. Silently skipping is a defect.
5. Run the gates: `bash ai/pipeline/checks.sh <run-dir>`. Exits non-zero on any
   failure and writes `<run-dir>/checks.json`. **Do not report success until it
   exits 0** — fix and re-run as needed.
6. Commit the work on the run's branch (read `branch` from
   `<run-dir>/run.json`; you must be on it). Stage the files this step
   changed, but do NOT stage unrelated files the gates dirtied (e.g.
   `tsconfig.tsbuildinfo` — known dependency, see BEAN-126). One commit is
   fine; the message must name the bean, e.g. `feat: <what changed>
   (BEAN-125)`. Do not push — the `pr` step is the only one that pushes.
7. End the step: `bash ai/pipeline/step.sh <run-dir> implement end PASS`
   (the step only ends after the commit exists).
8. Report: what changed (files), the commit hash, revert-check results (and
   limitations noted), gate results, caveats found.
