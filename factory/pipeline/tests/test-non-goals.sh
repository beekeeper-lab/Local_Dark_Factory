#!/usr/bin/env bash
# test-non-goals.sh — the half of a bean's non-goals a script can decide.
#
# `non_goals` was a list of English sentences checked by asking the judge, and on
# 2026-09-16 that judge was measured accepting seeded defects 7 to 9 times out of
# 15 — with `contradicts-non-goal`, a spec that plans work the bean forbids, among
# the cases it missed. controller-fitness had it as "not decidable from the
# documents, needs a judge".
#
# Half of it is decidable. A non-goal about a PLACE is a statement about paths and
# imports, and those are countable.
#
# The assertion that matters most is the one about a bean with no machine-readable
# non-goals: it reports that it checked NOTHING, not that nothing is wrong. Those
# are different answers and a check that conflates them is the fail-open this
# project keeps finding.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}
ng() { bash "$PIPELINE_DIR/non-goals.sh" --bean "$WORK/bean.yaml" "$@" 2>&1; }

cat > "$WORK/bean.yaml" <<'YAML'
schema_version: bean/2.0.0
id: bean-002
repo: e/x
title: t
intent: i
status: approved
allowed_write_paths: ["src/**", "tests/**"]
acceptance_criteria:
  - id: ac1
    text: a
    verify: { kind: command, run: ["true"] }
non_goals:
  - no database
  - text: no solver code
    forbidden_paths: ["src/**/solver/**"]
    forbidden_imports: [ortools]
  - text: no CI workflow files
    forbidden_paths: [".github/workflows/**"]
YAML

cat > "$WORK/prose-bean.yaml" <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: e/x
title: t
intent: i
status: approved
allowed_write_paths: ["src/**"]
acceptance_criteria:
  - id: ac1
    text: a
    verify: { kind: command, run: ["true"] }
non_goals:
  - no domain models
  - no solver code
  - no CI workflow files
YAML

printf '\n== a plan that stays out of the forbidden places ==\n\n'
out="$(ng --paths '["src/seating/models.py","tests/test_models.py"]')"; rc=$?
rc_is "it passes"                      "$rc" 0
check "and says how many rules ran"    "2 rule(s) checked" "$out"

printf '\n== a task that plans work the bean forbids ==\n\n'
#
# This is `contradicts-non-goal`, the seeded defect the judge misses, decided at
# PLAN time — before a model writes a line of it.
out="$(ng --paths '["src/seating/solver/cpsat.py"]')"; rc=$?
rc_is "it is refused"                  "$rc" 1
check "the non-goal is quoted"         '"no solver code"' "$out"
check "with the path that violates it" "src/seating/solver/cpsat.py" "$out"
check "and the pattern it is inside"   "src/**/solver/**" "$out"
check "and what a non-goal means"      "a different bean arriving early" "$out"

printf '\n-- and the other one, so it is not one hard-coded rule --\n\n'
out="$(ng --paths '[".github/workflows/ci.yml"]')"; rc=$?
rc_is "it is refused too"              "$rc" 1
check "naming the right non-goal"      '"no CI workflow files"' "$out"
nope  "and not the solver one"         "no solver code" "$out"

printf '\n== a diff that imports what the bean forbids ==\n\n'
printf '+++ b/src/seating/models.py\n+from ortools.sat.python import cp_model\n+x = 1\n' > "$WORK/import.diff"
out="$(ng --diff "$WORK/import.diff")"; rc=$?
rc_is "it is refused"                  "$rc" 1
check "the module is named"            "imports ortools" "$out"
check "with the line"                  "from ortools.sat.python import cp_model" "$out"

printf '\n-- indented, because an import inside a function is still an import --\n\n'
printf '+++ b/src/seating/a.py\n+    import ortools\n' > "$WORK/indent.diff"
out="$(ng --diff "$WORK/indent.diff")"; rc=$?
rc_is "it is refused"                  "$rc" 1

printf '\n-- and a REMOVED import is the bean being obeyed --\n\n'
#
# The first version of the grep tried `.*(^|[[:space:]])` to catch an import
# anywhere on the line. `^` cannot match after `.*`, so it matched nothing at all
# and reported a clean diff for one beginning `+from ortools.sat.python import`.
# A check that cannot fire is worse than no check: its silence reads as a pass.
printf '+++ b/src/seating/a.py\n-from ortools.sat import x\n+import json\n' > "$WORK/removed.diff"
out="$(ng --diff "$WORK/removed.diff")"; rc=$?
rc_is "removing one is not a violation" "$rc" 0

printf '\n-- a path in the diff is checked as well as an import --\n\n'
printf '+++ b/.github/workflows/ci.yml\n+name: ci\n' > "$WORK/wf.diff"
out="$(ng --diff "$WORK/wf.diff")"; rc=$?
rc_is "the changed file is caught"     "$rc" 1
check "by its non-goal"                '"no CI workflow files"' "$out"

printf '\n-- a DELETED file is not a write into a forbidden place --\n\n'
printf -- '--- a/.github/workflows/ci.yml\n+++ /dev/null\n' > "$WORK/del.diff"
out="$(ng --diff "$WORK/del.diff")"; rc=$?
rc_is "deleting one is not a violation" "$rc" 0

printf '\n== a bean with none says it checked NOTHING ==\n\n'
#
# Not "nothing forbidden". A check that conflates "I found nothing" with "I looked
# for nothing" is the fail-open this project keeps finding, and here the
# difference is whether the judge is still the only thing standing between a bean
# and its own non-goals.
out="$(bash "$PIPELINE_DIR/non-goals.sh" --bean "$WORK/prose-bean.yaml" --paths '["src/anything.py"]' 2>&1)"; rc=$?
rc_is "it passes, because it must"     "$rc" 0
check "and says it checked none"       "declares none in machine-readable form" "$out"
check "counting the prose ones"        "3 non-goal(s) are prose" "$out"
check "and whose job they remain"      "the audit" "$out"
nope  "it does not claim a clean bill" "nothing forbidden was touched" "$out"

printf '\n== the record says what was checked and what it cannot see ==\n\n'
ng --paths '["src/seating/solver/x.py"]' --json "$WORK/r.json" >/dev/null 2>&1
eq "the bean is named"                 "bean-002" "$(jq -r '.bean' "$WORK/r.json")"
eq "the rules are counted"             "2" "$(jq -r '.checkable_rules' "$WORK/r.json")"
eq "and the violation recorded"        "path" "$(jq -r '.violations[0].kind' "$WORK/r.json")"
check "with the caveat on imports"     "it does not catch __import__" "$(jq -r '.caveat' "$WORK/r.json")"

bash "$PIPELINE_DIR/non-goals.sh" --bean "$WORK/prose-bean.yaml" --paths '["src/x.py"]' --json "$WORK/r2.json" >/dev/null 2>&1
eq "a prose bean records zero rules"   "0" "$(jq -r '.checkable_rules' "$WORK/r2.json")"
check "and says nothing was checked"   "not the same as nothing being wrong" "$(jq -r '.note' "$WORK/r2.json")"

printf '\n== it refuses what it cannot check ==\n\n'
out="$(bash "$PIPELINE_DIR/non-goals.sh" --bean "$WORK/nope.yaml" --paths '[]' 2>&1)"; rc=$?
rc_is "a missing bean exits 2"         "$rc" 2
out="$(bash "$PIPELINE_DIR/non-goals.sh" --bean "$WORK/bean.yaml" 2>&1)"; rc=$?
rc_is "and neither paths nor diff"     "$rc" 2
out="$(bash "$PIPELINE_DIR/non-goals.sh" --bean "$WORK/bean.yaml" --diff "$WORK/absent.diff" 2>&1)"; rc=$?
rc_is "and a diff that is not there"   "$rc" 2
check "saying which file"              "no such diff file" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
