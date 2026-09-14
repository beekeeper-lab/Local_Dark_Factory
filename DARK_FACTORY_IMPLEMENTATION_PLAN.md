# Dark Factory — Implementation Plan (resumable ledger)

**Spec:** `dark-factory-guide.html` v4.0 · **Status:** candidate for baseline approval
**Owner:** _______________  **Approval recorded:** ☐ (date: ________)

> This Markdown file is the authoritative, resumable work ledger. Check boxes as work
> completes. A phase is done only when its closing ritual is complete:
> **all tasks checked → exit criteria machine-verified → audit report generated →
> findings corrected → audit re-run → phase-complete marker committed.**

---

## Phase 0 — Measure on Ollama
**Entry:** models pulled on Forge; Ollama bound to `127.0.0.1`.

- [ ] Configure `OLLAMA_KEEP_ALIVE=-1`, `OLLAMA_MAX_LOADED_MODELS=2`, `OLLAMA_NUM_PARALLEL=1` via `systemctl edit ollama.service`
- [ ] Benchmark at `OLLAMA_CONTEXT_LENGTH` = 16384 / 32768 / 49152; capture `ollama ps` residency + GPU/CPU split each
- [ ] Record prompt-processing vs generation speed separately
- [ ] If not co-resident: measure a real model switch time (feeds §07 model_load_timeout)
- [ ] gpt-oss Harmony conformance test passes
- [ ] Record digest / quant / backend / context beside every figure

**Exit (machine-verified):**
```yaml
phase_0_exit: { residency_recorded: true, harmony_conformance: pass,
                swap_time_measured: "true|na", figures_have_provenance: true }
```
- [ ] Exit criteria verified   - [ ] Audit report generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-0-COMPLETE` marker committed

---

## Phase 1 — One bean, by hand
**Entry:** Phase-0 complete; throwaway repo; one admitted bean with `invariants_ref`.

- [ ] Worker builds the bean via Pi (`--mode rpc`), sandboxed
- [ ] Controller contains diff, gates, creates **candidate commit**
- [ ] Judge reviews `base..candidate`; verdict validates against `schemas/verdict.schema.json` and records `candidate_sha`
- [ ] Allowed-path enforcement verified (out-of-scope edit → rejected, not stripped)
- [ ] Independent invariant ran

**Exit:**
```yaml
phase_1_exit: { allowed_path_enforced: pass, verdict_schema_valid: pass,
                candidate_sha_bound: pass, independent_invariant_ran: pass }
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-1-COMPLETE` committed

---

## Phase 2 — Controller drives it; worker cannot commit
**Entry:** Phase-1 complete.

- [ ] Full loop: sandbox → RPC → contain → classify tier → gates+invariants+hidden vs baseline → candidate commit → judge → push exact SHA → local & remote CI → **human merge**
- [ ] Fault injection — controller restart mid-side-effect
- [ ] Fault injection — unauthorized-path edit (must **reject**, not strip)
- [ ] Fault injection — duplicate PR (idempotency holds)
- [ ] Fault injection — credential-exposure attempt (worker has no creds/git)
- [ ] Fault injection — remote-CI failure returns to worker
- [ ] Fault injection — branch-behind-main → rebase → re-gate + re-review (new candidate)
- [ ] Fault injection — out-of-band PR-head change → blocked (violation, not re-review)
- [ ] Fault injection — wrong model loaded → blocked (inference healthcheck)

**Exit:**
```yaml
phase_2_exit:
  controller_restart_tests: pass
  unauthorized_path_tests:  pass    # rejected, not stripped
  duplicate_pr_tests:       pass
  credential_exposure_tests: pass
  remote_ci_failure_tests:  pass
  stale_branch_tests:       pass    # re-gate + re-review
  pr_head_violation_tests:  pass    # blocked
  wrong_model_tests:        pass
  human_merge_required:     verified
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-2-COMPLETE` committed

---

## Phase 3 — Lights-out to PRs
**Entry:** Phase-2 complete.

- [ ] Queue state machine, atomic leases, idempotency keys, provenance
- [ ] Inference-manager (serial load/unload, healthchecks, load-time telemetry)
- [ ] Kill switch: `pause` / `drain` / `stop-now` all verified
- [ ] Startup reconciliation after induced crash
- [ ] Pre-build ~10 admitted beans; run unattended producing **PRs only**
- [ ] Quality telemetry flowing (false-approval taxonomy, rework, escaped defects)

**Exit (concrete):**
```yaml
phase_3_exit:
  unattended_run_hours: ">= 48"
  completed_beans: ">= 25"
  kill_switch_verbs: "pause|drain|stop-now all verified"
  reconciliation_after_crash: pass
  quality_metrics_flowing: true
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-3-COMPLETE` committed

---

## Phase 4 — Unlock auto-merge by tier, on evidence
**Entry:** Phase-3 complete; ≥ 100 human-reviewed PRs accumulated.

- [ ] Tier-0 thresholds met (below); enable Tier-0 auto-merge only then
- [ ] Auto-suspend armed; Tiers 2–3 remain human / never
- [ ] Rejection-reason classification enforced before counting false approvals

**Exit:**
```yaml
tier_0_unlock:
  human_reviewed_prs: ">= 100"
  known_escapes: 0
  substantive_human_rejections: "<= 1"
  fault_injection: "all pass"
  open_high_sev_findings: 0
  auto_suspend_on: "1 critical escape OR 2 false approvals / 30 PRs"
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-4-COMPLETE` committed

---

## Cross-cutting build tasks (do alongside phases)
- [ ] Implement all schemas: `bean` / `verdict` / `event` / `gate-manifest` / `risk-policy` (provided)
- [ ] Schema-audit each: validate real payloads; fix; re-validate
- [ ] Controller skeleton: state machine + leases + idempotency + reconciliation
- [ ] `risk-policy.yaml` authored and human-reviewed
- [ ] Gate image built with pinned tool versions; startup version check
- [ ] Sandbox contract implemented (read-only outside worktree, no sockets/SSH/creds/git, caps dropped, no-net-by-default, resource limits)
- [ ] Hardened systemd unit; podman storage relocated under StateDirectory; integration-tested
- [ ] Human owner records baseline approval (flip status)
