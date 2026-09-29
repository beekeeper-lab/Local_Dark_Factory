# Phase-1 audit — 2026-09-29

**Audited commit:** `2456954` (main)
**Closing run:** `seating-planner-py/factory/runs/bean-021-20260929T165628Z` (bean-021, PR #17, merged after pre-merge review)
**Harness:** `bench/phase1-audit.sh <run> --cite-retry bean-006-20260924T191742Z`
**Result:** **green on the first run**: 8 ok, 0 findings (`audits/phase1-audit-20260929T214900Z.json`)
**Plan:** `plans/phase-1.md`

| Predicate | Value | Evidence |
| --- | --- | --- |
| `seven_stages_completed` | pass | all 12 steps of the full tier ended PASS, including real GitHub CI |
| `run_record_conforms` | pass | `run.json` validates against `run-record.schema.json` |
| `three_verdicts_schema_valid` | **amended_advisory** | 4 audits ran advisory and reached no verdict. The contract is proven without the judge: `test-audit-check.sh` is green (115/0) and `evidence/first-stamped-verdict-20260916.json` validates |
| `every_handoff_is_commit` | pass | 2 verified tasks, 2 commits, tree clean |
| `docs_rendered_and_read` | pass | read by Gregg Reed, 2026-09-29T21:48:42Z, recorded with `factory read` |
| `allowed_path_enforced_task_and_bean` | pass | task paths per attempt; whole diff against the bean |
| `task_retry_with_evidence` | **pass_cited** | from `bean-006-20260924T191742Z`: 1 retry that carried the real failure output |
| `independent_invariant_ran` | mechanism_proven | owner decision 2026-09-15; `tests/test-gate.sh` in both directions |

## The two amendments, stated plainly

1. **The local judge is advisory in v1.** One bounded fix was tried: the judge's tool call
   is now answered instead of resent. Qualification, stopped at 18 of 36 runs, gave 0 stamped
   verdicts, 11 of 18 still ending on tool calls, and 1 false accept
   (`evidence/judge-qualify-tool-answer-partial-20260929.log`). No real run has ever produced
   a stamped verdict. The gate that works is the pre-merge Claude review: it found a real
   defect in each of the 12 merged beans it checked. Judge accuracy is Phase 5 work.
2. **Retry evidence is cited from a second run.** The closing run needed no retry. Citing is
   labelled `pass_cited` and names the run.

## Pivot trigger, evaluated late

It was due after 10 beans and was never run. When evaluated on 2026-09-29, 10 of 10 beans
(001–010) reached a passing gate, so the count trigger does not fire. The same-class trigger
would have fired on the judge. It is answered by amendment 1.
