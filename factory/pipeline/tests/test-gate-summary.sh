#!/usr/bin/env bash
# test-gate-summary.sh — what a halted run tells a human about the gate.
#
# This was nine lines of jq inside orchestrate.sh's halt(), testable only by
# driving a whole run to a failing gate. So it was not tested, and it was wrong:
# it knew about containment, gates, criteria and invariants, and nothing about
# hidden tests or test integrity — both added after it was written. A run halted
# by a hidden-test failure printed "The gate failed. What it found:" and then
# nothing at all, which reads like a gate that failed for no reason.
#
# The rule with teeth here is the last section: no hidden test text may appear.
# QUESTIONS.md is written into the run directory, which is inside the repository,
# which the worker mounts whole.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}
sum() { bash "$PIPELINE_DIR/gate-summary.sh" "$WORK/gate.json" 2>&1; }
gate() { printf '%s\n' "$1" > "$WORK/gate.json"; }

printf '\n== a gate that passed says nothing ==\n\n'
gate '{"containment":{"contained":true,"violations":[]},"gates":[{"id":"unit","status":"pass"}],
       "acceptance_criteria":[{"id":"ac1","status":"pass"}],"invariants":null,
       "hidden_tests":{"status":"passed"},"overall":"pass"}'
out="$(sum)"; rc=$?
rc_is "it exits 0"                     "$rc" 0
if [ -z "$out" ]; then printf '  ok    and prints nothing\n'; PASS=$((PASS+1))
else printf '  FAIL  it printed: %s\n' "$out"; FAIL=$((FAIL+1)); fi

printf '\n-- and "nothing wrong" is not "I could not look" --\n\n'
#
# A caller that cannot tell them apart prints the first, which is the whole
# fail-open shape this project keeps finding.
out="$(bash "$PIPELINE_DIR/gate-summary.sh" "$WORK/does-not-exist.json" 2>&1)"; rc=$?
rc_is "a missing file exits 2"         "$rc" 2
check "and says so"                    "no such file" "$out"
printf 'not json\n' > "$WORK/gate.json"
out="$(sum)"; rc=$?
rc_is "and so does one that is not JSON" "$rc" 2

printf '\n== every failing part appears ==\n\n'
gate '{"containment":{"contained":false,"violations":["src/evil.py"]},
       "gates":[{"id":"lint","status":"fail","exit_code":1},{"id":"unit","status":"pass"}],
       "acceptance_criteria":[{"id":"ac1","status":"fail","reason":"the named test does not exist"}],
       "invariants":{"ref":"factory/invariants/seating.yaml","status":"fail","reason":"two guests in one seat"},
       "secret_scan":{"suspicious_lines":["a","b"]},
       "test_integrity":{"fails_on_revert":{"result":"no","why":"the tests pass with the change reverted"}},
       "hidden_tests":{"status":"failed","failed_count":3,"output_path":"/outside/the/repo/r.log"},
       "overall":"fail"}'
out="$(sum)"
check "containment"                    "containment: src/evil.py" "$out"
check "the failing gate"               "gate lint: exit 1" "$out"
nope  "and not the passing one"        "gate unit" "$out"
check "the failing criterion"          "ac1: the named test does not exist" "$out"
check "the invariant"                  "invariants: two guests in one seat" "$out"
check "the secret scan, by count"      "2 suspicious line(s)" "$out"
check "test integrity"                 "the tests pass with the change reverted" "$out"
check "hidden tests, by count"         "hidden tests: failed — 3 failing" "$out"

printf '\n-- and a contradicted non-goal, which is the bean\x27s own words --\n\n'
gate '{"containment":{"contained":true,"violations":[]},"gates":[],"acceptance_criteria":[],"invariants":null,
       "non_goals":{"checkable_rules":2,"violations":[
          {"non_goal":"no solver code","kind":"path","patterns":["src/**/solver/**"],"offending":["src/a/solver/x.py"]},
          {"non_goal":"no solver code","kind":"import","module":"ortools","lines":["+import ortools"]}]},
       "overall":"fail"}'
out="$(sum)"
check "the path violation"             "non-goal \"no solver code\": src/a/solver/x.py is inside src/**/solver/**" "$out"
check "and the import one"             "imports ortools" "$out"

printf '\n-- a bean with no machine-readable non-goals says nothing here --\n\n'
gate '{"containment":{"contained":true,"violations":[]},"gates":[{"id":"unit","status":"fail","exit_code":1}],
       "acceptance_criteria":[],"invariants":null,
       "non_goals":{"checkable_rules":0,"violations":[]},"overall":"fail"}'
out="$(sum)"
check "the real failure is shown"      "gate unit: exit 1" "$out"
nope  "and non-goals are not"          "non-goal" "$out"

printf '\n== a hidden-test failure never carries the tests ==\n\n'
#
# The output goes to a path outside the repository; this file is written inside
# it. A summary that quoted the failing assertion would put a hidden test in the
# one place the worker is guaranteed to be able to read.
gate '{"containment":{"contained":true,"violations":[]},"gates":[],"acceptance_criteria":[],"invariants":null,
       "hidden_tests":{"status":"failed","failed_count":2,
                       "output_path":"/outside/the/repo/r.log",
                       "why":"hidden tests failed (exit 1); see /outside/the/repo/r.log",
                       "worker_feedback":"2 hidden test(s) failed."},
       "overall":"fail"}'
out="$(sum)"
check "the count is there"             "2 failing" "$out"
check "and where the output is"        "/outside/the/repo/r.log" "$out"
check "and that it is not in the repo" "neither is their output" "$out"
nope  "no assertion text"              "assert" "$out"
nope  "no test function name"          "test_" "$out"

printf '\n-- could-not-run is reported too, and is not a pass --\n\n'
gate '{"containment":{"contained":true,"violations":[]},"gates":[],"acceptance_criteria":[],"invariants":null,
       "hidden_tests":{"status":"could_not_run","failed_count":0,"output_path":"/outside/x.log"},"overall":"fail"}'
out="$(sum)"
check "it says could_not_run"          "hidden tests: could_not_run" "$out"

printf '\n-- and a repo with none configured is silent about them --\n\n'
gate '{"containment":{"contained":true,"violations":[]},"gates":[{"id":"unit","status":"fail","exit_code":2}],
       "acceptance_criteria":[],"invariants":null,
       "hidden_tests":{"status":"not_configured"},"overall":"fail"}'
out="$(sum)"
check "the real failure is shown"      "gate unit: exit 2" "$out"
nope  "and hidden tests are not"       "hidden tests" "$out"

printf '\n== a gate.json from before these fields existed still works ==\n\n'
#
# bean-001's gate.json predates hidden_tests entirely. A summary that failed on
# it would be a summary that cannot read the only real gate record there is.
gate '{"containment":{"contained":true,"violations":[]},
       "gates":[{"id":"lint","status":"fail","exit_code":1}],
       "acceptance_criteria":[],"invariants":null,"overall":"fail"}'
out="$(sum)"; rc=$?
rc_is "it still exits 0"               "$rc" 0
check "and reports what it has"        "gate lint: exit 1" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
