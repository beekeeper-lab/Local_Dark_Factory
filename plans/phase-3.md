# Phase 3 — Intake refinery

**Status:** active since 2026-09-30. Entry met; the queue (`factory go`) was already built.
**Goal:** a real meeting transcript becomes at least five approved beans, through a
conversation with the owner, and those beans survive the size budget when they are specified.

## Entry (owner inputs needed)

- **A real transcript** (Markdown) for a real target repo. *The owner supplies this.*
  **Met 2026-09-30:** the owner's 1m 45s voice recording, transcribed by `transcribe-audio`
  (OpenAI `gpt-4o-mini-transcribe`, 202 words), is at
  `intake/tic-tac-toe-py/transcript-20260930.md`. The target is a new private repo,
  `beekeeper-lab/tic-tac-toe-py` (skeleton only: package, smoke test, tooling).
- **Who plays the AI side.** The owner decides. My recommendation: the developer model drafts
  and the judge reviews. The judge has not shown it can hold a long structured task on its own.
  **Decided 2026-09-30:** the owner chose the recommendation. The developer drafts and the judge reviews.

## Tasks

- [x] 1. `factory intake --repo <owner/name> --source <transcript.md>`: an interactive
      session over a read-only repo tree.
- [x] 2. Work-item extraction with source excerpts. Ambiguities come out as questions.
- [x] 3. Draft beans are schema-valid on save (`bean/2.0.0`, every AC has a `verify`,
      `size_budget` set).
- [x] 4. Joint review: split, merge, reject, reorder and fix dependencies. `manual` ACs are
      flagged.
- [x] 5. Approval stamps `status: approved` and an `approval` block.
- [x] 6. An intake branch and PR. The owner merges. *(beekeeper-lab/tic-tac-toe-py#1, merged 2026-10-01 at the owner's request.)*
- [x] 7. `factory go` refuses beans that are not approved (`factory/pipeline/queue.sh`,
      `tests/test-queue.sh`).
- [ ] 8. Specify each approved bean and confirm every one holds its `size_budget`.
- [ ] 9. Closing ritual, then `PHASE-3-COMPLETE`, the design document update, and a demo.

*Limit: if the chosen AI side cannot produce a schema-valid bean in 3 sessions on the real
transcript, stop and bring the owner a model or role change. Do not tune the prompt further.*

## Exit

```yaml
phase_3_exit: { transcript_to_beans: ">= 5 approved", all_ac_verifiable_or_manual: true,
                non_approved_refused: pass, size_budget_holds_at_specify: pass }
```

## Dropped from the ledger

"Same flow with Opus as the AI side produces byte-identical schema artifacts": a comparison
done during build-out only. It is in the parking lot, not in this plan.

## Amendments

- **2026-10-01, task 8: specify in dependency order, which means building.** Blocker: beans
  002–005 depend on earlier beans and read files those beans create (bean-002 reads
  `src/tictactoe/game.py` from bean-001), so the queue holds them, and a spec written against
  a tree without those files would describe code that does not exist. Smallest change: each
  bean runs the line to its PR (`factory go --bean <id> --stop-after pr`), gets the pre-merge
  Claude review, and merges, and then the next bean is specified. The exit predicate is
  unchanged: `bench/phase3-audit.sh` reads each bean's spec-check record.
  `--stop-after pr` because the target's CI cannot pull the gate image yet (intake PR #1's
  `gates` check: GHCR `manifest unknown`, most likely because the private package is not linked
  to `tic-tac-toe-py`). The owner fixes that in Package settings → Manage Actions access. The
  intake PR was merged at the owner's request with that check red. It changed only beans.
  **Fixed 2026-10-01 ~21:30 EDT:** the owner added `tic-tac-toe-py` (read) under the package's
  Manage Actions access. `gates` is green on `main` at `4fbd8c3` (covering beans 001–003, which
  merged before CI could run). bean-004 ran its `ci` step green on PR #5; bean-005 runs the full line.
