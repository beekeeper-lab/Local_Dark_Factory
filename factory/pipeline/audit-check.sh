#!/usr/bin/env bash
# audit-check.sh — turn a judge's judgement into a verdict the schema accepts.
#
# The judge writes what it thinks, with evidence. This adds the ten facts it
# could only have guessed at — the SHAs, the digests, the tier, the versions —
# from what the controller can actually observe, validates the result against
# verdict.schema.json, and writes the verdict the driver reads.
#
# See JUDGEMENT-CONTRACT.md for why the split exists. Short version: a verdict
# carrying a hex string a model invented is worse than one with the field
# missing, because it is indistinguishable from a true one.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
audit-check.sh — stamp, validate and record the verdict for one audit step.

usage: audit-check.sh <run_dir> --target spec|impl|doc|package --bean <bean.yaml>
                      [--policy <risk-policy.yaml>] [--gates <gates.lock.yaml>]

Reads the newest <run_dir>/verdicts/<target>.attempt-N.judgement.json, stamps the
provenance the judge must not invent, validates against verdict.schema.json, and
writes <run_dir>/verdicts/<target>.attempt-N.json.

Exit: 0 the verdict is `accept` · 1 it is `revise` or `block` · 2 there is no
usable judgement to turn into a verdict.
EOF
}

RUN_DIR=""; TARGET=""; BEAN_FILE=""; POLICY=""; GATES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?}"; shift 2 ;;
    --bean)   BEAN_FILE="${2:?}"; shift 2 ;;
    --policy) POLICY="${2:?}"; shift 2 ;;
    --gates)  GATES="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*) usage >&2; die "unknown flag: $1" ;;
    *)  [ -z "$RUN_DIR" ] || die "only one run dir"; RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || { usage >&2; die "run dir required"; }
case "$TARGET" in spec|impl|doc|package) ;; *) die "--target must be spec|impl|doc|package (got: ${TARGET:-none})" ;; esac
[ -n "$BEAN_FILE" ] && [ -f "$BEAN_FILE" ] || die "--bean is required and must exist"
require_cmd jq

ROOT="$(repo_root)"
PY="$(factory_python)"
[ -n "$POLICY" ] || POLICY="$ROOT/factory/risk-policy.yaml"
[ -n "$GATES" ]  || GATES="$ROOT/factory/gates.lock.yaml"
VERDICTS="$RUN_DIR/verdicts"
mkdir -p "$VERDICTS"

# The judgement for THIS attempt is the highest-numbered one.
JUDGEMENT=""; N=0
for f in "$VERDICTS/$TARGET".attempt-*.judgement.json; do
  [ -e "$f" ] || continue
  n="${f##*attempt-}"; n="${n%%.*}"
  if [ "$n" -gt "$N" ]; then N="$n"; JUDGEMENT="$f"; fi
done

# refuse <rule> <exit> <one-line reason> [<details as JSON>]
#
# Every refusal in this script used to exist only as words on stderr. The
# controller was making a real decision — this judgement is not usable — and
# recording it nowhere a later reader could count. "5 of 12 reaudit refusals were
# fabricated quotes" is a number this project needed twice and had to reconstruct
# by hand from terminal scrollback both times.
#
# So each refusal also writes <target>.attempt-N.refused.json, naming the RULE
# that fired. That makes the question "which check is doing the work?" arithmetic
# rather than recollection — and it is the same argument as everywhere else here:
# a decision a script cannot read is a decision that will be misremembered.
#
# It is deliberately NOT a verdict. A verdict says accept/revise/block about the
# artifact; this says nothing about the artifact at all, only that the judgement
# offered was not one the controller could stamp. Giving it the verdict schema
# would put those two on the same shelf, which is precisely the confusion the
# split in JUDGEMENT-CONTRACT.md exists to prevent.
refuse() {
  local rule="$1" code="$2" reason="$3" details="${4:-null}"
  mkdir -p "$VERDICTS" 2>/dev/null || true
  jq -n --arg t "$TARGET" --argjson n "${N:-0}" --arg rule "$rule" --arg reason "$reason" \
        --argjson details "$details" --arg j "${JUDGEMENT:-}" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg bean "${BEAN_ID:-}" \
        --arg run "$(jq -r '.run_id // ""' "$RUN_DIR/run.json" 2>/dev/null)" \
    '{schema:"refusal/1.0.0", target:$t, attempt:$n, rule:$rule, reason:$reason,
      details:$details, judgement:(if $j == "" then null else $j end),
      refused_at:$at, bean:(if $bean == "" then null else $bean end),
      run_id:(if $run == "" then null else $run end)}' \
    > "$VERDICTS/$TARGET.attempt-${N:-0}.refused.json" 2>/dev/null || true
  exit "$code"
}

STAGE_FOR() { case "$1" in spec) echo spec_audit ;; impl|package) echo impl_audit ;; doc) echo pre_pr_audit ;; esac; }
STAGE="$(STAGE_FOR "$TARGET")"

if [ -z "$JUDGEMENT" ]; then
  # Not retried blind: a missing judgement is the judge failing to do its job,
  # and there is nothing in it for the authoring step to act on.
  printf 'AUDIT %s: the judge wrote no judgement file.\n' "$TARGET" >&2
  printf '      expected: %s/%s.attempt-<n>.judgement.json\n' "$VERDICTS" "$TARGET" >&2
  ls -1 "$VERDICTS" 2>/dev/null | sed 's/^/      present: /' >&2
  refuse no-judgement 2 "the judge wrote no judgement file"
fi
if ! jq -e . "$JUDGEMENT" >/dev/null 2>&1; then
  printf 'AUDIT %s: %s is not valid JSON.\n' "$TARGET" "$JUDGEMENT" >&2
  refuse judgement-not-json 2 "the judgement file is not valid JSON"
fi

J="$(cat "$JUDGEMENT")"
VERDICT="$(jq -r '.verdict // empty' <<<"$J")"
case "$VERDICT" in
  accept|revise|block|abstain) ;;
  *) printf 'AUDIT %s: verdict is %s, expected accept|revise|block\n' "$TARGET" "${VERDICT:-absent}" >&2
     refuse verdict-not-a-word 2 "the verdict field is not accept, revise, block or abstain" \
       "$(jq -nc --arg v "${VERDICT:-}" '{got:$v}')" ;;
esac

# An abstention is the judge saying it could not tell. That is a question for a
# person, not work for the authoring step: re-entering the developer with "the
# judge was unsure" gives it nothing to act on, and re-running the judge just
# rolls the dice again. So it is recorded, flagged for human review, and the run
# stops here.
#
# This exists because the judge is the component with the recorded honesty
# problem — it once audited a document it never read, fluently — and a judge with
# no way to say "I cannot tell" will say something else instead. Quote
# verification catches invented evidence; nothing catches a confident accept
# whose quotes are all real. An abstention is the only place that doubt can go.
if [ "$VERDICT" = "abstain" ]; then
  printf 'AUDIT %s: the judge abstained — this goes to a human, not to a retry\n' "$TARGET" >&2
  printf '       %s\n' "$(jq -r '.feedback_to_worker // "no reason given"' <<<"$J")" >&2
fi

# A blocker with an accept is self-contradicting. The schema cannot say this, so
# the controller does — and it corrects rather than rejects, because the finding
# is the judge's real opinion and the summary word is the slip.
# Confidence below the floor is an abstention the judge did not know to declare.
# Routed to a human rather than to `revise` for the same reason: "the judge was
# unsure" is not a finding anybody can act on.
CONF_FLOOR="${JUDGE_CONFIDENCE_FLOOR:-0.4}"
CONF="$(jq -r '.confidence // 1' <<<"$J")"

# The contract says 0 to 1. A real judgement came back with confidence 100, was
# stamped into a verdict, and sailed past the floor check because 100 is not less
# than 0.4 — the one comparison that reads this number cannot tell a confident
# judge from one that answered a different question.
#
# Constrained decoding does not enforce numeric bounds: the grammar knows the
# field must be a number, not that it must be in range. So the range is checked
# here, where it is cheap, and a value outside it is refused rather than clamped.
# Clamping 100 to 1 would invent a claim the model never made — and the two
# readings, "certain" and "percent", are not reconcilable by guessing.
if ! awk -v c="$CONF" 'BEGIN{exit !(c >= 0 && c <= 1)}' 2>/dev/null; then
  printf 'AUDIT %s: confidence %s is outside the contract range 0..1.\n' "$TARGET" "$CONF" >&2
  printf '       The judgement is kept at %s; no verdict is stamped from it.\n' \
    "$VERDICTS/$TARGET.attempt-$N.json.rejected" >&2
  cp "$JUDGEMENT" "$VERDICTS/$TARGET.attempt-$N.json.rejected" 2>/dev/null || true
  refuse confidence-out-of-range 1 "confidence is outside the contract range 0..1" \
    "$(jq -nc --arg c "$CONF" '{confidence:$c}')"
fi
if [ "$VERDICT" = "accept" ] && awk -v c="$CONF" -v f="$CONF_FLOOR" 'BEGIN{exit !(c < f)}'; then
  printf 'AUDIT %s: accepted at confidence %s, below the %s floor — recorded as abstain\n' \
    "$TARGET" "$CONF" "$CONF_FLOOR" >&2
  VERDICT="abstain"
fi

# A `revise` with nothing to revise is not a verdict the line can act on.
#
# orchestrate.sh routes a failed audit back into the authoring step WITH THE
# FINDINGS: that is the entire mechanism by which an audit changes anything. A
# `revise` carrying zero findings re-enters the step with nothing attached, which
# asks the identical question again and burns an attempt — and the second failure
# halts the run for a human whose only information is "the judge said revise".
#
# Measured: judge-variance on 2026-09-16, five identical runs at temperature 0,
# returned `revise` every time with findings counts of 4, 0, 4, 3 and 1. The
# zero is not hypothetical and it is not rare.
#
# `abstain` is different and is left alone: it means "I cannot form a judgement",
# it goes to a human rather than to a retry, and feedback_to_worker is where its
# reason lives.
NFIND="$(jq '[.findings[]?] | length' <<<"$J")"
case "$VERDICT" in
  revise|block)
    if [ "$NFIND" -eq 0 ]; then
      printf 'AUDIT %s: verdict "%s" with zero findings.\n' "$TARGET" "$VERDICT" >&2
      printf '      A failed audit is routed back into the authoring step carrying its findings;\n' >&2
      printf '      that is the only way an audit changes anything. With none, the step is asked\n' >&2
      printf '      the identical question again and the second failure halts the run.\n' >&2
      printf '      If there is genuinely nothing to point at, the verdict is "abstain".\n' >&2
      cp "$JUDGEMENT" "$VERDICTS/$TARGET.attempt-$N.json.rejected" 2>/dev/null || true
      refuse verdict-without-findings 1 "a revise or block verdict with nothing to point at" \
        "$(jq -nc --arg v "$VERDICT" '{verdict:$v, findings:0}')"
    fi ;;
esac

BLOCKERS="$(jq '[.findings[]? | select(.severity == "blocker")] | length' <<<"$J")"
if [ "$BLOCKERS" -gt 0 ] && [ "$VERDICT" = "accept" ]; then
  printf 'AUDIT %s: %s blocker finding(s) with an "accept" verdict — recorded as "revise"\n' "$TARGET" "$BLOCKERS" >&2
  VERDICT="revise"
fi

# ------------------------------------ every criterion, and only the real ones --
#
# judge.sh puts the bean's criteria in the prompt by id and says "one entry in
# `criteria` per line, using exactly these ids". Nothing checked that it happened.
#
# Both halves are measured failure modes of this model, not hypotheticals:
#
#   too few  — bean-001's doc audit came back `accept` with zero criteria for a
#              bean with four. A partial audit presented as a complete one, and
#              the only thing that refused it was the quote check, by accident:
#              a judgement with no criteria also has no quotes, and "the
#              judgement quotes nothing" is the wrong sentence about it.
#   invented — without the id list in the prompt this judge reported against
#              criteria nobody asked about ("C001: the spec must be valid JSON").
#              The list was added; whether it is being followed was never read
#              back.
#
# Before the quote machinery, for that reason: this is the cheaper check and the
# more specific sentence.
#
# It applies to `abstain` too. The first version exempted abstentions, on the
# reasoning that a judge which cannot form a judgement should not be pushed
# toward working through a list. The exemption permitted nothing —
# verdict.schema.json already requires `criteria` to be non-empty for every
# verdict, so an abstention with none was refused a few lines later with
# "criteria: [] should be non-empty". It only moved the refusal somewhere less
# legible.
BEAN_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$BEAN_FILE")"
BEAN_ID="$(jq -r '.id' <<<"$BEAN_JSON")"
WANT_IDS="$(jq -r '[(.acceptance_criteria // [])[].id] | sort | .[]' <<<"$BEAN_JSON")"
GOT_IDS="$(jq -r '[(.criteria // [])[].id] | sort | .[]' <<<"$J")"
if [ -n "$WANT_IDS" ]; then
  MISSING_IDS="$(comm -23 <(printf '%s\n' "$WANT_IDS") <(printf '%s\n' "$GOT_IDS") | tr '\n' ' ')"
  EXTRA_IDS="$(comm -13 <(printf '%s\n' "$WANT_IDS") <(printf '%s\n' "$GOT_IDS") | tr '\n' ' ')"
  MISSING_IDS="${MISSING_IDS% }"; EXTRA_IDS="${EXTRA_IDS% }"
  if [ -n "$MISSING_IDS" ] || [ -n "$EXTRA_IDS" ]; then
    printf 'AUDIT %s: the judgement does not report on the criteria it was given.\n' "$TARGET" >&2
    [ -n "$MISSING_IDS" ] && printf '      not reported on: %s\n' "$MISSING_IDS" >&2
    [ -n "$EXTRA_IDS" ] && printf '      reported on, but not in the bean: %s\n' "$EXTRA_IDS" >&2
    printf '      %s declares: %s\n' "$BEAN_ID" "$(printf '%s' "$WANT_IDS" | tr '\n' ' ')" >&2
    printf '\n      A verdict over some of the criteria, stamped as a verdict, is the shape of\n' >&2
    printf '      a false accept: the ones nobody looked at are the ones that were wrong.\n' >&2
    cp "$JUDGEMENT" "$VERDICTS/$TARGET.attempt-$N.json.rejected" 2>/dev/null || true
    refuse criteria-do-not-match 1 "the judgement reports on criteria the bean does not declare, or misses some it does" \
      "$(jq -nc --arg m "$MISSING_IDS" --arg e "$EXTRA_IDS" \
         '{not_reported_on:($m|split(" ")|map(select(. != ""))), not_in_the_bean:($e|split(" ")|map(select(. != "")))}')"
  fi
  # wc -w, not wc -l. The ids come back newline-separated with no trailing
  # newline, so `wc -l` reports one fewer than there are and a two-criterion bean
  # announced "all 1 criterion(s)" — a wrong count inside a passing message,
  # which is where it is least likely to be questioned.
  printf 'AUDIT %s: all %s criterion(s) reported on, none invented\n' "$TARGET" \
    "$(printf '%s' "$WANT_IDS" | wc -w)" >&2
fi

# ------------ the counts it was handed, restated correctly or not restated at all --
#
# verdict.schema.json requires `test_integrity` on an impl audit: deleted_tests,
# new_skips, weakened_asserts. The controller already counted the first two, from
# the diff, and handed the judge the result as an artifact — so the judge is being
# asked to restate a number it was given, and two sources for one number is one
# source that will eventually disagree with itself.
#
# Disagreement is not a rounding error here. The judge was handed
# test-integrity.json in its own message. Restating its numbers wrongly is
# evidence it did not read what it was given, which is the same thing the quote
# check is for and the same failure this line has already seen once: a fluent,
# confident audit of a document the judge never opened.
#
# So: refused, with both numbers named. Not repaired — writing the controller's
# count into the verdict would hide that the judge contradicted its own evidence,
# and the verdict would then read as though the judge had got it right.
#
# `weakened_asserts` is not compared: the controller counts assertions removed
# against assertions added and declines to call that a boolean, so there is no
# measured value to compare a boolean to. The two that are counted are.
TI_FILE="$RUN_DIR/test-integrity.json"
if [ -f "$TI_FILE" ] && jq -e 'has("test_integrity")' <<<"$J" >/dev/null 2>&1; then
  ti_bad=""
  for field in deleted_tests new_skips; do
    measured="$(jq -r --arg f "$field" '.test_integrity[$f] // empty' "$TI_FILE" 2>/dev/null)"
    claimed="$(jq -r --arg f "$field" '.test_integrity[$f] // empty' <<<"$J" 2>/dev/null)"
    [ -n "$measured" ] && [ -n "$claimed" ] || continue
    [ "$measured" = "$claimed" ] || ti_bad="$ti_bad $field(measured=$measured claimed=$claimed)"
  done
  if [ -n "$ti_bad" ]; then
    printf 'AUDIT %s: the judgement restates counts it was given, wrongly:%s\n' "$TARGET" "$ti_bad" >&2
    printf '      test-integrity.json was in the judge\x27s own messages. A judgement that\n' >&2
    printf '      contradicts an artifact it was handed did not read it, which is the same\n' >&2
    printf '      failure the quote check exists for.\n' >&2
    printf '      Refused rather than repaired: writing the measured count into the verdict\n' >&2
    printf '      would hide that the judge contradicted its own evidence.\n' >&2
    cp "$JUDGEMENT" "$VERDICTS/$TARGET.attempt-$N.json.rejected" 2>/dev/null || true
    refuse restated-counts-wrong 1 "the judgement restates counts it was handed, wrongly" \
      "$(jq -nc --arg b "$ti_bad" '{fields:($b|split(" ")|map(select(. != "")))}')"
  fi
  printf 'AUDIT %s: the counts it restates match the ones it was given\n' "$TARGET" >&2
fi

# ------------------------------------------- did the judge read the artifact? --
#
# The first real judge this line asked for a verdict never read the spec. It
# wrote a fluent, confident audit of a document with sections called Purpose,
# Architecture, Input, Output and Errors — none of which exist in this pipeline's
# format — and declared the references in its own instruction file valid. Every
# sentence was plausible and none of it happened.
#
# A schema cannot catch that; the output was well-formed and entirely invented.
# What catches it is making the judge point at text that exists, and then looking.
# A judge that read the artifact can quote it without effort. One that did not
# cannot produce a single line that is really there.
# One quote per line, JSON-escaped: a quote spanning several lines is one quote,
# and splitting it on newlines would check fragments instead of the thing said.
QUOTES="$(jq -r '[(.criteria[]?.quote // empty), (.findings[]?.quote // empty)] | .[] | @json' <<<"$J" 2>/dev/null)"
NQ="$(printf '%s\n' "$QUOTES" | sed '/^$/d' | wc -l)"
if [ "$NQ" -eq 0 ]; then
  printf 'AUDIT %s: the judgement quotes nothing.\n' "$TARGET" >&2
  printf '      Every criterion needs a `quote` copied verbatim from the artifact. A judge\n' >&2
  printf '      that read it can do that without effort; one that did not, cannot. See\n' >&2
  printf '      JUDGEMENT-CONTRACT.md.\n' >&2
  refuse quotes-nothing 2 "the judgement quotes nothing at all"
fi

# Where a quote may legitimately come from: the artifacts under audit, anything
# else in the run directory (a verify log, a gate log), or any tracked file in
# the repository — a judge may quote the source it is judging.
norm() { tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'; }
HAYSTACK="$(mktemp)"
trap 'rm -f "$HAYSTACK"' EXIT
{
  # NOT the verdicts directory. The judgement is in there, so searching it would
  # let every quote match itself and the check would pass for any fiction at all.
  # No depth limit. It was 2, which excluded everything under
  # build/<task>/attempt-<n>/ — the verify logs, the containment records, the
  # worker's own output, all at depth 4. An impl audit quoting the output of a
  # check that failed would have had its quote refused as invented, which is the
  # one accusation this script must not make wrongly.
  find "$RUN_DIR" -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.json' -o -name '*.txt' -o -name '*.log' -o -name '*.jsonl' \) \
    -not -path "$VERDICTS/*" -exec cat {} + 2>/dev/null
  git -C "$ROOT" ls-files -z 2>/dev/null | xargs -0 -r cat 2>/dev/null
} | norm > "$HAYSTACK"

# One threshold, named once. It is used in three places — skipping a quote too
# short to check, refusing a judgement where every quote is, and refusing a
# CRITERION whose own quote is — and three copies of a number is two that drift.
# Twelve characters: below it a quote matches everything on disk and proves
# nothing. `"mypy src"` is eight, and it was the evidence the only stamped verdict
# this line has produced offered for "mypy reports no errors".
QUOTE_MIN_CHARS=12

UNFOUND=""
CHECKED=0
while IFS= read -r qjson; do
  [ -n "$qjson" ] || continue
  q="$(jq -r '.' <<<"$qjson" 2>/dev/null)" || continue
  # Very short quotes prove nothing and match everything.
  [ "${#q}" -ge "$QUOTE_MIN_CHARS" ] || continue
  CHECKED=$((CHECKED + 1))
  needle="$(printf '%s' "$q" | norm)"
  grep -qF -- "$needle" "$HAYSTACK" || UNFOUND="$UNFOUND
  - $(printf '%s' "${q:0:100}" | tr '\n' ' ')"
done <<< "$QUOTES"

if [ "$CHECKED" -eq 0 ]; then
  printf 'AUDIT %s: no quote long enough to prove anything (all under %s characters).\n' "$TARGET" "$QUOTE_MIN_CHARS" >&2
  refuse all-quotes-too-short 2 "every quote is under the length at which a quote proves anything" \
    "$(jq -nc --argjson min "$QUOTE_MIN_CHARS" --argjson n "$NQ" '{min_chars:$min, quotes:$n}')"
fi

# Per CRITERION, not per judgement. The rule above refuses a judgement whose
# quotes are ALL too short, and that left a gap wide enough to drive the whole
# verdict through: four criteria, one with a real 300-character quote and three
# with "the test" apiece, and the check reported "1 quote(s) verified" and passed.
# The three unverifiable criteria rode along on the one that was checked, and a
# verdict rests on every criterion, not on the best one.
#
# A judge that read the artifact can quote twelve characters of it per criterion
# without effort; the ones this project has measured emit 200-600 characters when
# they quote at all. So this costs an honest judge nothing, and it is the same
# argument the quote check itself is built on.
SHORT="$(jq -r --argjson min "$QUOTE_MIN_CHARS" '[.criteria[]? | select((.quote // "" | length) < $min) | .id] | join(", ")' <<<"$J" 2>/dev/null)"
if [ -n "$SHORT" ]; then
  printf 'AUDIT %s: these criteria are not backed by a quote long enough to check: %s\n' "$TARGET" "$SHORT" >&2
  printf '\n      A verdict rests on every criterion, not on the best one. %s characters\n' "$QUOTE_MIN_CHARS" >&2
  printf '      is the threshold below which a quote matches everything and proves nothing,\n' >&2
  printf '      and a criterion whose quote is under it was never verified — whatever the\n' >&2
  printf '      other criteria managed.\n' >&2
  refuse criterion-quote-too-short 2 "some criteria are not backed by a quote long enough to check" \
    "$(jq -nc --arg s "$SHORT" --argjson min "$QUOTE_MIN_CHARS" \
       '{min_chars:$min, criteria:($s|split(", ")|map(select(. != "")))}')"
fi

if [ -n "$UNFOUND" ]; then
  printf 'AUDIT %s: the judgement quotes text that is not on disk anywhere.\n' "$TARGET" >&2
  printf '%s\n' "$UNFOUND" >&2
  printf '\n      A quote is not a paraphrase. If the judge cannot point at real text, the\n' >&2
  printf '      audit did not happen — which is exactly how a confident false accept gets\n' >&2
  printf '      into a run. Refusing rather than recording it.\n' >&2
  refuse quote-not-on-disk 2 "the judgement quotes text that is not in any artifact, the run directory or the repository" \
    "$(printf '%s' "$UNFOUND" | sed 's/^ *- //' | jq -R . | jq -sc '{quotes: map(select(. != ""))}')"
fi
printf 'AUDIT %s: %s quote(s) verified against the artifacts\n' "$TARGET" "$CHECKED" >&2

# ------------------------------------------------------ the observable facts --
# BEAN_JSON and BEAN_ID are parsed above, by the criteria check.
BASE_REF="$(jq -r '.base // "main"' "$RUN_DIR/run.json" 2>/dev/null)"
BASE_SHA="$(git -C "$ROOT" rev-parse "$(git -C "$ROOT" merge-base "$BASE_REF" HEAD 2>/dev/null || echo "$BASE_REF")" 2>/dev/null || echo unknown)"
CAND_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
DIFF_SHA="$(git -C "$ROOT" diff "$BASE_SHA"...HEAD 2>/dev/null | sha256sum | cut -d' ' -f1)"
[ -n "$DIFF_SHA" ] || DIFF_SHA="$(printf '' | sha256sum | cut -d' ' -f1)"

# A provenance field the controller cannot observe is a reason to stop, not a
# reason to write a placeholder. The schema's patterns are strict precisely so
# that "unknown" cannot be smuggled into a field a later decision will read.
[[ "$BASE_SHA" =~ ^[0-9a-f]{40}$ ]] || die "cannot resolve base sha for '$BASE_REF' — a verdict without one cannot say what it judged"
[[ "$CAND_SHA" =~ ^[0-9a-f]{40}$ ]] || die "cannot resolve HEAD — a verdict must name the candidate it judged"

GATE_RUN_ID="$(jq -r '.started_at // empty' "$RUN_DIR/gate.json" 2>/dev/null)"
# For a spec audit there is no code gate yet; the spec check IS the gate run, and
# the schema says so explicitly. Name it rather than inventing a code gate id.
[ -n "$GATE_RUN_ID" ] || GATE_RUN_ID="spec-check:$(basename "$RUN_DIR")"

GATE_DIGEST=""
[ -f "$GATES" ] && GATE_DIGEST="$("$PIPELINE_DIR/yaml2json.sh" "$GATES" 2>/dev/null | jq -r '.image | split("@")[1] // empty')"
[[ "$GATE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || die "no digest-pinned gate image in $GATES — every verdict names the toolchain it was judged under"

# sha256 of nothing, for a bean bound by no invariants. The field is required and
# its pattern admits no sentinel, so the choice is between the digest of an empty
# input and a lie; this is the first one, and it is checkable.
EMPTY_SHA256="$(printf '' | sha256sum | cut -d' ' -f1)"
INV_REF="$(jq -r '.invariants_ref // empty' <<<"$BEAN_JSON")"
if [ -n "$INV_REF" ] && [ -f "$(resolve_repo_path "$INV_REF")" ]; then
  INV_DIGEST="sha256:$(sha256sum "$(resolve_repo_path "$INV_REF")" | cut -d' ' -f1)"
elif [ -n "$INV_REF" ]; then
  die "bean $BEAN_ID names invariants at $INV_REF and the file is not there — an invariant that cannot run is not a guarantee"
else
  INV_DIGEST="sha256:$EMPTY_SHA256"
fi

# The documents this verdict judged, bound by hash, so the pull request can prove
# which version the judge actually read.
ARTIFACTS="[]"
for pair in "spec:$RUN_DIR/spec.md" "tasks:$RUN_DIR/tasks.yaml" "impl_detail:$RUN_DIR/impl-detail.md"; do
  kind="${pair%%:*}"; path="${pair#*:}"
  [ -f "$path" ] || continue
  ARTIFACTS="$(jq -c --arg k "$kind" --arg p "$(realpath --relative-to="$ROOT" "$path")" \
    --arg h "$(sha256sum "$path" | cut -d' ' -f1)" \
    '. + [{kind:$k, path:$p, sha256:$h}]' <<<"$ARTIFACTS")"
done
POLICY_VERSION="$([ -f "$POLICY" ] && "$PIPELINE_DIR/yaml2json.sh" "$POLICY" | jq -r '.policy_version // "unknown"' || echo unknown)"

# The tier: from gate.json when the gate has run, otherwise computed from the
# diff now. The judge's suggestion can raise it and cannot lower it.
JUDGE_TIER="$(jq -r '.suggested_tier // empty' <<<"$J")"
if [ -f "$RUN_DIR/gate.json" ] && [ "$(jq -r '.tier.final_tier // "null"' "$RUN_DIR/gate.json")" != "null" ]; then
  TIER="$(jq -r '.tier.final_tier' "$RUN_DIR/gate.json")"
else
  CHANGED="$(git -C "$ROOT" diff --name-only "$BASE_SHA"...HEAD 2>/dev/null | sed '/^$/d' | jq -Rsc 'split("\n") | map(select(length>0))')"
  targs=( --policy "$POLICY" --paths "${CHANGED:-[]}" --json )
  bt="$(jq -r '.suggested_risk_tier // empty' <<<"$BEAN_JSON")"
  [ -n "$bt" ] && targs+=( --bean-tier "$bt" )
  TIER="$("$PY" "$PIPELINE_DIR/tier.py" "${targs[@]}" 2>/dev/null | jq -r '.final_tier // 1')"
fi
if [ -n "$JUDGE_TIER" ] && [ "$JUDGE_TIER" -gt "${TIER:-0}" ] 2>/dev/null; then
  printf 'AUDIT %s: the judge raised the tier from %s to %s\n' "$TARGET" "$TIER" "$JUDGE_TIER" >&2
  TIER="$JUDGE_TIER"
fi

ROLE_MODEL="$(jq -r '.roles.judge.model' "$PIPELINE_DIR/roles.json")"
MODEL_DIGEST="$(ollama list 2>/dev/null | awk -v m="$ROLE_MODEL" '$1 == m {print $2; exit}')"
[ -n "$MODEL_DIGEST" ] || MODEL_DIGEST="unknown"
# The prompt version is the skill's own content hash: "which prompt produced this
# verdict" is unanswerable later otherwise, and the skills are the thing most
# actively tuned.
SKILL_MD="$PIPELINE_DIR/../skills/factory-audit/SKILL.md"
PROMPT_VERSION="$([ -f "$SKILL_MD" ] && printf 'factory-audit@%s' "$(sha256sum "$SKILL_MD" | cut -c1-12)" || echo "factory-audit@unknown")"

# test_integrity comes from the controller's measurement, not the judge's memory.
#
# verdict.schema.json REQUIRES test_integrity on an impl audit. judge.sh's response
# schema does not contain the field at all — so the judge is never asked for it, and
# an impl verdict could never validate. On 2026-09-16 an impl audit got all the way
# through every other check, four criteria and two verified quotes, and died on
# "'test_integrity' is a required property". A contract that cannot be satisfied.
#
# The fix is not to ask the judge. test-integrity.sh already ran the tests against
# the reverted source and counted the deleted tests and new skips from the diff, and
# the judge was handed the result as an artifact. The verdict is the controller's
# document and this is the controller's measurement, so it goes in from there. If
# the judge volunteered numbers of its own, the check further up has already refused
# the judgement for contradicting them.
#
# weakened_asserts: the controller counts assertions removed against assertions
# added and declines to call that a boolean, so the boolean the schema wants is
# derived here, and derived to the only shape the counts can support — more removed
# than added. coverage_delta says "not measured", because it is not.
TI_MEASURED=null
if [ -f "$RUN_DIR/test-integrity.json" ]; then
  TI_MEASURED="$(jq -c '
    (.test_integrity // {}) as $t
    | if ($t | has("deleted_tests")) then
        {deleted_tests: $t.deleted_tests,
         new_skips: $t.new_skips,
         weakened_asserts: ((($t.removed_asserts // 0)) > (($t.added_asserts // 0))),
         coverage_delta: "not measured"}
      else null end' "$RUN_DIR/test-integrity.json" 2>/dev/null || echo null)"
  [ -n "$TI_MEASURED" ] || TI_MEASURED=null
fi

OUT="$VERDICTS/$TARGET.attempt-$N.json"
jq -n \
  --arg sv "verdict/2.0.0" --arg stage "$STAGE" --arg bean "$BEAN_ID" \
  --arg base "$BASE_SHA" --arg cand "$CAND_SHA" --arg diff "$DIFF_SHA" \
  --arg gate_run "$GATE_RUN_ID" --arg gate_digest "$GATE_DIGEST" --arg inv "$INV_DIGEST" \
  --arg policy "$POLICY_VERSION" --argjson tier "${TIER:-1}" \
  --arg model "$MODEL_DIGEST" --arg prompt "$PROMPT_VERSION" \
  --arg verdict "$VERDICT" --argjson j "$J" --argjson artifacts "$ARTIFACTS" \
  --argjson ti "$TI_MEASURED" \
  --argjson req "$([ -f "$VERDICTS/$TARGET.request.json" ] && cat "$VERDICTS/$TARGET.request.json" || echo null)" \
  '{schema_version: $sv, stage: $stage, bean_id: $bean,
    base_sha: $base, candidate_sha: $cand, diff_sha256: $diff,
    gate_run_id: $gate_run, gate_manifest_digest: $gate_digest,
    invariants_digest: $inv, policy_version: $policy,
    effective_risk_tier: $tier, model_digest: $model, prompt_version: $prompt,
    criteria: [($j.criteria // [])[] | {id, met,
      evidence: (.evidence + (if .quote then "  [quoted: " + .quote + "]" else "" end))}],
    verdict: $verdict, artifacts: $artifacts}
   # How big the prompt was that produced this. judge.sh writes it beside the
   # judgement; it is the most predictive variable measured on this judge — 8 of 8
   # rejections of a seeded defect at 20,422 bytes, 0 of 8 at 40,422 — and a
   # verdict that does not carry it cannot be weighed against that later. Absent
   # for a verdict written before 2026-09-17, which is the honest answer for one.
   + (if $req != null then {prompt_bytes: ($req.artifact_bytes // null),
                            prompt_artifacts: ($req.artifact_count // null)} else {} end)
   + (if $j.feedback_to_worker then {feedback_to_worker: $j.feedback_to_worker} else {} end)
   + (if $j.document_quality then {document_quality: $j.document_quality} else {} end)
   + (if $ti != null then {test_integrity: $ti}
       elif $j.test_integrity then {test_integrity: $j.test_integrity} else {} end)
   + (if $j.security_findings then {security_findings: $j.security_findings} else {} end)
   + (if $j.confidence then {confidence: $j.confidence} else {} end)
   + (if $j.suggested_tier then {suggested_tier: $j.suggested_tier} else {} end)
   + (if $j.suggested_human_review != null then {suggested_human_review: $j.suggested_human_review} else {} end)' \
  > "$OUT"

# ------------------------------------------------------------- validate it --
VALIDATE="$PIPELINE_DIR/../../bench/validate.py"
if [ -f "$VALIDATE" ] && [ -x "$PY" ]; then
  if ! vout="$("$PY" "$VALIDATE" verdict "$OUT" 2>&1)"; then
    printf 'AUDIT %s: the verdict does not validate against verdict.schema.json\n' "$TARGET" >&2
    printf '%s\n' "$vout" | sed 's/^/      /' >&2
    printf '      kept at %s for inspection\n' "$OUT" >&2
    exit 2
  fi
fi

# The step's recorded verdict. run-step.sh closed the attempt before this script
# existed to judge it, so it had nothing to go on: the verdict file is written
# here, after the child has gone. Amend the attempt it opened rather than append
# a second end line — an unpaired end is the shape that broke BEAN-125's
# telemetry, and step.sh refuses it for that reason.
STEPS="$RUN_DIR/steps.jsonl"
STEP_NAME="audit-$TARGET"
if [ -f "$STEPS" ]; then
  case "$VERDICT" in
    accept)  step_verdict=PASS ;;
    abstain) step_verdict=ABSTAIN ;;
    *)       step_verdict=FAIL ;;
  esac
  jq -sc --arg s "$STEP_NAME" --arg v "$step_verdict" --arg f "$OUT" '
    . as $arr
    | ([ to_entries[] | select(.value.step == $s and .value.event == "end") | .key ]) as $idx
    | if ($idx | length) == 0 then $arr
      else $arr | .[ ($idx | last) ] |= (.verdict = $v | .verdict_file = $f)
      end
    | .[]' "$STEPS" > "$STEPS.tmp" && mv "$STEPS.tmp" "$STEPS"
fi

nfind="$(jq '[.findings[]?] | length' <<<"$J")"
printf 'AUDIT %s   %s   attempt %s   tier %s   %s finding(s)   %s\n' \
  "$TARGET" "$VERDICT" "$N" "$TIER" "$nfind" "$OUT"
jq -r '.findings[]? | "  \(.severity): \(.summary)"' <<<"$J" 2>/dev/null

[ "$VERDICT" = "accept" ] && exit 0
# 7: a human is needed. Distinct from 1 (revise/block, which the driver routes
# back to the authoring step) because there is nothing to route.
[ "$VERDICT" = "abstain" ] && exit 7
exit 1
