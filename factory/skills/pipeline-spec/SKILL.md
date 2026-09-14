---
name: pipeline-spec
description: |
  Write the spec of the change pipeline: given a bean ID and a run dir, read the
  bean, the repo conventions, and the code the change will touch, and produce
  spec.html (human) plus a complete, self-contained spec.json (machine). Every
  acceptance criterion carries a test that could fail. Use when the user asks to
  write the spec for a bean before implementing it (spec step of the pipeline).
---

# pipeline-spec

The spec step of the change pipeline. The spec is the contract the implementer
builds against and the auditor judges against — it must be complete, testable,
and honest about scope.

## Rules

- Fresh context: everything you need is on disk in the run dir and the repo.
  Never assume prior conversation.
- Project specifics come from `ai/pipeline/config.json` in the current working
  directory (paths, scripts). Never hardcode repo paths.
- If the bean's instructions conflict with what is actually in the code, or an
  instruction appears missing: **stop, write the conflict to `<run_dir>/QUESTIONS.md`**
  (the question, what you read, and where you read it). Do not invent a workaround.

## Inputs

Arguments (from the `/skill:` invocation or user message):
`<bean-id> <run-dir>` — e.g. `BEAN-124 ai/runs/BEAN-124-20260101T000000Z`.

## Process

1. Preconditions: run dir exists with `run.json`; the bean dir exists
   (config `bean_dir_pattern`, e.g. `ai/beans/BEAN-NNN-<slug>`).
2. Start the step: `bash ai/pipeline/step.sh <run-dir> spec start`.
3. Read the bean, the repo instructions (root `CLAUDE.md` or equivalent),
   convention docs under `ai/context/`, and the code the change will touch.
4. If `<run_dir>/verdicts/spec.attempt-*.json` exist, read the latest and fix
   every finding before rewriting — this is a retry, not a fresh attempt.
5. Read the target code. Conflict or missing instruction → QUESTIONS.md, stop.
6. Write both artifacts (see below).
7. End the step: `bash ai/pipeline/step.sh <run-dir> spec end`.

## Artifacts

### `<run_dir>/spec.json` — the source of truth (complete, not a summary of the HTML)

```json
{
  "bean": "BEAN-NNN",
  "problem": "what is wrong and why it matters",
  "approach": "the strategy in a few sentences",
  "changes": [
    { "file": "src/…", "action": "create|modify|delete", "what": "…", "why": "…" }
  ],
  "acceptance_criteria": [
    { "id": "AC1", "text": "…", "test": "a concrete command that FAILS without the change and PASSES with it" }
  ],
  "expected_files": ["every repo-relative path the implementation will touch, tests included"]
}
```

Quality bar the auditor will enforce:

- **Every** acceptance criterion names a test a person could run, and that
  command fails on the unmodified tree. "Verify manually" is not a test.
- `expected_files` is exhaustive — the package audit diffs
  `git diff main...HEAD --name-only` against it and reports anything extra as
  scope creep.
- Every path in `changes` and `expected_files` is repo-relative.

### `<run_dir>/spec.html` — the human review surface

Self-contained (no external assets), readable in a browser. Same content as the
JSON, presented for a human: problem, approach, file-by-file change table,
acceptance criteria each with its pinning test, expected-files list.
