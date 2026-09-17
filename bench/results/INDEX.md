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

## A `.RETRACTED` note sits beside each superseded sweep

Six artifacts here carry a sibling `<name>.json.RETRACTED` saying what is wrong
with them and pointing at the clean run. **The JSON itself is unedited.** A
measurement records what was believed and when, and editing one so it agrees with
a later one is how a project loses the ability to say how it got where it is —
so the correction sits beside the record rather than inside it.

## The size effect was retracted in full on 2026-09-17

A clean re-run with the harness fixed — `size-sweep-clean-20260917T135317Z.json`,
five passes, neutral padding, judgements kept and checked one by one against the
table — gives **1 accept in 5 at 20,422 bytes and 1 accept in 5 at 40,422**. The
same rate. **There is no size effect**, and every earlier figure claiming one came
from the bug described below.

Read every `size-sweep-*.json` dated 2026-09-17 *except* the clean one as a
retracted measurement. They are kept because a measurement is a record of what
was believed and when, and deleting them would hide the best-documented mistake
in this repository.

## Every multi-pass `size-sweep-*.json` here is the first pass, repeated

Found 2026-09-17. The sweep shared one run directory across passes, `judge.sh`
numbers its output `attempt-N`, and the reader was pinned to `attempt-1` — so
passes 2..N re-read pass 1, and a pass that produced nothing was reported with
the earlier pass's verdict. **Treat the `points` array of every size-sweep
artifact dated 2026-09-17 as one measurement per size, not N.**

`size-sweep-padbean-*`, `size-sweep-kept-*` and `size-sweep-critcase-*` were run
with `--keep`, so their real judgements exist outside the artifact and are quoted
in RESUME. The others deleted their run directories and cannot be recovered.

Fixed by giving each pass its own run directory. Artifacts written after that
carry `schema: size-sweep/…` with the same shape and are not affected; there is
no marker inside the files themselves, which is the honest limitation of finding
this after the fact.

## Provenance

**Standing finding, and what is actually left of it.** `figures_have_provenance`
in the Phase-0 audit reports 14 files without a provenance block and should keep
reporting them: they were measured before `bench/provenance.sh` existed, and
writing a block into them afterwards would be inventing it. But "14 figures
without provenance" is not the same as "14 claims resting on nothing", and the
second is what would matter. Checked file by file on 2026-09-17: **thirteen are
superseded by a later figure that does carry a block, and the fourteenth
(`judge-variance-20260915T134814Z.json`) carries a finding partly overtaken by a
figure that does.** So no live decision in this repository rests on an
unprovenanced number.

That is why "re-measure the 14" is not on the list of things to do. Re-measuring
a superseded figure produces a second superseded figure with a nicer header.


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
| `controller-fitness-20260916T142616Z.json` | yes | **wrong, and kept because it is** — 1 of 5 named, 4 "not decidable". The `tautological-verify` fixture was not seeding the defect it claimed, so the controller was scored as missing something it catches |
| `controller-fitness-prose-20260917T003651Z.json` | yes | **yes** — the prose side of the annotation A/B, 2 of 5 named. Reproducible: it reads `bench/fixtures/bean-001-prose.yaml`, not a live bean |
| `reaudit-20260917T011437Z.json` | yes | **yes** — 0 of 12 stamped, the first reaudit after the per-criterion quote rule, and the test of a prediction written down before it ran. 5 of 12 refusals are fabricated quotes; 4 are the new rule; across the 44 criteria in its 11 judgements, 31% carry no quote at all |
| `reaudit-briefs-20260917T031738Z.json` | yes | **yes** — the same twelve audits with the prompt 4,085 bytes smaller on spec and 6,751 on impl. 0 of 12 stamped again, and **"quoted text that is on disk nowhere" is 5 of 12 in both runs**. Prompt size is not what makes this judge fabricate; the pair is the evidence |
| `controller-fitness-pob-20260917T011721Z.json` | yes | no — the first of three runs wiring `plans-other-beans` in, and it is the one where the check did not fire at all: it was handed a bean from `bench/fixtures`, inferred the bean set from that directory, found one bean, skipped it as itself and reported nothing to compare against. 3 of 5 |
| `controller-fitness-pob-20260917T011815Z.json` | yes | no — the second: the check fired and `unfinishable-task` reads "rejected, but not for the seeded defect", because the harness matches a catchphrase per case and this case had none. 3 of 5, and the 4th was sitting in the output unclaimed |
| `controller-fitness-pob-20260917T011917Z.json` | yes | **yes** — 4 of 5 seeded defects named by a check, 0 false alarms, after `plans-other-beans.sh` took `unfinishable-task`. The highest this figure has ever been; the two earlier runs the same evening (2 and 3 of 5) are the A/B either side of it |
| `size-sweep-clean-20260917T135317Z.json` | yes | **yes — it is the one that stands, and it retracts the rest.** Five passes with a fresh run directory per pass, neutral padding, judgements kept and verified row by row: **1 accept of 5 at 20,422 bytes, 1 of 5 at 40,422.** The same rate at both sizes. The verdict column varies again — revise, abstain, revise, revise, accept — which is what this judge looks like and what the bug was suppressing |
| `size-sweep-critcase-20260917T132231Z.json` | yes | **retracted** — the sweep on `criterion-not-really-met`, the one defect the controller cannot take. Its table read `revise` ten times; the kept judgements say `revise, revise, revise, accept` at the large size. Superseded with the rest of the size thread |
| `size-sweep-padbean-20260917T123004Z.json` | yes | **yes — the arm that settles whether the finding applies to a real audit.** Identical padding appended to a copy of the BEAN, so it arrives as a separate labelled artifact while the document under audit stays untouched: **4 false accepts of 5 at 41,286 bytes, 0 of 5 at 20,422.** Same as padding inside the document, so an artifact header is not a boundary for this model — and the doc audit, 36,731 bytes across three artifacts, is in the band |
| `size-sweep-kept-20260917T115236Z.json` | yes | supporting — two kept passes at 40,422 whose judgements are the evidence in `evidence/judge-answered-about-the-padding-20260917.md`. Also the run that showed `NAMED` flapping on identical input |
| `size-sweep-neutralpad-20260917T110731Z.json` | yes | **yes — it is the control that rules the confound out.** Same sizes, padded from `bench/fixtures/pad-neutral`: the corpus with every mention of the solver removed, so the padding can no longer legitimise the seeded defect. **5 accepts of 5 at 40,422 and 0 of 5 at 20,422** — sharper than with the real corpus, so the effect is size and not content. Read it beside the two sweeps below, never alone |
| `size-sweep-confirm-20260917T034250Z.json` | yes | **yes, and it is the strongest measurement in this directory** — five passes at each of two sizes, confirming the three-pass run above. With it: **8 of 8 rejections at 20,422 bytes and 0 of 8 at 40,422** (six accepts, two non-answers). The only lever measured this week that moved the false-accept rate |
| `size-sweep-tools-20260917T022025Z.json` | yes | **yes** — the only measurement this week that moved the false-accept rate: 0 of 3 at 20,422 and 30,422 bytes, **2 of 3 at 40,422**. Also retires the standing 10,000-byte finding, which does not reproduce now that `tools: []` is declared. Three passes, one seeded defect, and it never named the defect at any size |
| `judge-fitness-percrit-20260916T232926Z.json` | yes | **yes** — the measurement that killed the per-criterion lever: 6 cases, 6 `revise`, 0 defects named, control rejected, 6,209s. One pass, and cases 2 and 3 had their bean edited mid-run (the reason `freeze_inputs` exists); neither caveat touches "six of six said revise" |
| `controller-fitness-annotated-20260917T003726Z.json` | yes | **yes** — the annotated side, 3 of 5. The pair is the whole evidence that annotating a bean is worth anything, and the one case that moves is `contradicts-non-goal` |
| `controller-fitness-20260916T171150Z.json` | yes | no — one case, the broken `tautological-verify` fixture, kept as the before half of finding it |
| `controller-fitness-20260916T171317Z.json` | yes | no — the same case with the fixture fixed, 1 of 1 caught. The pair is the whole diagnosis |
| `controller-fitness-20260916T171328Z.json` | yes | no — superseded within the hour by 171837Z, after the same audit of every OTHER mutation found `contradicts-non-goal` spliced too |
| `controller-fitness-20260916T194257Z.json` | yes | no — the same 2 of 5, taken while wiring the non-goal check in; kept because it is the before half of the row below |
| `controller-fitness-20260916T194839Z.json` | yes | no — still 2 of 5, and the first to say *why* `contradicts-non-goal` is not decidable: bean-001's non-goals are prose |
| `controller-fitness-20260916T194913Z.json` | yes | **yes, and it is the argument for annotating the bean set** — one case, against a bean whose "no solver code" carries `forbidden_paths`: `contradicts-non-goal` goes from "not decidable, needs a judge" to **named by a check**. Three of five decidable for an annotated bean |
| `controller-fitness-20260916T171837Z.json` | yes | **yes** — every mutation fixed and asserting its own post-condition: **2 of 5 named by a check**, 3 not decidable, 0 false alarms. `tautological-verify` is decided by spec-check's verify precheck and always was |
| `format-support-20260915T024138Z.json` | no | superseded — a 200-byte question, which cleared two models that then failed on real artifacts |
| `format-support-real-payload-20260915T025711Z.json` | no | superseded by 111754Z |
| `format-support-20260916T111754Z.json` | yes | **yes** — gpt-oss:120b holds the schema on an 18KB payload only at `low` |
| `format-support-20260916T201730Z.json` | yes | **yes** — the other candidates on this box, with the real artifacts: `qwen3-coder-next` and `gemma4:26b` hold it with thinking off, `devstral:24b` is cut off mid-answer at 313s. The prerequisite for measuring any of them on the number that matters |
| `judge-fitness-20260915T012448Z.json` | no | no — one pass, four cases, before the fixtures were right |
| `judge-fitness-msgsep-20260915T023844Z.json` | no | no — one message per artifact vs one blob; single runs, and the judge is not reproducible |
| `judge-fitness-gemma4-20260915T025711Z.json` | no | **no longer** — gemma4:26b was rejected as a judge on this, and re-run on 2026-09-16 (`evidence/judge-fitness-gemma4-20260916.log`, three passes, with provenance) it rejected the clean control and then returned nothing at all on four cases in a row. The decision rests on that and on `format-support-20260916T111754Z.json`, both of which carry a provenance block |
| `judge-fitness-fixedfixtures-20260915T131308Z.json` | no | no — superseded by the three-pass runs |
| `judge-fitness-20260916T001225Z.json` | yes | superseded — 12000 cap, `thinking: medium` |
| `judge-fitness-20260916T130042Z.json` | yes | the 16000 half of the token-cap decision (0 of 18 cut off). Its catch-rate columns are **not** usable: two of the six fixtures were not seeding their defects |
| `judge-fitness-20260916T172619Z.json` | yes | **yes** — the first run on fixtures that seed what they claim, at the current grammar and `field_maxlen: 600`. 9 false accepts in 15, control rejected 3 of 3, 2 named |
| `judge-fitness-gemma4-20260916T202835Z.json` | yes | no — gemma4's first attempt, kept as the bug report it turned out to be: 14 of 18 "never ran", miscounted at the time as token cut-offs |
| `judge-fitness-gemma4-20260916T203559Z.json` | yes | **yes, as a disqualification** — the retry with the GPU idle and every other model stopped. 16 of 18 never ran. `journalctl -u ollama`: the model emits `<unused49>`, the grammar stack empties, llama.cpp throws, ollama answers 200. gemma4 cannot be driven under constrained decoding here |
| `judge-fitness-qwen-coder-20260916T201937Z.json` | yes | **yes** — `qwen3-coder-next:latest` as the judge on the same corpus: **15 false accepts in 15**, perfectly reproducible. The first measurement of any judge other than gpt-oss on the number that matters |
| `judge-fitness-rubricfix-20260916T211029Z.json` | yes | **yes — the best figure this judge has produced.** The rubric no longer tells it to open files it cannot open: 4 false accepts in 15 against 9, rejected 11 against 5, named 4 against 2. Same model, grammar, cap and fixtures. The control is still rejected 3 of 3 |
| `judge-fitness-20260916T174914Z.json` | yes | **yes** — the same with `field_maxlen: 0`. 7 false accepts, 3 named, 8 rejected. Better on every axis and inside the spread, so the caps are **not** the cause of the false-accept rate. The pair is the finding, not either number |
| `judge-variance-20260915T134814Z.json` | no | **the finding it carries has been partly overtaken** — two verdicts from five identical runs at temperature 0, which is where "the judge is not reproducible" came from. See 142555Z, which asked the same case again after the cap and prompt changed and got one verdict five times. Kept as the before half, and still the reason the older figure's missing provenance mattered |
| `judge-variance-20260916T142555Z.json` | yes | **yes** — same case, 16000 cap, `met` defined per target, thinking low: **1 distinct verdict across 5 identical runs**, where the 2026-09-15 run gave 2. Not enough to reopen advisory audits: one case, three variables changed at once, and the content still swings (findings 4/0/4/3/1, confidence 0.5–0.99, the seeded defect named in none of the five) |
| `size-sweep-20260915T134814Z.json` | no | superseded by 100658Z |
| `size-sweep-20260916T100658Z.json` | yes | **yes** — three passes at four sizes, and the finding that it cannot answer the byte-budget question |

## reaudit

The first three of these carry no provenance block: `reaudit.sh` did not emit one
until 2026-09-16 evening, and writing one in afterwards would be inventing it —
the same rule as everything else in this directory.

`factory reaudit` answers the question the seeded-defect harnesses cannot: when
something about the judge changes, does it change anything on a **real** run? Its
artifacts name the configuration they were taken at, because that is the only
thing that makes two of them comparable.

| file | provenance | still load-bearing? |
| --- | --- | --- |
| `reaudit-20260916T163000Z.json` | no (predates the block) | superseded by 173000Z — 12 audits, 8 judgements, 0 stamped, 2 of 8 answers with duplicate criterion ids |
| `reaudit-20260916T173000Z.json` | no (predates the block) | superseded — `criteria` keyed by id: 12 audits, 7 judgements, 0 stamped, 0 duplicates. The run that identified the quote as the remaining blocker |
| `reaudit-20260916T180000Z.json` | no (predates the block) | superseded — `confidence` as an enum: 12 audits, 8 judgements, 1 stamped |
| `reaudit-20260916T213000Z.json` | yes | **yes** — the same twelve after the prompt stopped contradicting itself: 6 judgements, **0 stamped**, every one refused on an invented quote. The fitness improvement did not transfer, and this is the figure that says so |

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
