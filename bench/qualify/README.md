# Judge qualification

Can a local judge catch what this line actually ships?

`bench/judge-fitness.sh` measures a judge against defects planted in one
bean-001 spec. This suite measures it against **real audits whose right answer is
known**. On 2026-09-28, independent Claude reviews of five merged beans found a
real defect in every one of them, and the first pre-merge review (bean-014) found three more. All five had passed tests, gate, CI and an
advisory audit. Those defects are the cases here, alongside repaired twins that
differ from a defect case only in the defect.

## Qualifying a model

```
bench/judge-qualify.sh --repo ~/workspace/seating-planner-py --roles <roles.json> --passes 3
```

- `--roles` is a copy of `factory/pipeline/roles.json` with `.roles.judge`
  pointed at the candidate. Without it, the current judge is measured.
- It needs the GPU to itself and refuses to start while a bean is being built.
  Run it when the line is idle.
- Use at least three passes. The judge has given different verdicts for
  byte-identical input at temperature 0, so a single pass is anecdote.

Each case runs the real `judge.sh`, then the real `audit-check.sh`. Both run from
a worktree of the target repository at the commit the audit originally saw, so a
quote from the code resolves exactly as it did. Results go to
`bench/results/judge-qualify-<time>.json`, with the judge's logs and verdict files
beside them.

## Reading the result

| figure | meaning |
| --- | --- |
| **pairs told apart** | For a defect case and its twin: the defect is named *and* the verdict stamped, and the twin raises no false alarm. This is the number that matters. |
| strict catch rate | Defects named and stamped, out of the uncontested defects. |
| false accepts | Defect cases the judge accepted. §11 wants this near zero. |
| false alarms | Twins where a blocker or major finding names the repaired defect. |
| stamp rate | How often audit-check accepted the judgement at all. It has been 0 in the live line. |

A judge that rejects everything and a judge that accepts everything both score
**zero pairs**. `bench/tests/test-judge-qualify.sh` asserts this. The per-criterion
judge of 2026-09-16 rejected all six of its cases, including the clean control.
A catch rate alone would have called that perfect.

"Named" is a keyword match (the case's `anchors`) over text the judge wrote, so it
is an upper bound, as judge-fitness says of its own. "Named and stamped" is
stricter: audit-check has checked every quote in that judgement against the disk.

## The cases

| case | audit | expect | difficulty | source |
| --- | --- | --- | --- | --- |
| `impl-audit-filter-sql-error` | impl | reject | easy | bean-004-20260922T142454Z (PR #4) |
| `impl-audit-filter-repaired` | impl | accept | - | twin of `impl-audit-filter-sql-error` |
| `impl-removal-writes-no-audit` | impl | reject | medium | bean-004-20260923T195628Z (PR #5) |
| `impl-soft-keep-apart-never-honoured` | impl | reject | hard | bean-007-20260925T015546Z (PR #9) |
| `impl-soft-keep-apart-repaired` | impl | accept | - | twin of `impl-soft-keep-apart-never-honoured` |
| `impl-worker-count-ignored` | impl | reject | hard | bean-009-20260925T125445Z (PR #11) |
| `impl-mode-identity-comparison` | impl | reject | medium | bean-013-20260928T134342Z (PR #15) |
| `impl-group-size-counts-ineligible` | impl | reject (contested) | medium | bean-005-20260924T001254Z (PR #6) |
| `impl-event-day-unlock-and-diagnosis` | impl | reject | medium | bean-014-20260928T162157Z (PR #16), from its pre-merge review |
| `spec-verify-contradicts-intent` | spec | reject | medium | bean-003-20260918T022947Z |
| `spec-verify-consistent` | spec | accept | - | twin of `spec-verify-contradicts-intent` |
| `spec-keyword-and-hardcode-both-asked` | spec | reject | medium | bean-009-20260925T125445Z |
| `impl-ttt-side-tiebreak-highest` | impl | reject | hard | **synthetic mutant** of tic-tac-toe-py bean-003 (PR #4); the suite passes on it |
| `impl-ttt-strategy-real` | impl | accept | - | twin of `impl-ttt-side-tiebreak-highest`: the real merged code |
| `impl-ttt-session-asks-x` | impl | reject | medium | **synthetic mutant** of tic-tac-toe-py bean-004 (PR #5); the suite passes on it |
| `impl-ttt-session-real` | impl | accept | - | twin of `impl-ttt-session-asks-x`: the real merged code |

Each `case.json` holds the defect, the reasoning, the evidence as verbatim
quotes from `inputs/` (checked on write), and the anchors. **Contested** means
there is a defensible reading under which accept is right. The bean-005 case is
one: the code matches its own spec and disagrees with the bean's intent. Contested
cases are scored separately and never count toward the catch rate.

The `impl-ttt-*` cases (Phase 4 task 11, 2026-10-02) run the other way round. The real merged
code is the twin and expects accept. The defect case is a mutant the pre-merge review found
surviving the line's own tests, applied to `diff.txt` alone and marked `mutation.synthetic: true`.
These cases ask whether a judge reads the diff against the bean, or only checks that the tests
are green. They belong to `tic-tac-toe-py`, so run them with
`--repo ~/workspace/tic-tac-toe-py`. A run against another target skips them and says so.

There are no clean controls taken from merged beans. Every merged bean that was
reviewed closely turned out to have a defect, so the twins are the controls. Each
twin is marked `repair.synthetic: true` and says exactly what was changed.

## Adding a case

```
bench/qualify/freeze-case.sh <run-dir> --repo <target-repo> --target impl \
  --id <kebab-id> --expect reject --pr <n>
```

This copies what `judge.sh` reads for that target. It takes the bean as it was at
the run's base, not as it is today: bean-004 gained a fifth criterion after the
run that is its best case. `--candidate` overrides the commit the pull request
records. PR #4's branch was later reset, so its case uses the backup branch's tip.

Then write the answer key by hand, and demonstrate the defect before you do. A
key written by the thing being measured measures nothing. "Merged" is not "clean":
bean-007 looked clean and was not. The harness refuses a case with no key.
