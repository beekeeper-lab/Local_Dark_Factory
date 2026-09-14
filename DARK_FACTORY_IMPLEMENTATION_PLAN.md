# Dark Factory — Implementation Plan (resumable ledger)

**Spec:** `dark-factory-guide.html` v5.0 · **Status:** candidate for baseline approval
**Owner:** Gregg Reed  **Approval recorded:** ☐ (date: ________)
**Target host:** Forge (Framework Desktop, Fedora Server, ~126 GB unified memory)
**Models:** developer `qwen3.8:27b-mtp-q8_0` via Pi · judge `gpt-oss:120b` · both on Ollama, localhost
**Outside builder:** Opus via Claude Code on WarDog — builds/tunes/monitors through PRs to this repo; never on the runtime path

> This Markdown file is the authoritative, resumable work ledger. Check boxes as work
> completes. A phase is done only when its closing ritual is complete:
> **all tasks checked → exit criteria machine-verified → audit report generated →
> findings corrected → audit re-run → phase-complete marker committed.**

---

## Phase 0 — Measure on Forge
**Entry:** both models pulled; Ollama bound to `127.0.0.1` under systemd.

**Harness:** `bench/phase0.sh` — sweeps context via per-request `options.num_ctx`
(no sudo, no service restart), measures prompt vs generation speed separately from
Ollama's own `prompt_eval_*` / `eval_*` counters, times swaps both directions, and
writes one provenanced JSON per run to `bench/results/`. `--provenance-only` is safe
to run while other work is using Ollama; the full harness is not (it calls `ollama stop`).

**Recorded 2026-09-14, pre-reboot:**
- No dedicated VRAM (`mem_info_vram_total` = 0). The GPU ceiling is the GTT limit,
  `ttm.pages_limit` = 16393715 pages × 4 KiB = **62 GB** — the driver default (half of
  125 GB RAM), not a BIOS choice. Kernel cmdline carried no `amdgpu`/`ttm` args at all.
- **Consequence:** `gpt-oss:120b` (65 GB) could not be fully GPU-resident at the default
  ceiling, so the regime decision was being made by an untouched kernel default rather
  than by measurement.
- **Action:** `ttm.pages_limit=25165824` (**96 GiB**) set via grubby 2026-09-14; pending
  reboot. Verify after reboot with `cat /sys/module/ttm/parameters/pages_limit`.
  `page_pool_size` deliberately left unset — `modinfo ttm` documents it as "Number of
  pages in the WC/UC/DMA pool per NUMA node", a reuse *cache*, not a second allocation
  ceiling; pairing it with `pages_limit` is a common forum recipe with no mechanism
  behind it here, and two knobs changed at once is one knob you cannot attribute.

- **Regime decision, reached before measurement: `serial`.** Co-residency of these two
  models is not viable on this box at any GTT setting, and the arithmetic is not close:

  | | GiB |
  |---|---|
  | gpt-oss:120b | 65 |
  | qwen3.8:27b-mtp-q8_0 | 29 |
  | weights, both resident | **94** |
  | + KV cache, both at 32K | ~4–8 |
  | total GPU-side | **~100** |
  | left of 125 GiB | ~25 |

  That remainder has to cover Fedora, Pi, and the podman gate containers — and §08 runs
  every gate (`pnpm build`, `dotnet test`, `pytest`) *while a model is resident*, so the
  gates are not an idle-time cost that can be scheduled around. A reported Strix Halo
  instability near 110 GiB puts the co-resident configuration at the edge as well.
  96 GiB was chosen over the initially-proposed 110 GiB for this reason: it holds the
  serial working set (65 + KV ≈ 70) with ~29 GiB of headroom, sits below the reported
  instability zone, and still lets Phase 0 *attempt* co-residency so the conclusion is
  recorded as a measurement rather than asserted from arithmetic.

  This is a finding, not a setback: §09 already treats serial as first-class. The open
  question changes from "which regime?" to "what does a swap cost, and how should the
  role-batched scheduler batch around it?" — which is exactly what `bench/phase0.sh`
  measures, and it feeds `model_load_timeout` and the `swap_overhead_pct` baseline.
  Raising the ceiling later is one command if the swap cost proves brutal and the gate
  containers prove lighter than assumed.
- Installed tags differ from spec v5.0 as written: the developer is
  `qwen3.8:27b-mtp-q8_0` (Q8_0, 29 GB, `qwen35`, native ctx 262144); `qwen3.8:27b`
  (Q4_K_M, 17 GB) is the comparison arm. Spec, plan and README corrected.
- Ollama 0.32.13. `OLLAMA_KEEP_ALIVE=-1` already set on the unit;
  `MAX_LOADED_MODELS`, `NUM_PARALLEL` and `CONTEXT_LENGTH` unset (serving 262144).
- Observed cost of that default context, from the InvTrac pipeline on Q4: spec step
  **39 min**, audit-spec 5 min, implement 11–12 min, audit-impl 7–10 min. Prompt
  processing dominates. Our beans are capped at 5 files / 400 diff lines, so the
  16–48K sweep is the relevant range and 262144 is pure overhead.

- [x] Record current GPU/CPU memory split (`amdgpu` params, `free -g`) — see above
- [ ] Re-record split after reboot (`bench/phase0.sh --provenance-only`; expect GTT **96 GiB**)
- [ ] Confirm the serial conclusion empirically: load both at 16K and record the failure/spill
- [ ] Configure `OLLAMA_KEEP_ALIVE=-1`, `OLLAMA_MAX_LOADED_MODELS=1`, `OLLAMA_NUM_PARALLEL=1`
      via `systemctl edit ollama.service` — `MAX_LOADED_MODELS=1` (not 2, as spec v5.0 says)
      follows from the serial conclusion: allowing 2 invites an eviction storm under a
      ceiling that cannot hold both
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
- [x] Implement all schemas: `bean` / `task` / `verdict` / `event` / `gate-manifest` / `risk-policy` / `repo-config` (provided in `schemas/`)
- [x] **Eighth contract added:** `run-record.schema.json` — fixes the *conditions* a run
      executed under (models + digests + quant + context + thinking, bean-set version,
      requirements hash, stack, skill versions). The forked pipeline already measured
      duration and tokens per step; without the conditions beside them, a Q4 run and a
      Q8 run are two anecdotes rather than one experiment.
- [~] Schema-audit each: validate real payloads; fix; re-validate
      - `bench/validate.py` checks all 8 schemas (`0 invalid`) and validates payloads
        and whole bean sets, including rules the schema cannot express: every AC has a
        `verify` (§05), ids unique, dependencies resolve inside the set.
      - **Finding, fixed:** PyYAML implicitly resolves unquoted RFC 3339 timestamps into
        `datetime` objects, which then fail every `"type": "string"` check — the spec's
        own `bean-014` example failed validation on `approval/approved_at` and
        `source/date`. The artifact was correct; the loader was lossy. Anything that
        reads beans must load timestamps as strings or the schemas reject valid beans.
      - Still to validate against real payloads: `verdict`, `event`, `task`, `repo-config`
        (the spec's verdict example carries `…` placeholders, so it needs a real one from
        Phase 1).
- [ ] `factory-doclint`: required sections present and non-empty for `spec.md` and `impl-detail.md`
- [ ] Document templates `factory/templates/spec.html`, `impl-detail.html` per `html-artifact-output` standard; renderer from Markdown
- [~] Prompt packs, versioned: `developer/specify`, `developer/build-task`, `developer/document`, `judge/spec-audit`, `judge/impl-audit`, `judge/pre-pr-audit`, `intake/extract`, `intake/draft-bean`
      - Forked into `factory/skills/` from the proven InvTrac set (spec / implement /
        doc / audit / pr / run) and loaded explicitly via `pi --skill`, because the
        global `~/.pi/agent/skills` is owned by that project — its `sync-skills.sh`
        treats its own copy as canonical, so editing the installed copies would break
        it silently on its next run. No `build-task` pack yet (see task loop below).
- [ ] Controller skeleton: state machine + leases + worktrees + idempotency + reconciliation + GitHub adapter (`gh`/REST, webhook)
- [x] **Role → model routing** (`factory/pipeline/roles.json` + `run-step.sh`). The forked
      pipeline passed no `--model`, so authoring *and* auditing ran on Pi's default
      weights — the judge was grading its own homework in a fresh context. Fresh context
      is not independence (§01). Steps now bind to roles; roles bind to models; the
      developer/judge model separation is asserted by test.
- [x] Provider registry allow-list = `["ollama"]`; startup refuses anything else
      — enforced in `run-step.sh`, with `factory/pipeline/tests/test-role-routing.sh`
      covering it (15/15 green). This closes Phase-2 `frontier_provider_refused` and the
      digest half of `wrong_model_tests` ahead of schedule.
- [ ] `factory` user env scrubbed of API keys
- [ ] `factory/risk-policy.yaml` authored (includes `factory/**` tiering) and human-reviewed
- [ ] Gate image built with pinned tool versions; startup version check
- [ ] Sandbox contract implemented (read-only outside editable tree, no sockets/SSH/creds/git, caps dropped, no-net-by-default, resource limits)
- [ ] Hardened systemd unit; podman storage relocated under StateDirectory; integration-tested
- [ ] Human owner records baseline approval (flip status)

## Known gaps in the forked pipeline (ranked)
The fork inherits a working, battle-tested 7-step pipeline. Three things it does
not yet do that the spec requires:

1. **No task loop.** `pipeline-implement` hands the model the whole spec in one
   session. Spec §06 builds task-by-task: one task, its `verify`, the real failure
   output fed back, `max_attempts` cap. This is the entire answer to "a 27B fails
   because it is asked to hold too much at once" (§04) — and the largest single
   piece still to build.
2. **No sandbox / no containment.** The worker has a full `git` binary and writes
   straight into the worktree. §08 requires a podman-contained editable tree with no
   `.git`, no credentials, and out-of-scope edits **rejected, not stripped**, at both
   task and whole-diff granularity.
3. **The model declares its own tier.** `orchestrate.sh` reads `**Pipeline Tier**`
   from the bean's markdown. §08 requires the controller to compute
   `max(policy, judge, bean)` from the actual diff — a model that under-reads its
   change currently down-classifies it.

Carried over and worth keeping: the `package` audit's run-integrity checks (branch
is not `main`, commits exist, `steps.jsonl` start/end pairs balance, verdict filenames
match their target) were each written after a real run failed that exact way.

## Open questions (owner)
- First real target application for Phases 4–6?
      **Answered 2026-09-14:** a wedding seating planner, built as a frozen benchmark
      corpus rather than an existing repo — same requirements rebuilt repeatedly across
      stacks and models, so the line can be measured instead of argued about. Corpus
      discipline in `benchmark/README.md`; requirements frozen and hashed, bean sets
      versioned and regenerable (bean quality is itself a dimension under test).
      Builds target disposable repos, never this one — `factory/**` is Tier 3
      agent-control, and the developer must not hold a writable tree in the repo that
      holds the policy governing it.
- Deploy-to-test mechanism per repo (GitHub Actions `workflow_dispatch` assumed)?
- GPU memory split on Forge — raise after Phase-0 numbers?
- Intake AI side: judge model (proposed) or developer drafts + judge reviews?
