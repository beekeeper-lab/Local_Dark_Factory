# Hidden tests — seating-planner-py

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
