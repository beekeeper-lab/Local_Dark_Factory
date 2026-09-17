# bench/fixtures

Inputs a measurement is allowed to depend on.

Everything else a bench harness reads — the spec and task list under
`evidence/`, a bean in `seating-planner-py` — lives somewhere that changes for
reasons that have nothing to do with the measurement. On 2026-09-16 that stopped
being theoretical twice in one evening:

- a six-case `judge-fitness` run re-read its bean at the start of every case, and
  the bean was annotated at 19:55 and reverted at 20:12 while the run was on its
  third case. Two cases measured a different bean from the other four. The
  harnesses freeze their inputs now (`freeze_inputs` in `bench/provenance.sh`)
  and record the three hashes, so this is visible rather than invisible.
- the figure *"3 of 5 seeded defects decided by the controller for an annotated
  bean"* was measured against bean-001 while it carried `forbidden_paths`.
  bean-001 went back to prose an hour later — correctly, its pull request is open
  — and the figure became unreproducible. Not wrong; unreproducible, which for a
  number is nearly as bad.

## bean-001-prose.yaml, bean-001-annotated.yaml

The same bean, differing **only** in whether its non-goals and constraints carry
`forbidden_paths` and `forbidden_imports`. Every sentence of prose is
byte-identical; the annotated copy adds `text:` and the lists and nothing else.
`bench/tests/test-corpus-forbids.sh` asserts that, so the pair cannot quietly
drift into measuring two things.

They exist to answer one question — *what does annotating a bean buy?* — without
that answer depending on the state of a repository somebody else is working in:

```
bash bench/controller-fitness.sh --spec evidence/bean-001-spec-20260915.md \
  --tasks evidence/bean-001-tasks-20260915.yaml \
  --bean "$PWD/bench/fixtures/bean-001-prose.yaml" \
  --repo /home/gregg/workspace/seating-planner-py --out /tmp/prose.json
```

and the same with `bean-001-annotated.yaml`. Thirty seconds each, no GPU, no
variance. Measured 2026-09-16:

| bean | named by a check | not decidable | false alarms |
| --- | --- | --- | --- |
| prose | 2 of 5 | 3 | 0 |
| annotated | **3 of 5** | 2 | 0 |

The one that moves is `contradicts-non-goal`, caught by `bean-forbids` — which
is the defect the annotation claims to make decidable, and the only one. The
annotation is worth one seeded defect out of five, exactly as advertised and no
more: `unfinishable-task` and `criterion-not-really-met` remain the judge's, and
the judge accepts about half of what it is shown.

**Do not edit these to match a bean.** A fixture that tracks a live file is the
live file with extra steps. If bean-001 changes in a way that matters, that is a
new fixture next to these two, and the old figures stay attached to the old one.
