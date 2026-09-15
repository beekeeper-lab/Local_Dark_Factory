#!/usr/bin/env bash
# step.sh — append one step start/end marker line to <run_dir>/steps.jsonl.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="step.sh <run_dir> <step-name> start|end [verdict]"
case "${1:-}" in
  --version)
    cat "$PIPELINE_DIR/VERSION"
    exit 0
    ;;
  -h|--help)
    echo "step.sh — record a pipeline step boundary (start/end) in <run_dir>/steps.jsonl."
    echo "$USAGE"
    echo ""
    echo "Each line: {ts, step, event, attempt, verdict}. attempt is 1 + the number of"
    echo "completed (end) events for the same step, so retries get attempt 2, 3, ...."
    echo "Invariant: every end closes an open start of the same attempt — an attempt"
    echo "must be started before it can be closed, and an already-closed attempt"
    echo "cannot be closed again (telemetry joins end lines to starts on (step, attempt),"
    echo "so an unopened end is dropped and its work is misattributed)."
    echo "Tokens and durations are NOT recorded here — they come from Pi's own session log."
    echo "STEP_TS=<iso8601> overrides the timestamp, for a caller that must write a"
    echo "boundary after the fact but knows when it really happened."
    exit 0
    ;;
esac
require_args "$#" 3 "$USAGE"
require_cmd jq

RUN_DIR="$1"
STEP="$2"
EVENT="$3"
VERDICT="${4:-}"

[ -d "$RUN_DIR" ] || die "run directory not found: $RUN_DIR"
[[ "$STEP" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "step name must be alphanumeric/hyphen (got: $STEP)"
case "$EVENT" in
  start|end) ;;
  *) die "event must be start or end (got: $EVENT)" ;;
esac

STEPS_FILE="$RUN_DIR/steps.jsonl"
[ -f "$STEPS_FILE" ] || : > "$STEPS_FILE"

# Attempt = 1 + number of completed attempts of this step so far (consistent for both start and end).
# Invariant: an end closes an OPEN start — attempts are started before they are
# closed, and an attempt is closed exactly once. Without this, steps.jsonl could
# carry an `end` with no matching `start`, which telemetry-report.sh (which joins
# ends to starts on (step, attempt)) would drop, misattributing the work.
starts="$(jq -rs --arg s "$STEP" '[.[] | select(.step == $s and .event == "start")] | length' "$STEPS_FILE")"
ends="$(jq -rs --arg s "$STEP" '[.[] | select(.step == $s and .event == "end")] | length' "$STEPS_FILE")"
attempt=$((ends + 1))
if [ "$EVENT" = "start" ] && [ "$starts" -gt "$ends" ]; then
  die "step '$STEP' already has an open attempt (starts=$starts, ends=$ends); close it before starting another"
fi
if [ "$EVENT" = "end" ] && [ "$starts" -lt "$attempt" ]; then
  die "cannot close attempt $attempt of '$STEP': no open start (starts=$starts, ends=$ends); an attempt must be started before it is closed"
fi

# STEP_TS lets a caller record when the step actually began rather than when this
# line is written.
#
# run-step.sh writes both boundaries after the child has finished, because the
# reconciliation it does — deciding whether the child opened its own attempt —
# can only be done once the child has exited. That is the right order for the
# bookkeeping and the wrong one for the clock: every model step recorded an
# elapsed time of zero, including a spec step that had taken sixteen minutes.
# The one column meant to answer "what does a bean cost" was blank for exactly
# the steps that cost anything.
ts="${STEP_TS:-$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)}"
if [ -n "$VERDICT" ]; then
  verdict_json="$(jq -cn --arg v "$VERDICT" '$v')"
else
  verdict_json="null"
fi

jq -cn \
  --arg ts "$ts" \
  --arg step "$STEP" \
  --arg event "$EVENT" \
  --argjson attempt "$attempt" \
  --argjson verdict "$verdict_json" \
  '{ts: $ts, step: $step, event: $event, attempt: $attempt, verdict: $verdict}' >> "$STEPS_FILE"
