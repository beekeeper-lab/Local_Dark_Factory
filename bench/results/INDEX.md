# bench/results — what each figure measured, and whether it can be trusted

Every file here is a measurement someone made on this box. None is deleted when it
is superseded: a measurement is a record of what was true at a time, and removing
one because a later one disagrees is how a project stops being able to say how it
got where it is.

What a reader needs from this directory is not "which is newest" but two things:
**does this figure say where and on what it was measured**, and **does any claim
still rest on it**. So that is what this table says.

`bench/provenance.sh` landed on 2026-09-16 and every harness emits a block now
(`harnesses_emit_provenance` in the Phase-0 audit keeps the next one from
skipping it). Everything measured before that carries none, and writing one in
afterwards would be inventing it. `figures_have_provenance` reports those files
as a standing major finding, and it should: the finding is about the artifacts,
not about the code.

## Provenance

| file | provenance | still load-bearing? |
| --- | --- | --- |
| `phase0-20260914T173319Z.json` | yes | **yes** — the serial/co-resident regime decision |
| `provenance-post-reboot-20260914T173223Z.json` | yes | yes — the post-reboot machine state |
| `harmony-20260914T182045Z.json` | yes | yes — gpt-oss:120b holds a schema with thinking on |
| `coresidency-probe-20260914.json` | n/a (predates the schema) | superseded by `phase0-20260914T173319Z.json` |
| `controller-fitness-20260915T124030Z.json` | no | superseded ×2 |
| `controller-fitness-20260915T124147Z.json` | no | superseded ×2 |
| `controller-fitness-20260915T124249Z.json` | no | superseded ×2 |
| `controller-fitness-20260916T003558Z.json` | yes | superseded by 142616Z |
| `controller-fitness-20260916T142616Z.json` | yes | **yes** — 1 of 5 seeded defects named by a check, 4 not decidable, 0 false alarms |
| `format-support-20260915T024138Z.json` | no | superseded — a 200-byte question, which cleared two models that then failed on real artifacts |
| `format-support-real-payload-20260915T025711Z.json` | no | superseded by 111754Z |
| `format-support-20260916T111754Z.json` | yes | **yes** — gpt-oss:120b holds the schema on an 18KB payload only at `low` |
| `judge-fitness-20260915T012448Z.json` | no | no — one pass, four cases, before the fixtures were right |
| `judge-fitness-msgsep-20260915T023844Z.json` | no | no — one message per artifact vs one blob; single runs, and the judge is not reproducible |
| `judge-fitness-gemma4-20260915T025711Z.json` | no | **partly** — gemma4:26b was rejected as a judge on this. Single run, so the comparison is weak; `format-support-20260916T111754Z.json` rejects it again on a different axis, which is why the decision stands |
| `judge-fitness-fixedfixtures-20260915T131308Z.json` | no | no — superseded by the three-pass runs |
| `judge-fitness-20260916T001225Z.json` | yes | superseded — 12000 cap, `thinking: medium` |
| `judge-fitness-20260916T130042Z.json` | yes | **yes** — the 16000 half of the token-cap decision (0 of 18 cut off) |
| `judge-variance-20260915T134814Z.json` | no | **the finding it carries has been partly overtaken** — two verdicts from five identical runs at temperature 0, which is where "the judge is not reproducible" came from. See 142555Z, which asked the same case again after the cap and prompt changed and got one verdict five times. Kept as the before half, and still the reason the older figure's missing provenance mattered |
| `judge-variance-20260916T142555Z.json` | yes | **yes** — same case, 16000 cap, `met` defined per target, thinking low: **1 distinct verdict across 5 identical runs**, where the 2026-09-15 run gave 2. Not enough to reopen advisory audits: one case, three variables changed at once, and the content still swings (findings 4/0/4/3/1, confidence 0.5–0.99, the seeded defect named in none of the five) |
| `size-sweep-20260915T134814Z.json` | no | superseded by 100658Z |
| `size-sweep-20260916T100658Z.json` | yes | **yes** — three passes at four sizes, and the finding that it cannot answer the byte-budget question |

## reaudit

`factory reaudit` answers the question the seeded-defect harnesses cannot: when
something about the judge changes, does it change anything on a **real** run? Its
artifacts name the configuration they were taken at, because that is the only
thing that makes two of them comparable.

| file | provenance | still load-bearing? |
| --- | --- | --- |
| `reaudit-20260916T163000Z.json` | yes (names run, bean, passes, thinking) | **yes** — the current configuration, measured: 12 audits, 8 judgements, 0 stamped, every answer carrying exactly four criteria. The baseline the next grammar change has to beat |

The baselines it has to be read against are terminal logs rather than JSON,
because `factory reaudit` did not exist when they were taken:
`evidence/reaudit-bean-001-20260916.log` (one pass, zero stamped),
`evidence/reaudit-bean-001-3pass-20260916.log` (twelve attempts, zero stamped),
`evidence/reaudit-bean-001-idenum-20260916.log` (twelve more, zero stamped, but
criterion compliance went from roughly none to complete).

## What is missing, and why it is not being back-filled

Eleven files carry no provenance. One of them still carries a claim on its own:
`judge-fitness-gemma4`, the gemma4 rejection — and that has a second, independent
measurement behind it (`format-support-20260916T111754Z`, which rejects the same
model on a different axis), so the decision stands on something that says where it
was measured.

`judge-variance-20260915T134814Z` was the other, and it was re-measured on
2026-09-16 (`142555Z`, with provenance) because the conclusion drawn from it —
advisory audits, `merge_mode: human_required` — is load-bearing for the whole
line. The re-measurement changed the answer on that case: one verdict five times
where there had been two. It did **not** change the decision, and the reasons are
on the row.

The rest are experiments whose conclusions were superseded by later work. They are
kept because the later work is only legible next to them.
