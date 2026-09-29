#!/usr/bin/env bash
# test-red-test.sh — factory/tools/red-test.py tells a red test from a broken one.
#
# bean-021's task-1 verified its red test with `! pytest`, which passed on a test
# that failed in its own setup (a weight outside 1..100) and never reached the
# defect. The cases below are the ones that distinguish right from wrong: an
# assertion, a defect raising inside the code being fixed (bean-004's SQL error),
# an exception from code the fix may not touch (bean-021's), a collection error,
# and a test that passes.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RT="$(cd "$HERE/../.." && pwd)/scaffold/factory/tools/red-test.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }
rc_is() { if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi; }
python3 -c 'import pytest' 2>/dev/null || { printf '  SKIP  no pytest for python3\n\n0 passed, 0 failed\n'; exit 0; }

cd "$WORK"; mkdir -p src/pkg/fixme src/pkg/model tests
printf '' > src/pkg/__init__.py; printf '' > src/pkg/fixme/__init__.py; printf '' > src/pkg/model/__init__.py
cat > src/pkg/model/__init__.py <<'PY'
def weight(w):
    if not 1 <= w <= 100:
        raise ValueError(f"weight must be 1..100; got {w}")
    return w
PY
cat > src/pkg/fixme/__init__.py <<'PY'
def buggy_sum(a, b):
    return a - b

def buggy_query():
    raise RuntimeError("near WHERE: syntax error")
PY
rt() { PYTHONPATH="$WORK/src" python3 "$RT" --fixes 'src/pkg/fixme/**' "$@" 2>&1; }
t() { printf 'from pkg.fixme import buggy_sum, buggy_query\nfrom pkg.model import weight\n%s\n' "$2" > "tests/$1"; }

printf '\n== red for the right reason ==\n\n'
t test_assert.py 'def test_it():
    assert buggy_sum(2, 2) == 4'
out="$(rt tests/test_assert.py)"; rc=$?
rc_is "an assertion against the bug"          "$rc" 0
check "and says so"                            "red for the right reason" "$out"
t test_defect_raises.py 'def test_it():
    assert buggy_query() == []'
out="$(rt tests/test_defect_raises.py)"; rc=$?
rc_is "the defect raising inside --fixes"     "$rc" 0
check "names where it raised"                  "inside what the fix may change" "$out"

printf '\n== red for the wrong reason ==\n\n'
t test_bad_setup.py 'def test_it():
    w = weight(120)
    assert buggy_sum(w, 0) == w'
out="$(rt tests/test_bad_setup.py)"; rc=$?
rc_is "an exception from code outside --fixes" "$rc" 1
check "is called broken"                       "BROKEN" "$out"
check "with the exception and the place"       "ValueError: weight must be 1..100; got 120" "$out"
check "and why the fix cannot help"            "outside what the fix may change" "$out"
t test_own_error.py 'def test_it():
    raise KeyError("typo in the test")'
out="$(rt tests/test_own_error.py)"; rc=$?
rc_is "an exception in the test file itself"   "$rc" 1
printf 'import nosuchmodule\n\ndef test_it():\n    assert False\n' > tests/test_collect.py
out="$(rt tests/test_collect.py)"; rc=$?
rc_is "a collection error"                     "$rc" 1
check "is called broken"                       "BROKEN" "$out"
t test_mixed.py 'def test_real():
    assert buggy_sum(2, 2) == 4

def test_broken():
    weight(0)'
out="$(rt tests/test_mixed.py)"; rc=$?
rc_is "one right and one wrong is still broken" "$rc" 1

printf '\n== an assertion that reads nothing from the project ==\n\n'
t test_blind_guard.py 'import itertools

def test_it():
    # bean-021 run 2: the scenario forces every enumerated chart to one score,
    # so this guard fails on every implementation, the fixed one included.
    def score(pick):
        return 60 if pick[0] != pick[1] else 50
    scores = [score(p) for p in itertools.product("ab", repeat=2) if p[0] != p[1]]
    assert len(set(scores)) >= 2
    assert buggy_sum(2, 2) == 4'
out="$(rt tests/test_blind_guard.py)"; rc=$?
rc_is "a guard over the test's own enumeration" "$rc" 1
check "is called broken"                         "reads nothing from the project" "$out"
check "and quotes it"                            "assert len(set(scores)) >= 2" "$out"
t test_uses_result.py 'def test_it():
    got = buggy_sum(2, 2)
    def double(x):
        return x * 2
    assert double(got) == 8'
out="$(rt tests/test_uses_result.py)"; rc=$?
rc_is "a nested helper over the project's result" "$rc" 0
t test_callback.py 'def test_it():
    seen = []
    def record(v):
        seen.append(v)
    record(buggy_sum(2, 2))
    assert seen == [4]'
out="$(rt tests/test_callback.py)"; rc=$?
rc_is "a list a callback fills"                  "$rc" 0
t test_raises.py 'import pytest

def test_it():
    with pytest.raises(TypeError) as exc:
        buggy_sum(None, None)
    assert "operand" not in str(exc.value)'
out="$(rt tests/test_raises.py)"; rc=$?
rc_is "what pytest.raises caught, as exc"        "$rc" 0
t test_flag.py 'def test_it():
    try:
        buggy_sum(1, 1) == 2 or (_ for _ in ()).throw(ValueError())
        raised = False
    except ValueError:
        raised = True
    assert not raised'
out="$(rt tests/test_flag.py)"; rc=$?
rc_is "a flag set in an except handler"          "$rc" 0

printf '\n== not red at all ==\n\n'
t test_green.py 'def test_it():
    assert buggy_sum(2, 0) == 2'
out="$(rt tests/test_green.py)"; rc=$?
rc_is "a test that passes"                     "$rc" 1
check "is not red"                             "NOT RED" "$out"

printf '\n== usage ==\n\n'
out="$(python3 "$RT" tests/test_assert.py 2>&1)"; rc=$?
rc_is "--fixes is required"                    "$rc" 2

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
