# Dark Factory — Implementation Plan (resumable ledger)

**Spec:** `dark-factory-guide.html` v5.0 · **Status:** candidate for baseline approval
**Owner:** Gregg Reed  **Approval recorded:** ☐ (date: ________)
**Target host:** Forge (Framework Desktop, Fedora Server, ~126 GB unified memory)
**Models:** developer `qwen3.8:27b-q8_0` via Pi · judge `gpt-oss:120b` · both on Ollama, localhost
**Outside builder:** Opus via Claude Code on WarDog — builds/tunes/monitors through PRs to this repo; never on the runtime path

> This Markdown file is the authoritative, resumable work ledger. Check boxes as work
> completes. A phase is done only when its closing ritual is complete:
> **all tasks checked → exit criteria machine-verified → audit report generated →
> findings corrected → audit re-run → phase-complete marker committed.**

---

## Phase 0 — Measure on Forge
**Entry:** both models pulled; Ollama bound to `127.0.0.1` under systemd.

- [ ] Record current GPU/CPU memory split (BIOS UMA setting, `amdgpu` params, `free -g`)
- [ ] Configure `OLLAMA_KEEP_ALIVE=-1`, `OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_NUM_PARALLEL=1` via `systemctl edit ollama.service`
- [ ] Benchmark `OLLAMA_CONTEXT_LENGTH` = 16384 / 32768 / 49152: each model alone, then both; capture `ollama ps` residency + GPU/CPU split
- [ ] Record prompt-processing vs generation speed separately, per model
- [ ] Time a real model switch in both directions (feeds `model_load_timeout` and `swap_overhead_pct` baseline)
- [ ] gpt-oss Harmony conformance test passes
- [ ] Pi drives **both** models through Ollama's OpenAI endpoint (`--mode rpc`; developer-role + reasoning fields OK)
- [ ] Record digest / quant / Ollama version / GPU split / context beside every figure
- [ ] **Decision recorded:** regime = `coresident` (at which context) or `serial`

**Exit (machine-verified):**
```yaml
phase_0_exit: { residency_recorded: true, swap_time_measured: true, harmony_conformance: pass,
                pi_drives_both_models: pass, regime_decision: "coresident|serial", figures_have_provenance: true }
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-0-COMPLETE` committed

---

## Phase 1 — One bean, by hand, through all seven stages
**Entry:** Phase-0 complete; throwaway GitHub repo with `factory/` scaffold (repo.yaml `human_required`, risk-policy, gates.lock, templates); one approved bean with `invariants_ref`.

- [ ] `factory step specify` — developer via Pi writes `spec.md` + `tasks.yaml`; controller lints sections, validates schemas, checks `size_budget`, renders `spec.html`
- [ ] `factory step commit` — spec candidate commit; artifact hashes recorded
- [ ] `factory step audit --stage spec_audit` — judge verdict validates against `verdict.schema.json` (stage-conditional fields present); every AC claimed by a task
- [ ] `factory step build` — task loop: worker session → sync-back → containment (task `write_paths`) → task `verify` in gate container → next; a forced failure retries with the real output; `max_attempts` exhaustion blocks with evidence
- [ ] `factory step gate` — full containment, tier computation, all gates + AC verifies + invariants + hidden tests + integrity checks
- [ ] `factory step commit` — implementation candidate; `diff_sha256`, `gate_run_id`
- [ ] `factory step audit --stage impl_audit` — `test_integrity` required and present
- [ ] `factory step document` — developer writes `impl-detail.md` from the actual diff; controller lints, renders `impl-detail.html`, commits doc candidate
- [ ] `factory step audit --stage pre_pr_audit` — `document_quality` + `artifacts` hashes present; `matches_diff` true
- [ ] `factory step pr` — exact `candidate_sha` pushed; PR body links both HTML docs and all three verdicts
- [ ] A human reads both rendered documents and confirms they teach (risk, blast radius, code blocks, no assumed knowledge)
- [ ] Allowed-path enforcement verified at task level and bean level (out-of-scope edit → rejected, not stripped)
- [ ] Independent invariant ran

**Exit:**
```yaml
phase_1_exit: { seven_stages_completed: pass, three_verdicts_schema_valid: pass, every_handoff_is_commit: pass,
                docs_rendered_and_read: pass, allowed_path_enforced_task_and_bean: pass,
                task_retry_with_evidence: pass, independent_invariant_ran: pass }
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-1-COMPLETE` committed

---

## Phase 2 — Controller drives it; the developer cannot commit
**Entry:** Phase-1 complete.

- [ ] Full loop unattended for one bean: lease → worktree → specify → spec audit → build loop → gate → impl audit → document → pre-PR audit → push → CI → **human merge**
- [ ] Fault injection — controller restart mid-stage (each of: specifying, building, committing, pushing, pr_open)
- [ ] Fault injection — out-of-path edit inside a task (must **reject**, not strip; attempt++)
- [ ] Fault injection — out-of-path edit in whole-diff containment
- [ ] Fault injection — task list with an unclaimed AC → spec audit must `revise`
- [ ] Fault injection — task list exceeding `size_budget` → `split_required`, bean blocked back to intake
- [ ] Fault injection — impl-detail that misdescribes the diff → pre-PR audit `matches_diff: false` → `revise` (doc only; code untouched)
- [ ] Fault injection — duplicate PR (idempotency holds)
- [ ] Fault injection — credential-exposure attempt (worker has no creds/git; `.git` absent from editable tree)
- [ ] Fault injection — remote-CI failure returns to build with targeted tasks
- [ ] Fault injection — branch-behind-main → rebase → re-gate + re-audit impl and pre-PR (new candidate); spec audit stands
- [ ] Fault injection — out-of-band PR-head change → blocked (violation, not re-review)
- [ ] Fault injection — wrong model loaded → blocked (inference healthcheck asserts digest)
- [ ] Fault injection — frontier provider added to `models.json` → startup refuses (registry allow-list is `ollama` only)

**Exit:**
```yaml
phase_2_exit:
  controller_restart_tests:   pass
  unauthorized_path_tests:    pass    # task-level and bean-level; rejected, not stripped
  unclaimed_ac_test:          pass
  size_budget_test:           pass
  doc_mismatch_test:          pass
  duplicate_pr_tests:         pass
  credential_exposure_tests:  pass
  remote_ci_failure_tests:    pass
  stale_branch_tests:         pass    # re-gate + re-audit
  pr_head_violation_tests:    pass    # blocked
  wrong_model_tests:          pass
  frontier_provider_refused:  pass
  human_merge_required:       verified
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-2-COMPLETE` committed

---

## Phase 3 — Intake refinery (may run alongside Phase 2)
**Entry:** Phase-1 complete; a real meeting transcript (Markdown) for a real target repo.

- [ ] `factory intake --repo <owner/name> --source <transcript.md>` — interactive session, read-only repo tree, judge model as the AI side
- [ ] Work-item extraction with source excerpts; ambiguities surfaced as questions
- [ ] Draft beans schema-valid on save (`bean/2.0.0`, every AC has `verify`, `size_budget` set)
- [ ] Joint review: split / merge / reject / reorder / fix dependencies; `manual` ACs flagged
- [ ] Approval stamps `status: approved` + `approval {approved_by, approved_at, order}`
- [ ] Intake branch `factory/intake-<date>` + PR opened; human merges
- [ ] `factory go` refuses non-approved beans; queues approved beans in `order` respecting `dependencies`
- [ ] During build-out only: same flow with Opus as the AI side produces byte-identical schema artifacts

**Exit:**
```yaml
phase_3_exit: { transcript_to_beans: ">= 5 approved", all_ac_verifiable_or_manual: true,
                non_approved_refused: pass, size_budget_holds_at_specify: pass }
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-3-COMPLETE` committed

---

## Phase 4 — Lights-out to PRs
**Entry:** Phases 2 and 3 complete.

- [ ] Queue state machine (all states in `event.schema.json`), atomic leases, idempotency keys, provenance
- [ ] Worktree manager: `worktrees/<bean-id>`, `max_inflight`, editable-tree sync without `.git`, evidence retention on block
- [ ] Inference manager: `ensure_loaded(role)` / `healthcheck(role)`; regime from Phase 0; load-time telemetry
- [ ] Role-batched scheduler: `swap_policy {prefer: bean_boundary, max_wait_minutes, min_batch}`; degenerates to natural order when co-resident
- [ ] Kill switch: `pause` / `drain` / `stop-now` all verified, including mid `deploying_test`
- [ ] Startup reconciliation after induced crash (GitHub state + worktrees + events.jsonl)
- [ ] Pre-build ≥10 approved beans; run unattended producing **PRs only** (`human_required`)
- [ ] Telemetry flowing: false-approval taxonomy, task attempts, revise rates per stage, swap overhead %, blocked reasons

**Exit (concrete):**
```yaml
phase_4_exit:
  unattended_run_hours:        ">= 48"
  completed_beans:             ">= 25"
  kill_switch_verbs:           "pause|drain|stop-now all verified"
  reconciliation_after_crash:  pass
  quality_metrics_flowing:     true
  swap_overhead_pct_recorded:  true
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-4-COMPLETE` committed

---

## Phase 5 — Supervised operation: the outside builder monitors
**Entry:** Phase-4 complete; line running on a real target repo in `human_required`.

- [ ] Weekly review packet generated from telemetry (the seven numbers in §11) + all human rejections with reasons
- [ ] Opus reviews packet; proposes changes as PRs to this repo only (prompts, templates, decomposition rules, scheduler knobs, risk policy) — Tier 3, human-merged
- [ ] Swap policy tuned from `swap_overhead_pct` and time-waiting-for-other-role; decision recorded (judge mid-bean: yes/no/conditional)
- [ ] Spec-audit vs impl-audit revise-rate balance checked; judge prompt tightened if impl catches what spec should have
- [ ] Rework-rate threshold and false-approval threshold set and met

**Exit:**
```yaml
phase_5_exit: { review_cycles_without_unresolved_drift: ">= 2", rework_rate_under_threshold: true,
                false_approval_rate_under_threshold: true, swap_policy_settled: true }
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-5-COMPLETE` committed

---

## Phase 6 — Merge modes & deploy-to-test
**Entry:** Phase-5 complete.

- [ ] One solo repo: `merge_mode: auto` with `merge_mode_signoff`; `post_merge` deploy-to-test (`workflow_dispatch`); `required_checks` named
- [ ] Startup refuses `auto` without signoff; Tier 3 never auto-merges in any mode; `manual` AC forces human review
- [ ] `deploying_test → deployed_test` and `→ deploy_failed` (alert, no auto-rollback) both exercised
- [ ] Escaped-defect logging against bean id verified end to end
- [ ] Shared repos: `auto_when_unlocked` thresholds enforced (≥100 human-reviewed PRs, 0 escapes, ≤1 substantive rejection, fault-injection green); auto-suspend armed (1 critical escape or 2 false approvals / 30 PRs)
- [ ] Rejection-reason classification enforced before counting false approvals

**Exit:**
```yaml
phase_6_exit: { solo_repo_lights_out_to_test: pass, auto_without_signoff_refused: pass,
                tier3_never_auto: pass, deploy_failed_path: pass, escaped_defect_log: pass,
                unlock_thresholds_enforced: pass, auto_suspend_armed: true }
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-6-COMPLETE` committed

---

## Standing protocol — changing a model (judge or developer)
The only situation in which a frontier model interacts with line artifacts after Phase 5.

- [ ] Shadow-run the candidate model on the recorded stages of the last K beans (K ≥ 20)
- [ ] Compare: verdict agreement (judge) or task pass rate + revise rate (developer) + `document_quality` against the incumbent
- [ ] Frontier model adjudicates disagreements for the test window only; its outputs are never committed as verdicts
- [ ] Cut over on evidence; changelog entry; `models.json` still contains only the `ollama` provider

---

## Cross-cutting build tasks (do alongside phases)
- [ ] Implement all schemas: `bean` / `task` / `verdict` / `event` / `gate-manifest` / `risk-policy` / `repo-config` (provided in `schemas/`)
- [ ] Schema-audit each: validate real payloads; fix; re-validate
- [ ] `factory-doclint`: required sections present and non-empty for `spec.md` and `impl-detail.md`
- [ ] Document templates `factory/templates/spec.html`, `impl-detail.html` per `html-artifact-output` standard; renderer from Markdown
- [ ] Prompt packs, versioned: `developer/specify`, `developer/build-task`, `developer/document`, `judge/spec-audit`, `judge/impl-audit`, `judge/pre-pr-audit`, `intake/extract`, `intake/draft-bean`
- [ ] Controller skeleton: state machine + leases + worktrees + idempotency + reconciliation + GitHub adapter (`gh`/REST, webhook)
- [ ] Provider registry allow-list = `["ollama"]`; startup refuses anything else; `factory` user env scrubbed of API keys
- [ ] `factory/risk-policy.yaml` authored (includes `factory/**` tiering) and human-reviewed
- [ ] Gate image built with pinned tool versions; startup version check
- [ ] Sandbox contract implemented (read-only outside editable tree, no sockets/SSH/creds/git, caps dropped, no-net-by-default, resource limits)
- [ ] Hardened systemd unit; podman storage relocated under StateDirectory; integration-tested
- [ ] Human owner records baseline approval (flip status)

## Open questions (owner)
- First real target application for Phases 4–6?
- Deploy-to-test mechanism per repo (GitHub Actions `workflow_dispatch` assumed)?
- GPU memory split on Forge — raise after Phase-0 numbers?
- Intake AI side: judge model (proposed) or developer drafts + judge reviews?
