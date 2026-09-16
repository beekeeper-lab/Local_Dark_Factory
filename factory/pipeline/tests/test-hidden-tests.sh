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
cat > "$WORK/fake-pytest" <<'STUB'
#!/usr/bin/env bash
# Passes or fails according to a file, so the outcome is the variable under test.
cat "$FAKE_PYTEST_OUT"
exit "$(cat "$FAKE_PYTEST_RC")"
STUB
chmod +x "$WORK/fake-pytest"
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
