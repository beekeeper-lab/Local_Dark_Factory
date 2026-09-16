#!/usr/bin/env bash
# test-audit-findings.sh — what a failed audit is allowed to tell the worker.
#
# The re-entered authoring step was handed the verdict file itself, which after
# audit-check.sh carries base_sha, candidate_sha, diff_sha256, model_digest,
# gate_manifest_digest, invariants_digest, policy_version, prompt_version and the
# artifact hashes. None of it is actionable, and a worker that can see the judge's
# model_digest can start theorising about the judge instead of fixing the thing.
#
# So most of this file asserts what is ABSENT.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}
af() { bash "$PIPELINE_DIR/audit-findings.sh" "$WORK/v.json" "${1:-spec}" 2>&1; }

cat > "$WORK/v.json" <<'JSON'
{"schema_version":"verdict/1.0.0","stage":"spec_audit","target":"spec","verdict":"revise",
 "confidence":0.9,
 "criteria":[{"id":"ac1","met":true,"evidence":"a task claims it"},
             {"id":"ac2","met":false,"evidence":"no task claims this criterion"}],
 "findings":[{"severity":"major","summary":"the plan adds solver code","evidence":"task-2 writes src/solver.py"}],
 "feedback_to_worker":"drop the solver task and claim ac2",
 "base_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
 "candidate_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
 "diff_sha256":"cccccccccccccccc","model_digest":"a951a23b46a1",
 "gate_manifest_digest":"dddddddddddddddd","invariants_digest":"eeeeeeeeeeeeeeee",
 "policy_version":"1.0.0","prompt_version":"2.0.0",
 "artifacts":[{"path":"spec.md","sha256":"ffffffffffffffff"}]}
JSON

printf '\n== what the worker can act on ==\n\n'
out="$(af)"
check "the verdict word"               "Verdict: **revise**" "$out"
check "the feedback"                   "drop the solver task" "$out"
check "the finding, with its severity" "**major** — the plan adds solver code" "$out"
check "and its evidence"               "task-2 writes src/solver.py" "$out"
check "the criterion that is not met"  "\`ac2\` — no task claims this criterion" "$out"
nope  "and not the one that is"        "a task claims it" "$out"
check "and what to do with it"         "Fix these in the artifact" "$out"

printf '\n== and what it must not be given ==\n\n'
#
# Every one of these is in the verdict file this was rendered from.
for secret in a951a23b46a1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
              cccccccccccccccc dddddddddddddddd eeeeeeeeeeeeeeee ffffffffffffffff; do
  nope "provenance: ${secret:0:12}" "$secret" "$out"
done
nope  "no policy version"              "policy_version" "$out"
nope  "no prompt version"              "prompt_version" "$out"
nope  "no confidence number"           "0.9" "$out"

printf '\n== a verdict with no findings says so, rather than nothing ==\n\n'
#
# audit-check refuses a revise carrying none, so this should be unreachable from
# the live line. If it ever is reached, a blank Findings section in a prompt reads
# as "nothing was wrong", which is the opposite of what a failed audit means.
jq -c '.findings = []' "$WORK/v.json" > "$WORK/v2.json" && mv "$WORK/v2.json" "$WORK/v.json"
out="$(af)"
check "it names the gap"               "The audit recorded none" "$out"
check "and says it is the audit's fault" "a defect in the audit" "$out"
check "and what to do"                 "ask a human rather than guessing" "$out"

printf '\n== a missing or unreadable verdict is not an empty findings file ==\n\n'
#
# An empty file handed to a retry is a retry asked the identical question, which
# is the thing the whole re-entry mechanism exists to avoid.
out="$(bash "$PIPELINE_DIR/audit-findings.sh" "$WORK/nope.json" spec 2>&1)"; rc=$?
rc_is "a missing file exits 2"         "$rc" 2
check "and says so"                    "no such verdict file" "$out"
printf 'not json\n' > "$WORK/v.json"
out="$(af)"; rc=$?
rc_is "and so does one that is not JSON" "$rc" 2

printf '\n== written to a file when asked, and the path is what comes back ==\n\n'
cat > "$WORK/v.json" <<'JSON'
{"verdict":"revise","criteria":[],"findings":[{"severity":"minor","summary":"s","evidence":"e"}]}
JSON
out="$(bash "$PIPELINE_DIR/audit-findings.sh" "$WORK/v.json" doc "$WORK/out.md" 2>&1)"
if [ "$out" = "$WORK/out.md" ]; then printf '  ok    stdout is the path, for the caller to pass on\n'; PASS=$((PASS+1))
else printf '  FAIL  expected the path on stdout, got: %s\n' "$out"; FAIL=$((FAIL+1)); fi
check "and the file has the document"  "The doc audit did not pass" "$(cat "$WORK/out.md")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
