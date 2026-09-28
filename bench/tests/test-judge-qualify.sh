#!/usr/bin/env bash
# test-judge-qualify.sh — the qualification harness, with no model and no GPU.
#
# The judge and audit-check are stubbed; everything else is the harness: cases
# read from disk, a worktree at each case's candidate, the answer key, and the
# scoring. The assertions that matter most are the two degenerate judges. One
# that rejects everything and one that accepts everything must BOTH score zero
# pairs told apart — the per-criterion judge of 2026-09-16 rejected all six of
# its cases, including the clean control, and a suite that scored that as a
# catch rate would have called it perfect.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$(tail -c 400 <<<"$3")"; FAIL=$((FAIL+1)); fi; }
eq() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
       else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }

# A target repository with one commit, and two cases on it: a defect and its twin.
R="$WORK/repo"; git init -q -b main "$R"; git -C "$R" config user.email t@e.com; git -C "$R" config user.name T
printf 'x = 1\n' > "$R/a.py"; git -C "$R" add -A; git -C "$R" commit -qm init
SHA="$(git -C "$R" rev-parse HEAD)"
C="$WORK/cases"
mkcase() { # mkcase <id> <expect> [twin_of]
  mkdir -p "$C/$1/inputs/bean"
  printf 'schema_version: bean/2.0.0\nid: bean-001\nacceptance_criteria:\n  - id: ac1\n    text: it works\n' > "$C/$1/inputs/bean/bean.yaml"
  printf 'diff --git a/a.py b/a.py\n+x = 1  # %s\n' "$1" > "$C/$1/inputs/diff.txt"
  printf '{"run_id":"qualify-%s","bean":"bean-001"}\n' "$1" > "$C/$1/inputs/run.json"
  jq -n --arg id "$1" --arg e "$2" --arg sha "$SHA" --arg tw "${3:-}" '
    {schema:"qualify-case/1.0.0", id:$id, target:"impl", expect:$e,
     source:{repo:"x/y", run_id:"r", pr:null, candidate_sha:$sha, bean_at:$sha, bean_path:"b"},
     defect:"d", answer_key:{why:"because", evidence:[{file:"diff.txt", quote:("x = 1  # " + $id)}]},
     anchors:["off by one"], key_by:"test", key_checked_at:"today"}
    + (if $tw == "" then {} else {twin_of:$tw} end)' > "$C/$1/case.json"
}
mkcase broken reject
mkcase broken-repaired accept broken

run() { # run <stub mode> [extra env]
  env QUALIFY_CASES="$C" FACTORY_NO_SNAPSHOT=1 QUALIFY_NO_GPU=1 \
    JUDGE_CMD="$HERE/fixtures/qualify-stub-judge.sh" AUDIT_CHECK="$HERE/fixtures/qualify-stub-check.sh" \
    STUB_JUDGE="$1" "${@:2}" bash "$BENCH/judge-qualify.sh" --repo "$R" --out "$WORK/out.json" 2>&1
}
s() { jq -r ".summary.$1" "$WORK/out.json"; }

printf '\n== a judge that tells them apart ==\n\n'
out="$(run discriminate)"
check "the defect is caught"               "CAUGHT — named and stamped" "$out"
check "the twin is accepted"               "accepted, correctly" "$out"
eq    "the pair is told apart"             "1" "$(s pairs_discriminated)"
eq    "strict catch rate"                  "100" "$(s strict_catch_rate)"
check "and it says one pass is not enough" "One pass is not a measurement" "$out"

printf '\n== the two degenerate judges both score zero pairs ==\n\n'
run catch >/dev/null
eq    "reject-everything: defect caught"    "1" "$(s defects_named_and_stamped)"
eq    "reject-everything: a false alarm"    "1" "$(s false_alarms)"
eq    "reject-everything: no pair"          "0" "$(s pairs_discriminated)"
run accept >/dev/null
eq    "accept-everything: a false accept"   "1" "$(s false_accepts)"
eq    "accept-everything: no pair"          "0" "$(s pairs_discriminated)"

printf '\n== named but not stamped is not a catch ==\n\n'
out="$(run discriminate STUB_STAMP=0)"
check "it says why it was not stamped"      "named, not stamped (the judgement quotes text" "$out"
eq    "no strict catch"                     "0" "$(s defects_named_and_stamped)"
eq    "and no pair"                         "0" "$(s pairs_discriminated)"

printf '\n== a judge that says nothing ==\n\n'
out="$(run silent)"
check "is reported as no judgement"         "no judgement" "$out"
eq    "and answered nothing"                "0" "$(s answered)"

printf '\n== a case without an answer key is refused ==\n\n'
mkcase unkeyed reject
jq '.answer_key.why = "" | .anchors = []' "$C/unkeyed/case.json" > "$WORK/k" && mv "$WORK/k" "$C/unkeyed/case.json"
out="$(run discriminate)"; rc=$?
eq    "it refuses to score"                 "2" "$rc"
check "and says which case"                 "case unkeyed has no answer key" "$out"
rm -rf "$C/unkeyed"

printf '\n== no worktree is left behind ==\n\n'
eq    "only the main worktree remains"      "1" "$(git -C "$R" worktree list | wc -l)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
