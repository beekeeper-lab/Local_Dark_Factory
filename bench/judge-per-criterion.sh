#!/usr/bin/env bash
# judge-per-criterion.sh — the same judge, asked one criterion at a time.
#
# Every audit this project has run hands the model 25–36KB of artifacts and asks
# one question — *is this sound?* — expecting a verdict, five per-criterion
# judgements, findings, quotes and a confidence in a single object. The shape of
# that ask has never been varied, and on 2026-09-16 everything else was:
#
#   the model      gpt-oss 7–9 false accepts in 15; qwen3-coder 15 of 15;
#                  gemma4 cannot be driven under a grammar at all
#   the grammar    five constraints, each measured, each doing exactly what it
#                  was measured to do, none of it changing whether the judge is right
#   the cap        16000 removes the cut-offs and is not binding on anything left
#   the level      `low` beats `medium` on generated tokens
#
# What is left is the size of the question. `criteria[ac2]: {met, evidence, quote}`
# is a much smaller thing to get right than a whole judgement, this model has
# shown it holds a tight grammar, and a wrong answer about ac2 no longer
# contaminates ac1.
#
# It also takes `verdict` out of the model's hands. Five answers about five
# criteria compose into a verdict by arithmetic, which is the controller's job —
# and "accept" has been the model's single most damaging output.
#
# Drop-in compatible with judge.sh's command line, so `JUDGE_CMD` points
# bench/judge-fitness.sh at it and every number is produced by the same
# classifier. It calls judge.sh once per criterion rather than reimplementing any
# of it: the artifacts, the preamble, the containment of a bad answer and every
# refusal in it are the ones the line actually uses.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPE="$HERE/../factory/pipeline"

usage() {
  cat <<'EOF'
judge-per-criterion.sh — ask the judge one acceptance criterion at a time.

usage: judge-per-criterion.sh <run_dir> --target <t> --bean <bean.yaml> [--thinking <l>]

Writes <run_dir>/verdicts/<target>.attempt-N.judgement.json in the normal shape,
composed from one answer per criterion:

  verdict     accept if every criterion is met, revise otherwise. Arithmetic,
              not the model's opinion.
  criteria    one entry per criterion, from the answer about that criterion.
  findings    one per criterion the judge says is not met, carrying its evidence.
  confidence  the lowest of the per-criterion confidences — a judgement is only
              as good as its least certain part.

Exit: 0 composed · 1 no criterion produced a usable answer · 2 could not run.
EOF
}

RUN_DIR=""; TARGET=""; BEAN=""; THINKING=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target)   TARGET="${2:?}"; shift 2 ;;
    --bean)     BEAN="${2:?}"; shift 2 ;;
    --thinking) THINKING="${2:?}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) [ -z "$RUN_DIR" ] && RUN_DIR="$1" || { usage >&2; exit 2; }; shift ;;
  esac
done
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || { usage >&2; printf 'no run dir\n' >&2; exit 2; }
[ -n "$TARGET" ] && [ -n "$BEAN" ] && [ -f "$BEAN" ] || { usage >&2; printf 'need --target and --bean\n' >&2; exit 2; }

BEAN_JSON="$("$PIPE/yaml2json.sh" "$BEAN")" || { printf 'cannot read bean\n' >&2; exit 2; }
IDS="$(jq -r '[(.acceptance_criteria // [])[].id] | .[]' <<<"$BEAN_JSON")"
if [ -z "$IDS" ]; then
  printf 'judge-per-criterion: %s declares no acceptance criteria; falling through to judge.sh\n' \
    "$(jq -r '.id // "?"' <<<"$BEAN_JSON")" >&2
  exec "$PIPE/judge.sh" "$RUN_DIR" --target "$TARGET" --bean "$BEAN" ${THINKING:+--thinking "$THINKING"}
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$RUN_DIR/verdicts"
# The attempt number this composed judgement will take, decided once, before any
# sub-run writes anything: the sub-runs each write attempt-1 into their own
# directory and the composed answer is what the caller sees.
N=1
while [ -f "$RUN_DIR/verdicts/$TARGET.attempt-$N.judgement.json" ]; do N=$((N + 1)); done

CRITERIA='[]'; ANSWERED=0; ASKED=0
printf 'judge-per-criterion: %s criteria, one request each\n' "$(printf '%s\n' "$IDS" | wc -l)" >&2
while IFS= read -r id; do
  [ -n "$id" ] || continue
  ASKED=$((ASKED + 1))
  # A bean carrying exactly one criterion. judge.sh builds its prompt and its
  # grammar from the bean, so this is the whole mechanism: the id enum has one
  # member, `criteria` is an object with one required key, and the question in
  # the prose is about one thing.
  "$PIPE/yaml2json.sh" "$BEAN" \
    | jq --arg i "$id" '.acceptance_criteria = [ .acceptance_criteria[] | select(.id == $i) ]' \
    > "$TMP/bean-$id.json"
  # judge.sh takes YAML; JSON is valid YAML, and this avoids a second serialiser.
  cp "$TMP/bean-$id.json" "$TMP/bean-$id.yaml"

  SUB="$TMP/run-$id"
  mkdir -p "$SUB"
  # The artifacts, not copies of them: judge.sh reads them out of the run dir by
  # name, so the sub-run gets the same directory contents. Symlinks would break
  # the quote check's haystack, which walks the tree.
  cp -r "$RUN_DIR"/. "$SUB"/ 2>/dev/null || true
  rm -rf "$SUB/verdicts"; mkdir -p "$SUB/verdicts"

  rc=0
  "$PIPE/judge.sh" "$SUB" --target "$TARGET" --bean "$TMP/bean-$id.yaml" \
    ${THINKING:+--thinking "$THINKING"} > "$RUN_DIR/verdicts/$TARGET.$id.log" 2>&1 || rc=$?
  J="$SUB/verdicts/$TARGET.attempt-1.judgement.json"
  if [ "$rc" -ne 0 ] || [ ! -f "$J" ]; then
    printf '  %-6s no answer (exit %s)\n' "$id" "$rc" >&2
    continue
  fi
  entry="$(jq -c --arg i "$id" '[.criteria[]? | select(.id == $i)] | .[0] // null' "$J")"
  if [ "$entry" = "null" ]; then
    printf '  %-6s answered about something else\n' "$id" >&2
    continue
  fi
  ANSWERED=$((ANSWERED + 1))
  conf="$(jq -r '.confidence // 0.5' "$J")"
  printf '  %-6s met=%s conf=%s\n' "$id" "$(jq -r '.met' <<<"$entry")" "$conf" >&2
  CRITERIA="$(jq -c --argjson e "$entry" --argjson c "$conf" \
    '. + [$e + {_confidence: $c}]' <<<"$CRITERIA")"
done <<< "$IDS"

if [ "$ANSWERED" -eq 0 ]; then
  printf 'judge-per-criterion: %s criteria asked, none answered — no judgement composed\n' "$ASKED" >&2
  exit 1
fi

# The verdict is arithmetic. "accept" has been this model's single most damaging
# output and it does not get to write it: a criterion the judge itself says is not
# met is a revise, and every criterion met is an accept. A criterion that was
# never answered is NOT met — silence is not agreement, and composing an accept
# over a question nobody answered is the fail-open this whole line is built against.
UNMET="$(jq '[.[] | select(.met == false)] | length' <<<"$CRITERIA")"
if [ "$ANSWERED" -lt "$ASKED" ] || [ "$UNMET" -gt 0 ]; then VERDICT=revise; else VERDICT=accept; fi

jq -n --arg sv "judgement/1.0.0" --arg target "$TARGET" \
  --arg verdict "$VERDICT" --argjson c "$CRITERIA" \
  --argjson asked "$ASKED" --argjson answered "$ANSWERED" \
  --arg stage "$(case "$TARGET" in spec) echo spec_audit ;; impl|package) echo impl_audit ;; doc) echo pre_pr_audit ;; esac)" \
  '{schema_version:$sv, stage:$stage, target:$target, verdict:$verdict,
    criteria: [$c[] | del(._confidence)],
    findings: [ $c[] | select(.met == false)
                | {severity:"major",
                   summary:("acceptance criterion " + .id + " is not met"),
                   evidence:.evidence, quote:.quote} ]
              + (if $answered < $asked
                 then [{severity:"blocker",
                        summary:("only " + ($answered|tostring) + " of " + ($asked|tostring) + " criteria were answered"),
                        evidence:"The remaining criteria produced no usable judgement. They are recorded as not met, because silence is not agreement."}]
                 else [] end),
    confidence: ([$c[]._confidence] | min),
    asked_per_criterion:{asked:$asked, answered:$answered},
    judged_by:{model:"see the per-criterion logs beside this file", composed_by:"bench/judge-per-criterion.sh"}}' \
  > "$RUN_DIR/verdicts/$TARGET.attempt-$N.judgement.json"

printf 'judge-per-criterion: %s of %s answered, verdict %s (composed, not the model'"'"'s)\n' \
  "$ANSWERED" "$ASKED" "$VERDICT" >&2
[ "$VERDICT" = accept ] && exit 0 || exit 0
