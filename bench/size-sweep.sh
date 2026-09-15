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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPE="$ROOT/factory/pipeline"

usage() {
  cat <<'EOF'
size-sweep.sh — judge catch rate against artifact size, one defect held constant.

usage: size-sweep.sh --spec <spec.md> --tasks <tasks.yaml> --bean <bean.yaml>
                     [--case <name>] [--pad-from <dir>] [--sizes "0 5000 10000 20000"]
                     [--out <results.json>]

  --case      which seeded defect to use (default: contradicts-non-goal, the one
              the judge has actually caught and named before, so a fall-off is
              legible rather than noise on a case it never catches)
  --pad-from  directory of bean.yaml files to pad with (default: the bean's own
              beans directory)
  --sizes     padding sizes in bytes, whitespace separated
EOF
}

SPEC=""; TASKS=""; BEAN=""; CASE="contradicts-non-goal"; PAD_FROM=""; OUT=""
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
    -h|--help)  usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
[ -n "$SPEC" ] && [ -n "$TASKS" ] && [ -n "$BEAN" ] || { usage >&2; exit 1; }
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

CATCH="$(grep "^$CASE|" "$ROOT/bench/judge-fitness.sh" | head -1 | cut -d'|' -f4)"
[ -n "$CATCH" ] || { echo "no catch phrases for case '$CASE' in judge-fitness.sh" >&2; exit 1; }

printf '\nsize sweep — case %s\n\n' "$CASE"
printf '%-10s %-10s %-9s %-7s %s\n' PADDING TOTAL VERDICT NAMED SECONDS

RESULTS='[]'
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
    verdict="none"; named="-"
  else
    verdict="$(jq -r '.verdict' "$J")"
    body="$(jq -r '[(.findings[]?|.summary,.evidence), (.criteria[]?|.evidence)] | join(" ")' "$J" | tr '[:upper:]' '[:lower:]')"
    named=no
    IFS='|' read -ra words <<< "$CATCH"
    for w in "${words[@]}"; do
      [ -n "$w" ] && grep -qF -- "$w" <<<"$body" && { named=yes; break; }
    done
  fi

  printf '%-10s %-10s %-9s %-7s %s\n' "$pad" "$total" "$verdict" "$named" "$((t1-t0))"
  RESULTS="$(jq -c --argjson p "$pad" --argjson t "$total" --arg v "$verdict" \
    --arg n "$named" --argjson s "$((t1-t0))" \
    '. + [{padding_bytes:$p, total_artifact_bytes:$t, verdict:$v, named_the_defect:$n, seconds:$s}]' \
    <<<"$RESULTS")"
done

jq -n --argjson r "$RESULTS" --arg case "$CASE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg model "$(jq -r '.roles.judge.model' "${ROLES_FILE:-$PIPE/roles.json}")" \
  '{schema:"size-sweep/1.0.0", measured_at:$ts, case:$case, judge:$model, points:$r,
    note:"One defect, one model, one prompt. The only variable is how much real surrounding material the judge reads with it."}' > "$OUT"
printf '\n%s\n' "$OUT"
