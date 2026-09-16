#!/usr/bin/env bash
# judge-variance.sh — the same question, asked repeatedly, to the same model.
#
# Everything this project has concluded about the judge came from single runs
# compared against each other: fenced artifacts against unfenced, one message per
# artifact against one blob, gpt-oss against gemma4. Every one of those
# comparisons assumed that a difference between two runs meant a difference
# between two configurations.
#
# Then the size sweep asked `criterion-not-really-met` at zero padding — the exact
# input the fitness run had used an hour earlier — and got no judgement at all,
# where the fitness run had got a correct, correctly-named catch. Same model, same
# artifacts, same prompt, temperature 0.
#
# If that reproduces, the fitness numbers are noise and the conclusions drawn from
# comparing them are unsupported. That is worth knowing before another hour goes
# into improving a number that is not measuring anything.
#
# This changes nothing between runs. It asks the same question N times and reports
# what came back.
set -uo pipefail
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
judge-variance.sh — ask the judge the same question N times.

usage: judge-variance.sh --spec <spec.md> --tasks <tasks.yaml> --bean <bean.yaml>
                         [--case <name>] [--runs <n>] [--out <results.json>]

  --case  seeded defect to use, or "clean" (default: criterion-not-really-met)
  --runs  how many times (default: 5)
EOF
}

SPEC=""; TASKS=""; BEAN=""; CASE="criterion-not-really-met"; RUNS=5; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)  SPEC="${2:?}"; shift 2 ;;
    --tasks) TASKS="${2:?}"; shift 2 ;;
    --bean)  BEAN="${2:?}"; shift 2 ;;
    --case)  CASE="${2:?}"; shift 2 ;;
    --runs)  RUNS="${2:?}"; shift 2 ;;
    --out)   OUT="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
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
[ -n "$OUT" ] || OUT="$ROOT/bench/results/judge-variance-$(date -u +%Y%m%dT%H%M%SZ).json"
mkdir -p "$(dirname "$OUT")"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

CATCH="$(grep "^$CASE|" "$ROOT/bench/judge-fitness.sh" | head -1 | cut -d'|' -f4)"

# One mutated copy, made once and reused for every run. Making it per-run would
# introduce a second thing that could differ, and the whole point is that nothing
# differs.
SRC="$TMP/src"; mkdir -p "$SRC"
cp "$SPEC" "$SRC/spec.md"; cp "$TASKS" "$SRC/tasks.yaml"
sed -n '/^mutate() {/,/^}/p' "$ROOT/bench/judge-fitness.sh" > "$TMP/mutate.sh"
ROOT="$ROOT" bash -c "source '$TMP/mutate.sh'; mutate '$CASE' '$SRC/spec.md' '$SRC/tasks.yaml'"
SHA="$(cat "$SRC/spec.md" "$SRC/tasks.yaml" | sha256sum | cut -c1-16)"

refuse_if_inflight

printf '\njudge variance — case %s, %s runs, identical input (sha %s)\n\n' "$CASE" "$RUNS" "$SHA"
printf '%-5s %-9s %-7s %-7s %s\n' RUN VERDICT NAMED SECONDS NOTE

RESULTS='[]'
for i in $(seq 1 "$RUNS"); do
  RD="$TMP/run-$i"; mkdir -p "$RD/verdicts"
  cp "$SRC/spec.md" "$SRC/tasks.yaml" "$RD/"
  printf '{"run_id":"v%s","bean":"%s","branch":"b"}\n' "$i" \
    "$("$PIPE/yaml2json.sh" "$BEAN" | jq -r '.id')" > "$RD/run.json"

  t0="$(date +%s)"; rc=0
  "$PIPE/judge.sh" "$RD" --target spec --bean "$BEAN" > "$RD/judge.log" 2>&1 || rc=$?
  t1="$(date +%s)"

  J="$RD/verdicts/spec.attempt-1.judgement.json"
  named="-"; note=""
  if [ ! -f "$J" ]; then
    verdict="none"; note="$(tail -1 "$RD/judge.log" | head -c 60)"
  else
    verdict="$(jq -r '.verdict' "$J")"
    body="$(jq -r '[(.findings[]?|.summary,.evidence), (.criteria[]?|.evidence)] | join(" ")' "$J" | tr '[:upper:]' '[:lower:]')"
    named=no
    if [ -n "$CATCH" ]; then
      IFS='|' read -ra words <<< "$CATCH"
      for w in "${words[@]}"; do
        [ -n "$w" ] && grep -qF -- "$w" <<<"$body" && { named=yes; break; }
      done
    fi
    note="$(jq -r '"\(.findings | length) finding(s), confidence \(.confidence)"' "$J")"
  fi

  printf '%-5s %-9s %-7s %-7s %s\n' "$i" "$verdict" "$named" "$((t1-t0))" "$note"
  RESULTS="$(jq -c --argjson i "$i" --arg v "$verdict" --arg n "$named" \
    --argjson s "$((t1-t0))" --arg note "$note" \
    '. + [{run:$i, verdict:$v, named:$n, seconds:$s, note:$note}]' <<<"$RESULTS")"
done

DISTINCT="$(jq -r '[.[].verdict] | unique | length' <<<"$RESULTS")"
VERDICTS="$(jq -r '[.[].verdict] | unique | join(", ")' <<<"$RESULTS")"

jq -n --argjson r "$RESULTS" --arg case "$CASE" --arg sha "$SHA" \
  --argjson distinct "$DISTINCT" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg model "$(jq -r '.roles.judge.model' "${ROLES_FILE:-$PIPE/roles.json}")" \
  --argjson prov "$(provenance_block "$(jq -r '.roles.judge.model' "${ROLES_FILE:-$PIPE/roles.json}")")" \
  '{schema:"judge-variance/1.0.0", measured_at:$ts, provenance:$prov, case:$case, judge:$model,
    input_sha:$sha, runs:$r, distinct_verdicts:$distinct,
    reproducible:($distinct == 1),
    note:"Identical input every run: same spec, same task list, same prompt, temperature 0. Any difference between rows is the model, not the question."}' > "$OUT"

printf '\n%s distinct verdict(s) across %s identical runs: %s\n' "$DISTINCT" "$RUNS" "$VERDICTS"
if [ "$DISTINCT" -gt 1 ]; then
  printf '\nNOT REPRODUCIBLE. A single run of bench/judge-fitness.sh cannot distinguish a\n'
  printf 'change in the pipeline from the model having a different day, and comparisons\n'
  printf 'between single runs — every one this project has made — do not support the\n'
  printf 'conclusions drawn from them.\n'
else
  printf '\nReproducible on this case. A single run means something here.\n'
fi
printf '%s\n' "$OUT"
