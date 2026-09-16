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
