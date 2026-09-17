# Verdict Schema

The contract that every audit step in the change pipeline writes against
(stages 2–3). An audit step reads the diff and the spec, and produces exactly
**one verdict JSON object per audit attempt**.

**Verdict files come only from audit steps.** An authoring step (`spec`,
`implement`, `doc`, `pr`) records its verdict on the `end` line in
`steps.jsonl` and writes **no file in `verdicts/`** — no verdict file for an
authoring step is expected, and its absence is never a finding. Likewise,
audits the run's tier does not include (e.g. `audit-spec` on the `small` tier)
produce no verdict files, and their absence is not a finding. When checking
verdict files, count only the audit steps the tier actually ran. The pipeline records the attempt via
`step.sh <run_dir> <step> end <verdict>` and stores the full object at
`<run_dir>/verdicts/<target>.attempt-<n>.json`. `<target>` is the audit target —
`spec`, `impl`, `doc`, or `package` — so the `audit-impl` step stores
`impl.attempt-<n>.json`. **Name the file after the target, never the step name:**
naming it after the step (`audit-…` as file stem) or any other spelling
makes the verdict invisible to the driver, and the run treats the audit as if
it never produced a verdict. (The `step` field inside the JSON carries the step
name; the file name carries the target.)

## JSON shape

```json
{
  "step": "audit-impl",
  "verdict": "FAIL",
  "attempt": 2,
  "findings": [
    {
      "severity": "blocker",
      "file": "src/features/inventory/useItem.ts",
      "line": 142,
      "summary": "Endpoint ignores the X-Site-Id header, so deductions are site-blind",
      "evidence": "useItem.ts:142 calls /api/items/:id with no site param; spec §3.2 requires site scoping"
    },
    {
      "severity": "minor",
      "file": "src/features/inventory/useItem.ts",
      "line": 30,
      "summary": "Unused import",
      "evidence": "tsc --noUnusedLocals reports 30:1"
    }
  ],
  "scope_check": {
    "pass": true,
    "details": "Diff touches useItem.ts and two tests, all within spec §3 scope"
  }
}
```

### Fields

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `step` | string | yes | Step name exactly as used in `steps.jsonl`, e.g. `audit-impl` (the step name — the *file* holding this verdict is named after the target, `impl.attempt-<n>.json`) |
| `verdict` | `"PASS" \\| "FAIL"` | yes | See rules below |
| `attempt` | integer ≥ 1 | yes | Must match the `attempt` in `steps.jsonl` |
| `findings` | array | yes | May be empty. Each finding: `severity` ∈ `blocker \| major \| minor`, `file`, `line` (nullable if file-level), `summary` (one sentence), `evidence` (a command output, a quote, or a link that proves the finding — **no evidence, no finding**) |
| `scope_check` | object | yes | `pass`: did the diff stay inside what the spec described; `details`: which paths the diff touched vs. what the spec authorized |

## Rules

1. **Any `blocker` finding forces `verdict: "FAIL"`.** A verdict of `PASS`
   with a blocker finding is invalid and the orchestrator must reject it.
2. **A `FAIL` returns control to the step that produced the artifact.** The
   authoring step (e.g. implementation) receives the findings and re-enters
   with `attempt` incremented. `major` and `minor` findings do not by
   themselves force FAIL, but a `FAIL` verdict requires at least one finding
   of any severity — a FAIL with zero findings is invalid.
3. **After 2 failed attempts on the same step — or after 1 failed attempt that
   produced no usable verdict — the run halts and writes `QUESTIONS.md`** at the
   run directory root for a human. The orchestrator does not start a third
   attempt on its own, and it does not retry blindly with no findings to pass
   on. `QUESTIONS.md` must contain: the step name, each recorded failed
   attempt's verdict (or, where a verdict file is missing, the expected
   verdict file name *and* what `verdicts/` actually contains), and the
   specific question or conflict that is being escalated. It must not claim
   actions that were not taken (e.g. a re-entry and re-audit that never
   happened on the first recorded failure).
4. **The `QUESTIONS.md` rule:** when the instructions conflict with what is
   actually in the code, or when a needed instruction appears to be missing,
   **stop and write the question rather than inventing a workaround.**
   Guessing around an underspecified or contradictory instruction is how
   silently-wrong changes ship; an explicit question costs one human turn and
   keeps the audit trail honest.

## Machine-readable summary

```
verdict ∈ { PASS, FAIL }
valid = verdict == PASS ? (no blocker findings AND scope_check.pass == true)
                        : at least one finding (a FAIL with zero findings is invalid)
failed_attempts(step) = count of attempt-N verdicts with verdict == FAIL
halt  = failed_attempts(step) >= 2  ⇒  write QUESTIONS.md, stop run;
        the orchestrator does not start a third attempt on its own
```
