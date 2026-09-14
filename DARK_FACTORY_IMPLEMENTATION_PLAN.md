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

  > **Superseded by measurement (post-reboot, see the checklist below).** The prediction that
  > 96 GiB "still lets Phase 0 attempt co-residency" held, and the attempt succeeded — but only
  > for the Q4 developer. The binding limit turned out not to be the GTT ceiling at all: ollama
  > withholds 8-15 GiB beneath it, putting the effective co-residency budget between 81.4 and
  > 88.4 GiB. Raising the ceiling further would therefore *not* have bought the Q8 pair, so the
  > "one command" escape hatch above is not the lever it appears to be.
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
- [x] Re-record split after reboot — verified 2026-09-14 post-reboot: `ttm.pages_limit=25165824`
      on the kernel cmdline, `mem_info_gtt_total` = 103079215104 (**96 GiB**), RAM 125 GiB,
      dedicated VRAM 512 MiB. Recorded in `bench/results/provenance-post-reboot-*.json`
- [x] Confirm the serial conclusion empirically — **done, and the first answer was wrong twice
      over.** The sweep's `regime_decision: serial` rested on nine evictions logged as
      `"predicted to exceed available memory"`, eight of which had predicted *below* the
      available figure on the same line. Two hypotheses were tested and both failed before the
      real constraint appeared (`bench/results/coresidency-probe-20260914.json`):

      1. **Not `MAX_LOADED_MODELS`.** Set to `2` and restarted: the Q8 developer was still
         evicted for the judge at 61.7 GiB predicted vs 68.9 available. Two small models
         (`qwen3-vl` + `gpt-oss:20b`) co-resided fine under the same setting, so multi-runner
         works and the setting is effective.
      2. **Not context, and not the judge.** At 8192 the refusal persisted (61.3 vs 69.0), so
         KV size is not the lever; and the judge co-resides happily with `gpt-oss:20b` at
         72.9 GiB, so it is not a per-model quirk.

      The constraint is **total footprint**, and ollama's own `available` figure overstates
      what it will grant. Bracketed by measurement:

      | pair | GTT used | co-resident? |
      |---|---|---|
      | judge + `gpt-oss:20b` | 72.9 GiB | yes |
      | Q8 developer + `qwen3-coder-next` | 77.4 GiB | yes |
      | judge + **Q4** developer @16384 | 79.0 GiB | yes |
      | judge + **Q4** developer @49152 | 81.4 GiB | yes |
      | judge + **Q8** developer | ~88.4 GiB predicted | **no** |

      **Effective co-residency budget is between 81.4 and 88.4 GiB — ollama withholds roughly
      8-15 GiB beneath the 96 GiB ceiling.** So the ceiling raise was not wasted (62 GiB could
      not have held any of these pairs), but 96 GiB does not buy the Q8 pair.
- [x] **Decision recorded: regime = `serial`** — and now for a reason that survives scrutiny.
      It is not a capacity claim about the ceiling, which the Q4 arm disproves: the developer
      and judge *can* co-reside, at 79-81 GiB, both 100% GPU, developer up to 49152 ctx, if the
      developer drops from Q8_0 to Q4_K_M. So the real choice is **developer quantisation vs.
      swap cost**, and swap is cheap — 8.0 s judge->developer, 13.2 s developer->judge, against
      per-stage runtimes in minutes. Paying ~10 s per role transition to keep Q8_0 weights is
      the better trade. **Revisit if `swap_overhead_pct` telemetry exceeds ~15%**, at which
      point the Q4 co-resident arm becomes a live alternative rather than a fallback.
- [x] Set the final ollama unit config — applied 2026-09-14 via
      `/etc/systemd/system/ollama.service.d/zz-factory.conf`; the temporary probe drop-in is
      gone. Asserted on every audit run (`bench/phase0-audit.sh`: `unit.*`, `unit.probe_dropin_removed`).
      `OLLAMA_KEEP_ALIVE=-1` (already on the unit),
      `OLLAMA_NUM_PARALLEL=1` (already the running value), and **`OLLAMA_MAX_LOADED_MODELS=1`**.
      The value `1` is now correct for a *measured* reason rather than the original one: the Q8
      pair genuinely cannot co-reside, so permitting 2 only invites load attempts that end in
      eviction and a wasted 8-13 s. **Remove the temporary probe drop-in first:**
      `/etc/systemd/system/ollama.service.d/zz-phase0-coresidency-test.conf`.
- [x] Benchmark context 16384 / 32768 / 49152, each alone then both, with `ollama ps` residency
      + GPU/CPU split — done via per-request `options.num_ctx` (no unit edit, no restart). Both
      models reported **100% GPU, 0% CPU at every context**; no spill to CPU at any point.
      Full rows in `bench/results/phase0-20260914T173319Z.json`.
- [x] Record prompt-processing vs generation speed separately, per model — measured, and the
      prompt/generation asymmetry is stark. Developer `qwen3.8:27b-mtp-q8_0`: ~325 prompt tok/s,
      ~20 gen tok/s. Judge `gpt-oss:120b`: ~861-1052 prompt tok/s, ~35 gen tok/s. The 120B MoE
      is **~3x faster at prompt processing and ~1.75x faster at generation than the 27B dense
      Q8_0**, which inverts the usual size intuition and matters for scheduling: the judge is
      not the expensive stage. Context had almost no effect on throughput across 16K-49K, so
      the earlier 39-minute InvTrac spec step was the 262144 default context, not model speed.
- [x] Time a real model switch in both directions — judge->developer **8.0 s**,
      developer->judge **13.2 s**. `model_load_timeout` suggestion: **27 s** (2x worst). Swap
      cost is far cheaper than feared, which weakens the case for co-residency independently
      of whether it is possible.
- [x] gpt-oss Harmony conformance test passes — **12/12**, `bench/harmony-conformance.sh`
      (re-runnable). Verified on both endpoints: the final channel returns clean content, the
      analysis channel is exposed separately as `reasoning`/`thinking`, no `<|channel|>`-class
      control tokens leak into either, the `developer` role is accepted, and constrained
      decoding still yields schema-legal JSON with a valid `verdict` enum while thinking is on.
      That last one is the load-bearing case: every verdict is a schema-shaped object, so if
      Harmony and constrained decoding interfered, every audit step would fail at the end
      rather than the start.
- [x] Pi drives **both** models — and finding this out cost the judge its reasoning. The
      pipeline does not use `--mode rpc` (that checklist wording was wrong; `run-step.sh` calls
      `pi --model <provider>/<model> --thinking <level> --skill <dir> -p`). Both models answer
      correctly under the real invocation. **But `--thinking high` was being silently
      discarded for the judge.** pi gates thinking on its own model catalog
      (`~/.pi/agent/models.json`), and `gpt-oss:120b` was registered without `reasoning: true`;
      pi accepted the flag, emitted no warning, and recorded `thinkingLevel: "off"` in the
      session. The developer, registered with `reasoning: true`, correctly recorded `"medium"`.

      So the judge — the one role whose entire value is careful, independent review (§01) — had
      been running with reasoning **off**, while `roles.json` declared `"high"`. Worse for the
      experiment: `run-step.sh` stamps `conditions.thinking` from `roles.json`, not from what
      pi actually did, so every run record would have asserted a thinking level the run never
      used. **A false provenance figure is worse than a missing one** — it survives into the
      telemetry that later decisions get made from, which is the same failure the run-record
      contract was added to prevent.

      Fixed in two places: `gpt-oss:120b` and `gpt-oss:20b` now declare `reasoning: true`
      (contextWindow 131072, maxTokens 32768) in pi's catalog — backup at
      `~/.pi/agent/models.json.bak-20260914-preharmony` — and `preflight.sh` now refuses to
      start a run if any role declaring a thinking level maps to a model pi believes cannot
      think. Re-verified: the judge now records `thinkingLevel: "high"`. This is the same class
      of gap `roles.json` already flagged for `num_ctx` ("declared here but Ollama serves what
      the unit says; assert, do not trust") — now proven real for `thinking`, and asserted.
- [x] Record digest / quant / Ollama version / GPU split / context beside every figure —
      every row in the results JSON carries provenance: developer `8a1582877303` [Q8_0],
      judge `a951a23b46a1` [MXFP4], ollama 0.32.13, kernel 7.2.5-100.fc43.x86_64, GTT 96 GiB.

**Exit (machine-verified):**
```yaml
phase_0_exit: { residency_recorded: true, swap_time_measured: true, harmony_conformance: pass,
                pi_drives_both_models: pass, regime_decision: "coresident|serial", figures_have_provenance: true }
```
- [x] Exit verified — all six `phase_0_exit` predicates hold:
      `residency_recorded: true`, `swap_time_measured: true`, `harmony_conformance: pass`,
      `pi_drives_both_models: pass`, `regime_decision: "serial"`, `figures_have_provenance: true`.
- [x] **Audit generated** — `bench/phase0-audit.sh` (re-runnable) + `audits/PHASE-0-AUDIT-20260914.md`.
      The first finding was the ritual's own first clause: "exit criteria machine-verified" was
      prose. `grep -rn phase_0_exit` matched this file and `RESUME.md` and nothing else — nothing
      computed the six predicates. The harness computes them, and checks the machine, the digests,
      the reproducibility of the evidence and the honesty of the harnesses around it.
      **10 findings: 2 blocker, 5 major, 3 minor.**
- [x] **Findings corrected** — all ten:
      1. *blocker* `bench/results/` was gitignored, so every figure the sections above cite lived
         only on Forge's disk. `.gitignore` now ignores sweep output but admits cited artifacts by
         name; the five are committed.
      2. *blocker* `run-step.sh` stamped `conditions.num_ctx` from `roles.json` and never applied
         it — pi has no context flag (`pi --help`), so ollama served its 131072 default against a
         declared 32768. Both `num_ctx` and `thinking` are now read back (ollama `/api/ps`, pi's
         session file), the declared values kept under `conditions.declared`, with
         `declared_matches_observed` and a `WARN` line on drift. The identical bug was fixed for
         `thinking` last session; this was the same lie one field over.
      3. *major* `preflight.sh`'s thinking tripwire was wrapped in `[ -f "$PI_MODELS" ]` — a pi
         upgrade that moved the catalog would have deleted the check silently while preflight
         printed PASS. A missing catalog is now a FAIL.
      4. *major* `regime_decision` was derived purely from observed co-residency, so under the
         final `MAX_LOADED_MODELS=1` it could only ever emit `serial` — the unit file wearing a
         measurement's clothes. It now emits `unknown` with a `regime_evidence` block when
         co-residency was not attemptable, and provenance carries the scheduler settings.
      5. *major* the co-residency probe was hand-written with no harness behind it.
         `phase0.sh --coresidency-probe` regenerates it under the same schema; it refuses (exit 3)
         unless `MAX_LOADED_MODELS>=2`, printing the drop-in commands rather than editing the unit
         itself.
      6. *major* `phase0.sh --provenance-only` logged "writing results to <path>" and wrote
         nothing there. It writes the file now.
      7. *major* `harmony-conformance.sh` printed 12/12 and saved nothing, leaving the
         `harmony_conformance` predicate resting on prose — for the one predicate that is a
         property of specific weights. It now writes `bench/results/harmony-<stamp>.json` with the
         judge's digest and quant beside every case.
      8/9. *minor* `RESUME.md` told the next session to run `python bench/validate.py`: no bare
         `python` on this box, and the bare invocation validates no bean at all. Both corrected.
      10. *minor* the unit-config checkbox above was unchecked though the work was done.
- [x] **Audit re-run green** — `./bench/phase0-audit.sh --with-models` → 0 findings; artifact at
      `audits/phase0-audit-20260914T182533Z.json`.
- [ ] `PHASE-0-COMPLETE` committed

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
