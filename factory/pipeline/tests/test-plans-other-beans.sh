#!/usr/bin/env bash
# test-plans-other-beans.sh — the check that reads the rest of the bean set.
#
# It decides `unfinishable-task`, which controller-fitness had as "not decidable
# from the documents, needs a judge" for two days. What makes it decidable is that
# every approved bean says in one line what it is for, and a task intent that
# describes one of those lines is proposing that bean's work.
#
# The risk is the obvious one for anything built on word overlap: a false alarm
# blocks a spec for a coincidence of English. The first version raised one
# immediately on the real bean-001 task list — "rules" from ruff's rule list
# `E,F,I,UP,B` and "seating" from the name of the product, both matching bean-003.
# So most of what follows is about the two rules that stop that, and they are
# asserted from both directions: the defect is caught, and the coincidence is not.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PIPELINE_DIR/../.." && pwd)"
POB="$PIPELINE_DIR/plans-other-beans.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi }
nope()  { if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
          else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi }
rc_is() { if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi }

BEANS="$WORK/beans"; mkdir -p "$BEANS"
mkbean() { # mkbean <id> <title> [extra yaml]
  cat > "$BEANS/$1.yaml" <<EOF
schema_version: bean/2.0.0
id: $1
repo: x/y
title: $2
intent: does a thing
status: approved
allowed_write_paths: [src/**]
acceptance_criteria:
  - id: ac1
    text: it works
    verify: { kind: command, run: ["true"] }
${3:-}
EOF
}
mkbean bean-001 "Project scaffold with linting, typing and test gates" "non_goals: [no domain models]"
mkbean bean-002 "Core domain models for events, tables, guests and groups"
mkbean bean-007 "Soft-constraint scoring and the optimization objective"
mkbean bean-003 "Structured seating rules with hardness and the wedding template"
mkbean bean-020 "Adjacent-seat rules report as unevaluable"

tasks() { cat > "$WORK/tasks.yaml" <<EOF
schema_version: tasks/1.0.0
tasks:
  - id: task-1
    intent: >
      $1
    write_paths: [src/a.py]
    verify: { kind: command, run: ["true"] }
    satisfies: [ac1]
EOF
}
pob() { bash "$POB" --bean "$BEANS/bean-001.yaml" --tasks "$WORK/tasks.yaml" --beans-dir "$BEANS" "$@" 2>&1; }

printf '\n== a task describing another bean is named, with the bean ==\n\n'
tasks "Implement the complete seating optimizer: soft-constraint scoring and the optimization objective, wired together."
out="$(pob)"; rc=$?
rc_is "it refuses"                  "$rc" 1
check "and names the bean"          "bean-007" "$out"
check "and that bean's title"       "Soft-constraint scoring" "$out"
check "and which words matched"     "scoring" "$out"
check "and says what it costs"      "lands outside these write paths" "$out"

printf '\n== one shared word is a coincidence, not a topic ==\n\n'
tasks "Write the scoring helper for this package and nothing else."
out="$(pob)"; rc=$?
rc_is "one term does not fire"      "$rc" 0
check "and it says what it compared" "against 4 other bean(s)" "$out"

printf '\n== a word several beans use belongs to none of them ==\n\n'
# "rules" is in bean-003's title and bean-020's. "seating" is in bean-003's. This
# is the real false alarm the first version raised: ruff's rule list and the name
# of the product, in a task intent about a package scaffold.
tasks "Create the package init for the wedding-seating project; must be ruff-clean under rules E,F,I,UP,B and mypy strict."
out="$(pob)"; rc=$?
rc_is "the coincidence does not fire" "$rc" 0
nope  "and bean-003 is not accused"   "bean-003" "$out"

printf '\n== a word this bean already uses is not distinctive of anyone ==\n\n'
# bean-001's own non-goals say "no domain models". Naming them is this bean
# talking about itself, and cannot be evidence it is doing bean-002's work.
tasks "Add nothing: this bean ships no domain models and no models of any kind."
out="$(pob)"; rc=$?
rc_is "its own vocabulary does not fire" "$rc" 0
nope  "and bean-002 is not accused"      "bean-002" "$out"

printf '\n== the threshold is a knob, and lowering it is visible ==\n\n'
tasks "Write the scoring helper for this package and nothing else."
out="$(pob --min-terms 1)"; rc=$?
rc_is "at one term it fires"        "$rc" 1
check "on the single word"          "scoring" "$out"

printf '\n== nothing to compare against is not a pass ==\n\n'
ONE="$WORK/one"; mkdir -p "$ONE"; cp "$BEANS/bean-001.yaml" "$ONE/"
out="$(bash "$POB" --bean "$ONE/bean-001.yaml" --tasks "$WORK/tasks.yaml" --beans-dir "$ONE" 2>&1)"; rc=$?
rc_is "it exits 0"                  "$rc" 0
check "and says nothing was checked" "nothing was checked" "$out"

printf '\n== the record says what it compared and what it cannot do ==\n\n'
tasks "Implement soft-constraint scoring and the optimization objective."
pob --json "$WORK/out.json" >/dev/null 2>&1
check "the finding is in it"        "bean-007" "$(jq -c '.findings' "$WORK/out.json")"
check "with how many beans it saw"  "4" "$(jq -r '.compared_against' "$WORK/out.json")"
check "and the caveat is explicit"  "cannot find one that describes it in different words" \
      "$(jq -r '.caveat' "$WORK/out.json")"

printf '\n== a bean it cannot read is counted, not skipped in silence ==\n\n'
printf 'this: is: not: yaml:\n  - [\n' > "$BEANS/broken.yaml"
pob --json "$WORK/out2.json" >/dev/null 2>&1
if [ "$(jq -r '.unreadable_beans' "$WORK/out2.json")" -ge 1 ]; then
  printf '  ok    it says how many it could not read\n'; PASS=$((PASS+1))
else printf '  FAIL  an unreadable bean vanished from the count\n'; FAIL=$((FAIL+1)); fi
rm -f "$BEANS/broken.yaml"

printf '\n== the real corpus: the seeded defect fires, the real plan does not ==\n\n'
CORPUS="$ROOT/benchmark/seating-planner/bean-sets/v1/beans"
REALT="$ROOT/evidence/bean-001-tasks-20260915.yaml"
if [ -d "$CORPUS" ] && [ -f "$REALT" ]; then
  out="$(bash "$POB" --bean "$CORPUS/bean-001.yaml" --tasks "$REALT" --beans-dir "$CORPUS" 2>&1)"; rc=$?
  rc_is "the real bean-001 plan is clean" "$rc" 0
  "$ROOT/.venv/bin/python" - "$REALT" "$WORK/mutated.yaml" <<'PY'
import sys, yaml
t = yaml.safe_load(open(sys.argv[1]))
t["tasks"][0]["intent"] = ("Implement the complete seating optimizer: domain models, the CP-SAT "
                           "solver, soft-constraint scoring, the persistence layer, the REST API "
                           "and the report renderer, all wired together and covered by tests.")
yaml.safe_dump(t, open(sys.argv[2], "w"), sort_keys=False)
PY
  out="$(bash "$POB" --bean "$CORPUS/bean-001.yaml" --tasks "$WORK/mutated.yaml" --beans-dir "$CORPUS" 2>&1)"; rc=$?
  rc_is "and the seeded unfinishable task is caught" "$rc" 1
  check "by the bean it belongs to"  "bean-007" "$out"
else
  printf '  SKIP  no corpus or no real task list\n'
fi

printf '\n== no bean in the corpus accuses another over its own criteria ==\n\n'
#
# The precision guarantee, swept rather than argued. Each bean's own acceptance
# criteria are used as its task intents — the closest thing to "what this bean's
# spec will plausibly say" that exists before the spec is written — and none of
# the twenty may trip the check. A future bean, a change to the stoplist, or a
# looser threshold breaks this and the suite says which bean.
#
# It matters because this check REFUSES a spec. The reason it is allowed to is
# that it has never raised a false alarm, and that claim needs a standing test
# rather than an afternoon's observation.
if [ -d "$CORPUS" ]; then
  SWEEP="$WORK/sweep"; mkdir -p "$SWEEP"
  fired=""
  for b in "$CORPUS"/bean-*.yaml; do
    "$ROOT/.venv/bin/python" - "$b" "$SWEEP/tasks.yaml" <<'PY' || continue
import sys, yaml
b = yaml.safe_load(open(sys.argv[1]))
tasks = {"schema_version": "tasks/1.0.0", "tasks": [
    {"id": f"task-{i}", "intent": ac["text"],
     "write_paths": (b.get("allowed_write_paths") or ["src/x.py"])[:1],
     "verify": {"kind": "command", "run": ["true"]}, "satisfies": [ac["id"]]}
    for i, ac in enumerate(b.get("acceptance_criteria") or [], 1)]}
yaml.safe_dump(tasks, open(sys.argv[2], "w"), sort_keys=False)
PY
    if ! bash "$POB" --bean "$b" --tasks "$SWEEP/tasks.yaml" --beans-dir "$CORPUS" >/dev/null 2>&1; then
      fired="$fired $(basename "$b" .yaml)"
    fi
  done
  n="$(ls -1 "$CORPUS"/bean-*.yaml | wc -l)"
  if [ -z "$fired" ]; then
    printf '  ok    all %s beans clean against their own criteria\n' "$n"; PASS=$((PASS+1))
  else
    printf '  FAIL  these accuse another bean over their own acceptance criteria:%s\n' "$fired"; FAIL=$((FAIL+1))
  fi
else
  printf '  SKIP  no corpus\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
