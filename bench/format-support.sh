#!/usr/bin/env bash
# format-support.sh — can this model hold the judgement schema at this thinking level?
#
# The judge's contract depends on constrained decoding: the answer is a judgement
# object, not an essay about one, and audit-check refuses anything that is not the
# contract shape. roles.json binds each role to a model AND a thinking level, and
# until this existed nothing checked that the pair could actually produce a
# judgement.
#
# It cannot be assumed, and the two candidates fail in opposite directions:
#
#   gpt-oss:120b   holds the schema at thinking=medium, returns EMPTY at think=false
#   gemma4:26b     holds the schema at think=false,     returns EMPTY at thinking=medium
#
# Neither is an error. Ollama reports success both times and returns a message
# with empty content, which every caller downstream has to guess the meaning of.
# So the pair is measured, not chosen: a model is eligible for the judge role only
# at a thinking level where it holds the real schema.
#
# The schema used here is judge.sh's own, read from the file, so this cannot drift
# away from what the judge actually asks for.
set -uo pipefail
# Run from a copy, always, without anyone having to remember.
#
# bash reads a script by byte offset as it executes, so editing one mid-run
# corrupts the run in progress. A three-pass measurement is seventy-five minutes
# — exactly the window in which someone improves the script — and on 2026-09-16
# that produced a zero-byte results file from a run whose numbers survived only
# because they had been printed to a terminal.
#
# `bench/snapshot.sh` existed for a day and was used once, by hand. A protection
# that depends on remembering it is not a protection, so the harness re-execs
# itself through the launcher. FACTORY_NO_SNAPSHOT=1 opts out, for iterating on
# the harness where seeing a change take effect is the point.
if [ "${FACTORY_BENCH_SNAPSHOTTED:-0}" != 1 ] && [ "${FACTORY_NO_SNAPSHOT:-0}" != 1 ]; then
  exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/snapshot.sh" \
    "$(basename "${BASH_SOURCE[0]}")" "$@"
fi

# Nothing else may be using the GPU. See inflight.sh for why this matters even
# for a harness that evicts nothing.
# shellcheck source=inflight.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inflight.sh"
# Every figure carries where and on what it was measured. One emitter, because
# two lists of what a figure must record is one list that disagrees with itself.
# shellcheck source=provenance.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/provenance.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPE="$HERE/../factory/pipeline"
HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"

# The real thing, not a copy of it.
SCHEMA="$(sed -n "/^SCHEMA='/,/^}'$/p" "$PIPE/judge.sh" | sed "1s/^SCHEMA='//; \$s/'$//")"
jq -e . >/dev/null 2>&1 <<<"$SCHEMA" || { echo "could not read the judgement schema out of judge.sh" >&2; exit 1; }

QUESTION='You are reviewing a plan. Reply with the judgement object: verdict,
criteria, findings, confidence. Nothing else.'

# The payload has to be realistic or this measures nothing. Measured: every model
# here holds the schema on a 200-byte question at every thinking level, including
# the two that failed to hold it inside a real audit. The failures appear only
# under a full set of artifacts — roughly 18KB — so a probe that asks a short
# question and reports "eligible" is a probe that would have cleared both models
# that then produced a markdown fence and an empty answer.
#
# --artifacts <dir> loads spec.md and tasks.yaml from a run directory and sends
# them the way judge.sh does: one message each, ahead of the question.
usage() {
  cat <<'EOF'
format-support.sh — which (model, thinking) pairs hold the judgement schema.

usage: format-support.sh [--artifacts <run-dir>] [--out <results.json>] [model ...]

With no models named, every model ollama has except embedding and vision ones.
--artifacts loads spec.md and tasks.yaml from a run directory and sends them the
way judge.sh does — one message each, ahead of the question — because the
failures this exists to find appear only under a full set of artifacts.
EOF
}

ART_DIR=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ART_DIR="${2:?--artifacts needs a run directory}"; shift 2 ;;
    --out)       OUT="${2:?--out needs a path}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    # An unrecognised flag was being taken as a model name, so `--help` ran four
    # requests against a model called "--help", printed a table of four failures,
    # and wrote a results file. A harness that reads a flag as data produces a
    # figure about nothing, and this one writes that figure to bench/results
    # where it looks exactly like a measurement.
    -*)          usage >&2; printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    *)           ARGS+=( "$1" ); shift ;;
  esac
done
set -- ${ARGS+"${ARGS[@]}"}

refuse_if_inflight

PAYLOAD='[]'
if [ -n "$ART_DIR" ]; then
  for f in "$ART_DIR/spec.md" "$ART_DIR/tasks.yaml"; do
    [ -f "$f" ] || continue
    PAYLOAD="$(jq -c --rawfile c "$f" --arg n "$(basename "$f")" \
      '. + [{role:"user", content:("===== \($n) =====\n" + $c)}]' <<<"$PAYLOAD")"
  done
  printf 'payload: %s artifact(s), %s bytes\n' \
    "$(jq length <<<"$PAYLOAD")" "$(jq -r '[.[].content | length] | add // 0' <<<"$PAYLOAD")"
else
  # Say it, every time, because the answer without artifacts is a different and
  # more flattering answer to a different question. On 2026-09-16 gpt-oss:120b at
  # `medium` came back eligible on a short question and, under 18KB of real
  # artifacts, spent its whole token budget thinking and wrote nothing — which is
  # the configuration the line had been running for two days.
  printf 'NO ARTIFACTS — this asks a short question, and the failures this harness\n'
  printf 'exists to find appear only under a full set. Pass --artifacts <run-dir>\n'
  printf 'before believing anything below.\n'
fi

LEVELS=( false low medium high )
MODELS=( "$@" )
if [ "${#MODELS[@]}" -eq 0 ]; then
  mapfile -t MODELS < <(ollama list 2>/dev/null | awk 'NR>1 && $1 !~ /embed|vl:/ {print $1}')
fi

printf '\nthe judgement schema, by model and thinking level\n\n'
printf '%-30s %-8s %-7s %-6s %s\n' MODEL THINKING HOLDS SECS WHAT-CAME-BACK

RESULTS='[]'
for m in "${MODELS[@]}"; do
  for lvl in "${LEVELS[@]}"; do
    body="$(jq -n --arg m "$m" --arg q "$QUESTION" --argjson f "$SCHEMA" --arg t "$lvl" \
      --argjson pay "$PAYLOAD" \
      '{model:$m, stream:false, format:$f,
        think:(if $t == "false" then false else $t end),
        options:{temperature:0, num_predict:4000},
        messages:($pay + [{role:"user", content:$q}])}')"
    t0="$(date +%s)"
    resp="$(curl -sS --max-time 600 "$HOST/api/chat" -d "$body" 2>&1)"
    t1="$(date +%s)"
    content="$(jq -r '.message.content // empty' <<<"$resp" 2>/dev/null)"
    reason="$(jq -r '.done_reason // .error // "?"' <<<"$resp" 2>/dev/null | head -c 40)"

    if [ -z "$content" ]; then
      holds=no
      case "$reason" in
        length) what="spent the whole budget thinking and wrote nothing" ;;
        *)      what="empty content (done_reason=$reason)" ;;
      esac
    elif ! jq -e . >/dev/null 2>&1 <<<"$content"; then
      case "$content" in
        '```'*) holds=no; what="wrapped in a markdown fence — the grammar did not bind" ;;
        *)      holds=no; what="not JSON: $(printf '%s' "$content" | head -c 40)" ;;
      esac
    elif ! jq -e 'has("verdict") and has("criteria") and has("findings") and has("confidence")' \
           >/dev/null 2>&1 <<<"$content"; then
      holds=no; what="JSON, but not the contract: $(jq -c 'keys' <<<"$content" 2>/dev/null | head -c 60)"
    elif ! jq -e '.verdict | IN("accept","revise","block","abstain")' >/dev/null 2>&1 <<<"$content"; then
      holds=no; what="verdict \"$(jq -r '.verdict' <<<"$content")\" is outside the enum"
    else
      holds=yes; what="$(jq -c '{verdict, confidence}' <<<"$content")"
    fi

    printf '%-30s %-8s %-7s %-6s %s\n' "$m" "$lvl" "$holds" "$((t1-t0))" "$what"
    RESULTS="$(jq -c --arg m "$m" --arg l "$lvl" --arg h "$holds" --arg w "$what" \
      --argjson s "$((t1-t0))" \
      '. + [{model:$m, thinking:$l, holds:($h == "yes"), seconds:$s, what:$w}]' <<<"$RESULTS")"
  done
done

OUT="${OUT:-$HERE/results/format-support-$(date -u +%Y%m%dT%H%M%SZ).json}"
mkdir -p "$(dirname "$OUT")"
jq -n --argjson r "$RESULTS" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson prov "$(provenance_block)" \
  --argjson with_artifacts "$([ -n "$ART_DIR" ] && echo true || echo false)" \
  --argjson payload_bytes "$(jq -r '[.[].content | length] | add // 0' <<<"$PAYLOAD")" \
  '{schema:"format-support/3.0.0", measured_at:$ts, provenance:$prov,
    asked_with_artifacts:$with_artifacts, payload_bytes:$payload_bytes,
    short_question_only: ($with_artifacts | not), results:$r,
    eligible_judges: [$r[] | select(.holds) | {model, thinking}]}' > "$OUT"

printf '\neligible (model, thinking) pairs:\n'
jq -r '.eligible_judges[] | "  \(.model)  thinking=\(.thinking)"' "$OUT"
printf '\n%s\n' "$OUT"
