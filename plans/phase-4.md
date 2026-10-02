# Phase 4 — Lights-out to PRs

**Status:** active since 2026-10-02. Entry met (below). Some pieces already exist:
`factory go` runs a queue serially, `ensure_loaded` exists (`tests/test-ensure-loaded.sh`),
and there is per-step telemetry.
**Goal:** the line runs unattended for 48 hours or more and produces at least 25 completed
beans as PRs only. It can be stopped three ways and recovers from a crash.

## Entry

- Phases 2 and 3 complete. **Met:** `phase-2-complete` 2026-09-29, `phase-3-complete` 2026-10-02.
- **The owner reviews `factory/risk-policy.yaml`** (`factory policy` shows what each rule does).
  This file decides what the line may touch unsupervised, and no human has reviewed it yet.
  **Met 2026-10-02:** the owner approved it as is (`risk/2026-09-14`). On seating-planner, 27 beans
  are tier 2, 3 are tier 1 and none are tier 3.
- The owner records baseline approval of the design document. **Met 2026-10-02:** v5.2
  approved as is; it is now the baseline, and changes go in its §14 changelog.

## Tasks

- [ ] 1. Queue state machine (every state in `event.schema.json`), atomic leases,
      idempotency keys and provenance.
- [ ] 2. Worktree manager (`worktrees/<bean-id>`, `max_inflight`), with evidence kept when a
      bean blocks.
- [ ] 3. Inference manager: finish `ensure_loaded(role)` and `healthcheck(role)`, and record
      load-time telemetry.
- [ ] 4. Role-batched scheduler (`swap_policy`). The regime is serial, measured in Phase 0.
- [ ] 5. Kill switch: `pause`, `drain` and `stop-now`, each verified.
- [ ] 6. Startup reconciliation after an induced crash (GitHub state, worktrees, `events.jsonl`).
- [ ] 7. A hardened systemd unit with podman storage under StateDirectory, and the
      `factory` user's environment scrubbed of API keys.
- [ ] 8. Telemetry: false-approval taxonomy, task attempts, revise rate per stage, swap
      overhead %, blocked reasons, judge wall-clock per audit.
- [ ] 9. **The workload.** Run the seating-planner backlog unattended: repair beans 021–030,
      then 015–020, plus new beans from Phase 3. That makes 25 or more completed beans. Each PR
      still gets the pre-merge Claude review before it merges.
- [x] 10. **claims-check stops calling present files absent** (from the Phase 3 parking lot,
      taken in by the owner 2026-10-02). Every tic-tac-toe spec drew "it also calls these
      absent, and they are not", when the spec said they exist. A check that fires on every
      spec trains people to ignore it.
- [ ] 11. **Weak-test cases in `bench/qualify/`** (Phase 3 parking lot, taken in 2026-10-02). The
      mutants the Phase 3 reviews found pass the suite on wrong code: bean-003's tie-breaks,
      its finished-game `ValueError`, X as the system mark, and bean-004's strategy asked for X.
      Frozen as cases with a known answer, so Phase 5 can measure a judge against them.
- [ ] 12. Closing ritual, then `PHASE-4-COMPLETE`, the design document update, and a demo.

*Limit: a bean that halts twice for the same cause is parked with its evidence. The queue
moves on without it. Fixing the line for that bean is a blocker only if 3 or more beans
halt the same way. That is the pivot trigger's same-class rule, reused.*

## Exit

```yaml
phase_4_exit: { unattended_run_hours: ">= 48", completed_beans: ">= 25",
                kill_switch_verbs: "pause|drain|stop-now all verified",
                reconciliation_after_crash: pass, quality_metrics_flowing: true,
                swap_overhead_pct_recorded: true }
```

## Amendments

_None._
