#!/usr/bin/env bash
# test-package-check.sh — the run record has to agree with itself.
#
# Every scenario here is a run that looks fine from the outside and is not. That
# is the point of the target: by the time a package audit runs, every step has
# already reported success, and the only thing left to find is a record that
# contradicts itself.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}

R="$WORK/run"
reset() {
  rm -rf "$R"; mkdir -p "$R/verdicts"
  cat > "$R/run.json" <<'JSON'
{"run_id":"R","bean":"bean-001","branch":"bean/bean-001","status":"complete","tier":"full"}
JSON
  # A clean full-tier run: four steps, each opened and closed once.
  : > "$R/steps.jsonl"
  for s in spec audit-spec build gate audit-impl doc audit-doc; do
    printf '{"event":"start","step":"%s","attempt":1}\n' "$s" >> "$R/steps.jsonl"
    printf '{"event":"end","step":"%s","attempt":1,"verdict":"PASS"}\n' "$s" >> "$R/steps.jsonl"
  done
  cat > "$R/gate.json" <<'JSON'
{"overall":"pass","containment":{"contained":true,"violations":[]},
 "tier":{"final_tier":1},
 "test_integrity":{"fails_on_revert":{"result":"yes","why":"ok"}}}
JSON
  for t in spec impl doc; do printf '{"verdict":"accept"}\n' > "$R/verdicts/$t.attempt-1.json"; done
}
pc() { bash "$PIPELINE_DIR/package-check.sh" "$R" "$@" 2>&1; }

printf '\n== a consistent run passes ==\n\n'
reset
out="$(pc)"; rc=$?
check "the steps pair"         "each opened and closed exactly once" "$out"
check "the gate passed"        "ok    gate" "$out"
check "the verdicts are named" "all correctly named" "$out"
check "and match the tier"     "full tier, and every audit it runs has one" "$out"
check "overall"                "PACKAGE CHECK PASS" "$out"

printf '\n== a step closed twice is caught ==\n\n'
reset
printf '{"event":"end","step":"build","attempt":1,"verdict":"PASS"}\n' >> "$R/steps.jsonl"
out="$(pc)"
check "it names the step and the counts" "build attempt 1: 1 start(s), 2 end(s)" "$out"
check "and fails"                        "PACKAGE CHECK FAIL" "$out"

printf '\n== a step that never closed is caught ==\n\n'
reset
printf '{"event":"start","step":"pr","attempt":1}\n' >> "$R/steps.jsonl"
out="$(pc)"
check "it names the open step" "pr attempt 1: 1 start(s), 0 end(s)" "$out"

printf '\n== a complete status with an unanswered question is a stale halt ==\n\n'
reset
printf '# something needed a human\n' > "$R/QUESTIONS.md"
out="$(pc)"
check "it is caught"       "stale halt" "$out"
check "and it is a blocker" "QUESTIONS.md is still present" "$out"

printf '\n== a halted status with nothing wrong is also a contradiction ==\n\n'
reset
jq '.status = "halted"' "$R/run.json" > "$R/t" && mv "$R/t" "$R/run.json"
out="$(pc)"
check "it is caught" "every step passed and there is no QUESTIONS.md" "$out"

printf '\n== a misnamed verdict file is invisible to the driver, so it is named here ==\n\n'
reset
mv "$R/verdicts/impl.attempt-1.json" "$R/verdicts/impl-attempt1.json"
out="$(pc)"
check "the stray file is named"      "impl-attempt1.json" "$out"
check "and what it means is said"    "a verdict that did not happen" "$out"

printf '\n== a verdict for a target this tier never runs ==\n\n'
reset
jq '.tier = "small"' "$R/run.json" > "$R/t" && mv "$R/t" "$R/run.json"
out="$(pc --tier small)"
check "the extra verdicts are named" "verdicts it never runs" "$out"
check "and the reason is given"      "describes a pipeline it did not follow" "$out"

printf '\n== an ungated change cannot be packaged ==\n\n'
reset
rm -f "$R/gate.json"
out="$(pc)"
check "it says so"  "the change was never gated" "$out"

printf '\n== a gate whose containment failed ==\n\n'
reset
jq '.containment = {"contained":false,"violations":["src/evil.py"]}' "$R/gate.json" > "$R/t" && mv "$R/t" "$R/gate.json"
out="$(pc)"
check "the violation is carried through" "src/evil.py" "$out"

printf '\n== tests that pass without the change are a blocker here too ==\n\n'
reset
jq '.test_integrity.fails_on_revert.result = "no"' "$R/gate.json" > "$R/t" && mv "$R/t" "$R/gate.json"
out="$(pc)"
check "it is caught"  "the tests pass without this change" "$out"

printf '\n== an undecided test-integrity is reported, not failed ==\n\n'
reset
jq '.test_integrity.fails_on_revert = {"result":"no_tests","why":"nothing was written to pin it"}' \
  "$R/gate.json" > "$R/t" && mv "$R/t" "$R/gate.json"
out="$(pc)"
check "it is carried into the findings" "nothing was written to pin it" "$out"
nope  "but it does not fail the package" "PACKAGE CHECK FAIL" "$out"

printf '\n== the findings are written where an audit can read them ==\n\n'
reset
printf '{"event":"end","step":"build","attempt":1,"verdict":"PASS"}\n' >> "$R/steps.jsonl"
pc >/dev/null 2>&1
check "the record exists"        "package-check/1.0.0" "$(cat "$R/package-check.json")"
check "it says it is not consistent" '"internally_consistent":false' \
      "$(tr -d ' \n' < "$R/package-check.json")"
check "with a blocker finding"   '"severity":"blocker"' "$(tr -d ' \n' < "$R/package-check.json")"
check "and it says what is left for a judge" "whether the run tells a coherent story" \
      "$(cat "$R/package-check.json")"

printf '\n== the step it runs inside is allowed to be open ==\n\n'
#
# package-check runs during audit-package, so audit-package's own `start` is in
# the log and its `end` cannot be — it is waiting for this check. Without
# --current-step the pairing check reported its own caller as an unclosed step
# every single time, and the run halted on the one entry that is supposed to be
# open. It went unnoticed until the audit steps started being recorded at all.
reset
printf '{"event":"start","step":"audit-package","attempt":1}\n' >> "$R/steps.jsonl"
out="$(pc)"
check "without the flag it complains"  "audit-package attempt 1: 1 start(s), 0 end(s)" "$out"

out="$(pc --current-step audit-package)"
nope  "with it, the open step is ignored" "audit-package attempt 1" "$out"
check "and everything else still pairs"  "each opened and closed exactly once" "$out"
check "the check passes"                 "PACKAGE CHECK PASS" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
