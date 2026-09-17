#!/usr/bin/env bash
# test-hidden-verify.sh — the half of hidden-test verification that was missing.
#
# The gate's control run proves a hidden suite CAN FAIL. Nothing proved it can
# pass, and a suite that can never pass is the worse failure: it blocks every
# attempt of its bean forever, and the worker is told only a count, so it cannot
# tell a wrong test from its own wrong code.
#
# hidden-tests/verify.sh checks both ends. These assertions are about it telling
# the three answers apart — verified, not verified, and half checked — because
# the whole point is that "the control passed" stops being mistaken for "the
# suite is good".
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PIPELINE_DIR/../.." && pwd)"
V="$ROOT/hidden-tests/verify.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:250}"; FAIL=$((FAIL+1)); fi }
rc_is() { if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi }

command -v pytest >/dev/null 2>&1 || { printf '  SKIP  no pytest\n\n0 passed, 0 failed\n'; exit 0; }
[ -f "$V" ] || { printf '  SKIP  no verify.sh\n\n0 passed, 0 failed\n'; exit 0; }

# A suite of our own, under the same tree verify.sh looks in.
SUITE="$ROOT/hidden-tests/_test-fixture/bean-x"
mkdir -p "$SUITE"
cleanup_fixture() { rm -rf "$ROOT/hidden-tests/_test-fixture"; }
trap 'cleanup_fixture; rm -rf "$WORK"' EXIT
cat > "$SUITE/test_h.py" <<'PY'
import os, pathlib
T = pathlib.Path(os.environ.get("HIDDEN_TREE", "/work"))

def test_the_file_is_there():
    assert (T / "made.txt").is_file()

def test_no_forbidden_file():
    assert not (T / "forbidden.txt").exists()
PY
printf '# asserts an absence\ntest_no_forbidden_file\n' > "$SUITE/absent-by-design.txt"
GOOD="$WORK/good"; mkdir -p "$GOOD"; printf 'x\n' > "$GOOD/made.txt"

printf '\n== a suite that fails on nothing and passes on the real tree is OK ==\n\n'
out="$(bash "$V" _test-fixture/bean-x --tree "$GOOD" 2>&1)"; rc=$?
rc_is "it exits 0"                    "$rc" 0
check "both directions are reported"  "pass against the real tree" "$out"
check "and the declared absence is accounted for" "declared absences" "$out"
check "and it says so plainly"        "it can fail, and it does pass on the real thing" "$out"

printf '\n== a test that cannot pass is the failure that had no check ==\n\n'
cat >> "$SUITE/test_h.py" <<'PY'

def test_asks_for_something_no_bean_produces():
    assert (T / "never-made.txt").is_file()
PY
out="$(bash "$V" _test-fixture/bean-x --tree "$GOOD" 2>&1)"; rc=$?
rc_is "it fails"                      "$rc" 1
check "and names the test"            "test_asks_for_something_no_bean_produces" "$out"
check "and says why it is the worst one" "blocks every attempt of its bean" "$out"
check "and that the worker cannot see it" "told only a count" "$out"

printf '\n== an undeclared test that passes on nothing is still caught ==\n\n'
python3 - "$SUITE/test_h.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace('''
def test_asks_for_something_no_bean_produces():
    assert (T / "never-made.txt").is_file()
''', '''
def test_passes_on_anything():
    assert True
''')
open(p, "w").write(s)
PY
out="$(bash "$V" _test-fixture/bean-x --tree "$GOOD" 2>&1)"; rc=$?
rc_is "it fails"                      "$rc" 1
check "and names it"                  "test_passes_on_anything" "$out"
check "with where to declare it"      "absent-by-design.txt" "$out"

printf '\n== no tree is HALF CHECKED, which is not a pass ==\n\n'
# Back to the good fixture first: the section above left a test that passes on
# nothing, and verify.sh would fail on that instead — a test asserting the wrong
# thing because of what the test before it did.
cat > "$SUITE/test_h.py" <<'PY'
import os, pathlib
T = pathlib.Path(os.environ.get("HIDDEN_TREE", "/work"))

def test_the_file_is_there():
    assert (T / "made.txt").is_file()

def test_no_forbidden_file():
    assert not (T / "forbidden.txt").exists()
PY
out="$(bash "$V" _test-fixture/bean-x 2>&1)"; rc=$?
rc_is "it exits 3, not 0 and not 1"   "$rc" 3
check "and says which half was skipped" "was NOT checked" "$out"
check "and when to come back"         "re-run with --branch once it has" "$out"

printf '\n== the real suites, both directions where a tree exists ==\n\n'
TGT=/home/gregg/workspace/seating-planner-py
BR=bean/bean-001-project-scaffold-with-linting-typing-and
if [ -d "$TGT/.git" ] && git -C "$TGT" rev-parse --verify "$BR" >/dev/null 2>&1; then
  out="$(bash "$V" seating-planner-py/bean-001 --branch "$BR" --repo "$TGT" 2>&1)"; rc=$?
  rc_is "bean-001's hidden suite is verified both ways" "$rc" 0
  check "all of it passes on what the bean produced"    "test(s) pass against the real tree" "$out"
else
  printf '  SKIP  bean-001 branch not present\n'
fi
out="$(bash "$V" seating-planner-py/bean-002 2>&1)"; rc=$?
rc_is "bean-002 is half checked, because it has not run" "$rc" 3

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
