# Phase 5 — Supervised operation: the outside builder monitors

**Status:** queued. Entry needs Phase 4 complete and the line running on a real target
repo in `human_required`.
**Goal:** the line improves through a weekly review cycle rather than through ad-hoc fixes,
and its quality numbers stay under set thresholds.

## Tasks

- [ ] 1. A weekly review packet generated from telemetry: the seven numbers in §11 of the
      design document, plus every human rejection with its reason.
- [ ] 2. Opus reviews the packet and proposes changes only as PRs to this repo: prompts,
      templates, decomposition rules, scheduler knobs and risk policy. These are Tier 3 and
      human-merged. **This is where judge accuracy work belongs.** The 2026-09-29
      qualification suite (`bench/judge-qualify.sh`) is the measure. A judge change is made
      through the standing model-change protocol, never mid-cycle.
- [ ] 3. Tune the swap policy from `swap_overhead_pct`, and record the decision.
- [ ] 4. Check the balance of spec-audit and impl-audit revise rates.
- [ ] 5. Set the rework-rate and false-approval thresholds, then meet them.
- [ ] 6. Closing ritual, then `PHASE-5-COMPLETE`, the design document update, and a demo.

*Limit: one change set per review cycle. A cycle that tries more than that cannot tell
which change moved which number.*

## Exit

```yaml
phase_5_exit: { review_cycles_without_unresolved_drift: ">= 2", rework_rate_under_threshold: true,
                false_approval_rate_under_threshold: true, swap_policy_settled: true }
```

## Amendments

_None._
