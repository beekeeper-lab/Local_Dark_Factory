# Resume here — Phase 1

Phase 0 closed 2026-09-14 (tag `phase-0-complete`). Branch `factory/phase0-prep-and-bean-set-v1`.

## State: Phase 0 closed. Phase 1 is being run, one failure at a time.

All six `phase_0_exit` predicates hold — and, as of the audit, they are *computed*
rather than asserted (`bench/phase0-audit.sh`), which they were not before:

```yaml
residency_recorded: true      swap_time_measured: true     harmony_conformance: pass
pi_drives_both_models: pass   regime_decision: "serial"    figures_have_provenance: true
```

The audit found 10 things (2 blocker, 5 major, 3 minor); all were corrected and the
re-run is green. Report: `audits/PHASE-0-AUDIT-20260914.md`. The two that matter most
for anything downstream:

- **Evidence is now committed.** `bench/results/` was gitignored, so every Phase-0
  figure lived only on Forge's disk. The cited artifacts are tracked by name now.
- **Run conditions are observed, not declared.** `run-step.sh` used to stamp
  `conditions.num_ctx` and `conditions.thinking` from `roles.json`. pi has no
  `num_ctx` flag at all, so that number was fiction whenever the server disagreed.
  Both are now read back (pi's session file, ollama `/api/ps`), with the declared
  value kept beside the observed one and a `declared_matches_observed` flag.

Marker convention, set here and binding on every later phase: a commit whose subject
begins `PHASE-N-COMPLETE`, plus an annotated tag `phase-N-complete`. Tags are local until
pushed.

**All 20 seating-planner beans are `status: approved`** (2026-09-14, bulk approval delegated
by the owner — recorded as such in `bean-sets/v1/manifest.json`, because a set-level
approval is not the per-bean human read §04 describes). Run order is bean id order, which
is a checked topological order.

## Sandbox — what is contained, and what is not

`factory/pipeline/sandbox.sh` implements the §08 contract and refuses rather than degrades.
Proven by attempting each escape (`tests/test-sandbox.sh`, 36 cases): read-only outside the
one writable tree, no network, no capabilities, no host environment, no container socket, no
SSH agent, limits on memory/cpu/pids/wall-clock/output, image pinned by digest and checked
against it, no git binary in the image, no `.git` in the tree.

**Contained today:** every task `verify`, via `build-loop.sh --sandbox` (§06 step 5). Results
record `ran_in: sandbox|host` so an uncontained verdict cannot pass for a contained one.

**Not contained today:** the worker session. It edits the real worktree and can see `.git`.
Two things are missing and neither is small: an image with `pi` in it, and a way to let the
worker reach *only* the model endpoint — `--network=model` reaches the host loopback and
general outbound, and says so when used. An allow-listed proxy is the next piece of that.

## The three ranked gaps in the forked pipeline are now two closed and one half

1. ~~No task loop~~ — built.
2. **Sandbox — half.** Gates and verifies are contained; the worker session is not.
3. ~~The model declares its own tier~~ — `tier.py` + `gate.sh`. The tier comes from the
   paths the diff touched; bean and judge can only raise it.

## The stages, as they stand

| Stage | Model half | Controller half | Tested |
|---|---|---|---|
| preflight | — | `preflight.sh` | via orchestrate |
| specify | `factory-spec` writes `spec.md` + `tasks.yaml` | `spec-check.sh`: sections, schema, paths, claimed criteria, budget, renders HTML | 24 |
| spec audit | `factory-audit` writes a *judgement* | `audit-check.sh` stamps provenance, validates, amends the step | 33 |
| build | `factory-build-task`, one task per session | `build-loop.sh`: contain → reject+reset → verify in the sandbox → commit | 67 |
| gate | — | `gate.sh`: whole-diff containment, tier, budget, secrets, gates, ACs, invariants | 42 |
| document / pre-PR audit / PR | still the forked skills | not yet written | — |

Supporting: `sandbox.sh` (36), `render-doc.py` + `doclint.sh` (33), invariants (9).

## The judge does not run as an agent

`audit-*` does not go through `run-step.sh`. gpt-oss:120b under pi calls a
`repo_browser.*` tool namespace that does not exist here — twelve calls, empty
arguments, no result, and then a confident audit of a document it never read.
`judge.sh` puts the artifacts in the question instead, constrains the answer,
and writes the file itself. A system message denying tools is load-bearing:
without it the model emits those tool calls even against the raw API with the
documents already in the prompt.

It is also the only place in the line where the declared context is the served
context, because `/api/chat` takes `options.num_ctx` and pi does not.

## The worker's harness surface is closed

`run-step.sh` passed pi `--model`, `--thinking`, `--skill` and nothing else, so pi
discovered the rest on its own: every file in `~/.pi/agent/extensions/` — 24 on this
box, among them `github-mcp.ts`, `trello.ts`, `obsidian.ts`, `team-lead.ts` and two
`posttooluse-edit-write` hooks — plus the prompt-template directory, plus any
`AGENTS.md`/`CLAUDE.md` in the target repo, prepended silently. None of it was in the
run record. That is the skill collision one directory over, on a line whose invariant
is "no credential near a model".

Now: `--no-extensions --no-prompt-templates --no-context-files --tools read,write,edit,bash`,
and `conditions.harness` records the flag set and the four tool names, so two runs
with different surfaces are not mistaken for comparable. `factory-spec` still tells
the worker to *read* the repo's context files if present — a recorded act — which is
why turning off the silent injection loses nothing.

Not done, and why: `--no-skills` alongside the explicit `--skill` would make the
global-skill collision impossible rather than alarmed, but whether pi 0.85.1 still
honours `--skill` under `--no-skills` needs a live smoke step to prove; the stub
cannot. The collision check stays as the defence until then.

## Queued for an idle pipeline

The judge setting its own `options.num_ctx` changes what `OLLAMA_CONTEXT_LENGTH` has to
do: it no longer has to express two roles, only the developer's. These wait for no run
in flight, and the first one restarts ollama:

- `zz-factory.conf`: add `OLLAMA_CONTEXT_LENGTH=32768` (or 49152, the co-residency
  probe's figure), `daemon-reload`, restart. Then `conditions.num_ctx` observed should
  equal declared for the developer too, and the 262144 default that made the spec step
  take eight minutes cannot recur.
- Smoke step with `--no-skills --skill "$FACTORY_SKILLS"`; if the skill loads, add
  `--no-skills` to `HARNESS_FLAGS` and demote the collision check to a regression test.
- Spike `pi --mode json` on a smoke step. If model, thinking level and tool calls arrive
  as events on stdout, `run-step.sh` reads them there and the session-directory search
  (`pi_sessions_dir()`, ~100 lines) goes; a pi update that changes the session format
  stops being a silent risk.
- `handle_audit_failure` hands the re-entered authoring step the whole verdict file,
  which after `audit-check.sh` names the judge's `model_digest`. The worker needs the
  findings, not the provenance block.
- One benchmark arm with `--append-system-prompt` for the developer — four lines: scope
  only what was asked; four tools exist and no others; the controller decides done, do
  not claim it; if blocked, write `QUESTIONS.md` and stop. `judge.sh` found the system
  message load-bearing for gpt-oss; whether it moves the 27B's containment-violation or
  `BLOCKED.md` rate is a measurement, not a prescription.

## What the first real runs taught

Four runs of bean-001 against the real models. Every one failed, each for a
different reason, and three of the four were **the line catching itself**:

1. The developer followed **another project's skill** — `~/.pi/agent/skills` has
   its own `pipeline-spec` and pi loads both. Fixed by prefixing every skill
   `factory-`, with a collision check that stops the run.
2. `.gitignore` was called a containment violation. The bean allows it; the
   matcher used `lstrip("./")`, which strips *characters*. Every dotfile was a
   false violation.
3. The judge wrote nothing usable — `factory-audit` was still the forked skill.
   That is what forced the judgement/verdict split.
4. `ac1` could never have passed: it imports a package the gate container never
   installs. **The developer model found this, refused to write a spec around it,
   and said so** — then `halt()` overwrote its report with a generic one. Fixed
   both: `sandbox_env`, and worker questions are now preserved.
5. The judge audited a document it never read — a fluent review of sections that
   do not exist in this format — and printed it instead of writing it. Forced the
   `quote` requirement: every criterion cites text the controller then looks for.

Six runs, six halts, nothing false let through. The halts are the product.

The conditions record has been the most useful single thing: on run one it
reported `num_ctx: 262144` observed against `32768` declared, which is true, was
invisible before, and explains the eight-minute spec step.

## Next action

Phase 1 — one bean, by hand, through all seven stages. Its entry needs three things; the
approval is done, and the other two are build work:

**How to run a bean** (from the target repo, with the factory's pipeline):

```
cd /home/gregg/workspace/seating-planner-py
PIPELINE_CONFIG=$PWD/factory/pipeline-config.json bash /home/gregg/workspace/Local_Dark_Factory/factory/pipeline/orchestrate.sh bean-001 --stop-after gate
```

Between runs the repo must be back on `main` with the bean branch deleted —
preflight refuses otherwise, correctly, and that is the most common way a re-run
stops in its first ten seconds.

1. ~~A throwaway GitHub repo~~ — `beekeeper-lab/seating-planner-py`, private, created
   2026-09-14. Cloned at `/home/gregg/workspace/seating-planner-py`.
2. ~~The `factory/` scaffold~~ — generated by `factory/scaffold.sh` and pushed. `repo.yaml`
   (`merge_mode: human_required`), `risk-policy.yaml`, `gates.lock.yaml` pinned to a real
   built image digest, both document templates, 20 approved beans with generated `bean.md`
   and `INDEX.md`. `preflight.sh bean-001` passes against it. Re-run `scaffold.sh` to update
   the control files; it never touches `factory/specs`, `factory/impl` or `factory/runs`.
3. ~~The task loop~~ — **built 2026-09-14.** `build-loop.sh` + `verify.sh` + `contain.py`
   + the `factory-build-task` skill, wired into `orchestrate.sh` as the `build` step
   (it replaces one-shot `implement` in both tiers). 71 test cases across
   `test-build-loop.sh` and `test-orchestrate-build.sh`, all against a stubbed worker.
   **What is left is the real thing:** the loop has never had the developer model on the
   other end of it. That is Phase 1's first real run, and the first place the feedback
   text — in the skill, and in the loop's rejection messages — gets judged by whether a
   27B can actually act on it.

**Independent invariants exist** (`factory/invariants/seating.yaml` + its pytest file),
authored before any code, by a different model family from the developer, at a path the line
cannot write. Six properties, each proven to catch its own violation. They are not
human-reviewed — if one ever fails and the argument becomes "the invariant is wrong", that
is yours to settle, not the line's.

One open owner decision rides along: `manifest.json` `conflicts_found` flags FR-048
(reproducibility) vs NFR-001 (15 s for 250 guests / 2000 rules) as `needs_owner_decision:
true`. bean-009 pins the solver configuration so the two can coexist; if real data says they
cannot, that is yours to settle, not the line's.

## What to re-run to confirm nothing drifted

There is no bare `python` on this box; the interpreter is the venv's. Run one per line:

```
./bench/phase0-audit.sh --with-models
./factory/pipeline/tests/test-role-routing.sh
.venv/bin/python bench/validate.py
.venv/bin/python bench/validate.py --corpus benchmark/seating-planner/bean-sets/v1
./bench/phase0.sh --provenance-only
```

Expected: audit `0 findings (green)`; role routing `29 passed`; `8 schemas, 0 invalid`;
`20 bean(s) ... 0 invalid`; GTT 96 GB. The audit's `--with-models` flag re-runs the
12-case Harmony suite (~2 min, loads the 120b) and writes
`bench/results/harmony-<stamp>.json`; without it that predicate reports as skipped.
Note that bare `validate.py` validates **no bean at all** — the `--corpus` line is the
one that checks the 20-bean set.

## Decisions recorded last session (don't re-litigate, do revisit on trigger)

**Regime = `serial`.** Not a capacity limit. The judge and the **Q4** developer *do*
co-reside at 79–81 GiB, both 100% GPU, developer to 49152 ctx. The Q8 developer + judge
needs ~88.4 GiB and ollama refuses above roughly 81.4–88.4 GiB — it withholds 8–15 GiB
beneath the 96 GiB ceiling, so raising the ceiling further would not buy the Q8 pair.
The real trade is developer quantisation vs. swap, and swap is cheap (8.0 s judge→dev,
13.2 s dev→judge) against per-stage runtimes in minutes.
**Revisit if `swap_overhead_pct` exceeds ~15%** — then the Q4 co-resident arm goes live.

**Speed inverts the size intuition.** `gpt-oss:120b` ≈ 861–1052 prompt tok/s, ~35 gen.
`qwen3.8:27b-mtp-q8_0` ≈ 325 prompt, ~20 gen. The 120B MoE judge is ~3× faster at prompt
processing than the 27B dense developer, so **the judge is not the expensive stage** —
don't design role-batching as if it were.

**Context barely affects throughput** across 16K–49K. The old 39-minute InvTrac spec step
was the 262144 default context, not model speed.

## Two live gotchas

1. **pi silently drops `--thinking` for models its catalog doesn't mark `reasoning: true`.**
   This had the judge running with reasoning *off* while `roles.json` said `"high"`, and
   `run-step.sh` would have stamped `conditions.thinking: high` into the run record anyway.
   Fixed in `~/.pi/agent/models.json` (backup: `models.json.bak-20260914-preharmony`) and
   `preflight.sh` now refuses a run that would repeat it. **If pi ever updates or rewrites
   its catalog, re-check this** — the backup and the preflight check are the two tripwires.

   The guard itself was wrong until the audit: it was wrapped in `[ -f "$PI_MODELS" ]`,
   so a pi upgrade that *moved* the catalog would have made the tripwire vanish silently
   while preflight still printed PASS. A missing catalog is now a `FAIL`; set
   `PI_MODELS_JSON` if pi relocates it.

2. **`roles.json` `num_ctx` is an intent, not a lever — pi has no flag for it.**
   `pi --help` lists no context option, so ollama serves whatever
   `OLLAMA_CONTEXT_LENGTH` (unset on the unit → 131072 default) or the last request
   set. The run record no longer pretends otherwise: `conditions.num_ctx` is read from
   `/api/ps` and the roles.json number is kept under `conditions.declared`. **The
   remaining work is control, not honesty** — to actually hold a role at 32768 the unit
   needs `OLLAMA_CONTEXT_LENGTH`, which is a single global value and cannot express a
   per-role context. Spec §09's healthcheck is where that belongs.

## Machine config as left (already applied, survives reboot)

- Kernel cmdline `ttm.pages_limit=25165824` → GTT **96 GiB** of 125 GiB RAM.
- `/etc/systemd/system/ollama.service.d/zz-factory.conf`: `MAX_LOADED_MODELS=1`, `NUM_PARALLEL=1`.
- `keepalive.conf`: `OLLAMA_KEEP_ALIVE=-1`. Temporary probe drop-in was removed.

## Evidence

`bench/results/` — `phase0-20260914T173319Z.json` (full sweep),
`coresidency-probe-20260914.json` (the seven co-residency trials),
`phase0-eviction-log-20260914.txt` (raw scheduler lines),
`provenance-post-reboot-*.json`.
