# Phase 1 — One bean, by hand, through every stage

**Status:** active since 2026-09-29 (plan written that day; the phase itself opened 2026-09-14).
**Goal:** one real bean goes from spec to PR through every stage, and each stage leaves
evidence that the exit script can check.

## Where it stands (measured 2026-09-29)

`bench/phase1-audit.sh` was run over all 26 run directories in `seating-planner-py`:

| Predicate | State | Evidence |
| --- | --- | --- |
| `seven_stages_completed` | **pass** | 14 runs, e.g. `bean-014-20260928T162157Z`: all 12 steps PASS, including real CI |
| `run_record_conforms` | **pass** | same runs |
| `every_handoff_is_commit` | **pass** | same runs |
| `allowed_path_enforced_task_and_bean` | **pass** | same runs |
| `task_retry_with_evidence` | **pass** | `bean-006-20260924T191742Z`, `bean-011-20260925T182220Z`: a task failed, retried with its output, then verified |
| `independent_invariant_ran` | **pass** (`mechanism_proven`, owner decision 2026-09-15) | `tests/test-gate.sh` |
| `three_verdicts_schema_valid` | **open**. No real run has a judge verdict the controller stamped. | 0 of 26 runs; judge qualification 2026-09-29 told apart 0 of 9 pairs |
| `docs_rendered_and_read` | **open**. Waiting on the owner. | documents render; `documents-read-by.txt` absent |

Every stage works except the judge.

## Tasks

- [x] **1. Evaluate the pivot trigger.** It was due after 10 beans and was never run.
      Result: 10 of 10 beans (001–010) reached a passing `gate.json`, so the count trigger
      does not fire. The same-class trigger would have fired on the judge: it produced no
      stampable verdict on any bean. It did not block anything only because audits run
      advisory. Separately, a Claude review found a real defect in each of the 12 merged beans
      it checked, even though every one had passed its gate. **Conclusion:** the developer
      model and the line hold up. The judge is the weak part, and a passing gate is not a
      quality signal on its own.
- [ ] **2. Fix the judge's tool-call failure. This is a bounded attempt.** 15 of 32 failed
      qualification runs were the judge calling a `repo_browser` tool that does not exist.
      Change `judge.sh` to answer any tool call with "no tools; judge from the artifacts
      given", and say the same in the system prompt. Then re-run `bench/judge-qualify.sh`.
      *Limit: one change, one qualification run (about 2 h).*
- [ ] **3. Produce three stamped verdicts on one real run.** Re-audit the spec, impl and
      package stages of a completed run (bean-014), using copies of the run directory, with
      audits non-advisory.
      *Limit: 3 passes. Stamped means the controller accepted it. Whether it is right is
      Phase 5's question.*
- [ ] **3-fallback, if 2 or 3 misses its limit.** Stop working on the judge in Phase 1.
      Amend the predicate so the verdict contract is proven by `factory/pipeline/tests/test-audit-check.sh`
      plus the one real stamped verdict in
      `evidence/first-stamped-verdict-20260916.json`. Record in the design document that in
      v1 the local judge is advisory and the pre-merge Claude review is the working gate.
      This is the same move the owner made for invariants on 2026-09-15.
- [ ] **4. The owner reads the two documents** for one run (`spec.html` and
      `impl-detail.html` of `bean-014-20260928T162157Z`) and records who read them and when in
      `documents-read-by.txt`. About 20 minutes. This is the one step that needs the owner.
- [ ] **5. Let the audit take evidence from more than one run.** Retry evidence comes from
      bean-006, and the closing run is bean-014. Change `phase1-audit.sh` to accept a
      `--cite <run>` for a predicate and to name the cited run in its report.
- [ ] **6. Closing ritual.** Compute the exit, generate the audit
      (`audits/PHASE-1-AUDIT-<date>.md`), correct the findings, re-run green, then commit
      `PHASE-1-COMPLETE` with tag `phase-1-complete`. Update the design document and demo to
      the owner.

## Exit

```yaml
phase_1_exit: { seven_stages_completed: pass, three_verdicts_schema_valid: pass | amended,
                every_handoff_is_commit: pass, docs_rendered_and_read: pass,
                allowed_path_enforced_task_and_bean: pass, task_retry_with_evidence: pass,
                independent_invariant_ran: mechanism_proven }
```

## Not in this plan

- Judge accuracy, meaning whether it catches real defects. That is Phase 5.
- Running more beans (021–030, 015–020). That is Phase 4 workload. bean-021 run 3 was already
  running when this plan was written. It finishes and gets its pre-merge review. No further
  beans start until Phase 4, except runs this plan needs as evidence.

## Amendments

_None._
