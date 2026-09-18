#!/usr/bin/env bash
# phase1-audit.sh — compute the seven `phase_1_exit` predicates from a real run.
#
# Phase 0 shipped `phase0-audit.sh` because its exit conditions existed only as
# prose in the ledger, and a predicate asserted in Markdown is a figure that
# survives into later decisions without having been checked. Phase 1 had the same
# gap: seven predicates, none computable, all of which would have been ticked by
# someone reading a log and feeling satisfied.
#
# Every one here is read out of a run directory and the repository, not out of
# the plan. It takes the run to audit as an argument, so it can be pointed at any
# run — including one that failed, which is the more interesting case, because a
# predicate that only passes on the happy path is not a predicate.
#
# Read-only. Loads no model.
set -uo pipefail
# An audit is a measurement of this repository at a moment, so it carries the
# same provenance block as every figure under bench/results. "Which machine,
# which ollama, which pipeline version" is the question asked of any other
# number here, and there is no reason an audit should be exempt from it.
# shellcheck source=provenance.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/provenance.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# For `verdicts_role`: what each file in a run's verdicts/ directory is. Three
# readers of that directory learned that list separately and each got it wrong
# first, so it lives in one place now.
# lib.sh reads PIPELINE_DIR at load time; this script is not in the pipeline, so
# it says where the pipeline is rather than being sourced into a shell that
# happens to have it set.
PIPELINE_DIR="${PIPELINE_DIR:-$ROOT/factory/pipeline}"
# shellcheck source=../factory/pipeline/lib.sh
source "$ROOT/factory/pipeline/lib.sh"
PIPE="$ROOT/factory/pipeline"

usage() {
  cat <<'EOF'
phase1-audit.sh — the seven phase_1_exit predicates, computed.

usage: phase1-audit.sh <run-dir> [--repo <dir>] [--json <path>]

<run-dir> is a run from the target repository (factory/runs/<bean>-<stamp>).
--repo defaults to the run directory's own repository.
EOF
}

RUN_DIR=""; REPO=""; JSON_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --json) JSON_OUT="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$RUN_DIR" ] || { usage >&2; exit 2; }; RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] || { usage >&2; exit 2; }
[ -d "$RUN_DIR" ] || { echo "no such run directory: $RUN_DIR" >&2; exit 2; }
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
[ -n "$REPO" ] || REPO="$(cd "$RUN_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -n "$REPO" ] || { echo "cannot find the repository for $RUN_DIR; pass --repo" >&2; exit 2; }

PASS_N=0; FAIL_N=0; FINDINGS='[]'; PREDICATES='{}'
ok()   { PASS_N=$((PASS_N+1)); printf '  ok    %-34s %s\n' "$1" "$2"; }
bad()  { FAIL_N=$((FAIL_N+1)); printf '  FAIL  %-34s [%s] %s\n' "$1" "$2" "$3"
         FINDINGS="$(jq -c --arg id "$1" --arg s "$2" --arg e "$3" \
           '. + [{predicate:$id, severity:$s, evidence:$e}]' <<<"$FINDINGS")"; }
pred() { PREDICATES="$(jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' <<<"$PREDICATES")"; }

printf '\nphase-1 audit — %s\n\n' "$(basename "$RUN_DIR")"

STEPS="$RUN_DIR/steps.jsonl"
RUNJSON="$RUN_DIR/run.json"
[ -f "$RUNJSON" ] || { echo "no run.json in $RUN_DIR" >&2; exit 2; }
TIER="$(jq -r '.tier // "full"' "$RUNJSON")"
case "$TIER" in
  small) EXPECTED_STEPS="preflight spec build gate audit-impl audit-package sync pr ci" ;;
  *)     EXPECTED_STEPS="preflight spec audit-spec build gate audit-impl doc audit-doc audit-package sync pr ci" ;;
esac

# ------------------------------------------------- 1. seven_stages_completed --
# "Seven stages" is the plan's phrasing from before `build` split out of
# `implement` and before the package audit existed. What it means is: every step
# this run's tier declares, ending in PASS. Counting to seven would be counting
# the wrong thing.
# A step that did not exist when the run was made cannot be missing from it.
#
# `EXPECTED_STEPS` is today's tier. A run recorded under an older pipeline version
# is not a failing run; it is a run of a different line, and saying "not PASS: ci"
# about a run made before `ci` existed is a true sentence about the wrong thing —
# the same shape of error as calling a previous attempt's file this attempt's
# output. A step that was NEVER recorded, in a run whose pipeline_version is not
# this one, is reported as what it is.
RUN_PV="$(jq -r '.conditions.pipeline_version // empty' "$RUNJSON" 2>/dev/null || true)"
NOW_PV="$(cat "$ROOT/factory/pipeline/VERSION" 2>/dev/null || echo unknown)"
missing=""; predates=""
for s in $EXPECTED_STEPS; do
  v="$(jq -rs --arg s "$s" '[.[] | select(.step == $s and .event == "end")] | last.verdict // "none"' "$STEPS" 2>/dev/null)"
  [ "$v" = PASS ] && continue
  seen="$(jq -rs --arg s "$s" '[.[] | select(.step == $s)] | length' "$STEPS" 2>/dev/null || echo 0)"
  # A record with no pipeline_version at all predates the version stamp itself,
  # which is the strongest evidence available that it predates anything else.
  if [ "$seen" = 0 ] && [ "${RUN_PV:-unstamped}" != "$NOW_PV" ]; then
    predates="$predates $s"
  else
    missing="$missing $s($v)"
  fi
done
if [ -z "$missing" ] && [ -z "$predates" ]; then
  ok "seven_stages_completed" "all $(wc -w <<<"$EXPECTED_STEPS") steps of the $TIER tier ended PASS"
  pred seven_stages_completed pass
elif [ -z "$missing" ]; then
  ok "seven_stages_completed" "every step this run's pipeline had ended PASS; the $TIER tier has since gained:$predates (run: ${RUN_PV:-unstamped}, now: $NOW_PV)"
  pred seven_stages_completed pass_for_its_version
else
  bad "seven_stages_completed" blocker "not PASS:$missing"
  pred seven_stages_completed fail
fi

# ----------------------------------------------- 1b. the record conforms --
# run-record.schema.json is one of the eight declared contracts, and until
# 2026-09-15 nothing validated the thing that produces it, so records drifted:
# `bean` where the schema says `bean_id`, and no schema_version, corpus or
# conditions at all. A run whose own record does not conform cannot say what
# input it derives from or what it ran on, which is most of what a later reader
# wants. Reported here rather than assumed, because reading around a missing
# block is how it stayed missing.
RSCHEMA="$ROOT/schemas/run-record.schema.json"
if [ -f "$RSCHEMA" ] && [ -x "$ROOT/.venv/bin/python" ]; then
  if rout="$("$ROOT/.venv/bin/python" "$ROOT/bench/validate.py" run-record "$RUNJSON" 2>&1)"; then
    ok "run_record_conforms" "run.json validates against run-record.schema.json"
    pred run_record_conforms pass
  else
    # The validator's own words, trimmed of its leading whitespace. A grep that
    # reshapes them risks saying something the validator did not.
    #
    # It used to take `<root>:` lines only, and every error nested under a key —
    # `conditions: 'judge' is a required property` — was dropped. A run.json
    # missing half of `conditions` produced the finding "run.json does not
    # validate — " with nothing after the dash. Found by the first test ever
    # written against this script, in its first run.
    # A run older than the schema cannot be made to conform, and a reader sent to
    # fix one wastes the trip. Say which it is: `schema_version` absent means the
    # record predates the field, and what the finding is really about is whether
    # the CURRENT line still writes records like this one.
    vintage=""
    if ! jq -e 'has("schema_version")' "$RUNJSON" >/dev/null 2>&1; then
      vintage=" · this record has no schema_version at all, so it predates the schema; the question a reader should ask is whether the line still writes records like it"
    fi
    bad "run_record_conforms" major \
      "run.json does not validate — $(printf '%s\n' "$rout" | sed -n 's/^ \{6,\}//p' | tr '\n' '@' | sed 's/@$//; s/@/; /g')$vintage"
    pred run_record_conforms fail
  fi
fi

# ---------------------------------------- 2. three_verdicts_schema_valid --
# Every verdict file the run produced, against verdict.schema.json. "Three" is
# the full tier's count; what matters is that each one validates, and that there
# is at least one — a run with no verdicts trivially has none that are invalid.
VSCHEMA="$ROOT/schemas/verdict.schema.json"
nv=0; invalid=""
for f in "$RUN_DIR"/verdicts/*.attempt-*.json; do
  [ -e "$f" ] || continue
  # One list, in lib.sh: `verdicts_role`, and the three halts that taught it.
  [ "$(verdicts_role "$(basename "$f")")" = verdict ] || continue
  nv=$((nv+1))
  if [ -f "$VSCHEMA" ] && [ -x "$ROOT/.venv/bin/python" ]; then
    "$ROOT/.venv/bin/python" - "$VSCHEMA" "$f" <<'PY' >/dev/null 2>&1 || invalid="$invalid $(basename "$f")"
import json, sys
import jsonschema
from referencing import Registry, Resource
from pathlib import Path
schema_path, doc = Path(sys.argv[1]), Path(sys.argv[2])
reg = Registry()
for p in schema_path.parent.glob("*.json"):
    reg = reg.with_resource(f"https://forge.local/schemas/{p.name}",
                            Resource.from_contents(json.loads(p.read_text())))
jsonschema.Draft202012Validator(json.loads(schema_path.read_text()),
                                registry=reg).validate(json.loads(doc.read_text()))
PY
  fi
done
# An audit that ran advisory reaches no verdict, on purpose, and orchestrate
# records `failed-attempts/audit-<target>.advisory.N` saying so. "No verdict
# files at all" and "nothing was audited" are then two different statements, and
# only the first is true: the judge ran, and what it produced was not a judgement.
#
# This is the third place in the line where the advisory decision met a rule that
# assumed a verdict — package-check and pr.sh were the other two. The predicate
# is not satisfied either way; what changes is that it says which of two very
# different things happened, and that `not_exercised` is not reported as `fail`.
nadv=0
for f in "$RUN_DIR/failed-attempts"/audit-*.advisory.* \
         "$RUN_DIR/failed-attempts/resolved"/audit-*.advisory.*; do
  [ -e "$f" ] && nadv=$((nadv + 1))
done
# Which rule refused, when one did. `audit-check.sh` writes a refusal record per
# refusal naming the rule, so "why did this run reach no verdict" is now read off
# the run rather than reconstructed from terminal output — which is how the same
# question got answered from memory twice before.
why=""
if compgen -G "$RUN_DIR/verdicts/*.refused.json" >/dev/null 2>&1; then
  why="$(jq -rs '[.[] | ((.by // "audit-check") + ":" + .rule)] | group_by(.) | map("\(.[0]) ×\(length)") | join(", ")' \
        "$RUN_DIR"/verdicts/*.refused.json 2>/dev/null)"
  [ -n "$why" ] && why=" Refused by: $why."
fi
if [ "$nv" -eq 0 ] && [ "$nadv" -gt 0 ]; then
  bad "three_verdicts_schema_valid" major \
    "no verdicts: $nadv audit(s) ran advisory and reached none. The judge ran; it did not produce a judgement the controller could stamp.$why Nothing here is schema-invalid — there is nothing to validate, which is a different problem and one this predicate cannot close."
  pred three_verdicts_schema_valid not_exercised
elif [ "$nv" -eq 0 ]; then
  bad "three_verdicts_schema_valid" blocker "no verdict files at all, and nothing recorded to say why — nothing was audited"
  pred three_verdicts_schema_valid fail
elif [ -n "$invalid" ]; then
  bad "three_verdicts_schema_valid" blocker "invalid against verdict.schema.json:$invalid"
  pred three_verdicts_schema_valid fail
else
  ok "three_verdicts_schema_valid" "$nv verdict(s), all schema-valid"
  pred three_verdicts_schema_valid pass
fi

# ------------------------------------------------- 3. every_handoff_is_commit --
# §09: work moves between stages as commits, not as files left in a directory.
# The check is that the branch has a commit for each verified task, and that the
# tree is clean at the end — an uncommitted change is a handoff that did not
# happen.
BRANCH="$(jq -r '.branch // empty' "$RUNJSON")"
# `jq ... || echo 0` is wrong here and produced "0\n0": jq prints its answer and
# *then* exits non-zero on a missing file, so the fallback appends a second line
# and `[ "$n" -gt 0 ]` fails with "integer expected". Check the file first.
ntasks=0
[ -f "$RUN_DIR/tasks.jsonl" ] && ntasks="$(jq -rs '[.[] | select(.event == "task" and .result == "verified")] | length' "$RUN_DIR/tasks.jsonl" 2>/dev/null)"
ntasks="${ntasks:-0}"
# How the commits are counted, and why it is not `rev-list main..<branch>`.
#
# That was the original instrument, and it answers "how many commits are not yet
# on main" — which is zero once the pull request merges. So this predicate passed
# on bean-001 while its PR was open and failed an hour later BECAUSE the bean had
# succeeded. The predicate is about whether each verified task handed off as a
# commit; that is a fact about the repository, not a distance from a branch that
# moves underneath it.
#
# So: the build loop records the sha it made for each task (tasks.jsonl, event
# "commit"), and this counts the ones git can still resolve. Runs from before
# that existed have no such events, and fall back to the branch count — with the
# instrument named in the message, because two runs scored by two instruments
# should not look identical in a report.
ncommits=0; how=""
recorded=0
[ -f "$RUN_DIR/tasks.jsonl" ] && recorded="$(jq -rs '[.[] | select(.event == "commit")] | length' "$RUN_DIR/tasks.jsonl" 2>/dev/null)"
recorded="${recorded:-0}"
if [ "$recorded" -gt 0 ]; then
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    git -C "$REPO" cat-file -e "$sha^{commit}" 2>/dev/null && ncommits=$((ncommits+1))
  done < <(jq -rs '[.[] | select(.event == "commit")] | unique_by(.task) | .[].sha' "$RUN_DIR/tasks.jsonl" 2>/dev/null)
  how="recorded by the build loop"
  [ "$ncommits" -eq "$recorded" ] || how="$how ($((recorded - ncommits)) of $recorded no longer resolve)"
else
  # No recorded shas: an older run. Its commits are still findable — `commit_task`
  # has always written `bean: <id>` into the body and `build(<task>):` into the
  # subject — so count the distinct tasks named by commits reachable from the
  # branch. Reachable, not `main..branch`: after a merge those are the same
  # commits and the range is empty.
  BEAN_ID_RR="$(jq -r '.bean_id // .bean // empty' "$RUNJSON" 2>/dev/null)"
  if [ -n "$BRANCH" ] && [ -n "$BEAN_ID_RR" ]; then
    ncommits="$(git -C "$REPO" log "$BRANCH" --format='%s' --grep="^bean: $BEAN_ID_RR\$" 2>/dev/null \
      | sed -n 's/^build(\([^)]*\)).*/\1/p' | sort -u | wc -l)"
  fi
  ncommits="${ncommits:-0}"
  how="found by message on $BRANCH — this run predates the recorded shas"
fi
dirty="$(git -C "$REPO" status --porcelain 2>/dev/null | grep -v '^?? factory/runs/' | head -3)"
if [ "$ntasks" -gt 0 ] && [ "$ncommits" -ge "$ntasks" ] && [ -z "$dirty" ]; then
  ok "every_handoff_is_commit" "$ntasks verified task(s), $ncommits commit(s) — $how — tree clean"
  pred every_handoff_is_commit pass
elif [ "$ntasks" -eq 0 ]; then
  bad "every_handoff_is_commit" blocker "no task was verified, so nothing was handed off"
  pred every_handoff_is_commit fail
elif [ -n "$dirty" ]; then
  bad "every_handoff_is_commit" blocker "the tree is dirty; work exists that was never committed: $(tr '\n' ' ' <<<"$dirty")"
  pred every_handoff_is_commit fail
else
  bad "every_handoff_is_commit" blocker "$ntasks verified task(s) but only $ncommits commit(s) — $how"
  pred every_handoff_is_commit fail
fi

# --------------------------------------------------- 4. docs_rendered_and_read --
# Rendered is computable. READ is not: it is a person confirming the documents
# teach, and no script can assert that. So this reports the rendering and says
# plainly that the second half is outstanding until a human records it — rather
# than quietly passing on the half it can see, which is how a predicate becomes
# a formality.
rendered=""; unrendered=""
for d in spec impl-detail; do
  if [ -s "$RUN_DIR/$d.html" ]; then rendered="$rendered $d.html"; else unrendered="$unrendered $d.html"; fi
done
READ_MARKER="$RUN_DIR/documents-read-by.txt"
if [ -n "$unrendered" ]; then
  bad "docs_rendered_and_read" blocker "not rendered:$unrendered"
  pred docs_rendered_and_read fail
elif [ -s "$READ_MARKER" ] && grep -q 'NOT a person' "$READ_MARKER" 2>/dev/null; then
  # An agent read is a different and weaker fact, and the predicate asks about a
  # person. Counting it as a pass would make `factory read --as-agent` the
  # formality that the absence of a `--yes` exists to prevent — so it is reported,
  # and the predicate stays open.
  bad "docs_rendered_and_read" major \
    "rendered:$rendered · read by an AGENT, not a person: $(sed -n 's/^read_by_agent: //p' "$READ_MARKER" | head -1). That is a weaker record and does not settle whether these documents teach."
  pred docs_rendered_and_read pending
elif [ -s "$READ_MARKER" ]; then
  ok "docs_rendered_and_read" "rendered:$rendered · read by $(head -1 "$READ_MARKER")"
  pred docs_rendered_and_read pass
else
  bad "docs_rendered_and_read" major \
    "rendered:$rendered — but no human has recorded reading them. Write who and when to $(basename "$READ_MARKER"); a script cannot assert that a document teaches."
  pred docs_rendered_and_read pending_human
fi

# ------------------------------- 5. allowed_path_enforced_task_and_bean --
# Enforced at both levels means: the loop checked every attempt against the
# task's paths, and the gate checked the whole diff against the bean's. Evidence
# is the containment record of each attempt plus gate.json's own.
nc=0; uncontained=""
for f in "$RUN_DIR"/build/*/attempt-*/containment.json; do
  [ -e "$f" ] || continue
  nc=$((nc+1))
  [ "$(jq -r '.contained | tostring' "$f")" = true ] || uncontained="$uncontained $(basename "$(dirname "$f")")"
done
gate_contained="$(jq -r '.containment.contained | tostring' "$RUN_DIR/gate.json" 2>/dev/null || echo missing)"
if [ "$nc" -gt 0 ] && [ "$gate_contained" = true ]; then
  ok "allowed_path_enforced_task_and_bean" "$nc attempt(s) checked against task paths; whole diff checked against the bean's"
  pred allowed_path_enforced_task_and_bean pass
elif [ "$nc" -eq 0 ]; then
  bad "allowed_path_enforced_task_and_bean" blocker "no attempt recorded a containment check"
  pred allowed_path_enforced_task_and_bean fail
else
  bad "allowed_path_enforced_task_and_bean" blocker "gate containment is '$gate_contained'; rejected attempts:$uncontained"
  pred allowed_path_enforced_task_and_bean fail
fi

# ------------------------------------------------- 6. task_retry_with_evidence --
# A retry that carried the real failure output into the next attempt, rather than
# a summary of it. Evidence: an attempt after the first whose predecessor
# recorded a failure, and a feedback.md that is not empty.
retries=0
[ -f "$RUN_DIR/tasks.jsonl" ] && retries="$(jq -rs '[.[] | select(.event == "attempt" and .attempt > 1)] | length' "$RUN_DIR/tasks.jsonl" 2>/dev/null)"
retries="${retries:-0}"
withfb=0
for f in "$RUN_DIR"/build/*/attempt-*/feedback.md; do
  [ -s "$f" ] && withfb=$((withfb+1))
done
if [ "$retries" -gt 0 ] && [ "$withfb" -gt 0 ]; then
  ok "task_retry_with_evidence" "$retries retry attempt(s), $withfb carrying the real failure output"
  pred task_retry_with_evidence pass
elif [ "$retries" -eq 0 ]; then
  bad "task_retry_with_evidence" minor \
    "no task needed a retry in this run — the path is tested (tests/test-build-loop.sh) but this run does not evidence it"
  pred task_retry_with_evidence not_exercised
else
  bad "task_retry_with_evidence" major "$retries retry attempt(s) but none carried a feedback file"
  pred task_retry_with_evidence fail
fi

# ------------------------------------------------- 7. independent_invariant_ran --
# The invariants are the corpus's only check authored independently of the
# implementation. "Ran" means the gate executed them, not that the file exists.
# Whether the bean declares any is the first question, and it changes what the
# answer means. bean-001 is a scaffold: it has no solver, so there is no seating
# answer for an invariant to be about, and it correctly declares none. A run of
# it can never exercise this predicate — which is a fact about which bean can
# close the phase, not a defect in the run.
BEAN_YAML=""
for cand in "$REPO"/factory/beans/*/bean.yaml; do
  [ -f "$cand" ] || continue
  [ "$(grep -c "^id: *$(jq -r '.bean' "$RUNJSON")\b" "$cand" 2>/dev/null)" -gt 0 ] && { BEAN_YAML="$cand"; break; }
done
DECLARES_INV=0
[ -n "$BEAN_YAML" ] && grep -q '^invariants_ref:' "$BEAN_YAML" && DECLARES_INV=1

# When the bean declares none, the question becomes whether the MECHANISM is
# proven, and that is decidable from this repository rather than from the run.
#
# The owner made this call on 2026-09-15, with the alternative on the table
# (run beans 002 through 006 so a bean with invariants reaches a gate). The
# reasoning, recorded here rather than in a checkbox: what the predicate is
# protecting against is a line that declares an independent guarantee and never
# runs it. Two tests answer that, and both had to exist before this reading was
# defensible —
#
#   tests/test-invariants.sh   the invariants catch their own violations, against
#                              a reference implementation written to satisfy them
#   tests/test-gate.sh         the CONTROLLER runs a real invariants file as part
#                              of a gate, both ways: `ok invariants` with the
#                              status and ref in gate.json and the output kept,
#                              and `FAIL invariants` with the assertion readable
#                              in invariants.log when the answer is wrong
#
# The second of those was written the same evening, because until then the only
# invariant assertion anywhere was the missing-file refusal — a mechanism tested
# by making it fail, which is a mechanism nobody had seen work.
#
# This is checked, not asserted: if either test stops covering it, the predicate
# stops reading `mechanism_proven` and goes back to being unexercised.
mechanism_proven() {
  local gt="$ROOT/factory/pipeline/tests/test-gate.sh"
  local it="$ROOT/factory/pipeline/tests/test-invariants.sh"
  [ -f "$gt" ] && [ -f "$it" ] || return 1
  grep -q "the controller runs the bean's invariants" "$gt" || return 1
  grep -q 'a violated invariant fails the gate' "$gt" || return 1
  return 0
}

inv="$(jq -r '.invariants // null' "$RUN_DIR/gate.json" 2>/dev/null)"
if [ "$DECLARES_INV" = 0 ] && mechanism_proven; then
  ok "independent_invariant_ran" "not exercised by this bean — bean-001 is a scaffold with no seating answer for an invariant to be about — and the mechanism is proven: tests/test-gate.sh runs a real invariants file through the gate both ways, tests/test-invariants.sh shows they catch their own violations"
  pred independent_invariant_ran mechanism_proven
elif [ "$DECLARES_INV" = 0 ]; then
  bad "independent_invariant_ran" major \
    "this bean declares no invariants_ref, and the mechanism is not proven either: tests/test-gate.sh no longer asserts that the controller runs a real invariants file through a gate in both directions. One or the other has to hold."
  pred independent_invariant_ran not_applicable
elif [ "$inv" = null ] || [ -z "$inv" ]; then
  bad "independent_invariant_ran" blocker "the bean declares invariants_ref but gate.json records no invariant run — the guarantee was declared and not checked"
  pred independent_invariant_ran fail
elif [ "$(jq -r '.status' <<<"$inv")" = pass ]; then
  ok "independent_invariant_ran" "$(jq -r '.ref' <<<"$inv") ran in the gate and passed"
  pred independent_invariant_ran pass
else
  bad "independent_invariant_ran" blocker "$(jq -r '.ref' <<<"$inv") ran and did not pass"
  pred independent_invariant_ran fail
fi

# ------------------------------------------------------------------ verdict --
printf '\n'
printf 'phase_1_exit:\n'
jq -r --argjson p "$PREDICATES" -n '$p | to_entries[] | "  \(.key): \(.value)"'

printf '\n%s ok, %s finding(s)\n' "$PASS_N" "$FAIL_N"
if [ -n "$JSON_OUT" ]; then
  mkdir -p "$(dirname "$JSON_OUT")"
  jq -n --argjson p "$PREDICATES" --argjson f "$FINDINGS" --arg run "$(basename "$RUN_DIR")" \
    --argjson prov "$(provenance_block)" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:"phase1-audit/1.0.0", measured_at:$ts, run:$run,
      phase_1_exit:$p, findings:$f,
      provenance:$prov,
      green:(($f | length) == 0)}' > "$JSON_OUT"
  printf '%s\n' "$JSON_OUT"
fi
[ "$FAIL_N" -eq 0 ]
