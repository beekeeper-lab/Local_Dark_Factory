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
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}

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

printf '\n== a walkthrough written as per-task subsections is read whole ==\n\n'
#
# The skill asks for the section BY TASK, so a real document puts each task under
# its own `###`. The extractor set "inside the walkthrough" from whether the
# current heading matched "walkthrough" at any depth, so the first subsection
# turned it off and every file mentioned after that was invisible — the check
# measured the empty run-up to the first task and reported the rest as uncovered.
#
# Same shape as the doclint bug found the same afternoon: both assumed a heading
# ends a section, rather than a heading of the same or higher level.
make_doc "$(printf '### task-1 — the calculator\n\n`src/calc.py` gains an add function, which is the whole of what this task does.\n\n```python src/calc.py\ndef add(a, b): return a + b\n```\n\n### task-2 — the test\n\n`src/test_calc.py` pins that behaviour with an assertion that fails if the\narithmetic changes.\n\n```python src/test_calc.py\nassert add(1, 2) == 3\n```')"
out="$(dc)"
check "both files are seen"     "the walkthrough covers all" "$out"
nope  "none is reported missing" "never covers" "$out"

printf '\n== the check leaves a record, like every other check in the line ==\n\n'
#
# It wrote only to the log, so "the document was checked" was a fact about a
# terminal and not about the run. A reader of the run directory could not tell
# whether doc-check had run, passed, or never happened — the same gap
# package-check exists to close, one file over. pr.sh reads this record when no
# judge verdict exists, which is when it matters most.
J="factory/runs/R/doc-check.json"
want "doc-check.json is written"       "the run record must say the document was checked" \
     test -s "$J"
want "with the result"                 "status should be pass" \
     test "$(jq -r '.status' "$J")" = pass
want "and the document it read"        "document should be impl-detail.md" \
     test "$(jq -r '.document' "$J")" = impl-detail.md
want "named by hash, not by trust"     "document_sha256 should be the file's own" \
     test "$(jq -r '.document_sha256' "$J")" = "$(sha256sum factory/runs/R/impl-detail.md | cut -d' ' -f1)"
want "every check appears"             "sections, coverage, invented files, render" \
     test "$(jq -r '[.checks[]] | length' "$J")" -ge 4

# A record that only ever says pass is not a record. Break the document and look.
cp factory/runs/R/impl-detail.md "$WORK/good.md"
printf '# What was built\n\n## Summary\n\nToo short.\n' > factory/runs/R/impl-detail.md
dc > /dev/null 2>&1 || true
want "a failing run is recorded failing" "status should be fail" \
     test "$(jq -r '.status' "$J")" = fail
want "with the check that failed named" "at least one check should be fail" \
     test "$(jq -r '[.checks[] | select(.status == "fail")] | length' "$J")" -ge 1
cp "$WORK/good.md" factory/runs/R/impl-detail.md

printf '\n== no advice about size, because the measurement was retracted ==\n\n'
#
# doc-check briefly told the author how many bytes the doc audit would send and
# warned above 30,422. The measurement behind it was a sweep reporting its first
# pass five times; a clean re-run gives the same accept rate at 20,422 and 40,422
# bytes. Telling an author that a longer document weakens its own audit, when
# that is not measured, is the kind of plausible advice this project exists to
# refuse — so these assertions keep it from coming back.
out="$(dc)"
nope "no size note"                  "doc audit size" "$out"
nope "and no threshold"              "30,422" "$out"
check "and the script says why it went" "retracted" "$(cat "$PIPELINE_DIR/doc-check.sh")"

printf '\n== the skill tells the author what this check requires ==\n\n'
#
# Not a test of doc-check. A test that the instruction and the check agree,
# because when they disagree the author cannot win and does not know why.
#
# bean-002 failed coverage on two of five changed files. The skill said to show
# "the diff hunks that matter", which invites selection; the check requires every
# changed path to appear in the walkthrough section alone. Both sentences are
# reasonable and together they are a trap — the same shape as the build skill
# telling a worker to run verify commands in a container with no python.
SKILLDOC="$(cd "$PIPELINE_DIR/../skills/factory-doc" && pwd)/SKILL.md"
if [ -f "$SKILLDOC" ]; then
  d="$(cat "$SKILLDOC")"
  check "the skill says every changed file" "Every changed file has to be named" "$d"
  check "and that only the walkthrough counts" "not a walkthrough, and does not count" "$d"
  check "and that headings are matched"        "section it cannot find is a section missing" "$d"
  # The check itself has to still be the thing described. If doc-check stops
  # looking at the walkthrough alone, the skill above becomes a lie, and this is
  # the line that notices.
  check "and doc-check still looks there only" "a filename that appears only in a" \
        "$(cat "$PIPELINE_DIR/doc-check.sh")"
else
  printf '  SKIP  no factory-doc skill to cross-check\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
