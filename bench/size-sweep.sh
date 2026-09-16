#!/usr/bin/env bash
# size-sweep.sh — does the judge stop finding the defect as the artifacts grow?
#
# This is the empirical basis for a decision about bean granularity, and without
# it that decision would be taste. Every judge failure so far has looked
# size-related — a model that holds the judgement schema perfectly on a 200-byte
# question emits a markdown fence at 18KB, and the one prompt change that helped
# was the one that stopped concatenating artifacts — but "looked size-related" is
# not a measurement.
#
# So: hold the defect, the model, the prompt and the question constant, and vary
# only how much other material the judge must read alongside it. The padding is
# real content from the same project's other beans rather than lorem ipsum,
# because the question is not "can it handle bytes" but "does the signal survive
# a realistic amount of surrounding context".
#
# If the catch rate falls off a cliff at some size, that size is the budget, and
# beans get split until specs fit under it. If it does not, granularity is not
# the lever and this says so.
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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPE="$ROOT/factory/pipeline"

usage() {
  cat <<'EOF'
size-sweep.sh — judge catch rate against artifact size, one defect held constant.

usage: size-sweep.sh --spec <spec.md> --tasks <tasks.yaml> --bean <bean.yaml>
                     [--case <name>] [--pad-from <dir>] [--sizes "0 5000 10000 20000"]
                     [--repeat <n>]
                     [--out <results.json>]

  --case      which seeded defect to use (default: contradicts-non-goal, the one
              the judge has actually caught and named before, so a fall-off is
              legible rather than noise on a case it never catches)
  --pad-from  directory of bean.yaml files to pad with (default: the bean's own
              beans directory)
  --sizes     padding sizes in bytes, whitespace separated
  --repeat    how many times to measure every size (default 1). Use at least 3:
              this judge gives different verdicts for byte-identical input at
              temperature 0, so one reading per size cannot tell a trend from the
              spread, and every sweep taken here before 2026-09-16 was one reading.
EOF
}

SPEC=""; TASKS=""; BEAN=""; CASE="contradicts-non-goal"; PAD_FROM=""; OUT=""
# One reading per size is not a sweep, it is six coin flips in a row.
#
# This harness asks whether the judge gets worse as the prompt grows. The judge
# has since been measured giving different verdicts for byte-identical input at
# temperature 0 — two of six fitness cases flipped between `revise` and `accept`
# across three passes — so a single reading at each size cannot tell a trend from
# the spread. Every earlier sweep here was one reading per point, and the
# conclusions drawn from it are withdrawn on the same grounds as the fitness ones.
REPEAT="${REPEAT:-1}"
SIZES="0 5000 10000 20000"
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)     SPEC="${2:?}"; shift 2 ;;
    --tasks)    TASKS="${2:?}"; shift 2 ;;
    --bean)     BEAN="${2:?}"; shift 2 ;;
    --case)     CASE="${2:?}"; shift 2 ;;
    --pad-from) PAD_FROM="${2:?}"; shift 2 ;;
    --sizes)    SIZES="${2:?}"; shift 2 ;;
    --out)      OUT="${2:?}"; shift 2 ;;
    --repeat)   REPEAT="${2:?}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
# Existence, not just presence. A flag pointing at a file that is not there
# produced a complete set of fitness numbers measured against nothing: the
# mutations applied to an empty spec, the judge answered about it, and the result
# was written to bench/results looking exactly like a real measurement. A harness
# that can fail open is worse than one that fails, because the output is a number
# someone will cite. judge-fitness.sh has always checked this; the three harnesses
# written after it copied the presence check and not the existence check.
for _f in "$SPEC" "$TASKS" "$BEAN"; do
  [ -n "$_f" ] && [ -f "$_f" ] || { usage >&2; printf 'missing input: %s\n' "${_f:-<unset>}" >&2; exit 2; }
done
[ -n "$PAD_FROM" ] || PAD_FROM="$(dirname "$(dirname "$BEAN")")"
[ -n "$OUT" ] || OUT="$ROOT/bench/results/size-sweep-$(date -u +%Y%m%dT%H%M%SZ).json"
mkdir -p "$(dirname "$OUT")"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The padding: other beans from the same set, as a "related work" appendix. Real
# text about the real project, which is what a larger bean's spec would carry.
PAD_ALL="$TMP/pad.txt"
{
  printf '\n## Related beans in this milestone\n\n'
  printf 'These are the other approved beans this one sits beside. They are here for\n'
  printf 'context: none of them is what you are auditing.\n\n'
  for b in "$PAD_FROM"/*/bean.yaml; do
    [ -f "$b" ] || continue
    case "$b" in *"$(basename "$(dirname "$BEAN")")"*) continue ;; esac
    printf -- '### %s\n\n```yaml\n' "$(basename "$(dirname "$b")")"
    cat "$b"
    printf '```\n\n'
  done
} > "$PAD_ALL"
printf 'padding available: %s bytes\n' "$(wc -c < "$PAD_ALL")"

# The case list out of judge-fitness.sh's own CASES block. A line-anchored grep
# misses `clean`, which shares a line with `CASES='` — and more importantly an
# unrecognised name makes `mutate` do nothing, so the sweep would pad and measure
# an UNMUTATED spec while the record named a seeded defect.
#
# The old guard here was `[ -n "$CATCH" ]`, which catches a typo only because an
# unknown case has no catchphrases. That is the right refusal for the wrong
# reason: `clean` is a real case with no catchphrases either, so this refused it
# too, and would have kept refusing it if anyone wanted to sweep the control.
CASE_LINES="$(sed -n "/^CASES='/,/'$/p" "$ROOT/bench/judge-fitness.sh" | sed "s/^CASES='//; s/'$//")"
if ! printf '%s\n' "$CASE_LINES" | grep -q "^$CASE|"; then
  printf 'no such case: %s\n\nthe cases judge-fitness.sh defines are:\n' "$CASE" >&2
  printf '%s\n' "$CASE_LINES" | cut -d'|' -f1 | sed 's/^/  /' >&2
  exit 2
fi
CATCH="$(printf '%s\n' "$CASE_LINES" | grep "^$CASE|" | head -1 | cut -d'|' -f4)"

refuse_if_inflight

printf '\nsize sweep — case %s\n\n' "$CASE"
printf '%-10s %-10s %-9s %-7s %-7s %s\n' PADDING TOTAL VERDICT NAMED SECONDS WHY-NOT

RESULTS='[]'
for _pass in $(seq 1 "$REPEAT"); do
[ "$REPEAT" -gt 1 ] && printf '\n-- pass %s of %s --\n' "$_pass" "$REPEAT"
for pad in $SIZES; do
  RD="$TMP/pad-$pad"; mkdir -p "$RD/verdicts"
  cp "$SPEC" "$RD/spec.md"; cp "$TASKS" "$RD/tasks.yaml"
  printf '{"run_id":"s","bean":"%s","branch":"b"}\n' \
    "$("$PIPE/yaml2json.sh" "$BEAN" | jq -r '.id')" > "$RD/run.json"

  sed -n '/^mutate() {/,/^}/p' "$ROOT/bench/judge-fitness.sh" > "$TMP/mutate.sh"
  ROOT="$ROOT" bash -c "source '$TMP/mutate.sh'; mutate '$CASE' '$RD/spec.md' '$RD/tasks.yaml'"

  [ "$pad" -gt 0 ] && head -c "$pad" "$PAD_ALL" >> "$RD/spec.md"
  total=$(( $(wc -c < "$RD/spec.md") + $(wc -c < "$RD/tasks.yaml") + $(wc -c < "$BEAN") ))

  t0="$(date +%s)"
  rc=0
  "$PIPE/judge.sh" "$RD" --target spec --bean "$BEAN" > "$RD/judge.log" 2>&1 || rc=$?
  t1="$(date +%s)"

  J="$RD/verdicts/spec.attempt-1.judgement.json"
  if [ ! -f "$J" ]; then
    # "none" covers three different failures and the distinction is the finding.
    #
    # The 2026-09-16 sweep produced `none` at exactly one size, in all three
    # passes, and the cause was not the judge running out of room: it answered
    # with `{"path": "", "depth": 3}` — valid JSON, not a judgement, the shape of
    # a file-browsing tool call leaking into the content. judge.sh refused it and
    # kept it beside the run, which is the only reason that was findable at all.
    #
    # A sweep that records all three as "none" cannot tell "the judge gets worse
    # with size" from "the judge falls out of the schema at this size", and the
    # second is the more interesting claim.
    verdict="none"; named="-"
    if [ -f "$J.rejected" ]; then
      reason="not a judgement: $(jq -cr 'keys | join(",")' "$J.rejected" 2>/dev/null || echo unparseable)"
    elif [ -f "$RD/verdicts/spec.truncated.json" ]; then
      reason="cut off at the token cap"
    elif [ -s "$RD/verdicts/spec.thinking.txt" ]; then
      reason="reasoned and wrote no answer"
    else
      reason="no response (exit $rc)"
    fi
  else
    reason=""
    verdict="$(jq -r '.verdict' "$J")"
    body="$(jq -r '[(.findings[]?|.summary,.evidence), (.criteria[]?|.evidence)] | join(" ")' "$J" | tr '[:upper:]' '[:lower:]')"
    named=no
    IFS='|' read -ra words <<< "$CATCH"
    for w in "${words[@]}"; do
      [ -n "$w" ] && grep -qF -- "$w" <<<"$body" && { named=yes; break; }
    done
  fi

  printf '%-10s %-10s %-9s %-7s %-7s %s\n' "$pad" "$total" "$verdict" "$named" "$((t1-t0))" "${reason:-}"
  RESULTS="$(jq -c --argjson p "$pad" --argjson t "$total" --arg v "$verdict" \
    --arg n "$named" --argjson s "$((t1-t0))" --argjson pass "$_pass" --arg why "${reason:-}" \
    '. + [{pass:$pass, padding_bytes:$p, total_artifact_bytes:$t, verdict:$v,
           named_the_defect:$n, seconds:$s}
          + (if $why == "" then {} else {no_judgement_because:$why} end)]' \
    <<<"$RESULTS")"
done
done

jq -n --argjson r "$RESULTS" --arg case "$CASE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg model "$(jq -r '.roles.judge.model' "${ROLES_FILE:-$PIPE/roles.json}")" \
  --argjson prov "$(provenance_block "$(jq -r '.roles.judge.model' "${ROLES_FILE:-$PIPE/roles.json}")")" \
  --argjson passes "$REPEAT" \
  '{schema:"size-sweep/2.0.0", measured_at:$ts, provenance:$prov, case:$case, judge:$model,
    passes:$passes, one_pass_is_not_a_sweep: ($passes < 2), points:$r,
    by_size: ([$r[] | {k: (.padding_bytes|tostring), v: .}] | group_by(.k)
              | map({key: .[0].k,
                     value: {verdicts: [.[].v.verdict], named: [.[].v.named_the_defect],
                             agree: ([.[].v.verdict] | unique | length == 1)}})
              | from_entries),
    note:"One defect, one model, one prompt. The only variable is how much real surrounding material the judge reads with it. With passes > 1 the same point is measured repeatedly, because this judge gives different verdicts for identical input and a single reading per size cannot tell a trend from the spread."}' > "$OUT"
printf '\n%s\n' "$OUT"
