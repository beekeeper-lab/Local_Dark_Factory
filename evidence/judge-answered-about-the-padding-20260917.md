# At twice the bytes, the judge reviewed the padding instead of the artifact

2026-09-17. A spec audit of bean-001 padded to 40,422 bytes with
`bench/fixtures/pad-neutral` — the bean corpus with every mention of the solver
removed, so nothing in the padding could legitimise the seeded defect.

**bean-001 is a project scaffold.** Its four acceptance criteria are:

    ac1  The package imports cleanly from an installed environment.
    ac2  Ruff reports no violations.
    ac3  Mypy reports no errors.
    ac4  Pytest runs and collects at least one passing test.

**This is what the judge said about them:**

    ac1  The repository includes a test case under `tests/feasibility/test_preflight.py` that defines a problem with only hard constraints and verifies that the planner can find at least one solution. This sat

    ac2  The repository does not contain any tests that verify a group staying together exceeding table capacity, nor is there a test for the rule naming a group larger than any table. No evidence was found fo

    ac3  No test case verifies that a same-table and a different-table hard rule over the same guest pair is reported as a contradiction naming both rules. No such verification was found in the repository.

    ac4  The repository does not contain any test that checks for a rule named "no soft" or "soft" constraints, nor a test that verifies no rules are added. No evidence was found for this criterion.

Verdict: **accept**, confidence **0.1**, with 2 findings:

    - Missing tests for FR-001 and FR-002: The repository does not contain any test files that verify a rule naming a group larger than any table or a same-table/different-table hard constraint conflict. No

    - Missing test for AC5: There is no test file in the repository that verifies a satisfiable problem has at least one solution.

## What this is

Not dilution. **Displacement.** `tests/feasibility/test_preflight.py` is bean-005's
territory; group capacity and same-table/different-table rules are bean-003's;
"no soft constraints" is bean-007's. None of it is in the document under audit,
and the seeded defect — a CP-SAT stub in a bean whose non-goals forbid solver
code — is not mentioned once.

The judge stopped reviewing the artifact and started reviewing the context, and
**the grammar made that invisible**: `criteria` is keyed on the bean's own ids
with `additionalProperties: false`, one of the five grammar constraints that took
schema conformance from about zero to 100%. So the answer has exactly four
entries, exactly `ac1` through `ac4`, perfectly shaped — and every one of them is
about somebody else's bean.

This is the clearest instance yet of the thing this project keeps finding:
**conformance is not judgement.** A grammar can guarantee the shape of an answer
and cannot make it an answer to the question asked.

## It also explains a column that was flapping

`NAMED` is a keyword match over the judgement body. Five rows of an earlier
control scored `yes` and these two scored `no` on identical input — because the
judgement is not about the spec at all, so whether a catchword happens to appear
is luck. A detector reading a body that is about something else is not measuring
what it thinks.

## What stops it reaching a run

`audit-check.sh` refuses this judgement on three independent grounds, and it is
worth knowing that the controller does not depend on noticing the displacement:

- **confidence 0.1** is below the 0.4 floor, which turns an accept into an
  abstain and exits 7 — a human is needed.
- **`accept` with two findings** is a judgement disagreeing with itself.
- the quotes, if checked against this run's artifacts, point at text that is in
  the prompt and in no file of the run.

The reason to record it anyway is that none of those checks is about the actual
failure. They catch it sideways. What catches it directly is not sending the
judge 40,000 bytes.
