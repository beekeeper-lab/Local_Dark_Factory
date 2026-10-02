# Phase-3 audit — 2026-10-02

**Harness:** `bench/phase3-audit.sh` (reads the beans on the target's `main`, the line's own
spec-check records, and `tests/test-queue.sh`)
**Result:** **green**: 4 ok, 0 findings (`audits/phase3-audit-20261002T122506Z.json`)
**Plan:** `plans/phase-3.md` · **Target:** `beekeeper-lab/tic-tac-toe-py` at `a8dead0`

| Predicate | Value | Evidence |
| --- | --- | --- |
| `transcript_to_beans` | pass (5) | The owner's 1m 45s voice memo (`intake/tic-tac-toe-py/transcript-20260930.md`, 202 words) became beans 001–005. Each carries a source excerpt found in the transcript and an `approval` block. Merged as tic-tac-toe-py#1. |
| `all_ac_verifiable_or_manual` | pass | 30 criteria: 27 are a pytest node or a command, and 3 (bean-005, the window) are `manual` with a note |
| `non_approved_refused` | pass | `test-queue.sh`, 77 passed: a draft is refused and named, and `factory go --bean` on an unapproved bean exits 1 |
| `size_budget_holds_at_specify` | pass | spec-check per bean: 001 2/4, 002 2/4, 003 2/4, 004 2/4, 005 3/4 tasks. None split. |

Beyond the exit: beans 001–004 also ran the whole line to merged PRs (tic-tac-toe-py #2–#5).
Each had a pre-merge Claude review with no demonstrated defect (`evidence/reviews/bean-00*-2026100*.md`).
Every reachable game position was checked against an independent oracle. bean-004 ran its
`ci` step green on GitHub.

## Findings corrected during the phase

1. **Task 8 could not be done as written** (amendment, 2026-10-01). Beans 002–005 read files
   that earlier beans create, so they could not be specified until those beans existed. Each
   bean therefore ran to a reviewed, merged PR before the next was specified.
2. **A manual criterion failed the gate on every attempt.** `gate.sh` sent bean-level `manual`
   verifies to `verify.sh`, which refuses them by design. bean-005 was the first bean to carry
   one. These criteria are now recorded as `manual`, kept out of the failure summary, and
   listed in the PR body as a checklist for whoever merges (factory PR #42; the new test
   fails without the fix).
3. **Intake approved a path the target's policy forbids.** bean-005 allows `README.md`, and
   `repo_allowed_paths` did not, so the gate's intersection rejected the build. `intake check`
   now reads the target's risk policy and refuses such a path at draft time (PR #42). The
   owner widened the target's policy to the docs class (tic-tac-toe-py#6).
4. **The target's CI could not pull the gate image.** The private GHCR package was not
   linked to the new repo. The owner granted read access, and `gates` is green on `main`.
   The intake PR and beans 001–003 merged before this fix, so their gates ran only on Forge.

## Not fixed, carried to the parking lot

- **The judge stayed unusable as a gate.** It hallucinated a `winner()` method into bean-001's
  spec, returned a malformed judgement on bean-002, and described a nonexistent `TicTacToe`
  class on bean-004. Audits ran advisory throughout, and the pre-merge review was the gate.
- **claims-check produced a false positive on every spec.** It reads "these files exist" as
  the spec calling them absent.
- **Weak tests the reviews found.** bean-003's tie-breaks are untested, and bean-004 has a
  strategy called with the wrong mark. Each is a candidate `bench/qualify/` case.
