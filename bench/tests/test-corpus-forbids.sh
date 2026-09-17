#!/usr/bin/env bash
# test-corpus-forbids.sh — the annotations in the bean set, and the scaffold that
# carries them downstream.
#
# `bean-forbids.sh` has its own suite; this one is about the DATA. Seventeen
# non-goals and constraints across the corpus now carry forbidden_paths and
# forbidden_imports, and every one of them is a glob or a module name typed by
# hand. A pattern with a typo does not fail — it silently matches nothing, and a
# check that cannot fire reads exactly like a check that passed. So every declared
# pattern is asserted to actually catch a path it describes, and every declared
# module to catch an import of itself.
#
# The other half is the false positive, which is worse than useless here: a bean
# that refuses its own work stops the line for a reason that is not a defect. So
# each bean is also run against its own allowed_write_paths, and the two cases
# that are easy to get wrong — bean-001 DECLARING ortools in pyproject.toml, and
# bean-004 importing sqlite3 in the bean whose whole job is SQLite — are asserted
# by name.
#
# Then the scaffold, because the corpus is copied into the target repo and the
# copy is what the line actually reads. Two failures found on 2026-09-16 that this
# covers: bean.md printed a Python dict for an annotated non-goal, and
# pipeline-config.json's hidden_tests block existed only in the target, one
# scaffold run from deletion.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CORPUS="$ROOT/benchmark/seating-planner/bean-sets/v1/beans"
FORBIDS="$ROOT/factory/pipeline/bean-forbids.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n          %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
rc_is(){ if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else bad "$1" "expected exit $3, got $2"; fi; }
check(){ if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "expected: $2 — got: $3"; fi; }
nope() { if grep -qF -- "$2" <<<"$3"; then bad "$1" "found: $2"; else ok "$1"; fi; }

if [ ! -d "$CORPUS" ]; then
  printf '  SKIP  no corpus at %s\n\n0 passed, 0 failed\n' "$CORPUS"; exit 0
fi

printf '\n== every declared pattern catches what it describes ==\n\n'
# One assertion per bean rather than per pattern: 74 identical lines is a wall
# nobody reads, and the failure names the pattern that missed either way.
for bean in "$CORPUS"/bean-*.yaml; do
  id="$(basename "$bean" .yaml)"
  rules="$("$ROOT/factory/pipeline/yaml2json.sh" "$bean" | jq -c '[(.non_goals//[]),(.constraints//[])]|add|map(select(type=="object"))[]')"
  [ -n "$rules" ] || continue
  missed=""; n=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      # A concrete path the pattern must match. `**` is a directory and something
      # under it; `*` is a name.
      conc="$(printf '%s' "$pat" | sed 's|/\*\*|/probe/x.py|g; s|\*|probe|g')"
      "$FORBIDS" --bean "$bean" --paths "$(jq -nc --arg c "$conc" '[$c]')" >/dev/null 2>&1
      [ $? -eq 1 ] || missed="$missed $pat"
      n=$((n+1))
    done < <(jq -r '.forbidden_paths//[] | .[]' <<<"$r")
    while IFS= read -r mod; do
      [ -n "$mod" ] || continue
      printf -- '--- a/x.py\n+++ b/x.py\n@@\n+    from %s.sub import thing\n' "$mod" > "$WORK/d.diff"
      "$FORBIDS" --bean "$bean" --diff "$WORK/d.diff" >/dev/null 2>&1
      [ $? -eq 1 ] || missed="$missed import:$mod"
      n=$((n+1))
    done < <(jq -r '.forbidden_imports//[] | .[]' <<<"$r")
  done <<< "$rules"
  if [ -z "$missed" ]; then ok "$id — $n pattern(s) all fire"
  else bad "$id" "declared but never fires:$missed"; fi
done

printf '\n== and no bean refuses its own work ==\n\n'
for bean in "$CORPUS"/bean-*.yaml; do
  id="$(basename "$bean" .yaml)"
  conc="$("$ROOT/factory/pipeline/yaml2json.sh" "$bean" | jq -r '.allowed_write_paths//[] | .[]' \
    | sed 's|/\*\*|/own_work.py|g' | jq -Rsc 'split("\n")|map(select(length>0))')"
  out="$("$FORBIDS" --bean "$bean" --paths "$conc" 2>&1)"; rc=$?
  if [ "$rc" = 0 ]; then ok "$id — its own write paths are allowed"
  else bad "$id" "refuses its own allowed_write_paths: $out"; fi
done

printf '\n== the two that are easy to get backwards ==\n\n'
B1="$CORPUS/bean-001.yaml"; B4="$CORPUS/bean-004.yaml"
printf -- '--- a/pyproject.toml\n+++ b/pyproject.toml\n@@\n+dependencies = ["ortools>=9.8"]\n' > "$WORK/pp.diff"
out="$("$FORBIDS" --bean "$B1" --diff "$WORK/pp.diff" 2>&1)"; rc=$?
rc_is "bean-001 may DECLARE ortools in pyproject" "$rc" 0
printf -- '--- a/x.py\n+++ b/x.py\n@@\n+from ortools.sat.python import cp_model\n' > "$WORK/imp.diff"
out="$("$FORBIDS" --bean "$B1" --diff "$WORK/imp.diff" 2>&1)"; rc=$?
rc_is "and may not import it" "$rc" 1
check "and the message names the statement it broke" "not yet imported by any module" "$out"
printf -- '--- a/x.py\n+++ b/x.py\n@@\n+import sqlite3\n' > "$WORK/sq.diff"
out="$("$FORBIDS" --bean "$B4" --diff "$WORK/sq.diff" 2>&1)"; rc=$?
rc_is "bean-004, the SQLite bean, may import sqlite3" "$rc" 0
# A real file, not a process substitution: bean-forbids greps the diff more than
# once, so it requires something seekable and says exit 2 rather than reading a
# pipe dry and reporting a clean diff.
printf -- '--- a/x.py\n+++ b/x.py\n@@\n+import sqlalchemy\n' > "$WORK/orm.diff"
out="$("$FORBIDS" --bean "$B4" --diff "$WORK/orm.diff" 2>&1)"; rc=$?
rc_is "and may not import an ORM" "$rc" 1
out="$("$FORBIDS" --bean "$B4" --diff <(printf -- '+import sqlalchemy\n') 2>&1)"; rc=$?
rc_is "a diff it cannot re-read is refused, not read as clean" "$rc" 2

printf '\n== a removal is the bean being obeyed, not broken ==\n\n'
printf -- '--- a/x.py\n+++ b/x.py\n@@\n-from ortools.sat.python import cp_model\n' > "$WORK/rm.diff"
out="$("$FORBIDS" --bean "$B1" --diff "$WORK/rm.diff" 2>&1)"; rc=$?
rc_is "deleting a forbidden import passes" "$rc" 0

printf '\n== prose stays prose, and says so ==\n\n'
out="$("$FORBIDS" --bean "$CORPUS/bean-009.yaml" --paths '["src/x.py"]' 2>&1)"; rc=$?
rc_is "a bean with no annotations is not a pass" "$rc" 0
check "it says nothing was checked"   "declares none in machine-readable form" "$out"
nope "not that nothing is wrong"      "nothing forbidden was touched" "$out"

printf '\n== the scaffold carries them downstream ==\n\n'
T="$WORK/target"; mkdir -p "$T"; git init -q "$T"
out="$("$ROOT/factory/scaffold.sh" "$T" 2>&1)"; rc=$?
rc_is "it installs" "$rc" 0
BM="$(cat "$T"/factory/beans/bean-001-*/bean.md)"
check "an annotated non-goal renders as its text" "- no domain models" "$BM"
nope  "not as a Python dict"                      "{'text':" "$BM"
check "and says what is machine-checked"          "checked, not judged" "$BM"
BY="$T/factory/beans/bean-001-project-scaffold-with-linting-typing-and/bean.yaml"
if [ -f "$BY" ] && diff -q "$BY" "$CORPUS/bean-001.yaml" >/dev/null; then
  ok "the installed bean.yaml is the corpus bean, byte for byte"
else bad "installed bean.yaml" "differs from $CORPUS/bean-001.yaml"; fi
PC="$T/factory/pipeline-config.json"
if jq -e . "$PC" >/dev/null 2>&1; then ok "pipeline-config.json parses"
else bad "pipeline-config.json" "not valid JSON — a quote in the jq literal ends it silently"; fi
check "and carries hidden_tests"  "/hidden" "$(jq -c '.hidden_tests' "$PC")"
check "keyed on the repo, not the directory it was cloned into" "seating-planner-py" "$(jq -r '.hidden_tests.dir' "$PC")"

printf '\n== --check sees what the scaffold would overwrite ==\n\n'
out="$("$ROOT/factory/scaffold.sh" --check "$T" 2>&1)"; rc=$?
rc_is "a fresh install is current" "$rc" 0
check "and says so"                "is current with" "$out"
printf '\n# edited downstream\n' >> "$T/factory/repo.yaml"
out="$("$ROOT/factory/scaffold.sh" --check "$T" 2>&1)"; rc=$?
rc_is "an edit downstream is drift" "$rc" 1
check "and it names the file"       "DIFFERS   factory/repo.yaml" "$out"
check "and warns the scaffold will not ask" "will not ask" "$out"
git -C "$T" checkout -- factory/repo.yaml 2>/dev/null || true
rm -f "$T/factory/repo.yaml"
out="$("$ROOT/factory/scaffold.sh" --check "$T" 2>&1)"; rc=$?
check "a deleted control file is MISSING, not silence" "MISSING   factory/repo.yaml" "$out"
mkdir -p "$T/factory/beans/bean-999-from-nowhere"; : > "$T/factory/beans/bean-999-from-nowhere/bean.yaml"
out="$("$ROOT/factory/scaffold.sh" --check "$T" 2>&1)"; rc=$?
check "a bean the set no longer has is EXTRA" "EXTRA     factory/beans/bean-999-from-nowhere" "$out"
out="$("$ROOT/factory/scaffold.sh" --check --dry-run "$T" 2>&1)"; rc=$?
rc_is "--check and --dry-run refuse each other" "$rc" 2

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
