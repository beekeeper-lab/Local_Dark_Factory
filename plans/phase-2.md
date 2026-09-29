# Phase 2 — The controller drives it; the developer cannot commit

**Status:** **complete 2026-09-29.** Tag `phase-2-complete`, audit `audits/PHASE-2-AUDIT-20260929.md`, 13 ok and 0 findings.
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

- [x] **1. Re-run `bench/phase2-audit.sh`** on the current tree and record the result.
      2026-09-29: 13 ok. `remote_ci_failure_tests` read `pass` only because the image is now
      published, which made a real run possible but was not one. The audit now requires a
      recorded real failure under `evidence/`.
- [x] **2. Make one real CI failure.** On a throwaway bean run in `seating-planner-py`,
      push a candidate whose required check fails on GitHub but not locally, for example an
      environment-only failure the gate cannot see. Confirm `ci.sh` rewinds to `build` and
      reopens the right tasks. *Limit: 2 attempts at building the fixture. If it cannot be
      made to fail only remotely, record it as `pass_in_tests` with the reason. That is an
      amendment, not a new plan.*
      **Done 2026-09-29, first attempt.** Throwaway PR seating-planner-py#18 reverted bean-021's
      fix. The required `gates` check went red on GitHub, and `ci.sh` exited 9 with
      `rewind.json` set to `to: build` and reopened task-1 and task-2. The PR was then closed
      and its branch deleted. Evidence: `evidence/phase2-real-ci-failure-20260929/`.
- [x] **3. Record `human_merge_required: verified`.** Cite the `merge_mode: human_required`
      refusal tests and the merged PRs. Note that under the 2026-09-29 authorisation, merges
      are made by Claude on the owner's authority after a pre-merge review.
- [x] **3a. Fix the hidden-test false alarm** (added at plan start from the parking lot, on the
      owner's go-ahead). `verify.sh` now makes its temp trees world-readable. It also revealed
      that the "fails against an empty tree" half had never been tested in the image. All 17
      image-verified suites were re-checked, and every one fails against an empty tree. The
      suite's own fixture only passed because of the bug, and it was repaired.
- [x] **4. Closing ritual**, then `PHASE-2-COMPLETE`, the design document update, and a demo.

## Exit

The `phase_2_exit` block in `DARK_FACTORY_IMPLEMENTATION_PLAN.md`, with every predicate
computed by `bench/phase2-audit.sh`.

## Not in this plan

Judge accuracy (Phase 5). Queue, leases and scheduling (Phase 4).

## Amendments

- **2026-09-29:** task 3a added at plan start (parking-lot item, owner approved).
