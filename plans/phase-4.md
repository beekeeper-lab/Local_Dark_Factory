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
- [x] 2. Worktree manager (`worktrees/<bean-id>`, `max_inflight`), with evidence kept when a
      bean blocks.
      *(2026-10-04.) `worktree.sh` puts each bean's worktree beside the main checkout,
      detached at main's tip, which preflight accepts in a linked worktree. It brings local
      main up to date first, keeps a blocked bean's worktree as evidence, and `prune` gives
      back done beans' worktrees. Run records, the state log and the leases resolve to the
      main checkout (`lib.sh runs_root_dir`), so the queue and reconciliation see every bean.
      `factory go --max-inflight N` runs up to N, and 1 is the old loop unchanged. Tested:
      two beans in flight at once, each in its own worktree, with the main checkout still on
      main.)*
- [x] 3. Inference manager: finish `ensure_loaded(role)` and `healthcheck(role)`, and record
      load-time telemetry.
      *(2026-10-02.) `ensure-loaded.sh` now does the §09 contract. In the serial regime it
      evicts the other role's model first. It retries a failed load twice, health-checks the
      model (it must be in `/api/tags` on the digest the run declared, and answer a one-token
      probe), and times each load into the run's `model-loads.jsonl`. `run-step.sh` (developer)
      and the orchestrator (judge, before every audit) call it, and a load or health-check
      failure halts the step and pushes a notification. Real runs only: the suites stay
      uncontained and never touch the GPU.)*
- [x] 4. Role-batched scheduler (`swap_policy`). The regime is serial, measured in Phase 0.
      *(2026-10-04.) `infergate.py` lets one model step use the GPU at a time across in-flight
      beans. The step holds the gate from load to exit, in `run-step.sh` for the developer and
      the orchestrator for the judge. When the gate frees, the resident role goes first, and
      past `FACTORY_MAX_WAIT_MINUTES` (default 30) the longest waiter goes. A dead holder is
      dropped. Every grant is logged with its wait and whether it cost a model switch.
      Tested: batching, the max_wait override, and a holder killed with -9.)*
- [x] 5. Kill switch: `pause`, `drain` and `stop-now`, each verified.
      *(2026-10-02.) `factory pause|drain|stop-now|resume` write a control file beside the state
      log. Every orchestrator reads it at each step boundary, and `factory go` reads it between
      beans. On pause, the run holds its lease and waits. On drain, the run records
      `drained_before_step`, releases its lease and exits 75, and `--resume` carries on.
      stop-now signals each lease holder's process group and kills `factory-worker-*`
      containers, and the evidence and the bean's state are kept for reconciliation. Each verb
      is verified against a real orchestrator run in `test-faults.sh` (stop-now ended a 30 s
      stub step in under 20 s).)*
- [x] 6. Startup reconciliation after an induced crash (GitHub state, worktrees, `events.jsonl`).
      *(2026-10-02.) `factory reconcile [--apply]` (`reconcile.py`) works through four checks.
      It drops leases whose owner is dead or expired. It moves a bean to what its PR says
      (merged; open with checks green, red or pending), recorded as an observation, not as a
      transition. It blocks a bean whose run halted without the log knowing. For a bean in
      flight with no lease, it saves the interrupted attempt's edits into the run directory,
      resets the tree to the branch's last commit, and prints the resume command. It only
      plans unless `--apply` is given, and a second run changes nothing. Induced crash in
      `test-faults.sh`: `kill -9` of the whole run mid-build, then reconcile, then the resume
      reaches GATE PASS. This also writes `merged`, the gap left in task 1.)*
- [ ] 7. A hardened systemd unit with podman storage under StateDirectory, and the
      `factory` user's environment scrubbed of API keys.
      *(Built and tested 2026-10-02, waiting on an install that needs sudo.)* `factory/deploy/` has
      `darkfactory@.service` (scored 7.1 by `systemd-analyze security --offline`, with podman's
      user namespaces limiting how far it can go). `NoNewPrivileges` is off because rootless
      podman's setuid `newuidmap` needs it; the worker containers keep `no-new-privileges`. Also
      there: `storage.conf` under the StateDirectory, and `run-line.sh`, which rebuilds the
      environment from an allowlist (tested: no `*_API_KEY`, `AWS_*` or other key reaches the
      line, and `GH_TOKEN` does), loops reconcile → go → wait, and stops after 3 halts in a row.
      `drain-and-wait.sh` is ExecStop, so a stop is a drain. `INSTALL.md` has the owner's
      one-line sudo steps, and `check-unit.sh` verifies the install before it is enabled.
      `test-deploy.sh` covers 31 cases.

- [x] 8. Telemetry: false-approval taxonomy, task attempts, revise rate per stage, swap
      overhead %, blocked reasons, judge wall-clock per audit.
      *(2026-10-02/04.) `factory telemetry` (`telemetry-summary.py`) works across every run of a
      repo. It reports task attempts and first-try rate; revise rate, stamp rate and judge
      wall-clock per audit stage; refusals by rule; swap overhead as load time over time inside
      steps; blocked reasons; and false approvals by class, joined against
      `evidence/reviews/index.jsonl`, which was backfilled with 16 reviews. First real
      numbers, from 34 runs: 1.38 attempts per task, 84% first try, judge stamp rate 0 on every
      stage, swap overhead 0.75%.)*

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
