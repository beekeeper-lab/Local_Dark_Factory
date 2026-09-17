#!/usr/bin/env bash
# test-validate.sh — the thing that says "8 schemas, 0 invalid" and "20 beans, 0 invalid".
#
# Those two sentences are quoted in the drift check, the phase audits and the
# handoff document, and they are the reason anyone believes the eight declared
# contracts are honoured. A validator that passes everything would produce the
# same two sentences.
#
# So the assertions here are mostly about REJECTION: a bean missing a required
# field, a payload against the wrong schema, a schema name that does not exist,
# and the two traps this file was written to survive — a `$ref` between schemas
# that must resolve locally rather than over the network, and a YAML timestamp
# that PyYAML turns into a datetime and every `"type": "string"` then rejects.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PY="$ROOT/.venv/bin/python"
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

if [ ! -x "$PY" ]; then
  printf '  SKIP  no venv interpreter at %s\n\n0 passed, 0 failed\n' "$PY"; exit 0
fi
v() { "$PY" "$ROOT/bench/validate.py" "$@" 2>&1; }

printf '\n== the schemas themselves ==\n\n'
out="$(v)"; rc=$?
rc_is "they are all well-formed"     "$rc" 0
check "and it says how many"         "schemas, 0 invalid" "$out"

printf '\n== a real bean validates, and a broken one does not ==\n\n'
BEAN="$(ls -d "$ROOT"/benchmark/seating-planner/bean-sets/v1/*.yaml 2>/dev/null | head -1)"
if [ -z "$BEAN" ]; then
  BEAN="$(ls -d /home/gregg/workspace/seating-planner-py/factory/beans/*/bean.yaml 2>/dev/null | head -1)"
fi
if [ -n "$BEAN" ]; then
  out="$(v bean "$BEAN")"; rc=$?
  rc_is "the real bean passes"       "$rc" 0
  check "and is counted"             "1 payload(s)" "$out"

  # Required fields. A validator that shrugs at a missing `id` is not validating.
  "$PY" - "$BEAN" "$WORK/nobody.yaml" <<'PYEOF'
import sys, yaml
class L(yaml.SafeLoader): pass
L.add_constructor("tag:yaml.org,2002:timestamp", yaml.SafeLoader.construct_yaml_str)
d = yaml.load(open(sys.argv[1]).read(), Loader=L)
d.pop("acceptance_criteria", None)
yaml.safe_dump(d, open(sys.argv[2], "w"))
PYEOF
  out="$(v bean "$WORK/nobody.yaml")"; rc=$?
  rc_is "a bean missing a required field fails" "$rc" 1
  check "and says which field"       "acceptance_criteria" "$out"
  check "and counts it invalid"      "1 invalid" "$out"
else
  printf '  SKIP  no bean to validate against\n'
fi

printf '\n== the $ref trap ==\n\n'
#
# task.schema.json refers to bean.schema.json#/$defs/verify. Without a local
# registry jsonschema FETCHES that over the network — from `https://forge.local`,
# which does not exist — and validation dies with a urllib traceback rather than a
# finding. The schemas were reported "8 valid" the whole time this was broken,
# because checking that a schema is well-formed never follows its references.
# Only validating a payload does.
cat > "$WORK/tasks.yaml" <<'TY'
schema_version: tasks/1.0.0
tasks:
  - id: task-1
    title: Do the thing
    intent: A sentence about why this task exists at all, long enough to be real.
    write_paths: ["src/**"]
    verify:
      - kind: command
        run: ["pytest", "-q"]
TY
out="$(v task "$WORK/tasks.yaml")"; rc=$?
nope "no network fetch is attempted" "urlopen" "$out"
nope "and no traceback"              "Traceback" "$out"
check "it reaches a verdict"         "payload(s) against" "$out"

printf '\n== the YAML timestamp trap ==\n\n'
#
# PyYAML resolves an unquoted `2026-09-14T15:10:00Z` into a datetime, which then
# fails every `"type": "string"` in the schemas. The bean on disk is correct RFC
# 3339 text; only the loader is lossy. Anything that reads beans must do this or
# the schemas reject valid artifacts.
cat > "$WORK/stamped.yaml" <<'SY'
schema_version: bean/2.0.0
id: bean-901
repo: example/x
title: A bean with an unquoted timestamp in it
intent: The timestamp below is unquoted on purpose; that is the whole test.
status: approved
approval:
  approved_by: Someone
  approved_at: 2026-09-14T15:10:00Z
  order: 1
allowed_write_paths: ["src/**"]
acceptance_criteria:
  - id: ac1
    text: It does the thing
    verify:
      kind: command
      run: ["true"]
definition_of_done: ["ac1"]
SY
out="$(v bean "$WORK/stamped.yaml")"; rc=$?
nope "a datetime is not reported as a type error" "is not of type 'string'" "$out"
rc_is "and the bean validates"       "$rc" 0

printf '\n== refusals ==\n\n'
out="$(v no-such-schema "$WORK/tasks.yaml")"; rc=$?
rc_is "an unknown schema name refuses" "$rc" 1
check "and says where it looked"     "no such schema" "$out"

out="$(v --corpus "$WORK/not-a-corpus")"; rc=$?
check "a missing corpus is reported" "$WORK/not-a-corpus" "$out"

printf '\n== the corpus, which is the sentence people quote ==\n\n'
CORPUS="$ROOT/benchmark/seating-planner/bean-sets/v1"
if [ -d "$CORPUS" ]; then
  out="$(v --corpus "$CORPUS")"; rc=$?
  rc_is "every bean in the set validates" "$rc" 0
  check "and the count is stated"    "bean(s) in" "$out"
  check "with the invalid count"     "0 invalid" "$out"
  # The bare form validates NO bean at all, which is worth pinning: the drift
  # check runs both lines for exactly this reason.
  nope "the bare form is not the corpus form" "bean(s) in" "$(v)"
else
  printf '  SKIP  no corpus directory\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
