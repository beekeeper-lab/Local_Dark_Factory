# The benchmark corpus

A fixed set of requirements, built over and over, so that changes to the line
can be measured instead of argued about.

Without this, every run processes different work, and "the Q8 developer is
better" is an anecdote. With it, the input is a constant and exactly one thing
varies per experiment.

## The layering, and why beans are not frozen

```
requirements/     FROZEN      the constant. Hashed; a change invalidates
                              comparison against every prior run.
bean-sets/        DERIVED     regenerated as intake improves. Versioned,
                              because bean quality is itself under test.
runs/             OBSERVED    one per (bean-set x models x stack x config).
```

The requirements never move. The beans absolutely do — turning a requirements
document into well-sized, properly-ordered, machine-verifiable beans *is* the
human-plus-AI skill the line depends on (spec §04), and it is the thing most
likely to improve as we learn. So a bean set is a dated, versioned artifact
with a manifest recording how it was produced, and regenerating one is a normal
event rather than a correction.

This matters for reading results. A run is only comparable to another run along
the axis being tested:

| Comparing | Hold constant | Vary |
|---|---|---|
| Q4 vs Q8 developer | bean set, stack, skills | `conditions.developer.model` |
| bean decomposition quality | models, stack, skills | `corpus.bean_set` |
| stack portability | bean set, models, skills | `conditions.stack` |
| a skill rewrite | bean set, models, stack | `conditions.skill_versions` |

Two runs that differ in more than one column answer nothing. `run-record.schema.json`
exists to make that checkable rather than remembered.

## Layout

```
benchmark/
  <corpus-name>/
    requirements/
      REQUIREMENTS.md          the frozen source document
      SHA256SUMS               proves it did not drift
    bean-sets/
      v1/
        manifest.json          who/what generated it, from which requirements hash
        beans/*.yaml           validated against schemas/bean.schema.json
      v2/ ...
    runs/
      <run-id>/                run.json (run-record/1.0.0), steps.jsonl, verdicts/
```

## Rules

1. **Never edit `requirements/` to make a run succeed.** If the requirements are
   genuinely wrong, that is a new corpus version and prior results are retired
   with it. Quietly fixing the input to flatter the output is how a benchmark
   stops meaning anything.
2. **Every bean set records its provenance** — the requirements hash it derives
   from, the model and prompt version that drafted it, and who approved it.
   A bean set whose requirements hash does not match the current frozen document
   is stale and must not be run.
3. **Every bean validates before it runs**:
   `.venv/bin/python bench/validate.py --corpus benchmark/<name>/bean-sets/<v>/beans`
   That checks the schema, that every acceptance criterion carries a `verify`
   (spec §05), that ids are unique, and that dependencies resolve inside the set.
4. **Build order exercises containment.** Greenfield under-tests the part of the
   line most likely to fail: allowed-write-paths, reject-not-strip, and blast
   radius are all machinery for changing code that already exists. The first few
   beans scaffold and contain nothing; the set must then deliberately include
   beans that modify what earlier beans wrote, plus refactors and fixes to
   earlier beans, so real callers and regression risk appear early rather than
   at bean 20.
5. **A failed run is data.** Halted and blocked runs stay in `runs/` with their
   evidence. The blocked rate and its reasons are a §11 metric; deleting the
   failures optimises the record rather than the line.

## Corpora

| Name | Source | Status |
|---|---|---|
| `seating-planner` | Wedding Seating Optimizer PRD v0.1 — 85 FR, 14 NFR, 8 acceptance scenarios | requirements frozen at `73512dcd…18e5`; bean set **v1 drafted and approved** — 20 beans, all `status: approved`, run order 001..020 |
