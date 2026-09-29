# Phase plans

One plan per phase. Each plan builds its phase out to completion, and the phase is then
audited as one chunk of work. The design document (`dark-factory-guide.html`, "Where we
are") links here and is updated when a plan completes, and at no other time.

| Phase | Plan | Status |
| --- | --- | --- |
| 0 — Measure on Forge | closed 2026-09-14 (`phase-0-complete`, `audits/PHASE-0-AUDIT-20260914.md`) | **complete** |
| 1 — One bean through every stage | [phase-1.md](phase-1.md) | **active** |
| 2 — Controller drives it; developer cannot commit | [phase-2.md](phase-2.md) | queued, nearly built |
| 3 — Intake refinery | [phase-3.md](phase-3.md) | queued, not started |
| 4 — Lights-out to PRs | [phase-4.md](phase-4.md) | queued, partly built |
| 5 — Supervised operation | [phase-5.md](phase-5.md) | queued |
| 6 — Merge modes and deploy-to-test | [phase-6.md](phase-6.md) | queued |

## How a plan runs

1. **One active plan at a time.** Work that belongs to a later phase waits for it, even when
   it is already half-built.
2. **The plan is fixed when it starts.** Its tasks and exit criteria do not grow while it runs.
   Anything new I think of goes to [PARKING-LOT.md](PARKING-LOT.md) with a one-line value
   estimate and my recommendation. It gets looked at when the phase closes.
3. **Pivot only on a blocker.** A blocker means the plan cannot reach its exit as written.
   When that happens I stop, write the blocker and the smallest change that gets past it into
   the plan's *Amendments* section, and tell the owner. A better idea is not a blocker.
4. **No-progress rule.** Each plan gives a task that does not converge a fixed number of
   attempts, and the plan names that number. When the attempts are used up, the task's
   fallback applies. I do not make one more attempt.
5. **Closing ritual.** The exit is computed by a script, then an audit report is generated,
   findings are corrected, and the audit is re-run green. Then the `PHASE-N-COMPLETE` commit
   and the `phase-N-complete` tag. The design document is updated and the owner gets a demo.
   At the demo the owner decides what, if anything, from the parking lot joins the next plan.

`DARK_FACTORY_IMPLEMENTATION_PLAN.md` stays as the detailed ledger with its history.
`RESUME.md` is a session log. Neither one is the plan.
