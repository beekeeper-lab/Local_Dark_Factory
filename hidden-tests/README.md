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
