# Phase 2 — The controller drives it; the developer cannot commit

**Status:** active since 2026-09-29, when Phase 1 closed. Almost all of it is built.
**Goal:** one bean runs unattended from lease to PR. Every fault in the list is injected
and handled correctly, and a human merges.

## Where it stands (2026-09-29)

- Twelve of the thirteen fault injections pass in `factory/pipeline/tests/test-faults.sh`,
  `test-ci.sh`, `test-sync.sh`, `test-pr.sh` and `test-role-routing.sh`.
  `bench/phase2-audit.sh` computed 13 of 13 ok on 2026-09-16.
- The worker is contained: `--network=none`, the model reached over a unix socket, and
  `.git` masked.
- The unattended full loop has run for real. `bean-014-20260928T162157Z` passed all 12 steps
  including real GitHub CI, and was merged.
- The gate image is published to GHCR and real CI runs it.
- **Open:** `remote_ci_failure_tests` has only been checked against a stubbed `gh`. No real
  required check has ever failed and sent the line back to build.

## Tasks

- [ ] **1. Re-run `bench/phase2-audit.sh`** on the current tree and record the result.
- [ ] **2. Make one real CI failure.** On a throwaway bean run in `seating-planner-py`,
      push a candidate whose required check fails on GitHub but not locally, for example an
      environment-only failure the gate cannot see. Confirm `ci.sh` rewinds to `build` and
      reopens the right tasks. *Limit: 2 attempts at building the fixture. If it cannot be
      made to fail only remotely, record it as `pass_in_tests` with the reason. That is an
      amendment, not a new plan.*
- [ ] **3. Record `human_merge_required: verified`.** Cite the `merge_mode: human_required`
      refusal tests and the merged PRs. Note that under the 2026-09-29 authorisation, merges
      are made by Claude on the owner's authority after a pre-merge review.
- [ ] **4. Closing ritual**, then `PHASE-2-COMPLETE`, the design document update, and a demo.

## Exit

The `phase_2_exit` block in `DARK_FACTORY_IMPLEMENTATION_PLAN.md`, with every predicate
computed by `bench/phase2-audit.sh`.

## Not in this plan

Judge accuracy (Phase 5). Queue, leases and scheduling (Phase 4).

## Amendments

_None._
