#!/usr/bin/env bash
# A stand-in judge for judge-qualify's tests: no model, a judgement shaped the way
# judge.sh writes one. STUB_JUDGE=catch names the case's first anchor and quotes
# its first piece of evidence; accept accepts; silent writes nothing.
set -uo pipefail
RD="$1"; shift; TARGET=""; BEAN=""
while [ $# -gt 0 ]; do case "$1" in --target) TARGET="$2"; shift 2 ;; --bean) BEAN="$2"; shift 2 ;; *) shift ;; esac; done
mode="${STUB_JUDGE:-catch}"
# discriminate: catch a defect case, accept its twin — the judge this suite is for.
if [ "$mode" = discriminate ]; then
  [ "$(jq -r .expect "${STUB_CASE_JSON:?}")" = reject ] && mode=catch || mode=accept
fi
[ "$mode" = silent ] && { echo "JUDGE  $TARGET: the stub said nothing" >&2; exit 1; }
case_json="${STUB_CASE_JSON:?}"
q="$(jq -r '.answer_key.evidence[0].quote' "$case_json")"
anchor="$(jq -r '.anchors[0] // "nothing"' "$case_json")"
ids="$("${PIPE_DIR:?}/yaml2json.sh" "$BEAN" | jq -c '[.acceptance_criteria[].id]')"
if [ "$mode" = catch ]; then verdict=revise; met=false
  findings="$(jq -nc --arg a "$anchor" --arg q "$q" '[{severity:"blocker", summary:("the change mishandles " + $a), evidence:$q, where:"diff.txt"}]')"
else verdict=accept; met=true; findings='[]'; fi
jq -n --arg t "$TARGET" --arg v "$verdict" --argjson ids "$ids" --argjson met "$met" --arg q "$q" --argjson f "$findings" '
  {schema_version:"judgement/1.0.0", stage:($t+"_audit"), target:$t, verdict:$v,
   criteria:[ $ids[] | {id:., met:$met, evidence:("checked against the artifact: " + $q), quote:$q} ],
   findings:$f, feedback_to_worker:"stub", suggested_tier:2, suggested_human_review:false, confidence:0.8,
   document_quality:{risk_called_out:true, blast_radius_called_out:true, code_blocks_teach:true, no_assumed_stack_knowledge:true, matches_diff:true},
   test_integrity:{deleted_tests:0,new_skips:0,weakened_asserts:false}, security_findings:[]}' \
  > "$RD/verdicts/$TARGET.attempt-1.judgement.json"
