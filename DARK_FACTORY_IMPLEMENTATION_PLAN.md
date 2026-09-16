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
>
> **Marker convention** (set 2026-09-14, at Phase 0): the marker is a commit whose subject
> begins `PHASE-N-COMPLETE`, plus an annotated tag `phase-N-complete` on it. The tag is what
> makes the boundary findable later — `git log phase-0-complete..HEAD` is the honest answer
> to "what changed since the line was last known good", and a run record can name the tag it
> was built under. Tags are local until pushed: `git push origin phase-0-complete`.

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
- [x] `PHASE-0-COMPLETE` committed — marker commit + annotated tag `phase-0-complete`.

**Phase 0 is closed.** The line has measured hardware, provenanced figures, a green
re-runnable audit, and a bean set approved to run against.

---

## Phase 1 — One bean, by hand, through all seven stages
**Entry:** Phase-0 complete; throwaway GitHub repo with `factory/` scaffold (repo.yaml `human_required`, risk-policy, gates.lock, templates); one approved bean with `invariants_ref`.

> **Entry met 2026-09-14, with one exception.** `beekeeper-lab/seating-planner-py` exists
> (private, no application code yet) and carries the scaffold generated by `factory/scaffold.sh`:
> `repo.yaml` (`merge_mode: human_required`), `risk-policy.yaml`, `gates.lock.yaml` pinned to a
> built image digest, both document templates, and all 20 approved beans with a generated
> `bean.md` and `INDEX.md`. `preflight.sh bean-001` passes against it end to end.
> **`invariants_ref` closed 2026-09-14**, at the owner's direction.
> `factory/invariants/seating.yaml` declares six hard guarantees of any seating answer —
> capacity, one table per guest, eligibility, hard rules, infeasibility being total, and
> reproducibility — with `test_seating_invariants.py` beside it. They were authored before
> any implementation existed, by a different model family from the developer, at a path the
> line can run and cannot write (tier 3, and absent from `repo_allowed_paths`). They are
> **not human-reviewed**, and `seating.yaml` records that under `reviewed_by: null` rather
> than implying otherwise. Wired into bean-006, 007, 009 and 013; the amendment is recorded
> in the bean set's manifest under the rule that an addition which only *narrows* what the
> line may get away with does not re-open approval.
>
> They check the answer through one documented conformance seam
> (`seating_planner.invariant_api.solve_from_spec`), so they constrain what the solver may
> produce without dictating how it is built. Nine cases in `tests/test-invariants.sh` prove
> each invariant catches its own violation and that a correct solver satisfies all six — an
> invariant nobody has seen fail is a comment.

- [~] `factory step specify` — **built and exercised against the real developer model.**
      `factory-spec` writes `spec.md` + `tasks.yaml` and nothing else (no HTML, no git, no
      step bookkeeping — three fewer things for a 27B to get wrong). `spec-check.sh` lints the
      seven sections, validates the task list against the schema, checks every task's paths
      against the bean's, checks every acceptance criterion is claimed, refuses a `manual` or
      `judge` verify, resolves dependencies, enforces `max_tasks` (over → exit 6,
      `split_required`, back to a human) and renders `spec.html`.
      **A real run passed every one of those checks.** What Phase 1 still needs is the same
      thing surviving the judge and the build.
- [x] `factory step commit` — spec candidate commit; artifact hashes recorded
  > **There is no separate commit step, and there should not be.** The spec and task
  > list live in the run directory, which is gitignored: they are the record of a run,
  > not part of the repository's history, and committing them would put a model's
  > working notes into the project's tree. What the item is actually asking for —
  > that the audited artifacts are bound by hash, so a reviewer can prove which
  > version was judged — is done. `audit-check.sh` stamps `artifacts[]` with the path
  > and sha256 of the spec, the task list and the implementation document, and `pr.sh`
  > puts that table in the pull request.
- [~] `factory step audit --stage spec_audit` — **the contract is built.** The judge writes a
      *judgement* (`JUDGEMENT-CONTRACT.md`): its verdict, criteria with evidence, findings,
      feedback, suggested tier. `audit-check.sh` stamps the ten provenance fields the judge
      could only have invented, hash-binds the documents it judged, validates against
      `verdict.schema.json`, and amends the step's own end line. A blocker inside an `accept`
      is recorded as `revise`; a judge's tier suggestion may raise and never lower; a
      provenance fact that cannot be observed stops the verdict rather than taking a
      placeholder. 33 cases. Not yet seen a real judge produce a valid judgement.
- [~] `factory step build` — task loop: worker session → sync-back → containment (task `write_paths`) → task `verify` in gate container → next; a forced failure retries with the real output; `max_attempts` exhaustion blocks with evidence
  > **Built and driven end to end, 2026-09-15.** The loop, containment, rejection
  > with scoped feedback, per-task commits and blocked-with-evidence are all
  > exercised by `tests/test-build-loop.sh` (83 assertions) and by
  > `tests/test-full-line.sh`, which drives preflight → pull request with pi, the
  > judge and gh stubbed. Against the real 27B it has written, verified and
  > committed a task. Still open: a complete real run of all three tasks, which
  > is what the current attempt is for.
  >
  > Two defects here were found only by running it for real, and both were
  > silent: the loop read its task list from stdin and the worker consumed it, so
  > a bean that was a third built recorded BUILD COMPLETE; and the verify sandbox
  > was a flag nobody passed, so task checks ran on a host with none of the pinned
  > toolchain and the worker was told its code failed when it had never been run.
      *(the loop itself is built and tested against a stubbed worker — `build-loop.sh`,
      `verify.sh`, `contain.py`, `factory-build-task`. What Phase 1 still has to prove
      is the loop with the **real** developer model on the other end; "in the gate
      container" waits on the sandbox.)*
- [x] `factory step gate` — full containment, tier computation, all gates + AC verifies + invariants + hidden tests + integrity checks
  > **Built,** with `tests/test-gate.sh` (44 assertions) and a run through the
  > full-line test. `test_integrity` is real: the source half of the diff is
  > reverted in a copy of the tree and the tests must stop passing, with a control
  > run first so a missing binary cannot masquerade as a test doing its job. Its
  > counts — deleted tests, new skips, assertions removed vs added — come from the
  > diff text and say so.
  >
  > **Hidden tests landed 2026-09-16** (`hidden-tests.sh`, 34 assertions). Every
  > other check in this line runs code the worker could read; `allowed_write_paths`
  > stops it writing the tests and nothing stops it reading them. So the hidden
  > suite lives outside the repository — refused if it is inside, because the
  > worker mounts the tree whole — and `sandbox.sh --mount-ro` puts it into the
  > gate container read-only at a path the worker never had, refusing a source
  > inside the tree or a target over /work or a system path.
  >
  > The harder half is what comes back. The run directory is in the repo, so the
  > full output goes outside it and the record carries counts: no names, no
  > assertions, no output. That also bounds the judge, whose findings reach the
  > worker as `feedback_to_worker`. Not-configured is exit 3 and a note, never a
  > pass; could-not-run is a gate failure, because "they did not run" arriving as
  > silence is the fail-open shape this project keeps finding.
- [x] `factory step commit` — implementation candidate; `diff_sha256`, `gate_run_id`
  > The build loop commits per verified task, which is the implementation candidate:
  > `every_handoff_is_commit` in `bench/phase1-audit.sh` checks that the branch carries
  > one commit per verified task and that the tree is clean. `diff_sha256` and
  > `gate_run_id` are stamped into every verdict by `audit-check.sh` and appear in the
  > pull request's provenance table.
- [~] `factory step audit --stage impl_audit` — `test_integrity` required and present
  > `test_integrity` is now measured by the controller rather than asked of the
  > judge, and handed to it as an artifact. What the judge is asked for is what
  > running things cannot settle — whether the tests assert the behaviour the bean
  > wanted, or merely touch it.
- [~] `factory step document` — **built, not yet exercised by a model.** `factory-doc` writes
      `impl-detail.md` from `diff.txt` (the controller puts the accepted diff on disk, because a
      model asked to describe a change from memory will describe the change it expected).
      `doc-check.sh` lints the seven sections, requires the **walkthrough** — not the document
      generally — to cover every changed file, refuses a file shown in the document but absent
      from the diff, and renders `impl-detail.html`. 13 cases. The doc candidate commit is not
      written yet.
- [~] `factory step audit --stage pre_pr_audit` — `document_quality` + `artifacts` hashes present; `matches_diff` true
  > Reached by the full-line test. The package rubric, which was entirely
  > arithmetic, is now `package-check.sh`: matching start/end pairs, a status that
  > agrees with the log, verdict files named so the driver can read them. The run
  > halts if the record contradicts itself rather than asking a judge for an
  > opinion about a record already known to be wrong.
- [~] `factory step pr` — **built as controller work with no model in it**
      (`factory/pipeline/pr.sh`; the `factory-pr` skill is retired to a refusal). It pushes
      only when an accepting verdict's `candidate_sha` **is** HEAD — a verdict is about one
      commit, and if HEAD moved the audit never saw what would be pushed — with a clean tree,
      a passing gate, no outstanding QUESTIONS.md, and never from main. The body leads with
      the fact that no human wrote it, links both documents, tables every verdict with its
      tier, lists what the audits saw and did not block on, and carries the provenance. Never
      merges, never force-pushes, never passes `--auto`, and recognises an existing PR rather
      than opening a second. 25 cases against a `gh` stub that records the verbs. Not yet run
      against real GitHub.
- [ ] A human reads both rendered documents and confirms they teach (risk, blast radius, code blocks, no assumed knowledge)
- [x] Allowed-path enforcement verified at task level and bean level (out-of-scope edit → rejected, not stripped)
  > `tests/test-build-loop.sh` asserts the rejection, the reset, and that the
  > worker's edits are discarded rather than trimmed — including the dotfile and
  > `*`-does-not-cross-a-slash cases that a naive matcher gets wrong. The whole
  > diff is re-checked at the gate against the bean's paths.
- [x] Independent invariant ran — **re-read as "the mechanism is proven", by the owner, 2026-09-15.** bean-001 declares no
  `invariants_ref`, correctly: it is a scaffold with no solver, so there is no seating
  answer for an invariant to be about. In this corpus the first bean that declares them
  is bean-006, which depends on 002–005. So closing Phase 1 needs the line to reach
  bean-006, or the predicate re-read as "the mechanism is proven" rather than "it ran on
  the Phase-1 bean". `bench/phase1-audit.sh` reports `not_applicable` and says which it
  is, rather than passing on a run that never tested it.
  *(the invariants exist and are proven to catch their own
      violations; what Phase 1 has to show is the controller running them against a real build)*
  >
  > **Updated 2026-09-15 evening.** The mechanism half is now shown, which it was
  > not: `tests/test-gate.sh` puts a real invariants file on `main` — outside the
  > bean's write paths, which is the independence guarantee, and the first draft of
  > this test tripped containment by trying to write one from the branch — and runs
  > the gate against an implementation that satisfies it and one that violates it.
  > The gate passes with `ok invariants`, records `invariants.status: pass` and the
  > ref in `gate.json`, keeps `invariants.log`, and fails with the assertion in the
  > log when the answer is wrong. Before this, the only invariant assertion here was
  > the missing-file refusal: a mechanism tested by making it fail, which is a
  > mechanism nobody had seen work.
  >
  > **Decided 2026-09-15: re-read it.** The alternative was on the table — run beans
  > 002 through 006 so a bean that declares invariants reaches a gate, about five
  > more full runs — and the owner chose the re-reading on the evidence above.
  >
  > What the predicate protects against is a line that declares an independent
  > guarantee and never runs it. Two tests answer that, and `bench/phase1-audit.sh`
  > now **checks that both still cover it** rather than taking the decision on
  > trust: if `tests/test-gate.sh` stops asserting that the controller runs a real
  > invariants file through a gate in both directions, the predicate stops reading
  > `mechanism_proven` and goes back to unexercised. A decision recorded as a
  > checkbox would have rotted silently; one recorded as a check cannot.
  >
  > It reports `mechanism_proven`, which is its own word — not `pass`, because this
  > run did not run an invariant, and not `not_applicable`, because the question was
  > answered elsewhere rather than dodged.

> **Where Phase 1 actually stands, 2026-09-15.**
>
> Every step of the line is built and every one has been driven, but by two
> different things: `tests/test-full-line.sh` drives all of it with the models
> stubbed, in twenty seconds, and the real 27B has driven preflight through a
> committed build task. No single real run has yet gone the whole way.
>
> That gap is the honest state of it, and it is smaller than it looks: the six
> defects that stopped the real runs were all found and fixed today, and four of
> them were in the controller rather than in anything a model did. The pattern is
> worth naming, because it will recur — every one was silent. A snapshot that
> turned containment off. A loop that reported success for a third of a bean. A
> containment check that accused the controller. Verifies running on a host with
> none of the pinned toolchain. None of them raised an error; all of them
> produced a plausible record of something that had not happened.
>
> The judge is the remaining known-weak component and is deliberately advisory
> for now, measured as not reproducible on identical input: five runs of the same
> question at temperature 0 gave two verdicts and findings counts of 9, 1, 1 and
> 4. Work has moved out of it rather than into prompting it — see
> `bench/controller-fitness.sh` for what the deterministic checks now settle.

**Exit:**
```yaml
phase_1_exit: { seven_stages_completed: pass, three_verdicts_schema_valid: pass, every_handoff_is_commit: pass,
                docs_rendered_and_read: pass, allowed_path_enforced_task_and_bean: pass,
                task_retry_with_evidence: pass, independent_invariant_ran: pass }
```
- [ ] Exit verified   - [ ] Audit generated   - [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-1-COMPLETE` committed

---

## Phase 2 — Controller drives it; the developer cannot commit
**Entry:** Phase-1 complete, **and the worker runs contained.** *(Containment
landed 2026-09-15 — see the note below. The fault injections it was blocking can
now be written against a real boundary rather than an after-the-fact check.)*

> **Sequencing, corrected 2026-09-14.** Worker containment was filed as
> "remaining sandbox work" to be finished sometime after the fault injections.
> That is backwards: *"out-of-path edit inside a task must reject, not strip"*
> and the credential-exposure test below are fault classes you cannot inject
> against a worker that is not contained — today it edits the real worktree with
> `.git` present and the host network reachable. Testing containment failures
> without containment tests the after-the-fact check and calls it the boundary.
>
> The two missing pieces were called "not small" in RESUME.md, and that was an
> overestimate worth correcting: an image with `pi` in it is a Containerfile with
> one static binary added to the gate image, and reaching only the model endpoint
> is a route, not a research project. `sandbox.sh` already has the `model`
> network mode and already warns that it currently permits general outbound —
> closing that is the actual work, and it is bounded.
>
> **Done, 2026-09-15.** `factory/worker-image/` (node pinned by digest, pi pinned
> by version), `worker-sandbox.sh`, `model-gateway.sh`, `model-bridge.py`, pinned
> in `factory/worker.lock.yaml` and wired into `run-step.sh` as the default for
> any developer step.
>
> The estimate was right about the image and wrong about the route, in an
> instructive way. There is no route: the container runs `--network=none`, which
> removes every route rather than filtering them, and the model arrives on a unix
> socket bridged to exactly one address and port. That is a stronger property
> than an allow-list — there is no interface to widen — and it cost less, except
> for one thing that took three attempts to see. SELinux checks a unix socket
> connection against the peer *process's* context, not the socket file's label,
> so a container may not connect to a socket held by an ordinary user process
> however the file is relabelled. The bridge runs under `runcon -t container_t`
> for that reason, and `factory doctor` now checks `runcon` is present.
>
> `.git` is masked with an empty read-only mount rather than removed, so the
> worker's edits still land in the real tree where the change scan reads them,
> while `git` inside reports "not a git repository". The controller makes every
> commit, after it has decided the attempt is worth one.

- [ ] Full loop unattended for one bean: lease → worktree → specify → spec audit → build loop → gate → impl audit → document → pre-PR audit → push → CI → **human merge**
> **Six of these are done, 2026-09-15**, in `tests/test-faults.sh` — model-free,
> seconds per case, run by `tests/run-all.sh`. They were filed as blocked on
> worker containment, correctly: you cannot test a containment failure against a
> worker that is not contained, only the after-the-fact check. Containment landed,
> and then four of the six passed on their first run, which says the refusals were
> already right rather than that the tests were written to fit them.
>
> Killing the controller mid-build joined them, which was not obvious: the reason
> it was filed as unfakeable is that a stub cannot produce a half-finished remote
> state — but it can be killed. Doing so found that the controller left its
> children running, and taught a limit worth writing down: bash does not run a
> trap while blocked on a foreground child, so TERM to the controller alone is
> deferred until the current step returns. Ctrl+C does not have that problem
> because a terminal signals the whole process group. To stop a detached run
> promptly, signal the group.
>
> Only the remote-CI case is genuinely left.

- [x] Fault injection — controller restart mid-stage — `tests/test-faults.sh`, two stages. **Mid-build**: the line is killed, the tree comes back clean, the run record says `interrupted`, and a resume continues rather than starting over. **Mid-document** (added 2026-09-15, because five of bean-001's six doc attempts ended in something other than the model finishing): the session is killed part-way through writing, the tree stays clean because a doc step writes only to the run directory, the fragment survives as evidence, and the resumed run writes the document again rather than skipping it. That case is the one the new "a step that produced its output is not undone by how it exited" rule has to survive, and it does — for the reason the rule was safe to add: the exit code was never what protected anyone, doc-check reads the document and a fragment fails on its contents.
- [x] Fault injection — out-of-path edit inside a task (must **reject**, not strip; attempt++) — `tests/test-faults.sh`
- [x] Fault injection — out-of-path edit in whole-diff containment — `tests/test-faults.sh`. Distinct from the task-level check: each attempt can stay inside its own write_paths while the branch drifts, because a commit made outside the loop is inside nobody's paths. The gate reads the whole diff against the bean.
- [x] Fault injection — task list with an unclaimed AC → spec audit must `revise` — `tests/test-faults.sh`; the controller refuses it before the judge is asked
- [x] Fault injection — task list exceeding `size_budget` → `split_required`, bean blocked back to intake — `tests/test-faults.sh`
- [x] Fault injection — impl-detail that misdescribes the diff → refused before the PR, with the code left committed and untouched — `tests/test-faults.sh`
- [x] Fault injection — duplicate PR (idempotency holds) — `tests/test-faults.sh`
- [x] Fault injection — credential-exposure attempt — asserted structurally against the worker image (no ssh dir, no git identity, `.git` masked in the mount) — `tests/test-faults.sh`
- [x] Fault injection — remote-CI failure returns to build with targeted tasks — `factory/pipeline/ci.sh` is the step, after `pr`; `tests/test-ci.sh` (44) covers green, a required check that never reported, checks that never finish, a failure that re-opens exactly the tasks whose write paths the log names, a failure that names nothing this bean wrote and so re-opens nothing, and a repo that names no required checks — which is reported as NOT ASKED rather than green. The rewind mechanism is the one `sync` already uses: `to: build`, forcing everything after it, with `reopened-tasks.txt` telling the build loop which tasks stopped being verified. **The workflow it waits on is `factory/scaffold/.github/workflows/gates.yml`**, which runs the image `gates.lock.yaml` pins, by digest, so a green on GitHub is the same claim as a green on Forge. Publishing it is `factory/gate-image/publish.sh --registry ghcr.io/<org>`; until then the workflow fails loudly rather than skipping. *Not yet exercised against a real GitHub run — the image has not been pushed.*
- [x] Fault injection — branch-behind-main → rebase → re-gate + re-audit impl and pre-PR (new candidate); spec audit stands — `factory/pipeline/sync.sh` is the step, between `audit-package` and `pr`; `tests/test-sync.sh` covers current, behind, conflict, a base that keeps moving, and the preconditions; `tests/test-full-line.sh` moves main under a *completed* run and asserts that exactly gate, audit-impl and audit-package replay while the spec audit and the document do not. The orchestrator's step loop became an index rather than a `for` so the line can go backwards. First exercised for real on run `bean-001-20260915T192025Z`, where a housekeeping commit of mine had landed on the bean's branch: moved to main, rebased out of the candidate, and the gate re-ran green against the new commit.
- [x] Fault injection — out-of-band PR-head change → blocked (violation, not re-review) — `tests/test-pr.sh`: pr.sh refuses when the verdict's `candidate_sha` is not what would be pushed, with "the audit did not see what would be pushed".
- [x] Fault injection — wrong model loaded → blocked — `tests/test-role-routing.sh`. Two halves. A model absent from ollama is refused rather than silently substituted. And, as of 2026-09-15, the digest is re-asserted at **every step**: new-run.sh records a digest per role, and a step whose model no longer matches it halts. Nothing compared the two before, so a tag re-pointed mid-run — `ollama pull` by this project or by anything else sharing the server — produced a run whose early steps ran on one set of weights and whose later steps ran on another, both recorded truthfully, with nothing anywhere saying they differ. A halt rather than a warning, because the comparison arm of every measurement here is another run, and a run that changed models partway through cannot be compared with anything, including itself.
- [x] Fault injection — frontier provider added to `models.json` → startup refuses — `tests/test-role-routing.sh`: the provider allow-list in roles.json is checked before any step runs, and a non-local provider is a refusal rather than a warning.

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
- [x] Audit generated — `bench/phase2-audit.sh`, 2026-09-16. It does not read this plan:
  it runs the suites that hold each predicate and looks for the specific assertions by
  name, so a renamed or deleted assertion reports as missing. Thirteen predicates,
  13 ok, 0 findings — with `remote_ci_failure_tests` reported as **`pass_in_tests`**,
  because `gates.lock.yaml` still pins a `localhost/` image that CI cannot pull, so that
  fault has only ever met a stubbed `gh`.
- [ ] Exit verified — waiting on the one thing above: publish the gate image, install the
  workflow, and let a real required check fail once. Everything else is computed green.
- [ ] Findings corrected   - [ ] Audit re-run green   - [ ] `PHASE-2-COMPLETE` committed

---

## Phase 3 — Intake refinery (may run alongside Phase 2)
**Entry:** Phase-1 complete; a real meeting transcript (Markdown) for a real target repo.

- [ ] `factory intake --repo <owner/name> --source <transcript.md>` — interactive session, read-only repo tree, judge model as the AI side
- [ ] Work-item extraction with source excerpts; ambiguities surfaced as questions
- [ ] Draft beans schema-valid on save (`bean/2.0.0`, every AC has `verify`, `size_budget` set)
- [ ] Joint review: split / merge / reject / reorder / fix dependencies; `manual` ACs flagged
- [ ] Approval stamps `status: approved` + `approval {approved_by, approved_at, order}`
- [ ] Intake branch `factory/intake-<date>` + PR opened; human merges
- [x] `factory go` refuses non-approved beans; queues approved beans in `order` respecting `dependencies` — `factory/pipeline/queue.sh` computes the queue and `factory go` runs it, one bean at a time, re-asking after each because a finished bean unblocks the next. `tests/test-queue.sh` (29). A bean is `ready`, `blocked` (with what it waits on named), `in_progress` (a branch exists — starting it again would cut a second branch off main), `done` (a run recorded a pull request), or **`refused`**: not approved. Refused rather than skipped, because in a list those look the same and mean opposite things, and `--bean <id>` goes through the same gate so a flag cannot bypass it. Serial by measurement, not simplification: `max_inflight: 1` and Phase 0 found the Q8 developer and the judge cannot co-reside.
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
      *(add judge wall-clock per audit: measured between 21 s and >15 min for the same
      artifacts depending on whether the shape held first time. A fifteen-minute audit is a
      throughput problem for an unattended line; a twenty-second one is not, and the
      difference is currently invisible.)*

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
- [x] `factory-doclint` — `factory/pipeline/doclint.sh`, both document kinds. Presence is the
      easy half; the half that earns its keep is refusing a section that restates its own heading
      and a `Deviations from the spec: None` that was never checked against anything. Accepts both
      spellings of "behaviour" — failing a document over a vowel teaches nothing.
- [x] Document templates + renderer — `factory/scaffold/factory/templates/{spec,impl-detail}.html`
      (self-contained, dark, printable, no external resource) and `factory/pipeline/render-doc.py`.
      The renderer is written here rather than pulled from PyPI on purpose: §06 records an artifact
      hash for every document, and a renderer whose output moves on a library upgrade makes "the
      document changed" stop meaning "someone changed the document". Markdown from a model that
      contains HTML is escaped, not rendered — tested.
- [~] Prompt packs, versioned: `developer/specify`, `developer/build-task`, `developer/document`, `judge/spec-audit`, `judge/impl-audit`, `judge/pre-pr-audit`, `intake/extract`, `intake/draft-bean`
      - Forked into `factory/skills/` from the proven InvTrac set (spec / implement /
        doc / audit / pr / run) and loaded explicitly via `pi --skill`, because the
        global `~/.pi/agent/skills` is owned by that project — its `sync-skills.sh`
        treats its own copy as canonical, so editing the installed copies would break
        it silently on its next run. **`developer/build-task` added 2026-09-14**
        (`factory/skills/factory-build-task`): one task, one session, no git, and an
        explicit account of what the controller does next, so the worker can predict
        the consequence of overreaching instead of discovering it.
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
- [~] `factory/risk-policy.yaml` authored — in `factory/scaffold/`, schema-valid, with `factory/**`
      and agent-control paths at tier 3 and the solver at tier 2. **Not yet human-reviewed**, which is
      the half that matters: this file decides what the line may touch unsupervised.
- [x] Gate image built and pinned — `factory/gate-image/` (Containerfile pinned to the base by
      digest, versions in `versions.env`, `build.sh` refuses to print a digest for an image whose
      contents disagree with them). Built 2026-09-14: ruff 0.16.7, mypy 2.3.1, pytest 9.1.1,
      pytest-cov 7.1.0, ortools 9.15.6755, python 3.12 — resolved by asking pip, not from memory.
      `gates.lock.yaml` names it by digest and sets `verify_versions_at_startup: true`; the startup
      assertion itself belongs to the controller and is not written yet.
- [~] Sandbox contract implemented — `factory/pipeline/sandbox.sh` + `sync-tree.sh`, every
      clause asserted by attempting the escape (36 cases). Gates and task verifies run inside
      it. **The worker session does not yet**: that needs a `pi` image and an allow-listed
      proxy for the model endpoint, since `--network=model` today also permits general
      outbound.
- [ ] Hardened systemd unit; podman storage relocated under StateDirectory; integration-tested
- [ ] Human owner records baseline approval (flip status)

## Known gaps in the forked pipeline (ranked)
The fork inherits a working, battle-tested 7-step pipeline. Three things it does
not yet do that the spec requires:

1. ~~**No task loop.**~~ **Built 2026-09-14.** `factory/pipeline/build-loop.sh` is the
   controller-driven loop of spec §06 step 5: tasks in dependency order, one worker
   session per attempt (`factory-build-task`, the prompt pack that was missing),
   containment against the task's `write_paths` **and** the bean's — rejected and the
   tree reset, never stripped — then the task's `verify` list run by the controller
   via `verify.sh`, the real failure output fed back as the next prompt, `max_attempts`
   exhaustion blocking the bean with its evidence. Each verified task is its own commit.
   Wired into `orchestrate.sh` as the `build` step, replacing one-shot `implement` in
   both tiers; `audit-impl` and `audit-package` now route their retries to `build`.
   55 cases in `tests/test-build-loop.sh`, 16 in `tests/test-orchestrate-build.sh`.

   Three things this deliberately does **not** do, so nobody reads more into it:
   - an unsupported verify (`manual`, `judge`, an undefined gate) is a **failure**,
     never a pass — a criterion the controller cannot check is not a criterion;
   - it does not sandbox anything. Containment is after the fact because the worker
     still edits the real tree (gap 2, below);
   - it has only ever run against a stubbed worker. The loop is tested; the *models*
     going round it are Phase 1's job.

   It also turned up a live defect in `run-step.sh`: attempts were counted across the
   whole run *after* the child ran, so a second invocation of a step (any build-loop
   attempt, and every retry after an audit FAIL) was mistaken for "the child closed its
   own attempt" — no new attempt line was written and the previous attempt's verdict
   was reused as the new one's. Fixed by comparing against a snapshot taken before the
   child starts, and pinned by two cases in `tests/test-role-routing.sh`.
2. **Sandbox: half closed, 2026-09-14.** `factory/pipeline/sandbox.sh` runs a command
   under the §08 contract and **refuses** rather than degrading: read-only rootfs with the
   editable tree as the only writable mount, no network, all capabilities dropped,
   no-new-privileges, memory/cpu/pids/wall-clock/output limits, an environment with nothing
   from the host, and an image that must be pinned by digest and must still match that
   digest. "No git" is structural on both sides — the image has no git binary (asserted at
   startup) and `sync-tree.sh` mirrors the worktree without `.git` (asserted after every
   sync). 36 cases in `tests/test-sandbox.sh`, each one *attempting* the escape rather than
   checking that a flag was passed.

   **What is contained now:** every task `verify` under `build-loop.sh --sandbox`, which is
   where §06 step 5 puts it. A test is code the developer model wrote, and a test that
   writes outside the tree or opens a socket is now stopped rather than noticed afterwards.
   The result records `ran_in: sandbox|host`, so a verdict cannot be silently uncontained.

   **What is not:** the worker session itself. It still edits the real worktree and can see
   `.git`, so its containment remains after-the-fact (reject the attempt, reset the tree).
   Closing it needs an image with `pi` inside and a network story — §08 wants no network,
   the worker needs exactly one endpoint, and `--network=model` currently reaches the host
   loopback *and* general outbound, which the script says out loud when used. An
   allow-listed proxy is the missing piece.

   Whole-diff containment at the bean level is also still to do; the task level is done.
3. ~~**The model declares its own tier.**~~ **Closed 2026-09-14.**
   `factory/pipeline/tier.py` computes `max(policy, bean_suggested, judge_suggested)` from
   the paths the diff actually touched, and `gate.sh` is the stage that runs it. Every term
   can raise the tier and none can lower it, so a model that under-reads its change is simply
   not consulted on the question. The policy term matches the risk policy's glob rules —
   including its brace alternatives, which the matcher did not handle and which would have
   silently classified every agent-control file as tier 1.

   `gate.sh` is §06 step 6 entire: whole-diff containment against the bean's paths
   **intersected** with the repo's approved surface (a bean declaring `**` gets no more reach
   than the human-approved list), the binding tier with the path and rule that set it, the
   size budget, a narrow secret scan, then every gate from the pinned manifest, every
   acceptance criterion, and the independent invariants — all inside the sandbox. It writes
   `gate.json` and the driver names what failed in QUESTIONS.md. 42 cases in
   `tests/test-gate.sh`.

   One bug found on the way and worth remembering: a rule whose `min_tier` was *below*
   `default_tier` never fired, because the maximum was seeded with the default. The policy's
   own tier-0 documents rule was dead code, and the file read as though it were not. The
   schema's wording is "max over matched minimums, default only when nothing matches", and
   that is now what happens.

Carried over and worth keeping: the `package` audit's run-integrity checks (branch
is not `main`, commits exist, `steps.jsonl` start/end pairs balance, verdict filenames
match their target) were each written after a real run failed that exact way.

## Judge fitness — the first number, 2026-09-15

`bench/judge-fitness.sh`, six cases against `gpt-oss:120b` at thinking=medium:
one clean control and five specs each carrying a single planted defect a script
cannot catch.

| | |
|---|---|
| clean control | **accepted**, correctly, in 52 s against the real ac1–ac4 with verbatim quotes |
| seeded defects | 5 |
| rejected | 4 |
| **named the actual defect** | **1** |
| false accepts | **0** |
| produced no judgement at all | 1 |

**The good half:** no false approvals. The judge has never passed a seeded
defect, and it accepts a clean spec rather than rejecting everything — a judge
that fails everything is not a judge either.

**The half that needs work:** it rejects for the *wrong reason* four times out of
five. Told a spec whose only verify is `test -d .`, it complained about YAML
syntax. Told a spec inventing a module that does not exist, it complained about
YAML syntax. Only "a criterion declared met by an argument that defeats it" was
caught and named.

That matters beyond tidiness, because `feedback_to_worker` is what the developer
gets on a revise. A judge that rejects correctly but explains wrongly sends the
developer to fix something that is not broken, and burns an attempt doing it. The
rejection is safe; the feedback is not yet useful.

Recorded at `bench/results/judge-fitness-20260915T012448Z.json` with every
judgement kept. Re-run after any change to the judge prompt, the thinking level,
or the model — this is the number the §01 argument rests on, and it is now a
number rather than a hope.

## The pivot trigger — decided in advance, on purpose

Six halts in one evening is a normal Phase 1. The hazard is not the halts; it is
that each one reopens "is the 27B simply not up to this, should we change the
harness / the model / the whole approach" — a question that is unanswerable in the
moment and expensive to re-litigate. So the trigger and the lever order are fixed
here, now, while nothing is at stake.

**When to evaluate.** After **10 beans attempted** (bean-001 … bean-010, which
spans a scaffold through the first solver work — enough variety that a result is
about the line rather than about one bean).

**What counts.** `pass_to_gate` = the bean reached a passing `gate.json` with no
human touching the artifacts. Not merged, not reviewed — gated.

**The trigger fires if either:**
- fewer than **5 of 10** beans reach a passing gate, or
- the **same class of failure** blocks **3 or more** beans (one cause, three
  beans, is a property of the line and not of the work).

**Lever order, and it is not negotiable in the moment:**

1. **Bean granularity and spec detail.** A plan is a prompt scaled up. The
   cheapest thing to change is the input, and §04 already says decomposition is
   the human's highest-leverage act. Re-cut the beans smaller, put more
   background in them, tighten the acceptance criteria. Re-run the same ten.
2. **The model.** Only after (1) has been tried and measured. The Q4 arm exists
   for this, and the standing protocol for changing a model (shadow-run over the
   last K≥20 beans, compare verdict agreement and task pass rate) is already
   written. A model swap without (1) is a swap whose result cannot be attributed.
3. **The harness.** Last. If the line's own mechanics are the problem, the
   evidence for that will be specific — a stage that fails for the same
   structural reason regardless of bean or model — and it will be obvious by the
   time the first two levers have been pulled.

The point of writing this down before it is needed: at the moment a run halts,
every lever looks equally plausible and the most recent failure looks like the
most important one. This ordering is a claim about cost and attributability, not
about which failure is freshest.

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
