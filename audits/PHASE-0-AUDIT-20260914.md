# Phase-0 audit — 2026-09-14

**Audited commit:** `5c1ec93` (branch `factory/phase0-prep-and-bean-set-v1`, tree clean)
**Harness:** `bench/phase0-audit.sh` (new, re-runnable; `--with-models` adds the Harmony suite)
**First run:** **not green** — 17 checks pass, **10 findings: 2 blocker, 5 major, 3 minor**
**After corrections:** **green** — `./bench/phase0-audit.sh --with-models` → 29 checks, 0 findings
(`audits/phase0-audit-20260914T182533Z.json`)

Phase 0's closing ritual is *exit criteria machine-verified → audit generated → findings
corrected → audit re-run → marker committed*. The first clause was the audit's first
finding in its own right: the six `phase_0_exit` predicates existed only as prose in the
ledger — `grep -rn phase_0_exit` matched `RESUME.md` and the plan, and nothing else.
Nothing computed them. So the audit begins by making them computable, then judges them.

---

## What verified

All six exit predicates hold when actually evaluated against the artifacts, and the
machine still is what the ledger says it is:

| | evidence |
|---|---|
| `residency_recorded` | 6 alone-rows across contexts {16384, 32768, 49152}; 9 rows carry a GPU/CPU split |
| `swap_time_measured` | judge→dev 8.0 s, dev→judge 13.2 s, both non-zero |
| `harmony_conformance` | re-run today: **12 passed, 0 failed** |
| `pi_drives_both_models` | every role declaring a thinking level maps to `reasoning: true` in pi's catalog |
| `regime_decision` | `serial`, recorded — but see finding 4 on what that field actually means |
| `figures_have_provenance` | every results JSON carries kernel + ollama version + GTT |
| machine | `ttm.pages_limit=25165824` (96 GiB) on the kernel cmdline; unit env `KEEP_ALIVE=-1`, `MAX_LOADED_MODELS=1`, `NUM_PARALLEL=1`; probe drop-in gone |
| digests | developer `8a1582877303`, judge `a951a23b46a1`, ollama `0.32.13` — all match the figures they were measured with |
| re-runs | role-routing **15/15**, schemas **8/8 valid**, bean set **20/20 valid**, GTT 96 GB |

The two things most likely to have rotted since last session — the pi catalog fix and the
removal of the temporary `MAX_LOADED_MODELS=2` drop-in — are both still in place.

---

## Findings

### 1. `evidence.tracked` — **blocker**

`bench/results/` is in `.gitignore`. **0 of 4** evidence files are tracked:
`phase0-20260914T173319Z.json`, `coresidency-probe-20260914.json`,
`phase0-eviction-log-20260914.txt`, `provenance-post-reboot-20260914T173223Z.json`.

Every Phase-0 figure the plan cites lives only on Forge's local disk, one `rm` or one
reinstall from gone, and invisible to anyone reading the repo. A phase whose exit
predicate is `figures_have_provenance: true` keeps its provenance where git is told not
to look. The ignore rule is right for *future* sweep output; it is wrong for the handful
of artifacts the ledger cites as the basis of a decision.

**Correction:** narrow the ignore rule and commit the four cited artifacts (≈15 KB).

### 2. `conditions.num_ctx_asserted` — **blocker**

`run-step.sh` reads `roles.json` `num_ctx` into `ROLE_CTX` at line 112, prints it at line
135, and stamps it into `conditions.num_ctx` at line 242 — and never passes it to pi or
ollama. `grep ROLE_CTX run-step.sh` returns those three lines and nothing else. The
context actually served is whatever last loaded the model (observed at session start:
`ollama ps` → **131072**, against `roles.json`'s declared 32768).

This is the *same defect the phase just closed for `thinking`*, still live for `num_ctx`,
and with no preflight guard behind it — only a note in `roles.json._known_gaps`. The
phase's own words: a false provenance figure is worse than a missing one, because it
survives into the telemetry later decisions are made from. It also costs real time — the
39-minute InvTrac spec step was exactly this, a default context nobody asked for.

The mechanism to fix it is already proven in this repo: `harmony-conformance.sh` sets
`options:{num_ctx}` per request, and `ollama ps` reflected the change.

**Correction:** either apply `num_ctx` on the request path, or stamp `conditions.num_ctx`
from what the server reports. Do not record the declared value.

### 3. `preflight.thinking_guard` — major

The role-thinking tripwire in `preflight.sh` is wrapped in
`if [ -f "$ROLES_JSON" ] && [ -f "$PI_MODELS" ]`. If pi's catalog moves or is rewritten
to a new path, the check does not fail — it silently does not run, and `preflight` prints
its overall PASS. That is precisely the scenario RESUME.md names as the thing to watch
("if pi ever updates or rewrites its catalog, re-check this").

Verified: the check's logic is correct — against a catalog doctored to
`reasoning: false` for `gpt-oss:120b` it reads `role=judge model=gpt-oss:120b
reasoning=false` and would fail. It is only the guard that is wrong.

**Correction:** a missing catalog is a `fail`, not a skip.

### 4. `regime_decision.falsifiable` — major

`phase0.sh` derives `regime_decision` mechanically from whether two models were ever
observed loaded together (lines 227–230). Under the final unit config
(`MAX_LOADED_MODELS=1`) ollama will never load two, so **a re-run emits `serial`
regardless of the truth**. The field now records a unit setting, not a memory fact.

The real finding — the effective co-residency budget of 81.4–88.4 GiB, and that the **Q4**
pair *does* co-reside — came from the hand-written probe, under a `MAX_LOADED_MODELS=2`
drop-in that has since been removed. Anyone later reading `regime_decision: serial` as a
measurement will be reading a tautology.

**Correction:** have `phase0.sh` record the co-residency *precondition* alongside the
verdict (`max_loaded_models`, and `unknown` rather than `serial` when it is 1).

### 5. `evidence.probe_reproducible` — major

`coresidency-probe-20260914.json` is hand-transcribed: no script emits its schema string
`phase0-coresidency-probe/1.0.0` (`grep -rn` across `bench/*.sh` and
`factory/pipeline/*.sh` → no match). Its own `conditions` block is honest about needing a
drop-in that no longer exists.

So the single most consequential Phase-0 conclusion — the one that overturned the earlier
reasoning twice — rests on an artifact that cannot be regenerated and is not committed
(finding 1). Its content is well-sourced and its notes are careful; that is not the issue.
The issue is that the next person to ask "is that still true after an ollama upgrade?" has
no way to ask it except by hand, from the prose.

**Correction:** a `--coresidency-probe` mode in `phase0.sh` that sets up, measures and
tears down, or an explicit note in the ledger that this figure is a one-shot manual
measurement with a named re-measurement procedure.

### 6. `harness.provenance_only_writes` — major

`phase0.sh --provenance-only` logs `writing results to <path>`, then prints JSON to
stdout and exits without writing that file. Observed: the run announced
`bench/results/phase0-20260914T180851Z.json`; `ls` shows it was never created.

The command RESUME.md hands the next session as the safe provenance check therefore
leaves no artifact, while telling the operator it just wrote one.

**Correction:** write the file, or do not claim to.

### 7. `harness.harmony_artifact` — major

`harmony-conformance.sh` prints `12 passed, 0 failed` and saves nothing. There is no
Harmony result in `bench/results/`. The phase's only record of the `harmony_conformance:
pass` predicate is the ledger prose asserting it — for the one predicate that is a
property of a *model version*, so it needs a digest and a timestamp beside it more than
most.

**Correction:** emit `bench/results/harmony-<ts>.json` with the provenance block and the
12 case results.

### 8. `repro.documented_commands` — minor

RESUME.md's re-run list says `python bench/validate.py`. There is no `python` on this
box's PATH (`/bin/bash: line 1: python: command not found`); the interpreter is
`.venv/bin/python`.

### 9. `repro.beanset_checked` — minor

That same line expects "8 schemas, 0 invalid" — which is `validate.py` run bare, and
validates **no bean at all**. The 20-bean set needs
`validate.py --corpus benchmark/seating-planner/bean-sets/v1` (run separately here:
20 beans, 0 invalid). As written, the confirmation reads as if it covered the bean set.

### 10. `ledger.stale_checkbox` — minor

The plan leaves *"Set the final ollama unit config"* unchecked (line 123), but the unit
already carries `MAX_LOADED_MODELS=1` / `NUM_PARALLEL=1` / `KEEP_ALIVE=-1` and the probe
drop-in is removed. The work is done; the ledger does not say so.

---

## What this audit does not claim

- It does not re-measure throughput or swap times. It checks that the recorded figures
  carry provenance, and that the digests, ollama version and GTT ceiling they were taken
  under still match the machine — so the figures remain attributable, not that they would
  reproduce to the same numbers today.
- It does not verify that pi *observably* ran the judge at `thinking: high` on a live
  step. It verifies the catalog state and the preflight guard, which is where the
  regression would reappear. Asserting the observed level belongs with finding 2.
- `harmony_conformance` is only actually re-run with `--with-models`; the default run
  reports it as skipped rather than passed.

## Re-running

```
./bench/phase0-audit.sh                          # read-only, no model loaded
./bench/phase0-audit.sh --with-models            # + the 12-case Harmony suite (~2 min)
./bench/phase0-audit.sh --json audits/phase0-audit-<ts>.json
```

Exit 0 means green: no blocker, no major. Minors are reported and do not fail the audit.

---

## Corrections (applied 2026-09-14, same session)

All ten were fixed. What changed, and how the audit now proves it rather than asserting it:

| # | finding | correction | check that would catch a regression |
|---|---|---|---|
| 1 | evidence gitignored | `.gitignore` ignores sweep output but admits cited artifacts by name; five committed | `evidence.tracked` |
| 2 | `num_ctx` declared, never applied | `conditions.num_ctx` read from ollama `/api/ps`, `thinking` from pi's session, declared values kept under `conditions.declared`, `declared_matches_observed` + a `WARN` on drift | `conditions.num_ctx_asserted`, `conditions.thinking_observed`, `conditions.drift_flagged` |
| 3 | preflight tripwire could skip itself | a missing pi catalog is now a `FAIL`, with `PI_MODELS_JSON` named in the message | `preflight.thinking_guard` |
| 4 | `regime_decision` unfalsifiable | provenance carries the scheduler settings; the verdict is `unknown` + a `regime_evidence` block when co-residency was not attemptable | `regime_decision.falsifiable` |
| 5 | probe not reproducible | `phase0.sh --coresidency-probe` regenerates the artifact under the same schema; refuses (exit 3) below `MAX_LOADED_MODELS=2` and prints the drop-in commands instead of editing the unit | `evidence.probe_reproducible` |
| 6 | `--provenance-only` wrote nothing | it writes the file it announces, under its own `phase0-provenance-<stamp>` name so it cannot shadow a sweep | `harness.provenance_only_writes` |
| 7 | Harmony result unrecorded | writes `bench/results/harmony-<stamp>.json` — judge digest, quant, context, and all 12 cases | `harness.harmony_artifact` |
| 8, 9 | broken re-run instructions | `.venv/bin/python`, plus the `--corpus` line that actually validates the 20 beans | `repro.documented_commands`, `repro.beanset_checked` |
| 10 | stale checkbox | checked, with the drop-in path recorded | `ledger.stale_checkbox` |

### Fallout worth knowing about

- **The role-routing suite grew from 15 to 19 cases.** Fix 2 broke
  `conditions.thinking stamped` — correctly: the stub `pi` echoed its arguments and wrote no
  session, so there was nothing to observe. The stub now writes a session file in pi's shape,
  and `STUB_PI_THINKING_OVERRIDE` reproduces the original bug verbatim (roles.json asks for
  `high`, the model runs with thinking `off`). The run record must say `off`. Verified the test
  can fail: against a copy of `run-step.sh` with the observation reverted to the declared value,
  it does.
- **Two of the audit's own checks were wrong on the first run and were tightened before any
  correction was made:** `evidence.probe_reproducible` passed on a grep that matched the phrase
  "Co-residency probe" in an unrelated block (it now matches the artifact's schema string), and
  `conditions.num_ctx_asserted` cited a served context that happened to equal the declared one
  because the Harmony suite had just set it. Three more (`figures_have_provenance`,
  `evidence.cited_exists`, `repro.documented_commands`) mis-fired after the corrections — a
  Harmony artifact has no GTT figure, `harmony-<stamp>.json` in prose is not a citation, and the
  word "Note" is not an interpreter. Fixed in the harness, not worked around in the repo.
- **`--with-models` writes its Harmony artifact to a temp file.** An audit that left an
  uncommitted artifact in `bench/results/` would fail its own `evidence.tracked` check on the
  next run. Run the suite directly when you want the artifact kept.

### Still open, deliberately

- `roles.json` `num_ctx` is now recorded honestly but still cannot be *controlled*: pi exposes no
  context flag, and `OLLAMA_CONTEXT_LENGTH` is a single global value that cannot express a
  per-role context. Spec §09's healthcheck is where that belongs.
- The co-residency bracket has a harness now, but re-measuring it still needs a deliberate
  `MAX_LOADED_MODELS=2` drop-in and a service restart. That is a property of the measurement,
  not a gap in the record.
- `PHASE-0-COMPLETE` is not committed: the marker convention (tag, file, or commit subject) has
  no precedent in this repo and is the owner's to set.
