#!/usr/bin/env bash
# test-beanstate.sh — the §09 state machine: its table, idempotency, leases, and
# the step.sh hook that drives it.
#
# The leases are the part that has to be right under contention, so they are
# tested under contention: twenty processes race for one bean and exactly one may
# win. A lease test that took turns would pass on a lock that does nothing.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PIPELINE_DIR/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PY="${PIPELINE_PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3
BS=("$PY" "$PIPELINE_DIR/beanstate.py")
export FACTORY_STATE_DIR="$WORK/state"

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
state_of() { "${BS[@]}" state "$1" --json | jq -r --arg b "$1" '.[$b].state'; }
events() { wc -l < "$FACTORY_STATE_DIR/events.jsonl" 2>/dev/null || echo 0; }
reset() { rm -rf "$FACTORY_STATE_DIR"; }

printf '\n== the table is the schema'"'"'s states, and every one is reachable ==\n\n'
out="$("$PY" - "$PIPELINE_DIR" "$ROOT" <<'EOF'
import json, sys, importlib.util
from collections import deque
spec = importlib.util.spec_from_file_location("bs", sys.argv[1] + "/beanstate.py")
bs = importlib.util.module_from_spec(spec); spec.loader.exec_module(bs)
enum = set(json.load(open(sys.argv[2] + "/schemas/event.schema.json"))["$defs"]["state"]["enum"])
table = set(bs.EDGES) | {t for v in bs.EDGES.values() for t in v}
print("missing-from-table", sorted(enum - set(bs.EDGES)))
print("not-in-schema", sorted(table - enum))
seen, q = {"ready"}, deque(["ready"])
while q:
    for n in bs.EDGES[q.popleft()]:
        if n not in seen: seen.add(n); q.append(n)
print("unreachable", sorted(enum - seen))
EOF
)"
check "every schema state is in the table" "missing-from-table []" "$out"
check "the table invents no state"          "not-in-schema []" "$out"
check "every state is reachable from ready" "unreachable []" "$out"

printf '\n== a transition is one legal edge, validated, written once ==\n\n'
reset
out="$("${BS[@]}" transition bean-001 --to leased --key k1 2>&1)"
check "a legal edge is written"            '"to_state": "leased"' "$out"
check "with provenance"                     '"pipeline_version"' "$(cat "$FACTORY_STATE_DIR/events.jsonl")"
n0="$(events)"
out="$("${BS[@]}" transition bean-001 --to building --key k2 2>&1)"; rc=$?
check "an edge not in §09 is refused"       "leased -> building is not a transition" "$out"
want  "and exits non-zero"                  "rc=$rc" test "$rc" -ne 0
want  "and writes nothing"                  "$(events) events, was $n0" test "$(events)" = "$n0"
out="$("${BS[@]}" transition bean-001 --to specifying --key k3 2>&1)"
out="$("${BS[@]}" transition bean-001 --to specifying --key k3 2>&1)"
check "the same key again is a no-op"       '"already": true' "$out"
want  "and is not written twice"            "$(events) events" test "$(events)" = 2
check "the state is the last event's"       "specifying" "$(state_of bean-001)"
out="$("${BS[@]}" transition bean-001 --to blocked --key k4 2>&1)"
check "blocked is reachable from mid-flight" '"to_state": "blocked"' "$out"
out="$("${BS[@]}" transition bean-001 --to specifying --key k5 2>&1)"; rc=$?
check "and is a dead end until cleared"     "blocked -> specifying is not a transition" "$out"

printf '\n== leases: one owner, under contention ==\n\n'
reset
for i in $(seq 1 20); do
  ( "${BS[@]}" lease bean-002 --owner "racer:$i" > "$WORK/race-$i.out" 2>&1; echo $? > "$WORK/race-$i.rc" ) &
done
wait
winners="$(grep -l '^0$' "$WORK"/race-*.rc | wc -l)"
want  "twenty racers, exactly one lease"    "$winners won" test "$winners" = 1
want  "and one ready -> leased event"       "$(events) events" test "$(events)" = 1
check "the loser is told who holds it"      "is leased to racer:" "$(cat "$WORK"/race-*.out)"
reset
"${BS[@]}" lease bean-003 --owner "$(hostname):999999" >/dev/null
out="$("${BS[@]}" lease bean-003 --owner "$(hostname):$$" 2>&1)"
check "a dead owner's lease is taken over"  "has lapsed; taking it" "$out"
reset
"${BS[@]}" lease bean-004 --owner "otherhost:1" --ttl 0 >/dev/null
out="$("${BS[@]}" lease bean-004 --owner "$(hostname):$$" 2>&1)"
check "an expired lease is taken over"      "leased bean-004 to $(hostname):$$" "$out"
out="$("${BS[@]}" release bean-004 --owner "someone:else" 2>&1)"
check "only the owner releases"             "refused: bean-004 is leased to" "$out"
"${BS[@]}" release bean-004 --owner "$(hostname):$$" >/dev/null
check "a lease never started goes back to ready" "ready" "$(state_of bean-004)"

printf '\n== the step hook drives a whole run ==\n\n'
reset
REPO="$WORK/repo"; RD="$REPO/factory/runs/bean-005-R1"; mkdir -p "$RD"
printf '{"run_id":"bean-005-R1","bean_id":"bean-005"}\n' > "$RD/run.json"
unset FACTORY_STATE_DIR
export FACTORY_STATE_DIR="$REPO/factory/runs/.state"
"${BS[@]}" lease bean-005 --owner "$(hostname):$$" >/dev/null
hook() { "${BS[@]}" step "$RD" "$@" 2>&1; }
for s in spec audit-spec build gate audit-impl doc audit-doc audit-package; do
  hook "$s" start >/dev/null; hook "$s" end PASS >/dev/null
done
hook sync start >/dev/null; hook sync end PASS >/dev/null
hook pr start >/dev/null; hook pr end PASS >/dev/null
hook ci start >/dev/null; out="$(hook ci end PASS)"
check "a full run ends merge_pending"        "merge_pending" "$(state_of bean-005)"
check "and says so as it goes"               "ci_pending -> merge_pending" "$out"
seq_="$(jq -r .to_state "$FACTORY_STATE_DIR/events.jsonl" | tr '\n' ' ')"
check "through every §09 state in order"     "leased specifying spec_committing spec_auditing spec_accepted building containing gating committing_candidate impl_auditing impl_accepted documenting doc_committing pre_pr_auditing accepted pushing pushed pr_open ci_pending merge_pending" "$seq_"
n0="$(events)"; hook ci end PASS >/dev/null
want  "a repeated boundary moves nothing"    "$(events) vs $n0" test "$(events)" = "$n0"

reset; "${BS[@]}" lease bean-005 --owner "$(hostname):$$" >/dev/null
for s in spec build gate audit-impl audit-package; do hook "$s" start >/dev/null; hook "$s" end PASS >/dev/null; done
implied="$(jq -r 'select(.detail.implied) | .to_state' "$FACTORY_STATE_DIR/events.jsonl" | tr '\n' ' ')"
check "a small run's skipped stages are implied hops" "spec_auditing spec_accepted documenting doc_committing" "$implied"
check "and it still ends accepted"            "accepted" "$(state_of bean-005)"

reset; "${BS[@]}" lease bean-005 --owner "$(hostname):$$" >/dev/null
hook spec start >/dev/null; hook spec end PASS >/dev/null; hook audit-spec start >/dev/null
hook audit-spec end FAIL >/dev/null
check "a failed audit moves nothing"          "spec_auditing" "$(state_of bean-005)"
hook spec start --attempt 2 >/dev/null
check "and the retry is the revise edge"      "specifying" "$(state_of bean-005)"

reset; "${BS[@]}" lease bean-005 --owner "$(hostname):$$" >/dev/null
hook spec start >/dev/null; hook spec end PASS >/dev/null
hook spec start --attempt 2 >/dev/null
check "a spec-check retry goes straight back" '"from_state":"spec_committing","to_state":"specifying"' "$(tail -1 "$FACTORY_STATE_DIR/events.jsonl")"

printf '\n== a halt blocks, and only a person unblocks ==\n\n'
"${BS[@]}" block bean-005 --key halt-1 --why "halted at spec" >/dev/null
check "a halt is blocked"                     "blocked" "$(state_of bean-005)"
out="$("${BS[@]}" lease bean-005 --owner "$(hostname):$$" 2>&1)"; rc=$?
check "a blocked bean cannot be leased"       "a person clears it first" "$out"
out="$("${BS[@]}" clear bean-005 --by tester 2>&1)"
check "clear is recorded with who"            "cleared by tester" "$out"
check "and the bean is ready"                 "ready" "$(state_of bean-005)"

printf '\n== resuming picks up where the run stopped ==\n\n'
reset; "${BS[@]}" lease bean-005 --owner "$(hostname):$$" >/dev/null
hook spec start >/dev/null; hook spec end PASS >/dev/null; hook audit-spec start >/dev/null; hook audit-spec end PASS >/dev/null
hook build start >/dev/null
"${BS[@]}" release bean-005 --owner "$(hostname):$$" >/dev/null   # the process died
out="$("${BS[@]}" lease bean-005 --owner "$(hostname):$$" 2>&1)"
check "a fresh run is refused mid-flight"     "resume that run" "$out"
out="$("${BS[@]}" lease bean-005 --owner "$(hostname):$$" --resume 2>&1)"
check "a resume takes the lease"              "leased bean-005" "$out"
check "without moving the bean"               "building" "$(state_of bean-005)"
reset; "${BS[@]}" lease bean-006 --owner "$(hostname):$$" >/dev/null
RD6="$REPO/factory/runs/bean-006-R1"; mkdir -p "$RD6"
printf '{"run_id":"bean-006-R1","bean_id":"bean-006"}\n' > "$RD6/run.json"
FACTORY_RESUME=1 "${BS[@]}" step "$RD6" gate start >/dev/null 2>&1
last="$(tail -1 "$FACTORY_STATE_DIR/events.jsonl")"
check "a resume from leased is one hop"       '"from_state":"leased","to_state":"gating"' "$last"
check "marked as a resume"                    '"resume":true' "$last"

printf '\n== step.sh drives the hook ==\n\n'
reset; "${BS[@]}" lease bean-005 --owner "$(hostname):$$" >/dev/null
: > "$RD/steps.jsonl"
bash "$PIPELINE_DIR/step.sh" "$RD" spec start >/dev/null 2>&1
check "a step boundary moves the bean"        "specifying" "$(state_of bean-005)"
FACTORY_STATE=0 bash "$PIPELINE_DIR/step.sh" "$RD" spec end PASS >/dev/null 2>&1
check "FACTORY_STATE=0 leaves it alone"       "specifying" "$(state_of bean-005)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
