# Phase 3 — Intake refinery

**Status:** queued. Only the queue (`factory go`) is built.
**Goal:** a real meeting transcript becomes at least five approved beans, through a
conversation with the owner, and those beans survive the size budget when they are specified.

## Entry (owner inputs needed)

- **A real transcript** (Markdown) for a real target repo. *The owner supplies this.*
- **Who plays the AI side.** The owner decides. My recommendation: the developer model drafts
  and the judge reviews. The judge has not shown it can hold a long structured task on its own.

## Tasks

- [ ] 1. `factory intake --repo <owner/name> --source <transcript.md>`: an interactive
      session over a read-only repo tree.
- [ ] 2. Work-item extraction with source excerpts. Ambiguities come out as questions.
- [ ] 3. Draft beans are schema-valid on save (`bean/2.0.0`, every AC has a `verify`,
      `size_budget` set).
- [ ] 4. Joint review: split, merge, reject, reorder and fix dependencies. `manual` ACs are
      flagged.
- [ ] 5. Approval stamps `status: approved` and an `approval` block.
- [ ] 6. An intake branch and PR. The owner merges.
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

_None._
