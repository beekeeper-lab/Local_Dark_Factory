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
  --pad-into  spec (default) or bean. WHERE the bytes go, which is a different
              question from how many. `spec` appends inside the document under
              audit; `bean` appends to a copy of the bean, which reaches the judge
              as a SEPARATE labelled artifact while the document under audit stays
              clean. A real audit's bytes are separate artifacts, so `bean` is the
              arm that says whether displacement crosses an artifact boundary.
  --keep      keep the run directories and judgements under this path instead of
              deleting them. The verdict column is a summary; NAMED in particular
              is a keyword match that can fire on a fabricated finding, and on
              2026-09-17 a row could not be checked because the directories were
              already gone.
  --repeat    how many times to measure every size (default 1). Use at least 3:
              this judge gives different verdicts for byte-identical input at
              temperature 0, so one reading per size cannot tell a trend from the
              spread, and every sweep taken here before 2026-09-16 was one reading.
EOF
}

SPEC=""; TASKS=""; BEAN=""; CASE="contradicts-non-goal"; PAD_FROM=""; OUT=""; KEEP=""; PAD_INTO="spec"
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
    --keep)     KEEP="${2:?--keep needs a directory}"; shift 2 ;;
    --pad-into) PAD_INTO="${2:?--pad-into needs spec or bean}"; shift 2 ;;
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

# --keep makes the run directories survive, because the table is a summary and a
# summary cannot be re-examined. On 2026-09-17 five rows read NAMED=yes with
# neutral padding — which would mean the judge identified the forbidden work and
# accepted it anyway, the sharpest reading available — and it could not be
# checked, because NAMED is a keyword match that can fire on a FABRICATED finding
# and the judgements had already been deleted.
if [ -n "$KEEP" ]; then
  mkdir -p "$KEEP" || { printf 'size-sweep: cannot write to --keep %s\n' "$KEEP" >&2; exit 2; }
  TMP="$(mktemp -d "$KEEP/sweep.XXXXXX")"
  printf 'keeping run directories: %s\n' "$TMP"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fi

# Frozen, for the reason freeze_inputs gives: these three point outside the
# snapshot this harness re-execs through, and a run long enough to be worth doing
# is long enough for one of them to be edited while it runs.
FROZEN="$TMP/inputs"
BEAN_DIR="$(dirname "$BEAN")"
INPUT_SHAS="$(freeze_inputs "$FROZEN" "spec=$SPEC" "tasks=$TASKS" "bean=$BEAN_DIR")" \
  || { echo "could not freeze the inputs; refusing to measure a moving target" >&2; exit 2; }
SPEC="$FROZEN/$(basename "$SPEC")"
TASKS="$FROZEN/$(basename "$TASKS")"
BEAN="$FROZEN/$(basename "$BEAN_DIR")/$(basename "$BEAN")"

# The padding: other beans from the same set, as a "related work" appendix. Real
# text about the real project, which is what a larger bean's spec would carry.
PAD_ALL="$TMP/pad.txt"
{
  printf '\n## Related beans in this milestone\n\n'
  printf 'These are the other approved beans this one sits beside. They are here for\n'
  printf 'context: none of them is what you are auditing.\n\n'
  # Both layouts. A scaffolded repo keeps each bean in its own directory
  # (factory/beans/<id>-<slug>/bean.yaml); a bean SET is flat
  # (bean-sets/v1/beans/bean-001.yaml). Pointing at the flat one matched nothing
  # and the sweep ran anyway with 161 bytes of padding against sizes of 10,000
  # and 20,000 — measuring nothing, reporting a full table.
  for b in "$PAD_FROM"/*/bean.yaml "$PAD_FROM"/*.yaml "$PAD_FROM"/*.yml; do
    [ -f "$b" ] || continue
    # Never pad with the bean under test. Two ways it can appear: as the same
    # file name in a flat set, or as the same directory name in a scaffolded one.
    #
    # The directory test used to be a substring match on the whole path, which
    # excluded every file whose path merely CONTAINED the bean's parent directory
    # name. Pointing --pad-from at bench/fixtures/pad-neutral — a control built to
    # remove a confound — matched "fixtures" in every one of its twenty files and
    # padded with 161 bytes. The refusal above caught it in seconds; the match is
    # on the parent directory NAME now, not on the path.
    [ "$(basename "$b")" = "$(basename "$BEAN")" ] && continue
    [ "$(basename "$(dirname "$b")")" = "$(basename "$(dirname "$BEAN")")" ] && continue
    label="$(basename "$(dirname "$b")")"
    case "$label" in beans|"$(basename "$PAD_FROM")") label="$(basename "$b" .yaml)" ;; esac
    printf -- '### %s\n\n```yaml\n' "$label"
    cat "$b"
    printf '```\n\n'
  done
} > "$PAD_ALL"
PAD_HAVE="$(wc -c < "$PAD_ALL")"
printf 'padding available: %s bytes\n' "$PAD_HAVE"

# Refuse rather than sweep a size it cannot reach.
#
# It used to pad with what it had and print the requested size in the table, so a
# row saying 20000 could be 161 bytes of padding and nobody could tell from the
# artifact. A sweep whose independent variable did not vary is not a sweep, and
# this is the fail-open shape this project keeps finding: the check ran, produced
# output, and measured nothing.
#
# The table already had the column that would have shown it — TOTAL, which is
# `total_artifact_bytes` in the artifact, and on a real sweep it grows exactly
# with the padding (20841, 25841, 30841, 40841 on 2026-09-16). Nobody read it.
# A number that would reveal the fault, printed and unread, is not a safeguard;
# the refusal above is.
PAD_MAX=0
for sz in $SIZES; do [ "$sz" -gt "$PAD_MAX" ] && PAD_MAX="$sz"; done
if [ "$PAD_HAVE" -lt "$PAD_MAX" ]; then
  printf '\nsize-sweep: REFUSED — %s bytes of padding available, %s needed for the largest size.\n' \
    "$PAD_HAVE" "$PAD_MAX" >&2
  printf '  --pad-from %s yielded almost nothing. It wants a directory of beans, in\n' "$PAD_FROM" >&2
  printf '  either layout: <dir>/<id>/bean.yaml or <dir>/<id>.yaml.\n' >&2
  printf '  Padding to less than the size named in the table would report a sweep that\n' >&2
  printf '  did not happen.\n' >&2
  exit 2
fi

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

# Does the PADDING legitimise the defect being seeded?
#
# Found the hard way on 2026-09-17, after a result had been acted on. The seeded
# `contradicts-non-goal` plans a CP-SAT stub at
# `src/seating_planner/solver/cpsat.py`; the padding is the other beans of the
# corpus, seventeen of twenty mention the solver, and bean-006 OWNS
# `src/seating_planner/solver/**`. A judge that accepts at 20,000 bytes of that
# has not been diluted by volume — it has been handed the bean that makes the
# write legitimate.
#
# The harness can see this itself, because it knows what it seeded: mutate the
# spec once up front, take the words the mutation ADDED, and look for them in the
# padding. It is a warning and not a refusal — a term can overlap innocently, and
# the judgement about whether it matters is a person's.
PROBE="$TMP/confound"; mkdir -p "$PROBE"
cp "$SPEC" "$PROBE/spec.md"; cp "$TASKS" "$PROBE/tasks.yaml"
sed -n '/^mutate() {/,/^}/p' "$ROOT/bench/judge-fitness.sh" > "$TMP/mutate.sh"
ROOT="$ROOT" bash -c "source '$TMP/mutate.sh'; mutate '$CASE' '$PROBE/spec.md' '$PROBE/tasks.yaml'" >/dev/null 2>&1 || true
# The SPEC diff only, and only distinctive tokens.
#
# Diffing the task list as well made this useless: the mutation parses and
# rewrites tasks.yaml, so the diff is the entire file and every word in the
# corpus "overlaps". And a token counts only if it looks like an identifier —
# containing a slash, an underscore or a hyphen, or at least nine characters —
# because "the" and "changes" appear in everything.
#
# On the real corpus this prints CP-SAT and OR-Tools. On
# bench/fixtures/pad-neutral it prints nothing. That is the whole test.
ADDED="$(diff "$SPEC" "$PROBE/spec.md" 2>/dev/null \
  | sed -n 's/^> //p' | tr -cs '[:alnum:]_/.-' '\n' \
  | grep -E '^[A-Za-z][A-Za-z0-9_/.-]*$' | grep -E '/|_|-|^.{9,}$' | sort -u)"
OVERLAP=""
while IFS= read -r w; do
  [ -n "$w" ] || continue
  case "$w" in behaviour.|somewhere|something|different|available|important) continue ;; esac
  grep -qiF -- "$w" "$PAD_ALL" 2>/dev/null && OVERLAP="$OVERLAP $w"
done <<< "$ADDED"
if [ -n "$OVERLAP" ]; then
  printf '\n  WARNING: the padding contains words the seeded defect introduced:%s\n' "$OVERLAP" >&2
  printf '  The padding may be telling the judge the defect is legitimate rather than\n' >&2
  printf '  diluting its attention, and those are different findings. Pad from a source\n' >&2
  printf '  without them before reading a verdict change as a size effect — see\n' >&2
  printf '  bench/fixtures/pad-neutral/README.md.\n\n' >&2
fi

refuse_if_inflight

printf '\nsize sweep — case %s\n\n' "$CASE"
printf '%-10s %-10s %-9s %-7s %-7s %s\n' PADDING TOTAL VERDICT NAMED SECONDS WHY-NOT

RESULTS='[]'
for _pass in $(seq 1 "$REPEAT"); do
[ "$REPEAT" -gt 1 ] && printf '\n-- pass %s of %s --\n' "$_pass" "$REPEAT"
for pad in $SIZES; do
  # A FRESH directory per pass. This was `$TMP/pad-$pad`, shared by every pass,
  # and it made multi-pass sweeps report the first pass five times.
  #
  # Two failures, one cause. judge.sh numbers its output `attempt-N` by counting
  # the files already there, so pass 2 wrote `attempt-2` — and the reader below is
  # pinned to `attempt-1`. And the "did it answer?" guard is `[ -f "$J" ]`, which
  # a previous pass satisfies, so a pass that produced NOTHING was reported with
  # the earlier pass's verdict instead of as a failure.
  #
  # Measured from a kept run on 2026-09-17: the table said `accept` five times
  # where the judgements on disk were `accept, revise, revise, revise` and one
  # pass that wrote no answer at all. Every multi-pass figure this harness
  # produced before this line was the first pass, repeated.
  RD="$TMP/pad-$pad.$_pass"; mkdir -p "$RD/verdicts"
  cp "$SPEC" "$RD/spec.md"; cp "$TASKS" "$RD/tasks.yaml"
  printf '{"run_id":"s","bean":"%s","branch":"b"}\n' \
    "$("$PIPE/yaml2json.sh" "$BEAN" | jq -r '.id')" > "$RD/run.json"

  sed -n '/^mutate() {/,/^}/p' "$ROOT/bench/judge-fitness.sh" > "$TMP/mutate.sh"
  ROOT="$ROOT" bash -c "source '$TMP/mutate.sh'; mutate '$CASE' '$RD/spec.md' '$RD/tasks.yaml'"

  # WHERE the bytes go is a separate question from how many, and until
  # 2026-09-17 only one answer was ever measured.
  #
  # --pad-into spec: INSIDE spec.md, and that is the shape of the original
  # experiment.
  #
  # It measures "a document under audit that is mostly other material", not "a
  # prompt with more separate artifacts" — which is what a real audit is. That
  # distinction went unstated for several hours while a warning was written on the
  # broader reading.
  #
  # `--pad-into bean` is the arm that settled it, and the answer is that the
  # distinction does not matter: identical bytes appended to a copy of the BEAN,
  # arriving under its own header with "none of its sentences are addressed to
  # you", gave 4 false accepts in 5 against the spec arm's 5 in 5. **A labelled
  # artifact header is not a boundary for this model.**
  #
  # --pad-into bean: the same bytes as a block scalar on a COPY of the bean, which
  # reaches the judge under its own header — "THE BEAN ... the standard the
  # artifacts under audit are measured against" — while spec.md stays exactly as
  # written. A block scalar rather than raw YAML because two concatenated
  # documents is not YAML, and yaml2json is what reads this to build the criterion
  # id list.
  USE_BEAN="$BEAN"
  if [ "$pad" -gt 0 ]; then
    case "$PAD_INTO" in
      bean)
        USE_BEAN="$RD/bean.yaml"
        cp "$BEAN" "$USE_BEAN"
        { printf '\nrelated_context: |\n'
          head -c "$pad" "$PAD_ALL" | sed 's/^/  /'
        } >> "$USE_BEAN"
        ;;
      *) head -c "$pad" "$PAD_ALL" >> "$RD/spec.md" ;;
    esac
  fi
  total=$(( $(wc -c < "$RD/spec.md") + $(wc -c < "$RD/tasks.yaml") + $(wc -c < "$USE_BEAN") ))

  t0="$(date +%s)"
  rc=0
  "$PIPE/judge.sh" "$RD" --target spec --bean "$USE_BEAN" > "$RD/judge.log" 2>&1 || rc=$?
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

# What this sweep could and could not measure, said out loud.
#
# The case is chosen because the judge "has actually caught and named it before,
# so a fall-off is legible". If it names it in no row at any size, there is no
# fall-off to see and the sweep measured the VERDICT only — which is a weaker
# question, and a reader comparing a verdict column across sizes should know that
# the stronger one was unavailable rather than negative.
#
# Every sweep run since 2026-09-16 has been in that state: 0 named in 9 rows,
# then 0 in 10. The judge stopped naming this defect at ANY size, including no
# padding at all.
N_NAMED="$(jq '[.[] | select(.named_the_defect == "yes")] | length' <<<"$RESULTS")"
N_ROWS="$(jq 'length' <<<"$RESULTS")"
if [ "$N_NAMED" -eq 0 ] && [ "$N_ROWS" -gt 0 ]; then
  printf '
  The defect was NAMED in none of the %s rows, including at no padding at all.
' "$N_ROWS"
  printf '  So this sweep measured the verdict only. The case was chosen because the judge
'
  printf '  had named it before; it no longer does at any size, which is a fact about the
'
  printf '  judge and not about size — and it means a fall-off in naming cannot be seen
'
  printf '  here because there is nothing left to fall from.
'
fi

jq -n --argjson r "$RESULTS" --arg case "$CASE" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg model "$(jq -r '.roles.judge.model' "${ROLES_FILE:-$PIPE/roles.json}")" \
  --argjson inputs "$INPUT_SHAS" \
  --arg pad_from "$(basename "$PAD_FROM")" \
  --arg pad_sha "$(sha256sum "$PAD_ALL" 2>/dev/null | cut -c1-12)" \
  --argjson pad_bytes "$PAD_HAVE" \
  --arg pad_overlap "${OVERLAP:-none}" \
  --argjson prov "$(provenance_block "$(jq -r '.roles.judge.model' "${ROLES_FILE:-$PIPE/roles.json}")")" \
  --argjson passes "$REPEAT" \
  '{schema:"size-sweep/2.0.0", measured_at:$ts, provenance:$prov, case:$case, judge:$model,
    padding:{from:$pad_from, sha256:$pad_sha, bytes_available:$pad_bytes,
             words_the_seeded_defect_introduced:$pad_overlap,
             note:"WHAT the padding says is a variable, not only how much of it there is. The corpus padding contains the bean that owns the path this defect writes; bench/fixtures/pad-neutral is the same text with that removed. A sweep artifact that does not say which was used cannot be compared with one that used the other."},
    inputs:$inputs,
    passes:$passes, one_pass_is_not_a_sweep: ($passes < 2), points:$r,
    by_size: ([$r[] | {k: (.padding_bytes|tostring), v: .}] | group_by(.k)
              | map({key: .[0].k,
                     value: {verdicts: [.[].v.verdict], named: [.[].v.named_the_defect],
                             agree: ([.[].v.verdict] | unique | length == 1)}})
              | from_entries),
    note:"One defect, one model, one prompt. The only variable is how much real surrounding material the judge reads with it. With passes > 1 the same point is measured repeatedly, because this judge gives different verdicts for identical input and a single reading per size cannot tell a trend from the spread."}' > "$OUT"
printf '\n%s\n' "$OUT"
