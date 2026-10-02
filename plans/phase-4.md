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

- [x] 1. Queue state machine (every state in `event.schema.json`), atomic leases,
      idempotency keys and provenance.
      *(`factory/pipeline/beanstate.py`, 2026-10-02.) It holds the §09 table edge by edge
      and keeps an append-only `events.jsonl` under the runs root, with every event
      validated against the schema. `step.sh` drives it, the orchestrator takes and releases
      the lease, and a halt is `blocked` until `factory clear` (a `--resume` counts as a clear).
      In the tests, 20 racers produce exactly one lease. A refused edge only warns until
      `FACTORY_STATE_STRICT=1`, which gets switched on after the first real runs come out clean.
      `merged` is not yet written: GitHub knows it, and task 6's reconciliation reads it.)*
- [ ] 2. Worktree manager (`worktrees/<bean-id>`, `max_inflight`), with evidence kept when a
      bean blocks.
- [x] 3. Inference manager: finish `ensure_loaded(role)` and `healthcheck(role)`, and record
      load-time telemetry.
      *(2026-10-02.) `ensure-loaded.sh` now does the §09 contract. In the serial regime it
      evicts the other role's model first. It retries a failed load twice, health-checks the
      model (it must be in `/api/tags` on the digest the run declared, and answer a one-token
      probe), and times each load into the run's `model-loads.jsonl`. `run-step.sh` (developer)
      and the orchestrator (judge, before every audit) call it, and a load or health-check
      failure halts the step and pushes a notification. Real runs only: the suites stay
      uncontained and never touch the GPU.)*
- [ ] 4. Role-batched scheduler (`swap_policy`). The regime is serial, measured in Phase 0.
- [x] 5. Kill switch: `pause`, `drain` and `stop-now`, each verified.
      *(2026-10-02.) `factory pause|drain|stop-now|resume` write a control file beside the state
      log. Every orchestrator reads it at each step boundary, and `factory go` reads it between
      beans. On pause, the run holds its lease and waits. On drain, the run records
      `drained_before_step`, releases its lease and exits 75, and `--resume` carries on.
      stop-now signals each lease holder's process group and kills `factory-worker-*`
      containers, and the evidence and the bean's state are kept for reconciliation. Each verb
      is verified against a real orchestrator run in `test-faults.sh` (stop-now ended a 30 s
      stub step in under 20 s).)*
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
- [x] 11. **Weak-test cases in `bench/qualify/`** (Phase 3 parking lot, taken in 2026-10-02). The
      mutants the Phase 3 reviews found pass the suite on wrong code: bean-003's tie-breaks,
      its finished-game `ValueError`, X as the system mark, and bean-004's strategy asked for X.
      Frozen as cases with a known answer, so Phase 5 can measure a judge against them.
      *(Done 2026-10-02: two pairs, the side tie-break and the session asking for X. Both mutants
      pass 28/28 in the gate image, and each one's wrong behaviour was measured. The finished-game
      `ValueError` and X-as-system mutants were left out, because the code under review for those
      two is not wrong. They are test gaps with nothing for a judge to reject.)*
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
