#!/usr/bin/env bash
# test-spec-check.sh — the spec audit's deterministic half.
#
# Most of spec-check is structural: does every task name a write path inside the
# bean's, does every acceptance criterion get claimed, is the dependency graph
# acyclic. Those are cheap to assert and cheap to get right.
#
# The part worth a test of its own is the newest one: running each `verify`
# against the tree BEFORE any task has run. A check that passes there cannot
# show the task was done. We asked the judge to notice that class of defect and
# measured that it does not — so the controller decides it, and a controller
# decision needs a test the way a model opinion cannot have one.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nocheck() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}

REPO="$WORK/repo"; git init -q -b main "$REPO"; cd "$REPO"
git config user.email t@e.com; git config user.name T
mkdir -p factory/runs/R src factory/beans
cat > factory/beans/bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: example/x
title: A bean whose tasks will be checked
intent: Prove the controller decides tautologies itself.
status: approved
allowed_write_paths: ["src/**"]
acceptance_criteria:
  - id: ac1
    text: the module exists
    verify: { kind: command, run: ["test", "-f", "src/a.py"] }
definition_of_done: ["ac1"]
YAML
printf 'x\n' > README.md
git add -A && git commit -q -m init

full_spec() { # full_spec <current-behaviour-body>
  cat > factory/runs/R/spec.md <<MD
# spec

## What and why

This bean exists so the fixture has a document that passes doclint, which every
later check depends on being reached. A spec that fails the section lint stops
the script before anything interesting runs.

## Current behaviour

$1

## Proposed change

Add the module, add a test for it, and bring the gates to green. The work is
deliberately small because the point of this fixture is the checking, not the
change itself.

## Risk

Low. Nothing here is loaded by anything else yet, so a mistake is contained to
the new files and is caught by the gates before it reaches a branch.

## Blast radius

Three files under src/, and nothing outside them. No configuration, no
dependency, and no public interface changes.

## Verification

The gates run lint, types and tests. Each task carries its own check, and the
controller runs every one of them rather than trusting the worker's report.

## Open questions

None. If something turns out to be ambiguous the task blocks and a person is
asked rather than guessed at.
MD
}
full_spec "The repository is an empty shell with nothing in \`src/\` yet. There is a
README, a licence and the factory directory, and no application code at all, so
nothing here can break in a way a test would notice."

# Two tasks. One verify cannot pass yet (the file is not there); the other
# passes on the tree as it stands, which is the defect.
cat > factory/runs/R/tasks.yaml <<'YAML'
schema_version: tasks/1.0.0
bean_id: bean-001
tasks:
  - id: task-1
    title: write the module
    intent: Create src/a.py so the package has something in it.
    write_paths: ["src/a.py"]
    satisfies: ["ac1"]
    verify:
      - { kind: command, run: ["test", "-f", "src/a.py"] }
  - id: task-2
    title: a task that verifies nothing
    intent: Do some work whose only check passes before the work is done.
    write_paths: ["src/b.py"]
    satisfies: ["ac1"]
    verify:
      - { kind: command, run: ["test", "-d", "."] }
  - id: task-3
    title: a task with one vacuous check among real ones
    intent: Do work that has both a vacuous check and a real one.
    write_paths: ["src/c.py"]
    satisfies: ["ac1"]
    verify:
      - { kind: command, run: ["test", "-d", "."] }
      - { kind: command, run: ["test", "-f", "src/c.py"] }
YAML

sc() { bash "$PIPELINE_DIR/spec-check.sh" factory/runs/R --bean factory/beans/bean.yaml "$@" 2>&1; }

printf '\n== without a sandbox it does not run model-authored commands ==\n\n'
# No gates.lock.yaml in this fixture, so there is nothing to run them inside.
out="$(sc)"
check "it says so plainly"        "not checked — no sandbox available" "$out"
want  "and records no results"    "verify-precheck.json must not exist" \
      test ! -f factory/runs/R/verify-precheck.json

printf '\n== the check can be turned off entirely ==\n\n'
out="$(SPEC_CHECK_RUN_VERIFIES=0 sc)"
nocheck "no mention of it at all" "verify can fail" "$out"

printf '\n== with a sandbox, a verify that already passes is a failure ==\n\n'
# A stub verify.sh, so the test asserts on spec-check's logic rather than on
# podman being installed. `test -d .` passes; everything else does not.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/verify.sh" <<'STUB'
#!/usr/bin/env bash
spec="$1"
if grep -q '"-d"' <<<"$spec"; then
  printf '{"kind":"command","status":"pass","exit_code":0,"command":"test -d ."}\n'; exit 0
fi
printf '{"kind":"command","status":"fail","exit_code":1,"command":"test -f src/a.py"}\n'; exit 1
STUB
chmod +x "$WORK/stub/verify.sh"
cat > "$WORK/stub/sync-tree.sh" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$2"; exit 0
STUB
chmod +x "$WORK/stub/sync-tree.sh"
cat > "$WORK/stub/podman" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$WORK/stub/podman"
printf 'schema_version: gate-manifest/1.0.0\nimage: example/x@sha256:0\ngates: []\n' > factory/gates.lock.yaml

# The stubs shadow the real scripts by sitting earlier on PATH for podman, and by
# a copy of the pipeline dir for the two scripts spec-check calls by path.
cp -r "$PIPELINE_DIR" "$WORK/pipeline"
cp "$WORK/stub/verify.sh" "$WORK/stub/sync-tree.sh" "$WORK/pipeline/"
out="$(PATH="$WORK/stub:$PATH" bash "$WORK/pipeline/spec-check.sh" factory/runs/R --bean factory/beans/bean.yaml 2>&1)"

check "the undemonstrable task is named" "every verify already passes for: task-2" "$out"
check "and explained"             "nothing these tasks do could be shown by running them" "$out"
nocheck "a task with a real check is not called undemonstrable" "for: task-2, task-3" "$out"
check "the step fails"            "SPEC CHECK FAIL" "$out"

printf '\n== and the result is recorded for the judge to read ==\n\n'
P=factory/runs/R/verify-precheck.json
want  "the file exists"           "verify-precheck.json should have been written" test -f "$P"
check "it names the schema"       "verify-precheck/1.0.0" "$(cat "$P")"
check "task-2 has no check that could fail" \
      'true' "$(jq -c '.tasks[] | select(.task=="task-2") | .every_verify_passes_before_the_work' "$P")"
check "task-1 does"                   'false' "$(jq -c '.tasks[] | select(.task=="task-1") | .every_verify_passes_before_the_work' "$P")"
check "and so does task-3, despite its vacuous one" \
      'false' "$(jq -c '.tasks[] | select(.task=="task-3") | .every_verify_passes_before_the_work' "$P")"
check "task-3's vacuous check is still recorded" \
      '"passes_before_the_work":true' "$(jq -c '.tasks[] | select(.task=="task-3") | .verifies[0]' "$P")"
check "the note explains the legitimate case" "a lint that is green on an empty directory" "$(cat "$P")"

printf '\n== a spec that describes files which are not there ==\n\n'
#
# The seeded defect from bench/judge-fitness.sh, which four judge runs never
# named: a Current-behaviour section written with complete confidence about a
# module that does not exist.
full_spec "The repository already contains \`src/config.py\`, which reads a \`SEATING_ENV\`
variable and returns a \`Settings\` dataclass. This work extends its existing
\`load_settings()\` helper rather than creating anything new."
out="$(SPEC_CHECK_RUN_VERIFIES=0 sc)"
check "the invented file is named"    "describes files that are not there: src/config.py" "$out"
check "and the spec fails"            "SPEC CHECK FAIL" "$out"
check "the finding is recorded"       '"missing_paths"' "$(cat factory/runs/R/claims-check.json)"

printf '\n== a name that occurs nowhere is reported, not failed ==\n\n'
full_spec "\`src/a.py\` exists and exports \`frobnicate\`, which this change will rename.
Nothing else imports it yet, so the rename is contained to that one file and its
test."
mkdir -p src && printf 'x\n' > src/a.py
out="$(SPEC_CHECK_RUN_VERIFIES=0 sc)"
check "the absent name is mentioned"  "occur nowhere in the repo, which may be fine: frobnicate" "$out"
nope  "but it does not fail the spec" "describes files that are not there" "$out"

printf '\n== code in a fenced block is an example, not a claim ==\n\n'
full_spec "\`src/a.py\` is a stub with nothing in it but a docstring, and no other
module refers to it yet. The change will add:

\`\`\`python
from src.nonexistent_module import helper_that_does_not_exist
\`\`\`"
out="$(SPEC_CHECK_RUN_VERIFIES=0 sc)"
nope "the example is not treated as a claim" "nonexistent_module" "$out"

printf '\n== saying a file is NOT there is a true claim, not a false one ==\n\n'
#
# This is the case that matters most for whether the check survives contact: a
# Current-behaviour section that carefully states what is absent is a *good* one,
# and a check that flags it punishes exactly the specs written well. It was found
# by breaking another suite's fixture, which said "There is no `src/a.py`."
full_spec "There is no \`src/nope.py\` and nothing imports it. The package directory
is empty apart from its docstring, so there is no behaviour here to preserve and
nothing that a test could currently observe."
out="$(SPEC_CHECK_RUN_VERIFIES=0 sc)"
nope  "an absent file is not a false claim" "describes files that are not there" "$out"
check "and the spec passes"                 "SPEC CHECK PASS" "$out"
check "it is recorded as a denial"          '"paths_said_to_be_absent"' \
      "$(cat factory/runs/R/claims-check.json)"

printf '\n== saying a file is absent when it is there is reported, never failed ==\n\n'
#
# This direction was implemented as a failure and then deliberately demoted.
# Negation detection exists to suppress a check; asking the same fuzzy signal to
# fire one needs precision it does not have, and on the first real spec it met it
# was wrong twice in a single section. A miss here costs a line someone reads.
mkdir -p src && printf 'x\n' > src/present.py
full_spec "There is no \`src/present.py\` yet, so this change creates it from
scratch. Nothing in the package refers to it and no test covers it, which is why
the work can be done in a single task without touching anything else."
out="$(SPEC_CHECK_RUN_VERIFIES=0 sc)"
check "it is still mentioned"  "it also calls these absent, and they are not: src/present.py" "$out"
nope  "but the spec passes"    "SPEC CHECK FAIL" "$out"

printf '\n== how much an audit is asked to read is budgeted in bytes ==\n\n'
#
# The existing size budget counts tasks, which bounds the work. This counts
# bytes, which bounds the reading — a bean with three enormous tasks passes the
# first and fails the second, and it is the second that has been hurting.
full_spec "The repository is an empty shell with nothing in \`src/\` yet, and no
module in it that any test could currently observe."
printf '{"spec_bytes_budget": 100}\n' > "$REPO/tiny-budget.json"
out="$(PIPELINE_CONFIG="$REPO/tiny-budget.json" SPEC_CHECK_RUN_VERIFIES=0 sc)"
check "an over-budget spec is refused" "over the 100 budget" "$out"
check "and it says what to do"         "split the bean" "$out"

printf '{"spec_bytes_budget": 1000000}\n' > "$REPO/big-budget.json"
out="$(PIPELINE_CONFIG="$REPO/big-budget.json" SPEC_CHECK_RUN_VERIFIES=0 sc)"
check "a spec within budget passes"    "within the 1000000 budget" "$out"

out="$(SPEC_CHECK_RUN_VERIFIES=0 sc)"
check "and with no budget set it just reports" "no budget set" "$out"

printf '\n== a file denied once and mentioned again is still denied ==\n\n'
#
# The first spec a contained worker ever wrote, and the first false positive this
# check produced. It opened with "no `pyproject.toml`, no `src/`, and no `tests/`
# exist in the repository today" — correct, and exactly what the section is for —
# then referred to `pyproject.toml` again forty lines later while describing the
# change. One denial, one neutral mention, and the neutral one won.
full_spec "There is no current behaviour to describe: no \`pyproject.toml\`, no \`src/\`,
and no \`tests/\` exist in the repository today. Running the gates now would fail
at collection.

The change will set test discovery to \`tests/\` in \`pyproject.toml\`, which is
where the tool configuration belongs."
out="$(SPEC_CHECK_RUN_VERIFIES=0 sc)"
nope  "the later mention does not revive the claim" "describes files that are not there" "$out"
check "and the spec passes"                         "SPEC CHECK PASS" "$out"

printf '\n== a section may talk about what the change will create ==\n\n'
#
# The third false positive this check produced, and the one that changed its
# design. A Current-behaviour section legitimately describes the future, and none
# of these sentences contains a negation:
#
#   "Both are fixed by this bean creating `tests/` and `src/`."
#   "...a `testpaths` setting in `pyproject.toml` (an allowed write path)"
#
# Inferring an existence claim from the absence of a negation accused a
# well-written section of lying, three specs running. A path is now only required
# to exist when the text says it does.
full_spec "The unit gate has nothing to run. No tests exist and \`--cov=src\` has
nothing to cover; both are fixed by this bean creating \`tests/\` and \`src/\`.

The setting that scopes collection from here onward is \`testpaths\` in
\`pyproject.toml\`, which this change adds along with the rest of the tool
configuration."
out="$(SPEC_CHECK_RUN_VERIFIES=0 sc)"
nope  "future work is not an existence claim" "describes files that are not there" "$out"
check "and the spec passes"                   "SPEC CHECK PASS" "$out"
check "the mention is recorded, not judged"   "mentioned without a claim" "$out"

printf '\n== but "already contains" is an existence claim, and is checked ==\n\n'
full_spec "The repository already contains \`src/config.py\`, which currently reads a
\`SEATING_ENV\` variable and returns a settings object. This change extends that
module rather than creating anything new, so the surface is unchanged."
out="$(SPEC_CHECK_RUN_VERIFIES=0 sc)"
check "the false claim is caught"  "describes files that are not there: src/config.py" "$out"
check "and the spec fails"         "SPEC CHECK FAIL" "$out"

printf '\n== a missing schema validator is a failure, not a note ==\n\n'
#
# It printed as a quiet note for a while. Then a pipeline snapshot left the
# schemas and the venv behind, spec-check said "structural checks only" and
# carried on, and the run recorded that the spec was checked — by a weaker check
# than anyone reading that record would assume.
full_spec "The repository is an empty shell with nothing in \`src/\` yet, and no
module in it that any test could currently observe."
out="$(SPEC_CHECK_VALIDATOR=/nonexistent/validate.py SPEC_CHECK_RUN_VERIFIES=0 sc)"
check "it refuses rather than noting"  "no schema validator" "$out"
check "and says what was not checked"  "NOT
          checked against task.schema.json" "$out"
check "the spec fails"                 "SPEC CHECK FAIL" "$out"

out="$(SPEC_CHECK_VALIDATOR=/nonexistent/validate.py SPEC_CHECK_ALLOW_NO_SCHEMA=1 SPEC_CHECK_RUN_VERIFIES=0 sc)"
check "but it can be accepted deliberately" "schema validation skipped" "$out"

printf '\n== a containment check that cannot run is not "outside the paths" ==\n\n'
#
# `! contain.py` treats exit 1 (outside the bean) and exit 2 (contain.py refusing
# to run) alike, so an unreadable pattern list made every task look out of bounds.
# That is a refusal for the wrong reason, and it sends the next person to edit a
# spec that was fine. The same two lines were in build-loop.sh twice.
BROKEN_PIPE="$WORK/broken-pipeline"; rm -rf "$BROKEN_PIPE"; cp -r "$PIPELINE_DIR" "$BROKEN_PIPE"
cat > "$BROKEN_PIPE/contain.py" <<'PYSTUB'
import sys
print("contain.py: patterns are not JSON", file=sys.stderr)
sys.exit(2)
PYSTUB
out="$(bash "$BROKEN_PIPE/spec-check.sh" factory/runs/R --bean factory/beans/bean.yaml 2>&1)" || true
check "it says the check did not run" "the check did not run" "$out"
nope  "and does not blame the paths"  "outside the bean's allowed paths" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
