---
name: factory-run
description: |
  Drives a pipeline run end to end from the user's request: picks the
  BEAN id, optional --resume <run-dir>, and --stop-after <step>, invokes
  ai/pipeline/orchestrate.sh, surfaces <run-dir>/QUESTIONS.md verbatim when
  the driver halts, and reports the per-step verdicts plus the telemetry
  table when the run completes. Use when the user asks to run the pipeline
  for a bean, resume a halted or stopped pipeline run, or continue a run
  up to a named step ("run the pipeline for BEAN-NNN", "resume BEAN-NNN",
  "resume <run-dir>", "run BEAN-NNN up to checks").
---

# pipeline-run

Thin operator skill: `orchestrate.sh` does the work (tier selection, retry
loop, halt, rollup). Never do a step's work yourself.

## Inputs

Pick flags from the user's request — do not ask for what is already given:

- `BEAN-NNN` (required) — the bean to process.
- `--resume <run-dir>` — when the user names a run directory or says "resume".
- `--stop-after <step>` — when the user says "up to <step>" / "stop after <step>".

## Do

1. Work from the repo root (the directory containing `ai/pipeline/`).
   Project specifics come from `ai/pipeline/config.json`; never hardcode paths.
2. Invoke exactly:
   `bash ai/pipeline/orchestrate.sh BEAN-NNN [--resume <run-dir>] [--stop-after <step>]`
3. **Exit 3 (halt):** read `<run-dir>/QUESTIONS.md`, show it verbatim, and stop.
   Do not attempt the fix the run is asking a human to decide.
4. **Exit 0 (completed / stopped-after):** report the per-step verdicts from
   the driver's Step verdicts output (or `<run-dir>/steps.jsonl`), then the
   telemetry table (driver output or `<run-dir>/telemetry.json`).
5. **Any other non-zero exit:** show the failing output tail and the
   preflight/gate lines; do not retry on your own.
