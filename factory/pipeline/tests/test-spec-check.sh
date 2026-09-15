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

printf '# spec\n\nSome specification prose.\n' > factory/runs/R/spec.md

# Two tasks. One verify cannot pass yet (the file is not there); the other
# passes on the tree as it stands, which is the defect.
cat > factory/runs/R/tasks.yaml <<'YAML'
schema_version: task/1.0.0
tasks:
  - id: t1
    title: write the module
    write_paths: ["src/a.py"]
    satisfies: ["ac1"]
    verify:
      - { kind: command, run: ["test", "-f", "src/a.py"] }
  - id: t2
    title: a task that verifies nothing
    write_paths: ["src/b.py"]
    satisfies: ["ac1"]
    verify:
      - { kind: command, run: ["test", "-d", "."] }
  - id: t3
    title: a task with one vacuous check among real ones
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

check "the undemonstrable task is named" "every verify already passes for: t2" "$out"
check "and explained"             "nothing these tasks do could be shown by running them" "$out"
nocheck "a task with a real check is not called undemonstrable" "for: t2, t3" "$out"
check "the step fails"            "SPEC CHECK FAIL" "$out"

printf '\n== and the result is recorded for the judge to read ==\n\n'
P=factory/runs/R/verify-precheck.json
want  "the file exists"           "verify-precheck.json should have been written" test -f "$P"
check "it names the schema"       "verify-precheck/1.0.0" "$(cat "$P")"
check "t2 has no check that could fail" \
      'true' "$(jq -c '.tasks[] | select(.task=="t2") | .every_verify_passes_before_the_work' "$P")"
check "t1 does"                   'false' "$(jq -c '.tasks[] | select(.task=="t1") | .every_verify_passes_before_the_work' "$P")"
check "and so does t3, despite its vacuous one" \
      'false' "$(jq -c '.tasks[] | select(.task=="t3") | .every_verify_passes_before_the_work' "$P")"
check "t3's vacuous check is still recorded" \
      '"passes_before_the_work":true' "$(jq -c '.tasks[] | select(.task=="t3") | .verifies[0]' "$P")"
check "the note explains the legitimate case" "a lint that is green on an empty directory" "$(cat "$P")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
