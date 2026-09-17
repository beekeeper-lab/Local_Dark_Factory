#!/usr/bin/env bash
# test-telemetry.sh — where a run's time and tokens went, and to which step.
#
# This is the file every later decision about the line reads from: whether a
# stage is worth its cost, whether a judge swap paid for itself, how long twenty
# beans would take. A wrong number here is not caught by anything downstream,
# because downstream is a human looking at a table and believing it.
#
# The attribution is the whole difficulty. A run spans one session file per child
# step plus the orchestrator's own, and events have to land on the right row:
# a file claimed by exactly one step is entirely that step's, a file claimed by
# several is split by their start/end windows, and whatever belongs to none is
# the orchestrator's — so driver overhead stays visible rather than being spread
# silently across the work.
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
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

R="$WORK/run"; mkdir -p "$R"
SESS="$WORK/sessions"; mkdir -p "$SESS"

msg() { # msg <file> <ts> <role> <in> <out> <reasoning> [tool] [iserror]
  jq -cn --arg ts "$2" --arg role "$3" --argjson i "$4" --argjson o "$5" --argjson r "$6" \
     --arg tool "${7:-}" --argjson err "${8:-false}" \
    '{type:"message", timestamp:$ts,
      message: ({role:$role, usage:{input:$i, output:$o, reasoning:$r}, isError:$err}
                + (if $tool == "" then {} else {toolName:$tool} end))}' >> "$1"
}
step() { # step <step> <attempt> <event> <ts> [verdict] [session_file]
  jq -cn --arg s "$1" --argjson a "$2" --arg e "$3" --arg ts "$4" \
     --arg v "${5:-}" --arg f "${6:-}" \
    '{ts:$ts, step:$s, event:$e, attempt:$a,
      verdict:(if $v == "" then null else $v end)}
     + (if $f == "" then {} else {session_file:$f} end)' >> "$R/steps.jsonl"
}

tr_() { ( bash "$PIPELINE_DIR/telemetry-report.sh" "$R" 2>&1 ); }

# --------------------------------------------------------------------------
printf '\n== one session file per step, which is the ordinary case ==\n\n'
cat > "$R/run.json" <<'RJ'
{"schema_version":"run-record/1.0.0","run_id":"bean-001-T","bean":"bean-001","bean_id":"bean-001","status":"completed"}
RJ
SPEC_S="$SESS/spec.jsonl"; BUILD_S="$SESS/build.jsonl"
msg "$SPEC_S" "2026-09-15T10:00:10Z" assistant 1000 100 50
msg "$SPEC_S" "2026-09-15T10:00:20Z" toolResult 0 0 0 read
msg "$SPEC_S" "2026-09-15T10:00:30Z" assistant 2000 200 100
msg "$BUILD_S" "2026-09-15T10:10:10Z" assistant 500 50 25 "" true
msg "$BUILD_S" "2026-09-15T10:10:20Z" toolResult 0 0 0 write

step spec  1 start "2026-09-15T10:00:00Z"
step spec  1 end   "2026-09-15T10:05:00Z" PASS "$SPEC_S"
step build 1 start "2026-09-15T10:10:00Z"
step build 1 end   "2026-09-15T10:12:00Z" PASS "$BUILD_S"

out="$(tr_)"; rc=$?
rc_is "it succeeds"                    "$rc" 0
want  "telemetry.json is written"      "telemetry.json should exist" test -f "$R/telemetry.json"
T="$(cat "$R/telemetry.json")"

eq "the spec step got its own tokens"  "3000" "$(jq -r '.steps[] | select(.step=="spec") | .input_tokens' <<<"$T")"
eq "and its turns"                     "2"    "$(jq -r '.steps[] | select(.step=="spec") | .turns' <<<"$T")"
eq "and its output"                    "300"  "$(jq -r '.steps[] | select(.step=="spec") | .output_tokens' <<<"$T")"
eq "and its reasoning"                 "150"  "$(jq -r '.steps[] | select(.step=="spec") | .reasoning_tokens' <<<"$T")"
eq "the build step got only its own"   "500"  "$(jq -r '.steps[] | select(.step=="build") | .input_tokens' <<<"$T")"
eq "its error is counted"              "1"    "$(jq -r '.steps[] | select(.step=="build") | .errors' <<<"$T")"
eq "and its tool use"                  "1"    "$(jq -r '.steps[] | select(.step=="build") | .tools.write' <<<"$T")"
eq "durations come from the step log"  "300"  "$(jq -r '.steps[] | select(.step=="spec") | .duration_s' <<<"$T")"
# And when the end line carries a measured duration, that wins: both boundaries
# of a model step are written after the work, so the gap between them is zero for
# exactly the steps that take the time.
printf '{"ts":"2026-09-15T14:00:00.000Z","step":"doc","event":"start","attempt":1,"verdict":null}\n' >> "$R/steps.jsonl"
printf '{"ts":"2026-09-15T14:00:00.006Z","step":"doc","event":"end","attempt":1,"verdict":"PASS","duration_s":947}\n' >> "$R/steps.jsonl"
out="$(tr_)"
eq "a measured duration wins over the gap" "947" \
   "$(jq -r '.steps[] | select(.step=="doc") | .duration_s' "$R/telemetry.json")"
eq "the mean is per turn, not per event" "1500" "$(jq -r '.steps[] | select(.step=="spec") | .mean_input_tokens_per_turn' <<<"$T")"
eq "totals add the steps up"           "3500" "$(jq -r '.totals.input' <<<"$T")"

printf '\n-- and the table says the same thing --\n\n'
check "the step appears"               "spec (try 1); PASS" "$out"
check "with its numbers"               "| 300 | 2 | 3000 |" "$out"
check "the orchestrator has its own row" "(orchestrator)" "$out"
check "and there is a total"           "| TOTAL |" "$out"

# --------------------------------------------------------------------------
printf '\n== the orchestrator row exists so driver overhead stays visible ==\n\n'
#
# Events in the run's own session that no step claims are the driver's. Folding
# them into the steps would make every stage look more expensive than it is and
# hide the cost of the thing doing the orchestrating.
rm -f "$R/steps.jsonl" "$R/telemetry.json"
ORCH_S="$SESS/orch.jsonl"
msg "$ORCH_S" "2026-09-15T09:59:00Z" assistant 700 70 0
msg "$ORCH_S" "2026-09-15T10:03:00Z" assistant 900 90 0
jq --arg f "$ORCH_S" '. + {pi_session_file:$f}' "$R/run.json" > "$WORK/rj" && mv "$WORK/rj" "$R/run.json"
step spec 1 start "2026-09-15T10:00:00Z"
step spec 1 end   "2026-09-15T10:05:00Z" PASS "$SPEC_S"
out="$(tr_)"
T="$(cat "$R/telemetry.json")"
# Both of the driver's events are the driver's, including the one that falls
# inside the spec step's window: spec has a session file of its own, and what it
# spent is in that file. An event in the orchestrator's session during a step is
# the orchestrator doing something, not the step.
eq "the driver's events are the driver's" "1600" "$(jq -r '.orchestrator.input' <<<"$T")"
eq "the step keeps only its own file"     "3000" "$(jq -r '.steps[] | select(.step=="spec") | .input_tokens' <<<"$T")"
eq "and the total counts each once"       "4600" "$(jq -r '.totals.input' <<<"$T")"
eq "the driver's turns are visible too"   "2"    "$(jq -r '.orchestrator.turns' <<<"$T")"

printf '\n-- but a step with no session file of its own still borrows from it --\n\n'
#
# Runs from before children recorded their own session files. The orchestrator's
# events are split by the step windows, which is the only attribution available.
rm -f "$R/steps.jsonl" "$R/telemetry.json"
step gate 1 start "2026-09-15T10:02:00Z"
step gate 1 end   "2026-09-15T10:04:00Z" PASS
out="$(tr_)"
T="$(cat "$R/telemetry.json")"
eq "the event inside the window is the step's" "900" "$(jq -r '.steps[] | select(.step=="gate") | .input_tokens' <<<"$T")"
eq "and the one outside is the driver's"       "700" "$(jq -r '.orchestrator.input' <<<"$T")"

# --------------------------------------------------------------------------
printf '\n== a session file that is gone ==\n\n'
#
# A run can outlive the machine its children ran on. That is a warning and a
# skipped file, never a failure: the rest of the record is still the record.
rm -f "$R/steps.jsonl" "$R/telemetry.json"
step spec 1 start "2026-09-15T10:00:00Z"
step spec 1 end   "2026-09-15T10:05:00Z" PASS "$SESS/vanished.jsonl"
out="$(tr_)"; rc=$?
rc_is "it still succeeds"              "$rc" 0
check "and says which file went"       "session file not found" "$out"
eq "the step is still in the report"   "spec" "$(jq -r '.steps[0].step' "$R/telemetry.json")"
eq "with zeroes rather than a hole"    "0"    "$(jq -r '.steps[0].input_tokens' "$R/telemetry.json")"

# --------------------------------------------------------------------------
printf '\n== a run driven outside a pi session ==\n\n'
#
# Tests and cron record a null pi_session_file. Nothing dies.
rm -f "$R/steps.jsonl" "$R/telemetry.json"
jq 'del(.pi_session_file)' "$R/run.json" > "$WORK/rj" && mv "$WORK/rj" "$R/run.json"
step gate 1 start "2026-09-15T11:00:00Z"
step gate 1 end   "2026-09-15T11:00:30Z" PASS
out="$(tr_)"; rc=$?
rc_is "it succeeds"                    "$rc" 0
eq "the session is recorded as null"   "null" "$(jq -r '.run.session_file' "$R/telemetry.json")"
eq "and a step with no model still has a duration" "30" "$(jq -r '.steps[0].duration_s' "$R/telemetry.json")"

# --------------------------------------------------------------------------
printf '\n== a step that started and never ended ==\n\n'
#
# An interrupted run is the most likely thing to be reading this report, so an
# open step must appear as open rather than be dropped or given a made-up end.
rm -f "$R/steps.jsonl" "$R/telemetry.json"
step doc 1 start "2026-09-15T12:00:00Z"
out="$(tr_)"; rc=$?
rc_is "it succeeds"                    "$rc" 0
eq "the step is marked open"           "true" "$(jq -r '.steps[0].open' "$R/telemetry.json")"
eq "and has no invented duration"      "null" "$(jq -r '.steps[0].duration_s' "$R/telemetry.json")"
check "the table says so"              "OPEN" "$out"

# --------------------------------------------------------------------------
printf '\n== retries are separate rows, not one merged step ==\n\n'
#
# "doc took ninety minutes" and "doc took three attempts of thirty" are different
# facts, and only the second explains anything.
rm -f "$R/steps.jsonl" "$R/telemetry.json"
A1="$SESS/doc1.jsonl"; A2="$SESS/doc2.jsonl"
msg "$A1" "2026-09-15T13:00:10Z" assistant 100 10 0
msg "$A2" "2026-09-15T13:10:10Z" assistant 200 20 0
step doc 1 start "2026-09-15T13:00:00Z"
step doc 1 end   "2026-09-15T13:05:00Z" FAIL "$A1"
step doc 2 start "2026-09-15T13:10:00Z"
step doc 2 end   "2026-09-15T13:12:00Z" PASS "$A2"
out="$(tr_)"
T="$(cat "$R/telemetry.json")"
eq "there are two rows"                "2"   "$(jq -r '[.steps[] | select(.step=="doc")] | length' <<<"$T")"
eq "the first is the failure"          "FAIL" "$(jq -r '.steps[] | select(.attempt==1) | .verdict' <<<"$T")"
eq "with its own tokens"               "100" "$(jq -r '.steps[] | select(.attempt==1) | .input_tokens' <<<"$T")"
eq "the second is the one that worked" "200" "$(jq -r '.steps[] | select(.attempt==2) | .input_tokens' <<<"$T")"
check "the table numbers the attempts" "doc (try 2); PASS" "$out"

# --------------------------------------------------------------------------
printf '\n== refusals ==\n\n'
out="$( bash "$PIPELINE_DIR/telemetry-report.sh" "$WORK/nowhere" 2>&1 )"; rc=$?
rc_is "a missing run dir refuses"      "$rc" 1
check "and says so"                    "run directory not found" "$out"
mkdir -p "$WORK/empty"
out="$( bash "$PIPELINE_DIR/telemetry-report.sh" "$WORK/empty" 2>&1 )"; rc=$?
rc_is "a run dir with no run.json refuses" "$rc" 1
check "and names the file"             "run.json not found" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
