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
# Every verify.sh in this suite writes its record into the temp directory, not
# into the repository's own. Two sections here deliberately verify half-way or
# against an edited suite, and without this they downgrade records someone
# earned by running the command properly — a test that mutates the evidence it
# is testing makes a green suite mean less than it says. It was set for one
# section first, which left the section ABOVE it still writing to the real
# records, and the real bean-002 record duly came back as `half_checked`.
export HIDDEN_VERIFIED_DIR="$WORK/verified"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:250}"; FAIL=$((FAIL+1)); fi }
want()  { local n="$1" d="$2"; shift 2
          if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
          else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi; }
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

printf '\n== it leaves a record, because this check used to run and write nothing --\n\n'
#
# verify.sh's own header says what is at stake: a suite that can never pass
# "blocks every attempt of its bean forever, and all the worker is told is a
# count". Whether that had been ruled out for a given bean lived in whoever last
# ran the command and remembered.
#
# The hash is the useful half. A suite EDITED since it was verified is back to
# unknown, and editing a hidden test is exactly what happens when one turns out
# to be wrong — which happened to bean-002's on 2026-09-17, the same day.
REC="$WORK/verified/seating-planner-py/bean-002.json"
want  "a record is written"              "$REC should exist" test -s "$REC"
want  "and a half check is not verified" "both_directions should be false" \
      test "$(jq -r .both_directions "$REC")" = false
want  "it says which"                    "outcome should be half_checked" \
      test "$(jq -r .outcome "$REC")" = half_checked
want  "and hashes the suite it checked"  "suite_sha256 should be 64 hex" \
      bash -c "jq -r .suite_sha256 '$REC' | grep -Eq '^[0-9a-f]{64}\$'"
SHA_BEFORE="$(jq -r .suite_sha256 "$REC")"
printf '\n# a comment\n' >> "$(dirname "$V")/seating-planner-py/bean-002/test_hidden_domain.py"
bash "$V" seating-planner-py/bean-002 >/dev/null 2>&1 || true
want  "an edited suite hashes differently" "the hash must move when the suite does" \
      bash -c "[ \"\$(jq -r .suite_sha256 '$REC')\" != '$SHA_BEFORE' ]"
git -C "$(cd "$(dirname "$V")/.." && pwd)" checkout -- "hidden-tests/seating-planner-py/bean-002/test_hidden_domain.py" 2>/dev/null || true
bash "$V" seating-planner-py/bean-002 >/dev/null 2>&1 || true

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
