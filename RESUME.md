# Resume here — Phase 0

Last session ended 2026-09-14. Branch `factory/phase0-prep-and-bean-set-v1`, pushed, tree clean.

## State: Phase 0 is measured and green; only the audit remains

All six `phase_0_exit` predicates hold:

```yaml
residency_recorded: true      swap_time_measured: true     harmony_conformance: pass
pi_drives_both_models: pass   regime_decision: "serial"    figures_have_provenance: true
```

## Next action

**Run the Phase-0 audit** — the last three checklist boxes in
`DARK_FACTORY_IMPLEMENTATION_PLAN.md` (§ Phase 0, bottom):

- [ ] Audit generated
- [ ] Findings corrected
- [ ] Audit re-run green
- [ ] `PHASE-0-COMPLETE` committed

Then Phase 1 (one bean, by hand, through all seven stages). Phase-1 entry needs a
throwaway GitHub repo with the `factory/` scaffold and one **approved** bean — all 20 beans
are still `status: draft`, and §04 requires a human to approve before anything queues.
That approval is yours to give and is the actual gate on starting Phase 1.

## What to re-run to confirm nothing drifted

```
./factory/pipeline/tests/test-role-routing.sh     # expect 15 passed
python bench/validate.py                           # expect 8 schemas, 0 invalid
./bench/harmony-conformance.sh                     # expect 12 passed (~2 min, loads the 120b)
./bench/phase0.sh --provenance-only                # expect GTT 96 GB
```

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

2. **`roles.json` `num_ctx` is still declared-not-asserted.** Ollama serves what the unit
   says; nothing yet checks they agree. Same class as the thinking bug above, still open —
   `roles.json` `_known_gaps` flags it, and spec §09 healthcheck is where it belongs.

## Machine config as left (already applied, survives reboot)

- Kernel cmdline `ttm.pages_limit=25165824` → GTT **96 GiB** of 125 GiB RAM.
- `/etc/systemd/system/ollama.service.d/zz-factory.conf`: `MAX_LOADED_MODELS=1`, `NUM_PARALLEL=1`.
- `keepalive.conf`: `OLLAMA_KEEP_ALIVE=-1`. Temporary probe drop-in was removed.

## Evidence

`bench/results/` — `phase0-20260914T173319Z.json` (full sweep),
`coresidency-probe-20260914.json` (the seven co-residency trials),
`phase0-eviction-log-20260914.txt` (raw scheduler lines),
`provenance-post-reboot-*.json`.
