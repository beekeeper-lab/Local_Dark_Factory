# Pre-merge review of a bean pull request

Adopted 2026-09-28, by the owner, after four merged beans in a row were found to
carry a real defect that every check in the line had passed:

| bean | defect | what passed it |
| --- | --- | --- |
| bean-007 | soft keep-apart indicator bounded from below only; the rule never counts | tests, gate, CI, advisory audit |
| bean-009 | `num_search_workers` accepted and ignored | tests, gate, CI, advisory audit |
| bean-005 | group size counts ineligible guests; ac2's own test asserts the false positive | tests, gate, CI, advisory audit |
| bean-013 | `mode is LOW_DISRUPTION` compares identity; a mode from JSON is misrouted | tests, gate, CI, advisory audit |

The tests are written by the model that wrote the code. The audits are advisory
and have never stamped a verdict. Most beans have no hidden tests. A green gate
and a green CI are therefore not a review, and merging on them added no
independent check.

## What happens now

Before a bean's pull request is merged, a fresh Claude session (the operator's
model, not the line's) reviews it. The rule on the retooling side of this
project is to use the best available model; until a local judge qualifies
(`bench/qualify/`), this is the only review the line has.

The reviewer gets the bean as it stands on the branch, the run's `spec.md`,
`tasks.yaml` and `diff.txt`, and read-only access to the repository. It reads
every changed line against the bean's intent, criteria, constraints and non-goals,
and looks in particular for:

- logic that the tests cannot see: CP-SAT indicators bounded in one direction,
  vacuous constraints, identity where equality was meant, arguments accepted and
  ignored, off-by-one limits
- tests that would pass without the change, or that assert the defect
- a spec that contradicts itself, faithfully built

**A suspected defect must be demonstrated**: run in the pinned gate image against
an export of the branch, with the command and its output in the review. An
undemonstrated suspicion is reported as such and does not block.

## Outcomes

- **No demonstrated defect** — merge. Minor points are noted in the review record
  and do not block.
- **A demonstrated defect** — do not merge. The owner decides between fixing it on
  the branch (a re-run), a repair bean after merge, or accepting it. Each finding
  also becomes a case in `bench/qualify/`, because it is exactly the kind of thing
  a qualified local judge must catch.

The review record is kept at `evidence/reviews/<run-id>.md`.

## The prompt

The reviewer is given this, with the paths filled in:

> Review seating-planner pull request #N (bean-NNN, run `<run-id>`) before it is
> merged. Assume nothing is clean: four merged beans in a row carried real defects
> their tests could not see. Read the bean
> (`factory/beans/<dir>/bean.yaml` on the PR head), the run's `spec.md`,
> `tasks.yaml` and `diff.txt`, and every changed line. Do not modify the
> repository or check out branches in it; export trees with `git archive`. You may
> run code in the pinned gate image (`factory/gates.lock.yaml`), with no network.
> Report: VERDICT merge / do-not-merge; each defect with file:line, a short quote,
> and the demonstration command and output; minor points separately. Under 400
> words.
