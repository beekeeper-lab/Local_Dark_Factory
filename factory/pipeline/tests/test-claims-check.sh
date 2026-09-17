#!/usr/bin/env bash
# test-claims-check.sh — the check that was wrong three times before it was right.
#
# It answers a rubric item no judge has ever caught: does the spec's Current
# behaviour section claim the code does something it does not? The question is
# decidable — a path is on disk or it is not — and the difficulty is entirely in
# reading English well enough to tell a claim from a mention.
#
# The first three versions inferred an assertion from the absence of a negation,
# and every one of them accused a well-written section of lying, using sentences
# taken from real specs this line produced. Those sentences are the fixtures
# here. A fourth regression would be worse than the first three: it would be one
# the line has already been taught about.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PIPELINE_PYTHON:-python3}"
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
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}
# Membership in a named list, asked of the JSON rather than of its rendering.
# The first version of this file used `grep -F` with a two-line pattern, which
# grep reads as two alternatives — so every assertion of the form "X is not in
# list L" passed the moment `"L": [` appeared anywhere, which it always does.
# Four of the five failures it reported were its own.
has_item() { # <name> <list> <value> <json>
  if jq -e --arg v "$3" --arg l "$2" '.[$l] | index($v)' >/dev/null 2>&1 <<<"$4"
  then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s not in %s: %s\n' "$1" "$3" "$2" "$(jq -c --arg l "$2" '.[$l]' <<<"$4")"; FAIL=$((FAIL+1)); fi
}
lacks_item() { # <name> <list> <value> <json>
  if jq -e --arg v "$3" --arg l "$2" '.[$l] | index($v)' >/dev/null 2>&1 <<<"$4"
  then printf '  FAIL  %s — %s is in %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}

REPO="$WORK/repo"; mkdir -p "$REPO/src/seating_planner" "$REPO/factory"
cd "$REPO"; git init -q -b main .
git config user.email t@e.com; git config user.name T
printf 'def solve_seating():\n    return []\n' > src/seating_planner/solver.py
printf '[project]\nname = "x"\n' > pyproject.toml
printf 'nothing\n' > factory/note.txt
git add -A && git commit -q -m init

spec() { # <body> -> path to a spec with that Current behaviour section
  local f="$WORK/spec.md"
  { printf '# Spec\n\n## Current behaviour\n\n'; printf '%s\n' "$1"; printf '\n## Proposed change\n\nSomething.\n'; } > "$f"
  printf '%s' "$f"
}
cc() { "$PY" "$PIPELINE_DIR/claims-check.py" "$1" --root "$REPO" --json 2>&1; }
run() { "$PY" "$PIPELINE_DIR/claims-check.py" "$1" --root "$REPO" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
printf '\n== the defect it exists to catch ==\n\n'
#
# From bench/judge-fitness.sh, and across four runs no judge ever named it.
s="$(spec 'The repository already contains `src/seating_planner/config.py`, which
holds the tuning constants the solver reads at import time.')"
out="$(cc "$s")"
has_item "the invented file is reported" missing_paths 'src/seating_planner/config.py' "$out"
run "$s"; rc=$?
rc_is "and the check fails"            "$rc" 1

printf '\n-- a file it says exists, which does --\n\n'
s="$(spec 'The repository already contains `src/seating_planner/solver.py`.')"
out="$(cc "$s")"
has_item "it is recorded as claimed" paths_said_to_exist 'src/seating_planner/solver.py' "$out"
run "$s"; rc=$?
rc_is "and nothing fails"              "$rc" 0
lacks_item "nothing is missing" missing_paths 'src/seating_planner/solver.py' "$out"

# --------------------------------------------------------------------------
printf '\n== the three sentences that broke the first three versions ==\n\n'
#
# Every one of these is from a real spec written by this line, and every one was
# reported as a false claim about a file. None of them says a file is there.
for pair in \
  'Both are fixed by this bean creating `tests/` and `src/`.|creating' \
  'The bean adds a `testpaths` setting in `pyproject.toml` (an allowed write path).|an allowed write path' \
  'Today no `pyproject.toml`, no `src/`, and no `tests/` exist in the repository.|no ... exist'
do
  sentence="${pair%%|*}"; label="${pair##*|}"
  s="$(spec "$sentence")"
  run "$s"; rc=$?
  rc_is "\"$label\" does not fail" "$rc" 0
done

printf '\n-- and a neutral mention is recorded as exactly that --\n\n'
s="$(spec 'The bean adds a `testpaths` setting in `pyproject.toml` (an allowed write path).')"
out="$(cc "$s")"
has_item "it is only mentioned" paths_only_mentioned 'pyproject.toml' "$out"
lacks_item "not claimed to exist" paths_said_to_exist 'pyproject.toml' "$out"

# --------------------------------------------------------------------------
printf '\n== a denial anywhere in the section wins ==\n\n'
#
# The first spec a contained worker ever wrote opened by saying three files did
# not exist — correct, and exactly what this section is for — and mentioned one
# of them again forty lines later while describing the change. The neutral
# mention won, and a true sentence was called a false claim.
s="$(spec 'No `src/seating_planner/missing.py` exists in the repository today.

Forty lines later, the change writes to `src/seating_planner/missing.py`, which
the bean already lists among its allowed write paths.')"
out="$(cc "$s")"
has_item "the denial is recorded" paths_said_to_be_absent 'src/seating_planner/missing.py' "$out"
run "$s"; rc=$?
rc_is "and the check does not fail"    "$rc" 0
lacks_item "the file is not called missing" missing_paths 'src/seating_planner/missing.py' "$out"

printf '\n-- said absent, but present: recorded and never failed --\n\n'
#
# Deciding which noun a negation attaches to is not something a regex can do, and
# it was wrong twice in one section of the first real spec. So the reverse check
# was implemented and then deliberately removed; this pins the removal.
s="$(spec 'There is no `pyproject.toml` in this repository.')"
out="$(cc "$s")"
has_item "it is recorded" said_absent_but_present 'pyproject.toml' "$out"
check "and why it never fails"         "Suppressing a check on a maybe is cheap" "$out"
run "$s"; rc=$?
rc_is "the check passes"               "$rc" 0

# --------------------------------------------------------------------------
printf '\n== fenced code is example, not claim ==\n\n'
#
# A spec routinely shows the code it is about to write. Every identifier inside
# a fence would otherwise be reported as invented.
s="$(spec 'The solver will gain a loader:

```python
from seating_planner.nonexistent_module import Loader
open("`src/does/not/exist.py`")
```

Nothing above this fence claims anything.')"
out="$(cc "$s")"
nope  "nothing inside the fence counts" 'does/not/exist.py' "$out"
run "$s"; rc=$?
rc_is "and it passes"                   "$rc" 0

# --------------------------------------------------------------------------
printf '\n== symbols are weaker evidence and never fail ==\n\n'
#
# A backticked name may be a function, a name the change introduces, or prose.
s="$(spec 'The module currently defines `solve_seating` and `allocate_tables`.')"
out="$(cc "$s")"
has_item   "the absent one is reported"   absent_symbols 'allocate_tables' "$out"
lacks_item "and the present one is not"   absent_symbols 'solve_seating' "$out"
has_item   "both are recorded as named"   named_symbols  'solve_seating' "$out"
run "$s"; rc=$?
rc_is "an absent symbol does not fail"  "$rc" 0

printf '\n-- prose that looks like an identifier is left alone --\n\n'
s="$(spec 'The repository currently contains `pytest`, `ruff` and `mypy` configuration.')"
out="$(cc "$s")"
lacks_item "pytest is not treated as a symbol" named_symbols 'pytest' "$out"
run "$s"; rc=$?
rc_is "and nothing fails"               "$rc" 0

# --------------------------------------------------------------------------
printf '\n== a bare dotted token is not assumed to be a file ==\n\n'
#
# `pytest.ini_options` is a TOML key. An unknown extension means the token is
# left alone rather than demanded of the filesystem.
s="$(spec 'The repository already contains a `pytest.ini_options` table and a `tool.ruff.lint` section.')"
out="$(cc "$s")"
lacks_item "the TOML key is not a path" paths_said_to_exist 'pytest.ini_options' "$out"
lacks_item "nor even mentioned as one"  paths_only_mentioned 'pytest.ini_options' "$out"
run "$s"; rc=$?
rc_is "and nothing fails"               "$rc" 0

# --------------------------------------------------------------------------
printf '\n== how far a negation reaches, measured rather than assumed ==\n\n'
#
# The window exists because a sentence-wide one read "the package does not exist.
# The entire working tree (excluding `factory/`...)" as a denial of `factory/`.
# It bounds the reach; it does not eliminate it, and the comment in the source
# said otherwise until these two cases were run.
s="$(spec 'The package does not exist. The repository already contains `src/config.py`.')"
out="$(cc "$s")"
has_item "an adjacent negation still reaches" paths_said_to_be_absent 'src/config.py' "$out"
run "$s"; rc=$?
rc_is "which suppresses the failure"   "$rc" 0

s="$(spec 'The package does not exist. Separately: the repository already contains `src/config.py`.')"
out="$(cc "$s")"
lacks_item "ten more characters and it does not" paths_said_to_be_absent 'src/config.py' "$out"
has_item   "so the claim is read as a claim"     paths_said_to_exist     'src/config.py' "$out"
has_item   "and the invented file is caught"     missing_paths           'src/config.py' "$out"
run "$s"; rc=$?
rc_is "and the check fails"            "$rc" 1

# This is only survivable because of what a denial is allowed to do: suppress a
# check and be recorded, never fire a failure. A stray negation costs at worst one
# path not checked. If denials ever start failing runs, 48 stops being adequate.
s="$(spec 'The package does not exist. The entire working tree, excluding `factory/`, is
what the gate runs against.')"
out="$(cc "$s")"
run "$s"; rc=$?
rc_is "a misattributed denial fails nothing" "$rc" 0

# --------------------------------------------------------------------------
printf '\n== a spec with no such section makes no claims ==\n\n'
{ printf '# Spec\n\n## Proposed change\n\nSomething entirely.\n'; } > "$WORK/nosec.md"
out="$("$PY" "$PIPELINE_DIR/claims-check.py" "$WORK/nosec.md" --root "$REPO" --json 2>&1)"
check "it says so plainly"             "makes no claims to check" "$out"
check "and marks itself unchecked"     '"checked": false' "$out"
"$PY" "$PIPELINE_DIR/claims-check.py" "$WORK/nosec.md" --root "$REPO" >/dev/null 2>&1; rc=$?
rc_is "and does not fail the spec"     "$rc" 0
# A check that cannot run must not be indistinguishable from one that passed.
# Here the distinction is in the record rather than the exit code, which is the
# right trade only because `checked` is carried into the run.
check "the distinction is recorded"    '"checked"' "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
