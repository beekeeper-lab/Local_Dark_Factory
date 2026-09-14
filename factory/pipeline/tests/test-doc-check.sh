#!/usr/bin/env bash
# test-doc-check.sh — the implementation document is about the change it claims.
#
# doclint already asks whether the sections are filled in. These are the two
# checks a script can make that a lint cannot: that the document covers every
# file the diff touched, and that it does not walk the reader through a file the
# diff never touched. A walkthrough that omits a changed file is how a reviewer
# misses the hunk that mattered; one that invents a file is a paragraph about
# work that did not happen.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main .; git config user.email t@e.com; git config user.name T
mkdir -p src factory/templates factory/runs/R
cp "$PIPELINE_DIR/../scaffold/factory/templates/impl-detail.html" factory/templates/
echo readme > README.md
git add -A && git commit -q -m init
git checkout -q -b bean/b
printf 'def add(a, b):\n    return a + b\n' > src/calc.py
printf 'def test_add():\n    assert add(1, 2) == 3\n' > src/test_calc.py
git add -A && git commit -q -m work
echo '{"run_id":"R","bean":"bean-001"}' > factory/runs/R/run.json

filler() { printf 'This section carries enough real content that a reader opening it learns something, which is the only bar the lint enforces here.\n\n'; }

make_doc() { # make_doc <walkthrough-body>
  local f=factory/runs/R/impl-detail.md
  : > "$f"
  printf '# What was built\n\n' >> "$f"
  local s
  for s in "Summary" "Walkthrough by task" "Deviations from the spec" "Risk & blast radius, as built" "Evidence" "How to verify locally" "Rollback"; do
    printf '## %s\n\n' "$s" >> "$f"
    case "$s" in
      "Walkthrough by task") printf '%s\n\n' "$1" >> "$f" ;;
      "Deviations from the spec") printf 'The diff touches exactly the two files the spec named and nothing else, checked file by file against git diff --name-only. No behaviour differs from the plan.\n\n' >> "$f" ;;
      *) filler >> "$f" ;;
    esac
  done
}

dc() { bash "$PIPELINE_DIR/doc-check.sh" factory/runs/R 2>&1; }

printf '\n== no document is not a pass ==\n\n'
out="$(dc)"; rc=$?
check "a missing document fails"   "not written" "$out"
want  "and it exits non-zero"      "expected non-zero" test "$rc" -ne 0

printf '\n== a document covering the diff passes ==\n\n'
make_doc 'Two files changed. `src/calc.py` gains an add function, and `src/test_calc.py` pins its behaviour with an assertion that fails if the arithmetic changes.'
out="$(dc)"; rc=$?
check "the sections lint"          "ok    impl-detail.md" "$out"
check "coverage is checked"        "the walkthrough covers all" "$out"
check "and it renders"             "ok    impl-detail.html" "$out"
check "it passes"                  "DOC CHECK PASS" "$out"
want  "and exits 0"                "expected 0" test "$rc" -eq 0
want  "the HTML exists"            "expected impl-detail.html" test -f factory/runs/R/impl-detail.html

printf '\n== a changed file the document never mentions ==\n\n'
make_doc 'One file changed: `src/calc.py` gains an add function, explained line by line for a reader new to the codebase.'
out="$(dc)"
check "the omission is caught"     "changed files the walkthrough never covers" "$out"
check "and the file is named"      "src/test_calc.py" "$out"

printf '\n== a file the document shows but the diff never touched ==\n\n'
make_doc 'The change spans `src/calc.py` and `src/test_calc.py`.

```python src/ghost.py
def never_written():
    ...
```
'
out="$(dc)"
check "the invention is caught"    "shown in the document but absent from the diff" "$out"
check "and it is named"            "src/ghost.py" "$out"

printf '\n== a bare "None" deviation still fails the lint ==\n\n'
make_doc 'Both files are walked through: `src/calc.py` and `src/test_calc.py`.'
python3 - <<'PY'
import re
p = "factory/runs/R/impl-detail.md"
s = open(p).read()
s = re.sub(r"## Deviations from the spec\n\n.*?\n\n", "## Deviations from the spec\n\nNone\n\n", s, flags=re.S)
open(p, "w").write(s)
PY
out="$(dc)"
check "a bare None is refused"     "say what was checked against what" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
