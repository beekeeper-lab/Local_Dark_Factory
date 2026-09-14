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

STAGE_FOR() { case "$1" in spec) echo spec_audit ;; impl|package) echo impl_audit ;; doc) echo pre_pr_audit ;; esac; }
STAGE="$(STAGE_FOR "$TARGET")"

if [ -z "$JUDGEMENT" ]; then
  # Not retried blind: a missing judgement is the judge failing to do its job,
  # and there is nothing in it for the authoring step to act on.
  printf 'AUDIT %s: the judge wrote no judgement file.\n' "$TARGET" >&2
  printf '      expected: %s/%s.attempt-<n>.judgement.json\n' "$VERDICTS" "$TARGET" >&2
  ls -1 "$VERDICTS" 2>/dev/null | sed 's/^/      present: /' >&2
  exit 2
fi
if ! jq -e . "$JUDGEMENT" >/dev/null 2>&1; then
  printf 'AUDIT %s: %s is not valid JSON.\n' "$TARGET" "$JUDGEMENT" >&2
  exit 2
fi

J="$(cat "$JUDGEMENT")"
VERDICT="$(jq -r '.verdict // empty' <<<"$J")"
case "$VERDICT" in
  accept|revise|block) ;;
  *) printf 'AUDIT %s: verdict is %s, expected accept|revise|block\n' "$TARGET" "${VERDICT:-absent}" >&2; exit 2 ;;
esac

# A blocker with an accept is self-contradicting. The schema cannot say this, so
# the controller does — and it corrects rather than rejects, because the finding
# is the judge's real opinion and the summary word is the slip.
BLOCKERS="$(jq '[.findings[]? | select(.severity == "blocker")] | length' <<<"$J")"
if [ "$BLOCKERS" -gt 0 ] && [ "$VERDICT" = "accept" ]; then
  printf 'AUDIT %s: %s blocker finding(s) with an "accept" verdict — recorded as "revise"\n' "$TARGET" "$BLOCKERS" >&2
  VERDICT="revise"
fi

# ------------------------------------------------------ the observable facts --
BEAN_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$BEAN_FILE")"
BEAN_ID="$(jq -r '.id' <<<"$BEAN_JSON")"
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

OUT="$VERDICTS/$TARGET.attempt-$N.json"
jq -n \
  --arg sv "verdict/2.0.0" --arg stage "$STAGE" --arg bean "$BEAN_ID" \
  --arg base "$BASE_SHA" --arg cand "$CAND_SHA" --arg diff "$DIFF_SHA" \
  --arg gate_run "$GATE_RUN_ID" --arg gate_digest "$GATE_DIGEST" --arg inv "$INV_DIGEST" \
  --arg policy "$POLICY_VERSION" --argjson tier "${TIER:-1}" \
  --arg model "$MODEL_DIGEST" --arg prompt "$PROMPT_VERSION" \
  --arg verdict "$VERDICT" --argjson j "$J" --argjson artifacts "$ARTIFACTS" \
  '{schema_version: $sv, stage: $stage, bean_id: $bean,
    base_sha: $base, candidate_sha: $cand, diff_sha256: $diff,
    gate_run_id: $gate_run, gate_manifest_digest: $gate_digest,
    invariants_digest: $inv, policy_version: $policy,
    effective_risk_tier: $tier, model_digest: $model, prompt_version: $prompt,
    criteria: ($j.criteria // []), verdict: $verdict, artifacts: $artifacts}
   + (if $j.feedback_to_worker then {feedback_to_worker: $j.feedback_to_worker} else {} end)
   + (if $j.document_quality then {document_quality: $j.document_quality} else {} end)
   + (if $j.test_integrity then {test_integrity: $j.test_integrity} else {} end)
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
  step_verdict="$([ "$VERDICT" = "accept" ] && echo PASS || echo FAIL)"
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
exit 1
