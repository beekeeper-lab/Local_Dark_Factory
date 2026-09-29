# Phase 6 — Merge modes and deploy-to-test

**Status:** queued. Entry needs Phase 5 complete.
**Goal:** one solo repo runs lights-out all the way to a test server, and the guardrails
around auto-merge are enforced.

## Entry (owner inputs needed)

- Which solo repo, and its deploy-to-test mechanism. The assumption is GitHub Actions
  `workflow_dispatch`.
- The owner's signed `merge_mode_signoff` for that repo.

## Tasks

- [ ] 1. `merge_mode: auto` with signoff, a `post_merge` deploy-to-test, and `required_checks`
      named.
- [ ] 2. Startup refuses `auto` without signoff. Tier 3 never auto-merges. A `manual` AC
      forces human review.
- [ ] 3. Exercise both `deploying_test → deployed_test` and `→ deploy_failed` (alert, no
      auto-rollback).
- [ ] 4. Escaped-defect logging against the bean id, end to end.
- [ ] 5. Shared repos: `auto_when_unlocked` thresholds enforced, and auto-suspend armed.
- [ ] 6. Rejection-reason classification runs before false approvals are counted.
- [ ] 7. Closing ritual, then `PHASE-6-COMPLETE`, the design document update, and a demo.

## Exit

```yaml
phase_6_exit: { solo_repo_lights_out_to_test: pass, auto_without_signoff_refused: pass,
                tier3_never_auto: pass, deploy_failed_path: pass, escaped_defect_log: pass,
                unlock_thresholds_enforced: pass, auto_suspend_armed: true }
```

## Amendments

_None._
