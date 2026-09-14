---
name: pipeline-pr
description: |
  Push a pipeline run's branch and open the pull request against main via
  gh pr create, with the change summary, test evidence, and audit caveats in
  the PR body. Never merges. Use when the user asks to push and open a PR for a
  finished pipeline run (pr step of the pipeline), after the package audit
  has passed.
---

# pipeline-pr

The last step: make the work reviewable by a human. This skill **opens a PR
and stops.** It never merges, never targets anything other than `main`, and
treats `git push --force` and `gh pr merge` as out of scope — they are not
available to you here, and neither flag `--auto` nor any merge option may be
passed to `gh pr create`.

## Rules

- Project specifics come from `ai/pipeline/config.json` in the current working
  directory. Never hardcode repo paths.
- If a precondition below is not met: **write why to
  `<run-dir>/QUESTIONS.md`** and stop. Do not bypass a failed or missing
  package verdict — that is the whole point of the pipeline.

## Inputs

Arguments: `<run-dir>` — a run whose package audit passed.

## Preconditions (refuse if any fail)

1. The latest `<run-dir>/verdicts/package.attempt-*.json` has `"verdict": "PASS"`.
2. The current branch matches `run.json .branch` and is a bean branch
   (config `branch_pattern`), not `main` or any protected branch.
3. `<run-dir>/checks.json` exists with `"overall": "pass"` — otherwise re-run
   `bash ai/pipeline/checks.sh <run-dir>` once; still failing means stop.

## Process

1. Gather the body's content:
   - **Summary** — from `implementation.json` (or `spec.json` if doc was not
     run): what changed and why.
   - **Test evidence** — the gate results from `checks.json` (name, status,
     exit code), and any revert-check results from `run-notes.md`.
   - **Caveats** — every non-blocker finding across
     `verdicts/*.attempt-*.json`, one line each, so reviewers know what the
     audits saw and chose not to block on.
2. Push: `git push -u origin <branch>` (never `--force`).
3. Open: `gh pr create --base main --title "feat: <bean> — <title>" --body …`.
4. Print the PR URL. That is the end of this step. A human merges, if anywhere.
