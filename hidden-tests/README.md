# Hidden tests

These run inside the gate container against the tree the worker built, mounted
read-only at `/hidden`. **The worker never sees them.** That is the point: every
other check in the line runs code the worker could read, and code written against
visible assertions satisfies exactly those assertions.

Two rules for anything added here.

**Write them from the bean, not from the diff.** Open `bean.yaml` — the
acceptance criteria, the constraints, the non-goals — and write what those mean.
Reading the implementation first and writing tests that fit it is how a hidden
suite becomes an expensive way of asserting that the code is the code.

**They live here, in the factory repo, not in the target repo.** The worker
mounts the target repo whole at `/work`. A test in it is a test it can read.
`hidden-tests.sh` refuses a directory inside the repo under test, and preflight
refuses it before the build starts; this directory is outside every repo the line
builds in, and versioned, which is the combination that was wanted.

One directory per bean. `hidden_tests.dir` carries `<bean>` and the run's bean id
replaces it, so bean-001's tests are never run against bean-007's tree. A bean
with no directory here has no hidden tests, which the gate records as a note.

## The worker is told the rule, not the answers

`factory/skills/factory-build-task/SKILL.md` says that some repositories measure
the finished change against tests written from the bean's criteria by someone who
is not the worker, kept outside the repository, and that a failure comes back as
a count and nothing else.

That is deliberate. A hidden test is not a trap: the point is not to catch a model
out, it is to remove the incentive to write code that satisfies the visible
assertions and nothing else. A worker that knows it will be measured on the
criterion rather than on the test has a reason to implement the criterion. One
that does not know simply optimises against what it can read, which is exactly
the behaviour these exist to defeat.

It also tells it there is nothing to reverse-engineer from a count, so guessing at
them is time spent away from re-reading the acceptance criteria.

**Unmeasured.** Whether saying this changes what the model writes is a question
for a run with hidden tests configured, and bean-002 is the first bean that will
have them.

## They run on the line, and they cannot run in CI

Worth saying before someone expects otherwise. `required_checks` in `repo.yaml`
names checks GitHub must report green before a merge, and
`factory/scaffold/.github/workflows/gates.yml` runs the pinned gate image against
the repository. **Hidden tests are not in the repository**, by construction — that
is the whole feature — so a GitHub runner has nothing to run them from.

What that means concretely:

- The hidden suite is a **local gate** result. It appears in `gate.json`, in the
  pull request body, and in the halt summary if it fails. It is not a check
  GitHub reports, and `required_checks` must not name it.
- A merge gated only on CI is a merge that did not consider them. The pull request
  body says whether they passed for exactly this reason: it is the one place a
  reviewer sees the result before clicking merge.
- If they ever need to run in CI, the suite has to be somewhere a runner can fetch
  — a private repository and a deploy key, say — and at that point "the worker
  cannot read it" becomes a claim about credentials rather than about the
  filesystem. That is a different and weaker guarantee, and it should be a
  deliberate decision rather than a consequence of wanting a green tick.

## What is here

| repo / bean | assertions | what they can check |
| --- | --- | --- |
| `seating-planner-py/bean-001` | 11 | Behavioural and structural. That bean's criteria are about a project's *shape* — installable, declares its floor, declares ortools without importing it, ships no domain code — and all of it is checkable from the tree without knowing any API. Eleven pass against what the line built; seven of eleven fail against a tree with those properties removed. |
| `seating-planner-py/bean-002` | 9 | **Deliberately structural, and the file says why.** bean-002 asks for `Event`, `Table`, `Guest` and `Group` but does not fix their API: "a capacity, a shape and an (x, y) position" does not say whether that is `capacity` or `seats`. The spec settles it, and the spec is the worker's own output — so a hidden test that guesses a constructor signature fails for a naming reason, costs a build cycle, and teaches nobody anything. What it asserts is what the bean states literally: four RSVP values by name, three limits by number, three constraints, three non-goals. **Worth revisiting once bean-002's spec is accepted**, when the API is fixed and the tests can be behavioural without being written against the implementation. |
| `seating-planner-py/bean-003` | 10 | Structural, and the first written **before** its bean's code existed — while the spec step was still running, which is the only way independence is a fact rather than a promise. It asserts what the bean states literally (both hardnesses, both weight bounds, FR-035's measure, the seven template categories by name) and never a constructor signature: the bean references FR-034 by number and fixes no type name. It passed on the first tree it ever saw. |
| `seating-planner-py/bean-004` | 6 | Written the same evening as bean-003's, also ahead of the line. Half-checked until bean-004 runs. |
| `seating-planner-py/bean-005` | 9 | Written ahead of the line, while bean-003 was still walking it. bean-005 fixes no API either — it never says whether the entry point is `preflight()` — so the four failures it must detect are matched as the English words its criteria use, with alternatives. Three of the nine ask things nothing visible asks: that the pre-flight does not reach for a solver (the package bean-006 will add, and the search libraries `forbidden_imports` does not name), that it does not enumerate arrangements with `itertools`, and that it **imports** bean-002's domain and bean-003's rules rather than redeclaring `Rule` or `Table` inside itself. The last is the one a green gate cannot see: a pre-flight that builds its own world passes every visible check and measures nothing anyone else shares. |

Both were checked twice before being committed: against a plausible correct
implementation, where they pass, and against one with the constraints violated,
where they bite and each names its own reason. A hidden suite that fails a correct
implementation costs a build cycle for nothing; one that passes a broken
implementation is worse than none. The control run in `hidden-tests.sh` catches
the second case automatically and cannot catch the first — that one is on whoever
writes them.

`__pycache__` is not committed and should not be: the directory is mounted into
the gate container, and a stale bytecode cache from a different Python is a
confusing way to fail.

## Absence tests, and why they are declared

A hidden suite's control run is the only thing standing between a vacuous test
and a green forever: the worker cannot read these tests by design, and the judge
is handed a **count**. So a test that can never fail inflates the number that
stands in for the whole hidden check.

The control used to require only that the SUITE fail against an empty tree, and a
suite fails if one test does. On 2026-09-16 that was hiding three tests that
passed against a tree with nothing in it:

- `test_nothing_imports_ortools_yet` — bean-001 declares ortools and must not
  import it. Nothing imports it in an empty directory either.
- `test_no_ci_workflow_files` — one of bean-001's non-goals. An empty tree has
  none.
- `test_the_domain_stays_inside_its_write_paths` — bean-002 may write only under
  two paths. An empty tree writes nowhere.

All three are legitimate: each asserts an **absence**, and an absence is true of
nothing. That is exactly why they cannot be found by inspection — they look like
the vacuous ones. So they are listed, one name per line with a comment saying
why, in `absent-by-design.txt` next to the tests. Any other test that passes
against an empty tree is refused by name, and the run stops.

The declaration is the whole mechanism. It is a short list a person can read, and
it grows only when somebody decides it should.

## Verifying a suite, in both directions

`factory/pipeline/hidden-tests.sh` runs a control against an empty tree and
refuses a suite that passes it. That proves the suite **can fail**. Nothing
proved it **can pass** — and a hidden suite that can never pass is the worse
failure of the two: it blocks every attempt of its bean, forever, and all the
worker is told is a count, so it cannot tell a wrong test from its own wrong
code.

`hidden-tests/verify.sh` checks both ends:

```
hidden-tests/verify.sh seating-planner-py/bean-001 \
  --branch bean/bean-001-project-scaffold-with-linting-typing-and \
  --repo /home/gregg/workspace/seating-planner-py
```

```
  ok      all 11 test(s) pass against the real tree
  ok      9 of 11 fail against an empty tree; the 2 that pass are declared absences
```

**Run it when a bean lands, and whenever its hidden tests are edited.** The real
tree is the accepted output of the bean itself, so the second half can only be
checked after the bean has run — a bean with no tree yet reports
`HALF CHECKED` and exits 3, which is a different answer from a pass and says so.

| suite | can fail | passes on the real tree |
| --- | --- | --- |
| `seating-planner-py/bean-001` | 9 of 11, 2 declared | **yes, 11 of 11** (2026-09-18) |
| `seating-planner-py/bean-002` | 8 of 9, 1 declared | **yes, 9 of 9** (2026-09-18) |
| `seating-planner-py/bean-003` | 9 of 10, 1 declared | **yes, 10 of 10** (2026-09-21) |
| `seating-planner-py/bean-004` | 6 of 6, 0 declared | unknown — bean-004 has not run |
| `seating-planner-py/bean-005` | 8 of 9, 1 declared | unknown — bean-005 has not run |

The table is a convenience. `verified/` is the record, `factory doctor` reads it,
and a suite EDITED since it was verified is back to unknown however this reads.

## Which beans have one, and how to tell if it can be trusted

`verify.sh <repo>/<bean> [--branch <ref> --repo <dir>]` answers the two
questions that matter, and writes what it found into `verified/`:

- **can it fail?** Every test except the declared absences must fail against an
  empty tree. `hidden-tests.sh` checks this at gate time too and refuses a suite
  that passes against nothing.
- **can it pass?** Against the tree the bean actually produced. This one can
  only be answered after the bean has run, and until then `verify.sh` says
  HALF CHECKED rather than pretending.

The second question is the one with teeth. A suite that can never pass **blocks
every attempt of its bean forever**, and the worker is told only a count — so it
cannot tell a wrong test from its own wrong code. That is the worst failure this
design can have.

`factory doctor` reads `verified/` and says how many suites are verified both
ways, how many have been EDITED since they were verified, and how many have
never been checked. The hash matters: editing a hidden test is exactly what
happens when one of them turns out to be wrong, and bean-002's was edited the
same day it was verified, because it failed a correct implementation on the
capital letter in `Confirmed`.

**Write the suite before the bean runs.** bean-003's and bean-004's were written
while bean-003's spec step was still going, which is the only way the first rule
above can be relied on rather than promised. It also means `verify.sh` can prove
the suite can fail long before there is anything for it to pass against.

**Do not repeat a machine-readable constraint.** If `bean.yaml` gives a non-goal
`forbidden_paths` or `forbidden_imports`, `bean-forbids` already checks it
against the diff, at the right resolution. bean-001's suite restated one — "no
CI workflow files" — as a property of the whole TREE, and duly failed on
`.github/workflows/gates.yml`, which the factory's own scaffold installs. A
hidden test earns its cost by asking something nothing visible asks.
