#!/usr/bin/env bash
# phase3-audit.sh — the four phase_3_exit predicates, computed.
#
# Phase 3 is intake: a real transcript became beans through a conversation, and
# the claim is about those beans, not about the intake code. So three of the
# four predicates read the target repository — the beans as they stand on its
# main, and the run records the line wrote when it specified them — and only
# one runs a suite here.
#
#   transcript_to_beans          >= 5 beans on the target's main that came from a
#                                transcript, say `status: approved`, and carry the
#                                approval block only `intake approve` writes
#   all_ac_verifiable_or_manual  every criterion of those beans is a test or a
#                                command the controller can run, or `manual` with
#                                a note saying what the person checks
#   non_approved_refused         test-queue.sh is green and holds the refusals
#   size_budget_holds_at_specify every approved bean has a run whose last
#                                spec-check passed size_budget. A bean with no
#                                run yet is `pending`, which is not a pass.
#
# Reads main, not a branch: the plan says the owner merges the intake PR, and
# beans that only exist on an open PR's branch have not been approved by anyone
# who can merge.
set -uo pipefail
# shellcheck source=provenance.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/provenance.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TESTS="$ROOT/factory/pipeline/tests"

usage() {
  cat <<'EOF'
phase3-audit.sh — the four phase_3_exit predicates, computed from the target repo.

usage: phase3-audit.sh [--repo-dir <path>] [--ref <git ref>] [--json <path>]

  --repo-dir  the target repository's checkout (default ~/workspace/tic-tac-toe-py)
  --ref       where the beans are read from (default origin/main, after a fetch)
  --json      also write the result as JSON
EOF
}

REPO_DIR="$HOME/workspace/tic-tac-toe-py"; REF="origin/main"; JSON_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir) REPO_DIR="${2:?}"; shift 2 ;;
    --ref)      REF="${2:?}"; shift 2 ;;
    --json)     JSON_OUT="${2:?}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
[ -d "$REPO_DIR/.git" ] || { echo "not a git checkout: $REPO_DIR" >&2; exit 2; }

PASS_N=0; FAIL_N=0; FINDINGS='[]'; PREDICATES='{}'
ok()   { PASS_N=$((PASS_N+1)); printf '  ok    %-30s %s\n' "$1" "$2"; }
bad()  { FAIL_N=$((FAIL_N+1)); printf '  FAIL  %-30s [%s] %s\n' "$1" "$2" "$3"
         FINDINGS="$(jq -c --arg id "$1" --arg s "$2" --arg e "$3" \
           '. + [{predicate:$id, severity:$s, evidence:$e}]' <<<"$FINDINGS")"; }
pred() { PREDICATES="$(jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' <<<"$PREDICATES")"; }

case "$REF" in origin/*) git -C "$REPO_DIR" fetch -q origin 2>/dev/null || true ;; esac
git -C "$REPO_DIR" rev-parse -q --verify "$REF^{commit}" >/dev/null \
  || { echo "no such ref in $REPO_DIR: $REF" >&2; exit 2; }
SHA="$(git -C "$REPO_DIR" rev-parse --short "$REF")"

printf '\nphase-3 audit — intake, computed from %s at %s (%s)\n\n' "$(basename "$REPO_DIR")" "$REF" "$SHA"

# One pass over every bean.yaml at the ref, as JSON: what each predicate needs
# and nothing it would have to re-parse.
BEANS="$(git -C "$REPO_DIR" ls-tree -r --name-only "$REF" -- factory/beans \
  | grep '/bean\.yaml$' \
  | while read -r p; do
      git -C "$REPO_DIR" show "$REF:$p" | python3 -c '
import json, sys, yaml
try:
    b = yaml.safe_load(sys.stdin) or {}
except yaml.YAMLError as e:
    print(json.dumps({"path": sys.argv[1], "error": str(e).splitlines()[0]})); sys.exit()
acs = []
for ac in b.get("acceptance_criteria") or []:
    v = (ac or {}).get("verify") or {}
    acs.append({"id": ac.get("id"), "kind": v.get("kind"),
                "runnable": bool(v.get("test_id") and "::" in str(v.get("test_id"))) if v.get("kind") == "test"
                            else bool(v.get("run")) if v.get("kind") == "command"
                            else bool(str(v.get("note") or "").strip()) if v.get("kind") == "manual"
                            else False})
print(json.dumps({"path": sys.argv[1], "id": b.get("id"), "status": b.get("status"),
                  "source": (b.get("source") or {}).get("kind"),
                  "approved": bool((b.get("approval") or {}).get("approved_by")),
                  "acs": acs}))
' "$p"
    done | jq -s '.')"

APPROVED="$(jq -c '[.[] | select(.status == "approved" and .approved and .source == "transcript")]' <<<"$BEANS")"
N_ALL="$(jq 'length' <<<"$BEANS")"
N_OK="$(jq 'length' <<<"$APPROVED")"
UNPARSED="$(jq -r '[.[] | select(.error) | .path] | join(", ")' <<<"$BEANS")"

# transcript_to_beans
if [ -n "$UNPARSED" ]; then
  bad transcript_to_beans blocker "bean files that do not parse: $UNPARSED"
  pred transcript_to_beans fail
elif [ "$N_OK" -ge 5 ]; then
  ok transcript_to_beans "$N_OK of $N_ALL beans approved from a transcript: $(jq -r 'map(.id) | join(" ")' <<<"$APPROVED")"
  pred transcript_to_beans pass
else
  bad transcript_to_beans blocker "$N_OK approved from a transcript on $REF (needs 5); $N_ALL bean file(s) there"
  pred transcript_to_beans fail
fi

# all_ac_verifiable_or_manual
if [ "$N_OK" -eq 0 ]; then
  bad all_ac_verifiable_or_manual blocker "no approved beans to check"
  pred all_ac_verifiable_or_manual fail
else
  BAD_AC="$(jq -r '[.[] | .id as $b | .acs[] | select(.runnable | not) | "\($b):\(.id) (\(.kind // "no verify"))"] | join(", ")' <<<"$APPROVED")"
  N_AC="$(jq '[.[].acs[]] | length' <<<"$APPROVED")"
  N_MAN="$(jq '[.[].acs[] | select(.kind == "manual")] | length' <<<"$APPROVED")"
  if [ -z "$BAD_AC" ]; then
    ok all_ac_verifiable_or_manual "$N_AC criteria: $((N_AC - N_MAN)) machine-checked, $N_MAN manual with a note"
    pred all_ac_verifiable_or_manual pass
  else
    bad all_ac_verifiable_or_manual blocker "not runnable and not a noted manual check: $BAD_AC"
    pred all_ac_verifiable_or_manual fail
  fi
fi

# non_approved_refused — the one predicate that lives in this repository.
QOUT="$(timeout 900 bash "$TESTS/test-queue.sh" 2>&1)"
QTALLY="$(grep -oE '[0-9]+ passed, [0-9]+ failed' <<<"$QOUT" | tail -1)"
QMISSING=""
for a in "by the draft, named" "an unapproved bean is refused (exit 1)"; do
  grep -qF "  ok    $a" <<<"$QOUT" || QMISSING="$QMISSING \"$a\""
done
if [ -z "$QTALLY" ] || [ "$(awk '{print $3}' <<<"$QTALLY")" != 0 ]; then
  bad non_approved_refused blocker "test-queue.sh: ${QTALLY:-no tally, it did not finish}"
  pred non_approved_refused fail
elif [ -n "$QMISSING" ]; then
  bad non_approved_refused blocker "test-queue.sh passes but lacks:$QMISSING"
  pred non_approved_refused fail
else
  ok non_approved_refused "test-queue.sh $QTALLY, refusal assertions present"
  pred non_approved_refused pass
fi

# size_budget_holds_at_specify — the newest run per bean that reached spec-check.
# The run directory is the line's own record, so this is what specify actually
# did, not what a bean promises.
HELD=""; BROKE=""; PENDING=""
for id in $(jq -r '.[].id' <<<"$APPROVED"); do
  last=""
  for d in $(ls -td "$REPO_DIR/factory/runs/$id"-*/ 2>/dev/null); do
    [ -f "$d/spec-check.txt" ] && { last="$d"; break; }
  done
  if [ -z "$last" ]; then
    PENDING="$PENDING $id"
  elif line="$(grep -E '^  ok +size_budget ' "$last/spec-check.txt")"; then
    HELD="$HELD $id($(awk '{print $3}' <<<"$line"))"
  else
    BROKE="$BROKE $id:$(basename "$last")"
  fi
done
if [ -n "$BROKE" ]; then
  bad size_budget_holds_at_specify blocker "spec-check did not pass size_budget:$BROKE"
  pred size_budget_holds_at_specify fail
elif [ -n "$PENDING" ] || [ "$N_OK" -eq 0 ]; then
  bad size_budget_holds_at_specify blocker "not specified yet:${PENDING:- no approved beans}${HELD:+; held:$HELD}"
  pred size_budget_holds_at_specify pending
else
  ok size_budget_holds_at_specify "held at specify:$HELD"
  pred size_budget_holds_at_specify pass
fi

printf '\nphase_3_exit:\n'
jq -r --argjson p "$PREDICATES" -n '$p | to_entries[] | "  \(.key): \(.value)"'
printf '\n%s ok, %s finding(s)\n' "$PASS_N" "$FAIL_N"

if [ -n "$JSON_OUT" ]; then
  jq -n --argjson p "$PREDICATES" --argjson f "$FINDINGS" --argjson beans "$BEANS" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg repo "$(basename "$REPO_DIR")" \
    --arg ref "$REF" --arg sha "$SHA" --argjson prov "$(provenance_block)" \
    '{schema:"phase3-audit/1.0.0", audited_at:$ts, provenance:$prov,
      target:{repo:$repo, ref:$ref, sha:$sha}, phase_3_exit:$p, findings:$f, beans:$beans}' \
    > "$JSON_OUT"
  printf 'written: %s\n' "$JSON_OUT"
fi
[ "$FAIL_N" -eq 0 ]
