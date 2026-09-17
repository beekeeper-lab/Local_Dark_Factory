#!/usr/bin/env bash
# package-check.sh — the package rubric, in full, without asking anyone.
#
# Of the four audit targets, `package` is the one whose entire rubric is
# arithmetic. Read it back and every bullet is a fact about files the controller
# itself wrote:
#
#   every `end` line has a matching `start` at the same attempt, none closed twice
#   run.json's status agrees with the recorded steps
#   gate.json says pass, its containment is clean, its tier is recorded
#   verdict files are named <target>.attempt-N.json for a real target
#   verdicts exist only for the audit steps this tier ran
#
# None of that needs judgement, and a language model doing bookkeeping on JSONL is
# the worst available way to get it done: it is slow, it costs a model call, and
# when it is wrong it is wrong fluently. The judge was asked to count matching
# start/end pairs across a log it was shown as text. This counts them.
#
# What is left for the judge on this target is the thing arithmetic cannot reach:
# whether the run, taken as a whole, tells a coherent story — whether the reasons
# recorded for the retries make sense together, whether the evidence supports the
# conclusion. That question is worth a model. Counting is not.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
package-check.sh — the deterministic half of the pre-PR audit.

usage: package-check.sh <run_dir> [--tier small|full]

  --tier <t>   which steps this run should have (default: read from run.json,
               else inferred from the steps actually recorded)
  --current-step <s>
               the step this check is running inside; its start is legitimately
               unpaired because it is waiting for this check to finish

Writes <run_dir>/package-check.json.

Exit: 0 the run record is internally consistent · 1 it is not.
EOF
}

RUN_DIR=""; TIER=""; CURRENT_STEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)    TIER="${2:?--tier needs small or full}"; shift 2 ;;
    # The step this check is running inside. Its `start` is in the log and its
    # `end` cannot be, because it has not finished — it is waiting for this.
    # Without this the pairing check reports its own caller as an unclosed step,
    # every single time, and the run halts on the one entry that is supposed to
    # be open.
    --current-step) CURRENT_STEP="${2:?--current-step needs a step name}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*)        usage >&2; die "unknown flag: $1" ;;
    *)         [ -z "$RUN_DIR" ] || die "only one run dir"; RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] || { usage >&2; exit 1; }
[ -d "$RUN_DIR" ] || die "run directory not found: $RUN_DIR"
require_cmd jq

FAILED=0
ok()  { printf '  ok    %-26s %s\n' "$1" "$2"; }
bad() { printf '  FAIL  %-26s %s\n' "$1" "$2"; FAILED=1; }
note(){ printf '  --    %-26s %s\n' "$1" "$2"; }

printf '\nPACKAGE CHECK  %s\n\n' "$(basename "$RUN_DIR")"

RUN_JSON="$RUN_DIR/run.json"
[ -f "$RUN_JSON" ] || die "no run.json in $RUN_DIR — there is no run to check"
STEPS="$RUN_DIR/steps.jsonl"
FINDINGS="[]"
finding() { # finding <severity> <summary>
  FINDINGS="$(jq -c --arg s "$1" --arg m "$2" '. + [{severity:$s, summary:$m}]' <<<"$FINDINGS")"
  # Printed as well as recorded. The one-line FAIL above says what tripped; this
  # says why it matters, and a person reading the terminal should not have to
  # open a JSON file to find that out.
  printf '        [%s] %s\n' "$1" "$2"
}

# ------------------------------------------------- 1. starts and ends pair --
# The failure this catches is specific and has happened: a step invoked twice
# recorded one start and two ends, or one start and none, and the run looked
# complete because the last line said PASS.
PAIRS='[]'
if [ -f "$STEPS" ]; then
  PAIRS="$(jq -s --arg cur "$CURRENT_STEP" '
    [ .[] | select(.event == "start" or .event == "end")
          | select($cur == "" or .step != $cur)
          | {step, attempt: (.attempt // 1), event} ]
    | group_by([.step, .attempt])
    | map({step: .[0].step, attempt: .[0].attempt,
           starts: ([.[] | select(.event == "start")] | length),
           ends:   ([.[] | select(.event == "end")]   | length)})' "$STEPS")"
  UNPAIRED="$(jq -r '[.[] | select(.starts != 1 or .ends != 1)
    | "\(.step) attempt \(.attempt): \(.starts) start(s), \(.ends) end(s)"] | join("; ")' <<<"$PAIRS")"
  if [ -z "$UNPAIRED" ]; then
    ok "step log" "$(jq 'length' <<<"$PAIRS") step attempt(s), each opened and closed exactly once"
  else
    bad "step log" "$UNPAIRED"
    finding blocker "The step log does not pair: $UNPAIRED. A step recorded twice or left open means the run's own account of what it did is wrong."
  fi
else
  bad "step log" "no steps.jsonl — a run with no recorded steps cannot be audited"
  finding blocker "There is no steps.jsonl. Nothing about this run is evidenced."
fi

# --------------------------------------- 2. the status agrees with the log --
STATUS="$(jq -r '.status // "?"' "$RUN_JSON")"
FAILED_STEPS="$(jq -rs '[.[] | select(.event == "end" and .verdict != null and .verdict != "PASS")
  | "\(.step)=\(.verdict)"] | unique | join(", ")' "$STEPS" 2>/dev/null || true)"
case "$STATUS" in
  halted|blocked)
    if [ -n "$FAILED_STEPS" ] || [ -f "$RUN_DIR/QUESTIONS.md" ]; then
      ok "status" "$STATUS, and the log says why"
    else
      bad "status" "$STATUS, but every step passed and there is no QUESTIONS.md"
      finding blocker "run.json says $STATUS while every recorded step passed and nothing asked for a human. One of the two is untrue."
    fi ;;
  complete|pr_open|merged)
    if [ -f "$RUN_DIR/QUESTIONS.md" ]; then
      bad "status" "$STATUS, but QUESTIONS.md is still at the run root — a stale halt"
      finding blocker "run.json says $STATUS while QUESTIONS.md is still present. Either a question went unanswered or the file was left behind; both make the record untrustworthy."
    elif [ -n "$FAILED_STEPS" ]; then
      note "status" "$STATUS, after retrying: $FAILED_STEPS"
      ok "status" "$STATUS, consistent with a retried run"
    else
      ok "status" "$STATUS, and every step passed"
    fi ;;
  *) note "status" "$STATUS — not a terminal status; this run is still in flight" ;;
esac

# ---------------------------------------------------- 3. the gate's result --
GATE="$RUN_DIR/gate.json"
if [ ! -f "$GATE" ]; then
  bad "gate" "no gate.json — the change was never gated"
  finding blocker "There is no gate.json. Nothing ran against this change."
else
  G_OVERALL="$(jq -r '.overall // "?"' "$GATE")"
  G_CONTAINED="$(jq -r '.containment.contained | tostring' "$GATE")"
  G_TIER="$(jq -r '.tier.final_tier // "none"' "$GATE")"
  [ "$G_OVERALL" = pass ] && ok "gate" "pass" \
    || { bad "gate" "overall is '$G_OVERALL'"; finding blocker "The gate did not pass (overall=$G_OVERALL), so there is nothing to package."; }
  [ "$G_CONTAINED" = true ] && ok "containment" "clean" \
    || { bad "containment" "the diff went outside its allowed paths"
         finding blocker "Whole-diff containment failed: $(jq -r '[.containment.violations[]?] | join(", ")' "$GATE")"; }
  [ "$G_TIER" != none ] && ok "tier" "$G_TIER, recorded" \
    || { bad "tier" "no final tier recorded"; finding major "The gate recorded no binding tier, so nothing downstream can say what review this change needed."; }

  # test_integrity rides along in gate.json. Its undecided states are not the
  # package's problem to settle, but a package that hides them is.
  TI="$(jq -r '.test_integrity.fails_on_revert.result // "not run"' "$GATE")"
  case "$TI" in
    yes)       ok "test integrity" "the tests fail without this change" ;;
    no)        bad "test integrity" "the tests pass without this change"
               finding blocker "The tests pass with the change reverted; they do not test it." ;;
    "not run") note "test integrity" "not run" ;;
    *)         note "test integrity" "$TI — $(jq -r '.test_integrity.fails_on_revert.why // ""' "$GATE")"
               finding minor "Test integrity was undecided ($TI): $(jq -r '.test_integrity.fails_on_revert.why // ""' "$GATE")" ;;
  esac
fi

# ------------------------------------------------- 4. verdict files, named --
# A verdict under the wrong spelling is invisible to the driver, and the run halts
# on a phantom failure. This has happened, which is why it is in the rubric and
# why it is now counted rather than looked for.
VALID_TARGETS="spec impl doc package"
STRAY=""; VERDICTS_SEEN=""
if [ -d "$RUN_DIR/verdicts" ]; then
  for f in "$RUN_DIR"/verdicts/*.json; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    # What the model said, and what was sent to it. Neither is a verdict, and
    # both live here because they belong beside the verdict they produced.
    #
    # `<target>.request.json` arrived on 2026-09-17 — the prompt's byte count and
    # artifact count, recorded so that what was asked is on the record beside
    # what came back. (It was added while a size effect looked real; that finding
    # was retracted the same day, and the file is worth keeping anyway.) Without
    # this line it would be reported as a misnamed verdict and raise a BLOCKER on
    # every real run. The suite did not catch it: package-check's fixtures build
    # their own verdicts directory, so nothing put a request file in one.
    #
    # `<target>.attempt-N.refused.json` is the controller's own record that the
    # judgement could not be stamped, and which rule said so. Also not a verdict:
    # it says nothing about the artifact, only about the judgement offered.
    case "$b" in *.judgement.json|*.request.json|*.refused.json) continue ;; esac
    if [[ "$b" =~ ^([a-z]+)\.attempt-([0-9]+)\.json$ ]]; then
      t="${BASH_REMATCH[1]}"
      case " $VALID_TARGETS " in
        *" $t "*) VERDICTS_SEEN="$VERDICTS_SEEN $t" ;;
        *) STRAY="$STRAY $b(unknown target '$t')" ;;
      esac
    else
      STRAY="$STRAY $b"
    fi
  done
fi
if [ -z "$STRAY" ]; then
  ok "verdict files" "${VERDICTS_SEEN:- none}, all correctly named"
else
  bad "verdict files" "misnamed:$STRAY"
  finding blocker "Verdict file(s) under a name the driver does not read:$STRAY. A verdict it cannot see is a verdict that did not happen."
fi

# --------------------------------- 5. verdicts only for the steps this ran --
[ -n "$TIER" ] || TIER="$(jq -r '.tier // empty' "$RUN_JSON")"
if [ -z "$TIER" ] && [ -f "$STEPS" ]; then
  # Inferred rather than assumed: a run that recorded audit-spec ran the full tier.
  jq -e -s 'any(.[]; .step == "audit-spec")' "$STEPS" >/dev/null 2>&1 && TIER=full || TIER=small
fi
case "$TIER" in
  small) EXPECTED="impl package" ;;
  full)  EXPECTED="spec impl doc package" ;;
  *)     EXPECTED="" ;;
esac
# An audit run in advisory mode produces no verdict, and that is recorded rather
# than silent: orchestrate writes `failed-attempts/audit-<target>.advisory.N`
# saying the judge produced none and why the run continued anyway. Two rules in
# this line disagreed about what that means — the advisory mode says a missing
# verdict is expected, this check says a missing verdict is the record
# contradicting itself — and on the first run that reached this step, both were
# applying at once.
#
# The rule that resolves it without weakening anything: a full-tier audit must
# have EITHER a verdict OR a recorded reason it has none. Both are facts on disk.
# Neither is the contradiction, and that is still a blocker.
advisory_recorded() { # advisory_recorded <target>
  local t="$1" f
  for f in "$RUN_DIR/failed-attempts/audit-$t".advisory.* \
           "$RUN_DIR/failed-attempts/resolved/audit-$t".advisory.*; do
    [ -e "$f" ] && return 0
  done
  return 1
}

if [ -n "$EXPECTED" ]; then
  MISSING=""; UNEXPECTED=""; ADVISORY=""
  for t in $EXPECTED; do
    # `package` is this step; its own verdict does not exist yet.
    [ "$t" = package ] && continue
    case " $VERDICTS_SEEN " in
      *" $t "*) : ;;
      *) if advisory_recorded "$t"; then ADVISORY="$ADVISORY $t"
         else MISSING="$MISSING $t"; fi ;;
    esac
  done
  for t in $VERDICTS_SEEN; do
    case " $EXPECTED " in *" $t "*) : ;; *) UNEXPECTED="$UNEXPECTED $t" ;; esac
  done
  if [ -z "$MISSING" ] && [ -z "$UNEXPECTED" ]; then
    if [ -n "$ADVISORY" ]; then
      # Not a pass dressed up. The run has no verdict for these and says so; a
      # reader of this record must see that rather than infer it from an absence.
      note "verdicts vs tier" "$TIER tier; no verdict for:$ADVISORY — each has an advisory record saying the judge produced none"
    else
      ok "verdicts vs tier" "$TIER tier, and every audit it runs has one"
    fi
  else
    [ -n "$MISSING" ] && { bad "verdicts vs tier" "$TIER tier is missing a verdict for:$MISSING, with nothing recorded to say why"
      finding blocker "The $TIER tier runs audits with no verdict recorded and no advisory record explaining the absence:$MISSING"; }
    [ -n "$UNEXPECTED" ] && { bad "verdicts vs tier" "$TIER tier has verdicts it never runs:$UNEXPECTED"
      finding major "Verdicts exist for audits the $TIER tier does not run:$UNEXPECTED — this run's record describes a pipeline it did not follow."; }
  fi
fi

# ------------------------------------------------------------------ record --
jq -n --arg schema "package-check/1.0.0" --arg tier "$TIER" --arg status "$STATUS" \
  --argjson pairs "$PAIRS" --argjson findings "$FINDINGS" \
  --argjson consistent "$([ "$FAILED" -eq 0 ] && echo true || echo false)" \
  '{schema:$schema, tier:$tier, run_status:$status,
    step_pairs:$pairs, findings:$findings, internally_consistent:$consistent,
    note:"Everything here was decided by counting. What is left for a judge on this target is whether the run tells a coherent story — whether the reasons recorded for its retries make sense together — which counting cannot reach."}' \
  > "$RUN_DIR/package-check.json"

printf '\n'
[ "$FAILED" -eq 0 ] && printf 'PACKAGE CHECK PASS\n' \
  || printf 'PACKAGE CHECK FAIL — the run record contradicts itself\n'
exit "$FAILED"
