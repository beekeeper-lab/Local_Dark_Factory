#!/usr/bin/env bash
# test-test-integrity.sh — the check that asks whether the tests mean anything.
#
# The rubric item this replaces is the one the judge is worst at, because
# answering it means running the tests against code that does not have the change
# in it. So the fixtures here are two branches that differ only in whether the
# test actually looks at the new behaviour, and the check has to tell them apart.
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

REPO="$WORK/repo"; git init -q -b main "$REPO"; cd "$REPO"
git config user.email t@e.com; git config user.name T
mkdir -p src tests factory/runs/R
printf '{"run_id":"R","bean":"bean-001","branch":"b"}\n' > factory/runs/R/run.json
printf 'def existing():\n    return 1\n' > src/a.py
printf 'from src.a import existing\n\ndef test_existing():\n    assert existing() == 1\n' > tests/test_a.py
printf '{"test_command":["python3","-m","pytest","-q"]}\n' > config.json
# A scaffolded repo keeps run directories out of the index. Without this the
# fixture commits test-integrity.json, which then blocks every branch switch —
# and, worse, makes the script's own output look like source code needing a test.
printf 'factory/runs/\n' > .gitignore
# A rootdir conftest is what puts the repository on sys.path for pytest. Without
# it every test errors on import, the revert run "fails", and the check reports
# that tautological tests pin the change — which is the exact false positive its
# own caveat warns about, arrived at by accident in its own fixture.
: > conftest.py
git add -A && git commit -q -m init

ti() { PIPELINE_CONFIG="$REPO/config.json" bash "$PIPELINE_DIR/test-integrity.sh" factory/runs/R "$@" 2>&1; }

printf '\n== a test that only asserts what was already true is caught ==\n\n'
git checkout -q -b tautological
printf 'def existing():\n    return 1\n\ndef added():\n    return 2\n' > src/a.py
# The test imports the new function but asserts something about the old one.
printf 'from src.a import existing\n\ndef test_added_feature():\n    assert existing() == 1\n' > tests/test_b.py
git add -A && git commit -q -m "add a feature and a test that does not test it"
out="$(ti)"
check "it says the tests pass without the change" "these tests do not pin it" "$out"
check "and names the command it ran"              "pytest" "$out"
check "the step fails"                            "TEST INTEGRITY FAIL" "$out"
want  "the finding is recorded"                   "test-integrity.json should exist" \
      test -f factory/runs/R/test-integrity.json
check "the record says no"                        '"result":"no"' \
      "$(tr -d ' \n' < factory/runs/R/test-integrity.json)"
check "and says why in words"                     "whatever they assert was already true" \
      "$(cat factory/runs/R/test-integrity.json)"

printf '\n== a test that actually exercises the change passes ==\n\n'
git checkout -q main && git checkout -q -b real
printf 'def existing():\n    return 1\n\ndef added():\n    return 2\n' > src/a.py
printf 'from src.a import added\n\ndef test_added_feature():\n    assert added() == 2\n' > tests/test_b.py
git add -A && git commit -q -m "add a feature and a test that tests it"
out="$(ti)"
check "it says the tests fail without the change" "as it must" "$out"
check "the step passes"                           "TEST INTEGRITY PASS" "$out"
check "the record says yes"                       '"result":"yes"' \
      "$(tr -d ' \n' < factory/runs/R/test-integrity.json)"

printf '\n== source changed and no test written is not a pass ==\n\n'
git checkout -q main && git checkout -q -b untested
printf 'def existing():\n    return 1\n\ndef added():\n    return 2\n' > src/a.py
git add -A && git commit -q -m "add a feature and no test at all"
out="$(ti)"
check "it says so plainly"    "nothing was written to pin it" "$out"
check "and it is undecided"    "TEST INTEGRITY UNDECIDED" "$out"
check "recorded as no_tests"  '"result":"no_tests"' \
      "$(tr -d ' \n' < factory/runs/R/test-integrity.json)"

printf '\n== deleted tests and new skips are counted ==\n\n'
git checkout -q main && git checkout -q -b weakened
printf 'def existing():\n    return 2\n' > src/a.py
printf 'import pytest\n\n@pytest.mark.skip\ndef test_existing():\n    pass\n' > tests/test_a.py
git add -A && git commit -q -m "make the old test stop looking"
out="$(ti)"
check "the removed test is counted"  "1 removed" "$out"
check "the new skip is counted"      "skip/xfail marker(s) added" "$out"
check "the lost assertion is counted" "net loss of 1" "$out"

printf '\n== a doc-only change has nothing to revert, and says so ==\n\n'
git checkout -q main && git checkout -q -b docsonly
printf '# notes\n' > README.md
git add -A && git commit -q -m "docs"
out="$(ti)"
check "it is not applicable"   "nothing to revert" "$out"
nope  "and it does not fail"   "TEST INTEGRITY FAIL" "$out"

printf '\n== if the tests do not pass to begin with, it says so instead of guessing ==\n\n'
#
# This is the case the script was originally wrong about, found by its own
# fixture naming a `python` that does not exist on this machine. Every revert run
# "failed", so every tautological test was reported as pinning the change. A
# one-sided check cannot tell a test doing its job from a command that cannot
# run, and it fails in the direction that looks like success.
git checkout -q main && git checkout -q -b broken-env
printf 'def existing():\n    return 1\n\ndef added():\n    return 2\n' > src/a.py
printf 'from src.a import added\n\ndef test_added_feature():\n    assert added() == 2\n' > tests/test_b.py
printf '{"test_command":["definitely-not-a-real-command"]}\n' > config.json
git add -A && git commit -q -m "a test command that cannot run"
out="$(ti)"
check "it refuses to decide"      "not decidable" "$out"
check "and says the control failed" "WITH the change" "$out"
check "recorded as inconclusive"  '"result":"inconclusive"' \
      "$(tr -d ' \n' < factory/runs/R/test-integrity.json)"
check "it does not settle it either way" "TEST INTEGRITY UNDECIDED" "$out"
nope  "and it never claims the tests pin anything"    '"result":"yes"' \
      "$(tr -d ' \n' < factory/runs/R/test-integrity.json)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
