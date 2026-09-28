#!/usr/bin/env bash
# test-test-basenames.sh — test files that pytest would import as one module.
#
# bean-011's criteria named tests/domain/test_locks.py and tests/solver/test_locks.py.
# With no __init__.py under tests/ and pytest's default import mode that is one
# module name, and the suite stops at collection. The task that first ran the whole
# suite spent three attempts on it, on a path it could not write.
#
# The cases that matter as much as the collision: a repository that imports with
# importlib, and directories that are packages, must NOT be reported. A check that
# fails beans for a collision pytest would never have is the overreach this
# project has already had to take out of a check once.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}
tb() { bash "$PIPELINE_DIR/test-basenames.sh" "$@" 2>&1; }

R="$WORK/repo"; git init -q "$R"
mkdir -p "$R/tests/domain" "$R/tests/solver" "$R/tests/store"
printf '[tool.pytest.ini_options]\ntestpaths = ["tests"]\n' > "$R/pyproject.toml"
: > "$R/tests/domain/test_locks.py"
: > "$R/tests/store/test_repo.py"
git -C "$R" add -A

printf '\n== the bean-011 pair ==\n\n'
out="$(tb "$R" tests/solver/test_locks.py)"; rc=$?
rc_is "a new file sharing a tracked file's basename is refused" "$rc" 1
check "it names both files"            "tests/domain/test_locks.py and tests/solver/test_locks.py" "$out"
check "and says why"                   "pytest stops at collection" "$out"
check "and the three ways out"         "set --import-mode=importlib" "$out"

out="$(tb "$R" tests/a/test_x.py tests/b/test_x.py)"; rc=$?
rc_is "two new files with one basename are refused too" "$rc" 1

printf '\n== what must not be reported ==\n\n'
out="$(tb "$R" tests/solver/test_modes.py)"; rc=$?
rc_is "a new, distinct basename passes" "$rc" 0
check "and says what it checked"       "1 test file(s), no basename shared" "$out"

out="$(tb "$R" src/pkg/solver.py tests/solver/conftest.py)"; rc=$?
rc_is "files that are not tests are not counted" "$rc" 0
check "and it says there were none"    "no test files named" "$out"

out="$(tb "$R" tests/solver/__init__.py tests/solver/test_locks.py)"; rc=$?
rc_is "a directory the bean makes a package is fine" "$rc" 0

: > "$R/tests/domain/__init__.py"
out="$(tb "$R" tests/solver/test_locks.py)"; rc=$?
rc_is "one side a package: two different module names" "$rc" 0
rm "$R/tests/domain/__init__.py"

: > "$R/tests/store/test_x.py"; mkdir -p "$R/tests/other"; : > "$R/tests/other/test_x.py"
git -C "$R" add -A
out="$(tb "$R" tests/solver/test_modes.py)"; rc=$?
rc_is "a collision already in the tree is not this bean's" "$rc" 0

printf '[tool.pytest.ini_options]\naddopts = "--import-mode=importlib"\n' > "$R/pyproject.toml"
out="$(tb "$R" tests/solver/test_locks.py)"; rc=$?
rc_is "importlib mode has no such collision" "$rc" 0
check "and it says it did not check"   "not checked — pyproject.toml sets --import-mode=importlib" "$out"

printf '[pytest]\naddopts = --import-mode importlib\n' > "$R/pytest.ini"; rm "$R/pyproject.toml"
out="$(tb "$R" tests/solver/test_locks.py)"; rc=$?
rc_is "the space form in pytest.ini counts too" "$rc" 0

out="$(tb 2>&1)"; rc=$?
rc_is "no repository is a usage error" "$rc" 2

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
