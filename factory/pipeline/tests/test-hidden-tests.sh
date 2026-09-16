#!/usr/bin/env bash
# test-hidden-tests.sh — the one check the worker cannot optimise against.
#
# Two properties, and the file is mostly about the second:
#
#   1. Where the tests live. A directory inside the repository is not hidden from
#      anything that can read /work, which is the worker. That has to be a refusal
#      and not a warning, because the failure mode is invisible: the tests run,
#      they pass, and nobody finds out the worker read them first.
#   2. What comes back. The worker is told a COUNT. A failure message quoting the
#      test is a hidden test the worker has now seen, and the next attempt is
#      written against it — so the assertions below check what is absent from
#      worker_feedback, not only what is present.
#
# Plus the exit-code distinction this project keeps having to re-learn: could not
# run is not failed, and neither is a pass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "$HERE/.." && pwd)"
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
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

REPO="$WORK/repo"; mkdir -p "$REPO"; ( cd "$REPO" && git init -q -b main . \
  && git config user.email t@e.com && git config user.name T \
  && : > README.md && git add -A && git commit -q -m init )
RUN="$REPO/factory/runs/R"; mkdir -p "$RUN"

cfg() { printf '%s\n' "$1" > "$WORK/config.json"; }
ht() { ( cd "$REPO" && PIPELINE_CONFIG="$WORK/config.json" bash "$PIPELINE_DIR/hidden-tests.sh" "$RUN" "$@" 2>&1 ); }
rec() { jq -r "$1" "$RUN/hidden-tests.json" 2>/dev/null; }

printf '\n== no hidden tests is its own answer, not a pass ==\n\n'
#
# A gate that reports "nothing configured" the same way it reports "they passed"
# is the fail-open this project keeps finding. Exit 3 is its own code for exactly
# that reason.
cfg '{"test_command":["pytest","-q"]}'
rm -f "$RUN/hidden-tests.json"
out="$(ht)"; rc=$?
rc_is "exit 3, not 0"                  "$rc" 3
eq "the record says so"                "not_configured" "$(rec .status)"
check "and the run says so out loud"   "not configured" "$out"

printf '\n== a directory inside the repository is not hidden ==\n\n'
#
# The worker mounts the whole tree at /work. A test in it is a test the worker can
# read, and code written against assertions it can read satisfies exactly those.
# This is the property the feature IS, so it refuses rather than warning.
mkdir -p "$REPO/tests-hidden"
printf 'def test_x():\n    assert True\n' > "$REPO/tests-hidden/test_x.py"
cfg "$(jq -nc --arg d "$REPO/tests-hidden" '{hidden_tests:{dir:$d}}')"
rm -f "$RUN/hidden-tests.json"
out="$(ht)"; rc=$?
rc_is "it refuses"                     "$rc" 2
check "and says why it is not hidden"  "is inside the repository" "$out"
check "and names what reads it"        "/work" "$out"
eq "recorded as could not run"         "could_not_run" "$(rec .status)"
# Not a failure of the worker's code, and not a pass either.
nope "not recorded as a pass"          "passed" "$(rec .status)"

printf '\n== configured and missing is a refusal, never silence ==\n\n'
cfg '{"hidden_tests":{"dir":"/definitely/not/here"}}'
rm -f "$RUN/hidden-tests.json"
out="$(ht)"; rc=$?
rc_is "it refuses"                     "$rc" 2
check "and names the directory"        "/definitely/not/here" "$out"
eq "and the record exists anyway"      "could_not_run" "$(rec .status)"

printf '\n-- and so is an empty hidden suite --\n\n'
#
# An empty suite that reports success reads exactly like a check that passed,
# which is the most expensive kind of nothing.
HID="$WORK/hidden"; mkdir -p "$HID"
cfg "$(jq -nc --arg d "$HID" '{hidden_tests:{dir:$d}}')"
rm -f "$RUN/hidden-tests.json"
out="$(ht)"; rc=$?
rc_is "it refuses"                     "$rc" 2
check "and says why an empty one is worse" "reads as a check that passed" "$out"

printf '\n== they run against what was built ==\n\n'
#
# Uncontained here: the sandbox is exercised by test-sandbox.sh, and what this
# file is about is the decision made from the result.
# A stub that behaves like a real suite: it looks at the tree it was given. A
# stub that ignores the tree passes against an empty one, which the control run
# correctly refuses — so a tree-blind stub cannot exercise anything downstream of
# it, and finding that out was the control run's first real catch.
cat > "$WORK/fake-pytest" <<'STUB'
#!/usr/bin/env bash
# Fails when the tree has nothing in it, like any suite that tests something.
[ -f "${HIDDEN_TREE:-/work}/built" ] || { echo "ERROR nothing to test"; exit 1; }
cat "$FAKE_PYTEST_OUT"
exit "$(cat "$FAKE_PYTEST_RC")"
STUB
chmod +x "$WORK/fake-pytest"
printf 'the worker built this\n' > "$REPO/built"
printf 'def test_hidden_seating_capacity():\n    assert True\n' > "$HID/test_hidden.py"
printf '1 passed\n' > "$WORK/pytest.out"; printf '0\n' > "$WORK/pytest.rc"
cfg "$(jq -nc --arg d "$HID" --arg p "$WORK/fake-pytest" '{hidden_tests:{dir:$d, command:[$p,"-q"]}}')"
rm -f "$RUN/hidden-tests.json"
out="$(FAKE_PYTEST_OUT="$WORK/pytest.out" FAKE_PYTEST_RC="$WORK/pytest.rc" ht)"; rc=$?
rc_is "a passing suite passes"         "$rc" 0
eq "and is recorded as passed"         "passed" "$(rec .status)"
eq "with the files counted"            "1" "$(rec .test_files)"
# The record identifies WHICH tests ran without being a copy of them.
if [ -n "$(rec .dir_sha256)" ] && [ "$(rec .dir_sha256)" != "null" ]; then
  printf '  ok    and hashed, so the record says which ones without quoting them\n'; PASS=$((PASS+1))
else
  printf '  FAIL  no dir_sha256 — the record cannot say which tests it ran\n'; FAIL=$((FAIL+1))
fi

printf '\n== a failure tells the worker a COUNT and nothing else ==\n\n'
#
# This is the assertion the feature exists for. A failure message that quotes the
# test is a hidden test the worker has read, and the next attempt is written
# against it rather than against the criteria.
cat > "$WORK/pytest.out" <<'OUT'
FAILED test_hidden.py::test_hidden_seating_capacity - assert event.capacity == 4999
FAILED test_hidden.py::test_hidden_group_split - assert len(groups) == 3
1 passed, 2 failed
OUT
printf '1\n' > "$WORK/pytest.rc"
rm -f "$RUN/hidden-tests.json"
out="$(FAKE_PYTEST_OUT="$WORK/pytest.out" FAKE_PYTEST_RC="$WORK/pytest.rc" ht)"; rc=$?
rc_is "a failing suite fails"          "$rc" 1
eq "and is recorded as failed"         "failed" "$(rec .status)"
fb="$(rec .worker_feedback)"
check "the worker is told how many"    "2 hidden test(s) failed" "$fb"
nope "and not the test names"          "test_hidden_seating_capacity" "$fb"
nope "nor the other one"               "test_hidden_group_split" "$fb"
nope "nor the assertions"              "event.capacity" "$fb"
nope "nor the file"                    "test_hidden.py" "$fb"
check "it is pointed at the criteria"  "Re-read the criteria" "$fb"
# And nothing else in the run directory quotes them either. The run directory is
# INSIDE the repository, and the worker mounts the repository whole — so a full
# failure log written next to the record is a file the worker opens on its next
# attempt, and redacting one string while writing the log beside it is theatre.
log="$(rec .output_path)"
if [ -n "$log" ] && [ "$log" != "null" ] && [ -s "$log" ]; then
  printf '  ok    the full output is kept, at output_path\n'; PASS=$((PASS+1))
else
  printf '  FAIL  the full output was not kept anywhere (output_path=%s)\n' "$log"; FAIL=$((FAIL+1))
fi
check "and it has everything"          "test_hidden_seating_capacity" "$(cat "$log" 2>/dev/null)"
case "$log/" in
  "$REPO"/*) printf '  FAIL  the log is inside the repository: %s\n' "$log"; FAIL=$((FAIL+1)) ;;
  *)         printf '  ok    and it is outside the repository\n'; PASS=$((PASS+1)) ;;
esac
# The strongest form of the assertion: grep the whole run directory.
if grep -rqF 'test_hidden_seating_capacity' "$RUN" 2>/dev/null; then
  printf '  FAIL  a hidden test name is somewhere under the run directory\n'; FAIL=$((FAIL+1))
else
  printf '  ok    no hidden test name appears anywhere under the run directory\n'; PASS=$((PASS+1))
fi
if grep -rqF 'event.capacity' "$RUN" 2>/dev/null; then
  printf '  FAIL  a hidden assertion is somewhere under the run directory\n'; FAIL=$((FAIL+1))
else
  printf '  ok    nor a hidden assertion\n'; PASS=$((PASS+1))
fi
eq "and the count is recorded"         "2" "$(rec .failed_count)"

printf '\n-- and results_dir inside the repository, for the same reason --\n\n'
#
# The natural place for a log is next to the run. The run is in the repo. The
# worker reads the repo.
cfg "$(jq -nc --arg d "$HID" --arg r "$REPO/hidden-results" --arg p "$WORK/fake-pytest" \
  '{hidden_tests:{dir:$d, results_dir:$r, command:[$p,"-q"]}}')"
rm -f "$RUN/hidden-tests.json"
out="$(FAKE_PYTEST_OUT="$WORK/pytest.out" FAKE_PYTEST_RC="$WORK/pytest.rc" ht)"; rc=$?
rc_is "it refuses"                     "$rc" 2
check "and says what reads it"         "hidden test it can read" "$out"

printf '\n== a suite that passes against nothing is refused ==\n\n'
#
# test-integrity runs a control for the same reason: a check whose control also
# passes has not been shown to check anything. It matters more here, because a
# hidden suite is the one thing nobody eyeballs — the worker cannot see it by
# design and the judge is given a count — so a vacuous one reports green forever.
cat > "$WORK/blind-pytest" <<'STUB'
#!/usr/bin/env bash
echo "1 passed"
exit 0
STUB
chmod +x "$WORK/blind-pytest"
cfg "$(jq -nc --arg d "$HID" --arg p "$WORK/blind-pytest" '{hidden_tests:{dir:$d, command:[$p,"-q"]}}')"
rm -f "$RUN/hidden-tests.json"
out="$(ht)"; rc=$?
rc_is "it refuses"                     "$rc" 2
check "and says what the control did"  "passes against a tree with nothing in it" "$out"
check "and why that is the worst case" "nobody eyeballs" "$out"
eq "recorded as could not run"         "could_not_run" "$(rec .status)"
nope "and certainly not as a pass"     "\"status\":\"passed\"" "$(cat "$RUN/hidden-tests.json")"

printf '\n-- and the control can be turned off, on the record --\n\n'
#
# Some suites legitimately cannot run against an empty tree. Turning the control
# off is allowed and is written down, because "we did not check" and "we checked"
# must not look the same in the record.
cfg "$(jq -nc --arg d "$HID" --arg p "$WORK/blind-pytest" \
  '{hidden_tests:{dir:$d, command:[$p,"-q"], control:false}}')"
rm -f "$RUN/hidden-tests.json"
out="$(ht)"; rc=$?
rc_is "it runs"                        "$rc" 0
eq "and the record says the control did not" "not run" "$(rec .control)"

printf '\n== hidden tests are per bean, because they are written per bean ==\n\n'
#
# One directory for the whole repository would run bean-001's tests against
# bean-007's tree and call the result a failure. `<bean>` in the path is the
# run's bean id.
printf '{"run_id":"R","bean_id":"bean-042"}\n' > "$RUN/run.json"
mkdir -p "$WORK/per-bean/bean-042"
printf 'def test_bean_042():\n    assert True\n' > "$WORK/per-bean/bean-042/test_b.py"
cfg "$(jq -nc --arg d "$WORK/per-bean/<bean>" --arg p "$WORK/fake-pytest" \
  '{hidden_tests:{dir:$d, command:[$p,"-q"]}}')"
printf '1 passed\n' > "$WORK/pytest.out"; printf '0\n' > "$WORK/pytest.rc"
rm -f "$RUN/hidden-tests.json"
out="$(FAKE_PYTEST_OUT="$WORK/pytest.out" FAKE_PYTEST_RC="$WORK/pytest.rc" ht)"; rc=$?
rc_is "the bean's own directory runs" "$rc" 0
check "and the record names it"       "bean-042" "$(rec .dir)"
eq "with a control that failed, as it must" "failed against an empty tree, as it must" "$(rec .control)"

printf '\n-- a bean with none is a fact about the bean, not a broken config --\n\n'
#
# Most beans will not have hidden tests. That has to read differently from a
# path someone mistyped, or the first is silently filed as the second.
printf '{"run_id":"R","bean_id":"bean-999"}\n' > "$RUN/run.json"
rm -f "$RUN/hidden-tests.json"
out="$(ht)"; rc=$?
rc_is "exit 3, not 2"                 "$rc" 3
eq "recorded as not configured"       "not_configured" "$(rec .status)"
check "and it says which bean"        "bean-999" "$out"

printf '\n-- but a repo-wide path that is not there is still a typo --\n\n'
cfg '{"hidden_tests":{"dir":"/definitely/not/here"}}'
rm -f "$RUN/hidden-tests.json"
out="$(ht)"; rc=$?
rc_is "exit 2, not 3"                 "$rc" 2

printf '\n-- and <bean> with no bean in the run record is refused --\n\n'
printf '{"run_id":"R"}\n' > "$RUN/run.json"
cfg "$(jq -nc --arg d "$WORK/per-bean/<bean>" '{hidden_tests:{dir:$d}}')"
rm -f "$RUN/hidden-tests.json"
out="$(ht)"; rc=$?
rc_is "it refuses"                    "$rc" 2
check "and says what is missing"      "no bean_id" "$out"
printf '{"run_id":"R","bean_id":"bean-001"}\n' > "$RUN/run.json"

printf '\n== the record is written on every path ==\n\n'
#
# A gate that reads hidden-tests.json and finds nothing cannot tell "did not run"
# from "ran and was fine", and it is the gate that decides whether the branch
# moves.
missing=0
for c in '{"test_command":["pytest"]}' \
         '{"hidden_tests":{}}' \
         '{"hidden_tests":{"dir":"/definitely/not/here"}}'; do
  cfg "$c"; rm -f "$RUN/hidden-tests.json"
  ht >/dev/null 2>&1
  [ -s "$RUN/hidden-tests.json" ] || missing=$((missing+1))
done
eq "no path exits without one"         "0" "$missing"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
