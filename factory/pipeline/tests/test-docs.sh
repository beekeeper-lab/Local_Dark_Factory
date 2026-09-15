#!/usr/bin/env bash
# test-docs.sh — the document lint and the renderer.
#
# These two are what stand between "the model wrote something" and "a human can
# read it and a judge can audit it". The cases that matter are the dishonest
# ones: a section that exists but says nothing, a "Deviations: None" that was
# never checked, and Markdown from a model that happens to contain HTML.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAFFOLD="$PIPELINE_DIR/../scaffold/factory/templates"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PY="${PIPELINE_PYTHON:-$PIPELINE_DIR/../../.venv/bin/python}"
[ -x "$PY" ] || PY=python3

PASS=0; FAIL=0
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}

check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nocheck() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found what must not be there: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}

# Note the trailing blank line: without it there is no blank line before the next
# heading, and the fixture stops being the Markdown it claims to be.
filler() { printf 'This section carries enough real content to be worth a reader opening it, which is the only bar the lint is trying to enforce here.\n\n'; }

make_spec() { # make_spec <file> [omit-section] [thin-section]
  local f="$1" omit="${2:-}" thin="${3:-}"
  : > "$f"
  printf '# A spec\n\n' >> "$f"
  local s
  for s in "What and why" "Current behaviour" "Proposed change" "Risk" "Blast radius" "Verification" "Open questions"; do
    [ "$s" = "$omit" ] && continue
    printf '## %s\n\n' "$s" >> "$f"
    if [ "$s" = "$thin" ]; then printf 'Low.\n\n' >> "$f"; else filler >> "$f"; fi
  done
}

printf '\n== doclint: the sections exist and say something ==\n\n'
make_spec "$WORK/ok.md"
out="$(bash "$PIPELINE_DIR/doclint.sh" spec "$WORK/ok.md" 2>&1)"; rc=$?
check "a complete spec passes"        "doclint: PASS" "$out"
want  "and exits 0"                   "expected 0" test "$rc" -eq 0

make_spec "$WORK/missing.md" "Blast radius"
out="$(bash "$PIPELINE_DIR/doclint.sh" spec "$WORK/missing.md" 2>&1)"; rc=$?
check "a missing section fails"       "section missing" "$out"
check "and it is named"               "blast radius" "$out"
want  "and it exits non-zero"         "expected non-zero" test "$rc" -ne 0

make_spec "$WORK/thin.md" "" "Risk"
out="$(bash "$PIPELINE_DIR/doclint.sh" spec "$WORK/thin.md" 2>&1)"
check "a one-word section fails"      "too thin to be worth a reader's time" "$out"

# The spec is written in British English; the developer model is not.
sed 's/## Current behaviour/## Current behavior/' "$WORK/ok.md" > "$WORK/us.md"
out="$(bash "$PIPELINE_DIR/doclint.sh" spec "$WORK/us.md" 2>&1)"
check "American spelling is accepted" "doclint: PASS" "$out"

# A section that echoes its own heading is empty with extra steps.
make_spec "$WORK/echo.md"
$PY - "$WORK/echo.md" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"## Risk\n\n.*?\n\n", "## Risk\n\nRisk\n\n", s, flags=re.S)
open(p, "w").write(s)
PY
out="$(bash "$PIPELINE_DIR/doclint.sh" spec "$WORK/echo.md" 2>&1)"
check "a heading echo does not count"  "restates its heading" "$out"

printf '\n== doclint: the implementation document ==\n\n'
make_impl() { # make_impl <file> <deviations-body>
  local f="$1" dev="$2"
  : > "$f"
  printf '# What was built\n\n' >> "$f"
  local s
  for s in "Summary" "Walkthrough by task" "Deviations from the spec" "Risk & blast radius, as built" "Evidence" "How to verify locally" "Rollback"; do
    printf '## %s\n\n' "$s" >> "$f"
    if [ "$s" = "Deviations from the spec" ]; then printf '%s\n\n' "$dev" >> "$f"; else filler >> "$f"; fi
  done
}
make_impl "$WORK/impl-none.md" "None"
out="$(bash "$PIPELINE_DIR/doclint.sh" impl "$WORK/impl-none.md" 2>&1)"
check "a bare 'None' deviation fails" "say what was checked against what" "$out"

make_impl "$WORK/impl-ok.md" "The diff matches the spec file for file. The spec named src/a.py and tests/test_a.py, and the diff touches exactly those two, with no third file and nothing removed."
out="$(bash "$PIPELINE_DIR/doclint.sh" impl "$WORK/impl-ok.md" 2>&1)"
check "a checked 'no deviations' passes" "doclint: PASS" "$out"

printf '\n== renderer: structure ==\n\n'
cat > "$WORK/doc.md" <<'MD'
# Title of the document

## What and why

A paragraph with `inline code`, **bold**, *italic* and a [link](https://example.com).

```python src/seating_planner/solver.py
def solve(tables: list[int]) -> None:
    return None
```

| AC | Verify |
|---|---|
| ac1 | `ruff check .` |

- first
- second

> A quoted aside.
MD
out="$($PY "$PIPELINE_DIR/render-doc.py" "$WORK/doc.md" "$SCAFFOLD/spec.html" "$WORK/doc.html" --meta "bean=bean-001" 2>&1)"
html="$(cat "$WORK/doc.html")"
check "heading gets a stable id"      '<h2 id="what-and-why">' "$html"
check "code block keeps its file label" '<figcaption>src/seating_planner/solver.py</figcaption>' "$html"
check "code language is recorded"     'class="language-python"' "$html"
check "tables render"                 '<table><thead><tr><th>AC</th>' "$html"
check "lists render"                  '<li>first</li>' "$html"
check "blockquotes render"            '<blockquote>A quoted aside.</blockquote>' "$html"
check "inline code renders"           '<code>inline code</code>' "$html"
check "links render"                  '<a href="https://example.com">link</a>' "$html"
check "the title reaches the header"  '<h1>Title of the document</h1>' "$html"
check "metadata reaches the header"   '<dt>bean</dt><dd>bean-001</dd>' "$html"
check "a table of contents is built"  '<a href="#what-and-why">' "$html"
nocheck "no unfilled placeholders"    '{{' "$html"

printf '\n== renderer: a model writing HTML must not become HTML ==\n\n'
cat > "$WORK/evil.md" <<'MD'
# Title

## What and why

The model wrote <script>alert(1)</script> and <img src=x onerror=alert(2)> into its prose.

```html
<script>also inside a code block</script>
```
MD
$PY "$PIPELINE_DIR/render-doc.py" "$WORK/evil.md" "$SCAFFOLD/spec.html" "$WORK/evil.html" >/dev/null 2>&1
evil="$(cat "$WORK/evil.html")"
nocheck "no live script tag from prose"  '<script>alert(1)</script>' "$evil"
nocheck "no live img handler"            '<img src=x onerror=alert(2)>' "$evil"
check   "it is shown as text instead"    '&lt;script&gt;alert(1)&lt;/script&gt;' "$evil"
check   "and inside code blocks too"     '&lt;script&gt;also inside a code block&lt;/script&gt;' "$evil"

printf '\n== renderer: the same input renders the same bytes ==\n\n'
# §06 records an artifact hash for every document. A renderer that is not
# deterministic makes "the document changed" stop meaning anything.
$PY "$PIPELINE_DIR/render-doc.py" "$WORK/doc.md" "$SCAFFOLD/spec.html" "$WORK/again.html" --meta "bean=bean-001" >/dev/null 2>&1
want "byte-identical on a second run" "the renderer is not deterministic" \
  cmp -s "$WORK/doc.html" "$WORK/again.html"

printf '\n== renderer: both templates are self-contained ==\n\n'
for t in spec impl-detail; do
  body="$(cat "$SCAFFOLD/$t.html")"
  nocheck "$t.html loads nothing external (src=http)"  'src="http' "$body"
  nocheck "$t.html loads no external stylesheet"       '<link' "$body"
  check   "$t.html has a print stylesheet"             '@media print' "$body"
done

printf '\n== a section written as subsections is not empty ==\n\n'
#
# The authoring skill asks for exactly this shape — "per task: what changes,
# where, and an illustrative code block" — and doclint reported "section is
# empty" about a Proposed change section of three thousand characters, because
# it started a new section at every heading including deeper ones and measured
# only the gap before the first `###`.
#
# It cost a real run two spec attempts. The model was right both times, and said
# so: "the section was never thin, the linter just didn't recognize its
# blocks/subsections".
SUBS="$WORK/subsections.md"
cat > "$SUBS" <<'MD'
# A spec whose sections have subsections

## What and why

The bean asks for a scaffold. This document explains what that means for someone
who has not seen this repository before, and what they should expect to change.

## Current behaviour

There is nothing here yet. The tree holds a README and the factory directory,
and no application code at all, so nothing can break in a way a test would see.

## Proposed change

### task-1 — declare the project

`pyproject.toml` declares the package, the Python floor and the tool
configuration the gates need. It deliberately does not pin the tool versions,
because the gate image is already pinned by digest and a second list would drift.

```toml pyproject.toml
[project]
name = "seating-planner"
```

### task-2 — the package module

A two-statement module: a docstring and a version. Nothing imports it yet, which
is the point — the scaffold has to exist before anything can be built on it.

## Risk

Low. Every file is new, nothing refers to any of them, and reverting the branch
restores the previous state exactly with no ordering to respect.

## Blast radius

Three files, all new, all inside the bean's allowed write paths. No dependency
changes and no public interface, so nothing outside this bean can be affected.

## Verification

Each task carries its own check and the controller runs every one of them, in
the pinned gate container rather than on the host where the versions differ.

## Open questions

None. If something turns out to be ambiguous the task blocks and a person is
asked, rather than the model guessing and the guess becoming the specification.
MD
out="$(bash "$PIPELINE_DIR/doclint.sh" spec "$SUBS" 2>&1)"
check "the section is measured whole"  "proposed change" "$out"
nope  "and is not called empty"        "section is empty" "$out"
check "the document passes"            "doclint: PASS" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
