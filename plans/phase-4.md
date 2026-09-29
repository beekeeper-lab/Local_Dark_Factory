# Phase 4 — Lights-out to PRs

**Status:** queued. Entry needs Phases 2 and 3 complete. Some pieces already exist:
`factory go` runs a queue serially, `ensure_loaded` exists (`tests/test-ensure-loaded.sh`),
and there is per-step telemetry.
**Goal:** the line runs unattended for 48 hours or more and produces at least 25 completed
beans as PRs only. It can be stopped three ways and recovers from a crash.

## Entry

- Phases 2 and 3 complete.
- **The owner reviews `factory/risk-policy.yaml`** (`factory policy` shows what each rule does).
  This file decides what the line may touch unsupervised, and no human has reviewed it yet.
- The owner records baseline approval of the design document.

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
- [ ] 10. Closing ritual, then `PHASE-4-COMPLETE`, the design document update, and a demo.

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
