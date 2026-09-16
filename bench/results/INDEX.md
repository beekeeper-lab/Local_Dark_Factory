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
| `judge-variance-20260915T134814Z.json` | no | **yes, and this is the uncomfortable one** — the whole "the judge is not reproducible" finding rests on it. Two verdicts from five identical runs at temperature 0. It has no provenance block and it is the single most consequential figure in the directory |
| `size-sweep-20260915T134814Z.json` | no | superseded by 100658Z |
| `size-sweep-20260916T100658Z.json` | yes | **yes** — three passes at four sizes, and the finding that it cannot answer the byte-budget question |

## What is missing, and why it is not being back-filled

Eleven files carry no provenance. Only two of them still carry a claim:
`judge-fitness-gemma4` and `judge-variance-20260915T134814Z`. The gemma4 rejection
has a second, independent measurement behind it. The variance finding does not.

Re-measuring variance is ~25 minutes of GPU and is worth doing; the reason it has
not simply been re-run and the old file forgotten is that the conclusion drawn
from it — advisory audits, `merge_mode: human_required` — is load-bearing for the
whole line, and a finding that important should rest on a figure that says which
machine and which ollama produced it.

The rest are experiments whose conclusions were superseded by later work. They are
kept because the later work is only legible next to them.
