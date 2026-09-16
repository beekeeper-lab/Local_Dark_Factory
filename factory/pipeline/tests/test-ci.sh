#!/usr/bin/env bash
# test-ci.sh — the remote gates, and what the line does when they disagree.
#
# The gates run twice: once here in the pinned image before anything is pushed,
# and once on GitHub against the same image by digest. The second is the only one
# a reviewer can see without trusting this machine. When it disagrees, the local
# one does not win.
#
# What must not happen, in order of how bad it is: calling a check green because
# it never reported; calling it green because the wait timed out; and rebuilding
# the whole bean because one gate found one thing.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
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
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

REPO="$WORK/repo"; git init -q -b main "$REPO"; cd "$REPO"
git config user.email t@e.com; git config user.name T
mkdir -p factory src tests "$REPO/factory/runs/R"
R="$REPO/factory/runs/R"
cat > factory/repo.yaml <<'RY'
schema_version: repo-config/1.0.0
repo: example/x
default_branch: main
merge_mode: human_required
required_checks:
  - gates
RY
cat > "$R/tasks.yaml" <<'TY'
schema_version: tasks/1.0.0
tasks:
  - id: task-1
    title: the package
    write_paths: ["src/**"]
  - id: task-2
    title: the tests
    write_paths: ["tests/**"]
  - id: task-3
    title: the project file
    write_paths: ["pyproject.toml"]
TY
printf 'x\n' > src/a.py; printf 'y\n' > tests/test_a.py; printf 'z\n' > pyproject.toml
# A workflow on the branch. Without one, ci.sh refuses immediately rather than
# waiting for a check nothing can report — which is its own case, below.
mkdir -p .github/workflows && printf 'name: gates\non: [pull_request]\n' > .github/workflows/gates.yml
git add -A && git commit -q -m init
HEAD_SHA="$(git rev-parse HEAD)"
printf '{"schema_version":"run/1.0.0","run_id":"R","bean_id":"bean-001","bean":"bean-001","pr_url":"https://github.com/example/x/pull/1"}\n' > "$R/run.json"

# A gh that answers with whatever the test put in $GH_CHECKS, and serves a log
# from $GH_LOG.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr checks") cat "$GH_CHECKS" 2>/dev/null || exit 1 ;;
  "run view")  cat "$GH_LOG" 2>/dev/null || exit 1 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export GH_CHECKS="$WORK/checks.json" GH_LOG="$WORK/log.txt"
: > "$GH_LOG"

ci() { bash "$PIPELINE_DIR/ci.sh" "$R" --interval 1 --timeout 3 "$@" 2>&1; }
clean() { rm -f "$R/ci.json" "$R/rewind.json" "$R/ci-findings.md" "$R/ci-logs.txt" \
                "$R/reopened-tasks.txt" "$R/QUESTIONS.md"; }

# --------------------------------------------------------------------------
printf '\n== every required check green ==\n\n'
clean
printf '[{"name":"gates","state":"SUCCESS","bucket":"pass","link":"https://github.com/example/x/actions/runs/7"}]\n' > "$GH_CHECKS"
out="$(ci)"; rc=$?
rc_is "it passes"                      "$rc" 0
check "it names the pull request"      "pull/1" "$out"
check "and what was required"          "required                gates" "$out"
check "and the candidate it is about"  "${HEAD_SHA:0:12}" "$out"
want  "ci.json is written"             "ci.json should exist" test -s "$R/ci.json"
want  "with nothing failed"            "failed should be empty" \
      test "$(jq -c '.failed' "$R/ci.json")" = '[]'
want  "and no rewind"                  "rewind.json must not exist" test ! -f "$R/rewind.json"

# --------------------------------------------------------------------------
printf '\n== a required check that never reported ==\n\n'
#
# The worst of the three, because it is the one that looks like nothing happening.
# A required check that does not run is not a check, and a step that waits for it
# and then shrugs has converted a missing guarantee into a green tick.
clean
printf '[{"name":"something-else","state":"SUCCESS","bucket":"pass","link":""}]\n' > "$GH_CHECKS"
out="$(ci)"; rc=$?
rc_is "it does not pass"               "$rc" 3
check "and says what is missing"       "never reported" "$out"
check "in the words that matter"       "a required check that does not run is not a check" "$out"
nope  "and never calls it green"       "CI PASS" "$out"
check "the question names the cause"   "the workflow is not installed" "$(cat "$R/QUESTIONS.md")"
# PENDING and MISSING are different failures and must not share a sentence.
nope  "it is not called slow"          "PENDING after" "$out"

# --------------------------------------------------------------------------
printf '\n== checks that never finish ==\n\n'
clean
printf '[{"name":"gates","state":"PENDING","bucket":"pending","link":""}]\n' > "$GH_CHECKS"
out="$(ci)"; rc=$?
rc_is "it refuses rather than assuming" "$rc" 3
check "it says how long it waited"      "PENDING after 3s" "$out"
want  "and asks a human"                "QUESTIONS.md should exist" test -s "$R/QUESTIONS.md"
want  "the run record says it ran"      "ci.json should say unfinished" \
      test "$(jq -r '.status' "$R/ci.json" 2>/dev/null)" = unfinished
check "naming the likely cause"         ".github/workflows" "$(cat "$R/QUESTIONS.md")"
nope  "it never calls that green"       "CI PASS" "$out"

# --------------------------------------------------------------------------
printf '\n== a failing check sends the run back to build, for the right tasks ==\n\n'
clean
printf '[{"name":"gates","state":"FAILURE","bucket":"fail","link":"https://github.com/example/x/actions/runs/42"}]\n' > "$GH_CHECKS"
cat > "$GH_LOG" <<'LOG'
gates  Run the gates  src/a.py:1:1: F401 imported but unused
gates  Run the gates  Found 1 error in 1 file (checked 1 source file)
LOG
out="$(ci)"; rc=$?
rc_is "it reports the failure"         "$rc" 9
check "naming the check"               "gates" "$out"
check "and linking the run"            "runs/42" "$out"
want  "ci.json records what failed"    "failed should name gates" \
      test "$(jq -r '.failed[0]' "$R/ci.json")" = gates
want  "the log is kept"                "ci-logs.txt should exist" test -s "$R/ci-logs.txt"
check "with the failing output in it"  "F401 imported but unused" "$(cat "$R/ci-logs.txt")"

printf '\n-- targeted: only the tasks the failure names --\n\n'
#
# Rebuilding the whole bean because one gate found one thing throws away work CI
# did not object to, and makes the second attempt impossible to compare with the
# first.
want  "task-1 is re-opened"            "src/ is named in the log" \
      grep -qx 'task-1' "$R/reopened-tasks.txt"
want  "task-2 is not"                  "nothing in the log names tests/" \
      bash -c "! grep -qx 'task-2' '$R/reopened-tasks.txt'"
want  "task-3 is not"                  "nothing in the log names pyproject.toml" \
      bash -c "! grep -qx 'task-3' '$R/reopened-tasks.txt'"
check "and it says which"              "re-opening             task-1" "$out"

printf '\n-- and the rewind says what has to happen again --\n\n'
want  "a rewind is written"            "rewind.json should exist" test -s "$R/rewind.json"
want  "back to build"                  "to should be build" \
      test "$(jq -r '.to' "$R/rewind.json")" = build
want  "forcing everything after it"    "build through pr must re-run" \
      test "$(jq -r '.force | length' "$R/rewind.json")" = 8
want  "and recording the task list"    "reopened_tasks should name task-1" \
      test "$(jq -r '.reopened_tasks[0]' "$R/rewind.json")" = task-1
check "findings are written for the worker" "The remote gates disagreed with the local ones" \
      "$(cat "$R/ci-findings.md")"
check "and say where to look first"    "difference between the two trees" \
      "$(cat "$R/ci-findings.md")"

printf '\n-- a failure naming nothing this bean wrote re-opens nothing --\n\n'
#
# Guessing would be worse than admitting the log does not say.
clean
cat > "$GH_LOG" <<'LOG'
gates  Run the gates  the runner could not reach the registry
LOG
out="$(ci)"; rc=$?
rc_is "it still reports the failure"   "$rc" 9
want  "and re-opens nothing"           "reopened-tasks.txt must not exist" \
      test ! -f "$R/reopened-tasks.txt"
check "saying so plainly"              "the logs name no file this bean wrote" "$out"

printf '\n-- a skipped required check is not a passing one --\n\n'
#
# GitHub skips jobs for all sorts of good reasons — a path filter, a matrix
# exclusion — and every one of them means the gates did not run on this commit,
# which is the one thing `required_checks` exists to rule out.
clean
printf '[{"name":"gates","state":"SKIPPED","bucket":"skipping","link":""}]\n' > "$GH_CHECKS"
out="$(ci)"; rc=$?
rc_is "a skip is not green"            "$rc" 9
check "and it says what a skip means"  "the gates did not run on this commit" "$out"
nope  "never CI PASS"                  "CI PASS" "$out"

printf '\n-- and a cancelled one is a failure, not a pending one --\n\n'
#
# `bucket` is gh's own normalisation of `state`; matching raw states means a check
# reporting one this list has never seen reads as neither terminal nor failed, and
# the step waits for it until the timeout. That is how a missing guarantee turns
# into a slow one.
clean
printf '[{"name":"gates","state":"CANCELLED","bucket":"cancel","link":""}]\n' > "$GH_CHECKS"
out="$(ci)"; rc=$?
rc_is "a cancel is terminal"           "$rc" 9
nope  "and not waited on"              "after 3s" "$out"

# --------------------------------------------------------------------------
printf '\n== required checks that nothing can produce ==\n\n'
#
# Forty-five minutes of polling ends at the same conclusion this can reach now.
# The difference is that a run which halts immediately gets fixed, and one that
# halts after forty-five minutes gets abandoned.
clean
printf '[{"name":"gates","state":"SUCCESS","bucket":"pass","link":""}]\n' > "$GH_CHECKS"
git rm -rq .github/workflows/gates.yml && git commit -q -m "no workflows"
out="$(ci)"; rc=$?
rc_is "it refuses at once"             "$rc" 3
check "saying what is impossible"      "CI IMPOSSIBLE" "$out"
check "and that it did not wait"       "Not waiting" "$out"
want  "and the run record says so"     "ci.json should say impossible" \
      test "$(jq -r '.status' "$R/ci.json" 2>/dev/null)" = impossible
check "the question names both fixes"  "or remove" "$(cat "$R/QUESTIONS.md")"
check "including how to install one"   "factory/scaffold.sh" "$(cat "$R/QUESTIONS.md")"
nope  "and it is never green"          "CI PASS" "$out"
git revert -q --no-edit HEAD

# --------------------------------------------------------------------------
printf '\n== a repository that names no required checks ==\n\n'
#
# Not a pass. There is nothing to assert, and saying "green" would assert it.
clean
printf 'schema_version: repo-config/1.0.0\nrepo: example/x\ndefault_branch: main\n' > factory/repo.yaml
out="$(ci)"; rc=$?
rc_is "it does not fail the run"       "$rc" 0
check "but it does not claim green"    "CI NOT ASKED" "$out"
check "and says what that means"       "a green here would" "$out"
nope  "no CI PASS"                     "CI PASS" "$out"
# Not "no record" — a record that says nothing was asked. The first version of
# this asserted ci.json must not exist, which made a step that ran and a step that
# was skipped indistinguishable in the run directory. The record is the point; what
# must not happen is a record that says `pass`.
want  "it records what happened"       "ci.json should say not_asked" \
      test "$(jq -r '.status' "$R/ci.json" 2>/dev/null)" = not_asked
want  "and claims nothing green"       "status must not be pass" \
      test "$(jq -r '.status' "$R/ci.json" 2>/dev/null)" != pass

# --------------------------------------------------------------------------
printf '\n== preconditions ==\n\n'
clean
printf 'schema_version: repo-config/1.0.0\nrequired_checks:\n  - gates\n' > factory/repo.yaml
jq 'del(.pr_url)' "$R/run.json" > "$WORK/rj" && mv "$WORK/rj" "$R/run.json"
out="$(ci)"; rc=$?
rc_is "no pull request refuses"        "$rc" 1
check "and says why"                   "records no pr_url" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
