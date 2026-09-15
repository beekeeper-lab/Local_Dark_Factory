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
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  small) EXPECTED_STEPS="preflight spec build gate audit-impl audit-package sync pr" ;;
  *)     EXPECTED_STEPS="preflight spec audit-spec build gate audit-impl doc audit-doc audit-package sync pr" ;;
esac

# ------------------------------------------------- 1. seven_stages_completed --
# "Seven stages" is the plan's phrasing from before `build` split out of
# `implement` and before the package audit existed. What it means is: every step
# this run's tier declares, ending in PASS. Counting to seven would be counting
# the wrong thing.
missing=""
for s in $EXPECTED_STEPS; do
  v="$(jq -rs --arg s "$s" '[.[] | select(.step == $s and .event == "end")] | last.verdict // "none"' "$STEPS" 2>/dev/null)"
  [ "$v" = PASS ] || missing="$missing $s($v)"
done
if [ -z "$missing" ]; then
  ok "seven_stages_completed" "all $(wc -w <<<"$EXPECTED_STEPS") steps of the $TIER tier ended PASS"
  pred seven_stages_completed pass
else
  bad "seven_stages_completed" blocker "not PASS:$missing"
  pred seven_stages_completed fail
fi

# ---------------------------------------- 2. three_verdicts_schema_valid --
# Every verdict file the run produced, against verdict.schema.json. "Three" is
# the full tier's count; what matters is that each one validates, and that there
# is at least one — a run with no verdicts trivially has none that are invalid.
VSCHEMA="$ROOT/schemas/verdict.schema.json"
nv=0; invalid=""
for f in "$RUN_DIR"/verdicts/*.attempt-*.json; do
  [ -e "$f" ] || continue
  case "$f" in *.judgement.json) continue ;; esac
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
if [ "$nv" -eq 0 ]; then
  bad "three_verdicts_schema_valid" blocker "no verdict files at all — nothing was audited"
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
ncommits=0
[ -n "$BRANCH" ] && ncommits="$(git -C "$REPO" rev-list --count "main..$BRANCH" 2>/dev/null)"
ncommits="${ncommits:-0}"
dirty="$(git -C "$REPO" status --porcelain 2>/dev/null | grep -v '^?? factory/runs/' | head -3)"
if [ "$ntasks" -gt 0 ] && [ "$ncommits" -ge "$ntasks" ] && [ -z "$dirty" ]; then
  ok "every_handoff_is_commit" "$ntasks verified task(s), $ncommits commit(s) on $BRANCH, tree clean"
  pred every_handoff_is_commit pass
elif [ "$ntasks" -eq 0 ]; then
  bad "every_handoff_is_commit" blocker "no task was verified, so nothing was handed off"
  pred every_handoff_is_commit fail
elif [ -n "$dirty" ]; then
  bad "every_handoff_is_commit" blocker "the tree is dirty; work exists that was never committed: $(tr '\n' ' ' <<<"$dirty")"
  pred every_handoff_is_commit fail
else
  bad "every_handoff_is_commit" blocker "$ntasks verified task(s) but only $ncommits commit(s) on $BRANCH"
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

inv="$(jq -r '.invariants // null' "$RUN_DIR/gate.json" 2>/dev/null)"
if [ "$DECLARES_INV" = 0 ]; then
  bad "independent_invariant_ran" major \
    "this bean declares no invariants_ref, so this run cannot exercise the predicate at all. Phase 1 cannot close on it: the phase's entry condition asks for a bean WITH invariants, and in this corpus that is bean-006 onward."
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
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:"phase1-audit/1.0.0", measured_at:$ts, run:$run,
      phase_1_exit:$p, findings:$f,
      green:(($f | length) == 0)}' > "$JSON_OUT"
  printf '%s\n' "$JSON_OUT"
fi
[ "$FAIL_N" -eq 0 ]
