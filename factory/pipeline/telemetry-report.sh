#!/usr/bin/env bash
# telemetry-report.sh — attribute Pi session tokens/time to pipeline steps; write telemetry.json.
#
# A run now spans one session file per child step (recorded as `session_file`
# on the step's end line in steps.jsonl), plus the orchestrator's own session
# from run.json (`pi_session_file`, which may be null).
#
# Attribution rules:
#   - A session file claimed by exactly one step row → all of its events are
#     that step's (a child does only its own step).
#   - A session file claimed by several rows (rare/shared) → events are split
#     by the rows' start/end windows; anything outside a window goes to the
#     earliest row.
#   - The orchestrator's own file (run.json's), when no step claims it →
#     legacy behavior: split over step rows by window; anything outside all
#     windows (or the whole file when no step rows exist) is the ORCHESTRATOR
#     row, so driver overhead is visible separately from the work.
#   - Files referenced but missing → warning + skipped (a run can outlive the
#     machine its children ran on).
#   - pi_session_file may be null (runs driven outside a Pi session, e.g.
#     tests/cron) — nothing dies.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="telemetry-report.sh <run_dir>"
case "${1:-}" in
  --version)
    cat "$PIPELINE_DIR/VERSION"
    exit 0
    ;;
  -h|--help)
    echo "telemetry-report.sh — build per-step telemetry from the Pi session JSONL(s) and steps.jsonl."
    echo "$USAGE"
    echo ""
    echo "Writes <run_dir>/telemetry.json and prints a Markdown table."
    echo "Aggregates every session file recorded per step in steps.jsonl plus the"
    echo "orchestrator session from run.json (row '(orchestrator)'), handles missing"
    echo "files and a null pi_session_file, and keeps the mean in/turn column."
    exit 0
    ;;
esac
require_args "$#" 1 "$USAGE"
require_cmd jq

RUN_DIR="$1"
[ -d "$RUN_DIR" ] || die "run directory not found: $RUN_DIR"
RUN_JSON="$RUN_DIR/run.json"
[ -f "$RUN_JSON" ] || die "run.json not found: $RUN_JSON"

# The orchestrator's own session file; null is legitimate (runs driven outside
# a Pi session record that) — no longer a fatal error.
RUN_SESS="$(jq -r '.pi_session_file // empty' "$RUN_JSON")"

RUN_ID="$(jq -r '.run_id // empty' "$RUN_JSON")"
BEAN="$(jq -r '.bean // empty' "$RUN_JSON")"

STEPS_FILE="$RUN_DIR/steps.jsonl"
[ -f "$STEPS_FILE" ] || : > "$STEPS_FILE"

# ---------------------------------------------------------------- sessions --
# Collect the referenced session files (unique, existence-checked) in order:
# step-recorded first, then the orchestrator's.
declare -A SEEN_FILES=()
FILES=()
add_file() {
  local f="$1"
  [ -n "$f" ] || return 0
  [ -n "${SEEN_FILES[$f]:-}" ] && return 0
  SEEN_FILES["$f"]=1
  if [ -f "$f" ]; then
    FILES+=("$f")
  else
    printf 'warning: session file not found, skipping: %s\n' "$f" >&2
  fi
}
while IFS= read -r f; do
  add_file "$f"
done < <(jq -rs 'map(select(.event == "end") | .session_file // null) | map(select(. != null)) | unique | .[]' "$STEPS_FILE")
add_file "$RUN_SESS"

# Per-file events, streamed to a JSONL work file (one {file, events} object per
# line). jq reads every session file itself (--slurpfile), so no session content
# crosses a command-line argument: the old `--argjson ev "$ev"` / `--argjson
# files "$files_json"` form blew ARG_MAX on real runs (BEAN-129). The final
# report is written to a temp file and moved into place only on success, so a
# failure never leaves a truncated telemetry.json behind.
FILES_JSONL="$(mktemp)"
TELE_TMP="$(mktemp "$RUN_DIR/.telemetry.json.XXXXXX")"
trap 'rm -f "$FILES_JSONL" "$TELE_TMP"' EXIT
: > "$FILES_JSONL"
for f in ${FILES[@]+"${FILES[@]}"}; do
  jq -cn --arg fn "$f" --slurpfile ev "$f" '
      [ $ev[] | select(.type == "message")
        | { ts: .timestamp,
            turn: (.message.role == "assistant"),
            usage: (.message.usage? // null),
            tool: (.message.toolName? // null),
            err: (.message.isError? // false) } ] as $events
    | { file: $fn, events: $events }' >> "$FILES_JSONL"
done

# jq's strptime/mktime treat the broken-down time as UTC only when TZ=UTC.
export TZ=UTC
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

JQ_PROG='
def epoch: sub("\\.[0-9]+"; "") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;

def empty_agg: { turns: 0, input: 0, output: 0, reasoning: 0, tools: {}, errors: 0 };

def agg($evs):
  { turns: ([$evs[] | select(.turn)] | length),
    input: ([$evs[] | .usage.input? // 0] | add // 0),
    output: ([$evs[] | .usage.output? // 0] | add // 0),
    reasoning: ([$evs[] | .usage.reasoning? // 0] | add // 0),
    tools: ([$evs[] | select(.tool != null)] | group_by(.tool)
            | map({ key: .[0].tool, value: length }) | from_entries),
    errors: ([$evs[] | select(.err)] | length) };

def add_agg($a; $b):
  { turns: $a.turns + $b.turns,
    input: $a.input + $b.input,
    output: $a.output + $b.output,
    reasoning: $a.reasoning + $b.reasoning,
    tools: (([$a.tools | to_entries[]] + [$b.tools | to_entries[]])
            | group_by(.key)
            | map({ key: .[0].key, value: ([.[].value] | add) })
            | from_entries),
    errors: $a.errors + $b.errors };

def mean_in($m): if $m.turns > 0 then (($m.input / $m.turns * 10 | round) / 10) else null end;

# Step rows: one per (step, attempt) start line, joined to its end line.
( [ $steps[] | select(.event == "start") ]
  | map( . as $s
    | ([ $steps[] | select(.event == "end" and .step == $s.step and .attempt == $s.attempt) ] | last) as $en
    | ( if $en == null then null else $en.ts end ) as $ended
    | { step: $s.step, attempt: $s.attempt,
        key: ($s.step + "|" + ($s.attempt | tostring)),
        started_at: $s.ts,
        ended_at: $ended,
        open: ($en == null),
        verdict: (if $en != null then ($en.verdict // null) else null end),
        duration_s: (if $ended != null then ((($ended) | epoch) - (($s.ts) | epoch)) else null end),
        session_file: (if $en != null then ($en.session_file // null) else null end) }
  )) as $rows
|
# Pick the owning row of an event inside a file claimed by one or more rows.
def pick_row($f; $ts):
  [ $rows[] | select(.session_file == $f) ] as $refs
  | ([ $refs[] | select(.started_at <= $ts and ((.ended_at == null) or ($ts <= .ended_at))) ]
     | sort_by(.started_at) | first)
    // ([ $refs[] ] | sort_by(.started_at) | first);

# Legacy mode (orchestrator file, no step claims it): window-match against rows
# that have no session file of their own; null → the orchestrator.
def pick_legacy($ts):
  [ $rows[] | select(.session_file == null) ] as $legacy
  | ([ $legacy[] | select(.started_at <= $ts and ((.ended_at == null) or ($ts <= .ended_at))) ]
     | sort_by(.started_at) | first)
    // null;

# Assign every event to exactly one place: a step row ("key") or the
# orchestrator ("__orch__"). Each event lands exactly once — no double count.
{ acc: (reduce $rows[] as $r ({}; .[$r.key] = empty_agg)),
  orch: empty_agg } as $init
| (reduce $files[] as $e ($init;
    $e.file as $f
    | if ([ $rows[] | select(.session_file == $f) ] | length) > 0 then
        ( (if ([ $rows[] | select(.session_file == $f) ] | length) == 1 then
            [ { k: ([ $rows[] | select(.session_file == $f) ] | first).key, ev: $e.events } ]
          else
            [ $e.events[] | . as $ev | { k: (pick_row($f; $ev.ts).key), ev: $ev } ]
          end ) as $assign
          | (reduce $assign[] as $a (. ; .acc[$a.k] = add_agg(.acc[$a.k]; agg($a.ev)))) )
      elif ($f == $run_sess) then
        # The orchestrator file. Its events go to a step only when that step
        # has no session file of its own, which means a run from before children
        # recorded theirs. Otherwise they belong to the driver, which is the
        # whole point of having a separate row for it.
        #
        # A guard here produced an EMPTY assignment whenever every step owned a
        # session file, which is every run since children began recording them:
        # every event in the orchestrator file was dropped on the floor. The row
        # read 0 for every run and the totals were short by the entire driver
        # cost, while the header comment at the top of this file described the
        # behaviour it now has. Found by the first test written against it.
        #
        # No apostrophes in this comment on purpose: the whole jq program is one
        # single-quoted shell string, and one apostrophe ends it.
        ( ( [ $e.events[] | . as $ev | (pick_legacy($ev.ts)) as $r
              | if $r == null then { k: "__orch__", ev: $ev } else { k: $r.key, ev: $ev } end
            ] ) as $assign
          | (reduce $assign[] as $a (. ;
               if $a.k == "__orch__" then .orch = add_agg(.orch; agg([$a.ev]))
               else .acc[$a.k] = add_agg(.acc[$a.k]; agg([$a.ev])) end)) )
      else
        (.orch = add_agg(.orch; agg($e.events)))
      end)) as $st

| ( $rows | sort_by(.started_at) ) as $sorted
| ( [ $sorted[] as $r
    | (($st.acc[$r.key] // empty_agg)) as $m
    | $r + { turns: $m.turns,
             input_tokens: $m.input,
             output_tokens: $m.output,
             reasoning_tokens: $m.reasoning,
             tools: $m.tools,
             errors: $m.errors,
             mean_input_tokens_per_turn: mean_in($m) } ] ) as $strows

| ( reduce $strows[] as $r ($st.orch;
      add_agg( .; { turns: $r.turns, input: $r.input_tokens, output: $r.output_tokens,
                    reasoning: $r.reasoning_tokens, tools: $r.tools, errors: $r.errors } )) ) as $tot

| { generated_at: $generated_at,
    run: { run_id: $run_id, bean: $bean,
           session_file: (if $run_sess == "" then null else $run_sess end),
           session_files: [ $files[].file ] },
    orchestrator: ($st.orch + { mean_input_tokens_per_turn: mean_in($st.orch) }),
    steps: $strows,
    totals: ($tot + { mean_input_tokens_per_turn: mean_in($tot) })
  }
'

jq -n \
  --slurpfile files "$FILES_JSONL" \
  --slurpfile steps "$STEPS_FILE" \
  --arg run_id "$RUN_ID" \
  --arg bean "$BEAN" \
  --arg run_sess "$RUN_SESS" \
  --arg generated_at "$GENERATED_AT" \
  "$JQ_PROG" > "$TELE_TMP"
mv "$TELE_TMP" "$RUN_DIR/telemetry.json"

# Readable Markdown table.
jq -r '
  def fmt(v): if v == null then "—" else (v | tostring) end;
  def tools_str(m): (m.tools // {} | to_entries | map("\(.key)=\(.value)") | join(", "));
  def row(lbl; dur; m):
    "| \(lbl) | \(fmt(dur)) | \(m.turns) | \(m.input) | \(m.output) | \(m.reasoning) | \(tools_str(m)) | \(m.errors) | \(fmt(m.mean_input_tokens_per_turn)) |";
  [
    "| step | dur (s) | turns | in | out | reason | tools | err | mean in/turn |",
    "|---|---|---|---|---|---|---|---|---|",
    (row("(orchestrator)"; null; .orchestrator)),
    (.steps[]
     | (if .open then (.step + " (try \(.attempt)) — OPEN") else (.step + " (try \(.attempt))" + "; " + (.verdict // "no verdict")) end) as $lbl
     | row($lbl; .duration_s; { turns, input: .input_tokens, output: .output_tokens, reasoning: .reasoning_tokens, tools, errors, mean_input_tokens_per_turn })),
    (row("TOTAL"; ([.steps[] | .duration_s] | map(select(. != null)) | add // null); .totals))
  ] | .[]
' "$RUN_DIR/telemetry.json"
