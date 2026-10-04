#!/usr/bin/env bash
# test-telemetry-summary.sh — the cross-run quality numbers, from runs whose
# answers are known because the test wrote them.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PIPELINE_DIR/../.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PY="${PIPELINE_PYTHON:-$ROOT/.venv/bin/python}"; [ -x "$PY" ] || PY=python3
PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1));
       else printf '  FAIL  %s — expected %s, got %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }

R="$WORK/runs"
mk() { # mk <run> <status>
  mkdir -p "$R/$1/verdicts"
  jq -nc --arg r "$1" --arg s "$2" '{run_id:$r, bean_id:($r|split("-")[0:2]|join("-")), status:$s}' > "$R/$1/run.json"
}
# Run A: two tasks (one first try, one on the third attempt), a stamped accept on
# impl, a revise on spec, 100 s inside steps of which 10 s loading models.
mk bean-001-A completed
printf '%s\n' \
 '{"ts":"2026-10-01T00:00:00Z","step":"spec","event":"start","attempt":1}' \
 '{"ts":"2026-10-01T00:01:00Z","step":"spec","event":"end","attempt":1,"verdict":"PASS"}' \
 '{"ts":"2026-10-01T05:00:00Z","step":"build","event":"start","attempt":1}' \
 '{"ts":"2026-10-01T05:00:40Z","step":"build","event":"end","attempt":1,"verdict":"PASS"}' > "$R/bean-001-A/steps.jsonl"
printf '%s\n' \
 '{"event":"attempt","task":"task-1","attempt":1,"result":"verified"}' \
 '{"event":"attempt","task":"task-2","attempt":1,"result":"verify_failed"}' \
 '{"event":"attempt","task":"task-2","attempt":2,"result":"verify_failed"}' \
 '{"event":"attempt","task":"task-2","attempt":3,"result":"verified"}' > "$R/bean-001-A/tasks.jsonl"
echo '{"verdict":"revise","judged_by":{"seconds":100}}' > "$R/bean-001-A/verdicts/spec.attempt-1.judgement.json"
echo '{"verdict":"accept","judged_by":{"seconds":300}}' > "$R/bean-001-A/verdicts/impl.attempt-1.judgement.json"
echo '{"verdict":"accept"}' > "$R/bean-001-A/verdicts/impl.attempt-1.json"
echo '{"rule":"quote-not-on-disk"}' > "$R/bean-001-A/verdicts/spec.attempt-1.refused.json"
printf '%s\n' '{"load_seconds":6}' '{"load_seconds":4}' > "$R/bean-001-A/model-loads.jsonl"
# Run B: halted in a build task; an advisory (unstamped) accept on impl.
mk bean-002-B halted
jq -c '. + {halted_at_step:"build"}' "$R/bean-002-B/run.json" > "$WORK/t" && mv "$WORK/t" "$R/bean-002-B/run.json"
mkdir -p "$R/bean-002-B/build/task-1" && : > "$R/bean-002-B/build/task-1/BLOCKED.md"
echo '{"verdict":"accept","judged_by":{"seconds":200}}' > "$R/bean-002-B/verdicts/impl.attempt-1.judgement.json"
printf '%s\n' '{"run_id":"bean-001-A","defect_class":"defect"}' '{"run_id":"bean-002-B","defect_class":"requirement_miss"}' > "$WORK/index.jsonl"

"$PY" "$PIPELINE_DIR/telemetry-summary.py" "$R" --reviews "$WORK/index.jsonl" --json "$WORK/out.json" >/dev/null
S() { jq -r "$1" "$WORK/out.json"; }
eq "two runs"                              2 "$(S .summary.runs)"
eq "two tasks"                             2 "$(S .summary.task_attempts.tasks)"
eq "mean attempts (1 and 3)"              2 "$(S .summary.task_attempts.mean)"
eq "first-try rate"                        0.5 "$(S .summary.task_attempts.first_try_rate)"
eq "spec revise rate"                      1.0 "$(S .summary.stages.spec.revise_rate)"
eq "impl stamp rate (one of two stamped)"  0.5 "$(S .summary.stages.impl.stamp_rate)"
eq "impl judge median seconds"             250.0 "$(S .summary.stages.impl.judge_seconds_median)"
eq "swap overhead: 10 s of 100 s in steps" 10.0 "$(S .summary.swap_overhead_pct)"
eq "not 10 s of five hours"                100 "$(S '.runs[] | select(.run_id=="bean-001-A") | .active_seconds')"
eq "refusals by rule"                      1 "$(S '.summary.refusals_by_rule["quote-not-on-disk"]')"
eq "blocked at the task"                   1 "$(S '.summary.blocked_reasons["build:task-1"]')"
eq "a stamped accept on defective code is a false approval" 1 "$(S '.summary.false_approvals_by_class.defect')"
eq "an advisory accept approved nothing"   null "$(S '.summary.false_approvals_by_class.requirement_miss')"
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]
