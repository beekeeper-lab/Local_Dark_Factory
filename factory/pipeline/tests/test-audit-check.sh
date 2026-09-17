#!/usr/bin/env bash
# test-audit-check.sh — the judge judges; the controller stamps.
#
# The split exists because verdict.schema.json requires ten provenance fields a
# model could only guess at, and a guessed hex string is indistinguishable from a
# true one. These cases check both halves of that: that the judge's opinion is
# carried faithfully, and that nothing the judge said can become a provenance
# fact — including the one thing it is allowed to influence, the tier, which it
# may raise and may not lower.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}

REPO="$WORK/repo"; mkdir -p "$REPO"; cd "$REPO"
git init -q -b main .; git config user.email t@e.com; git config user.name T
mkdir -p factory/beans src factory/runs/R/verdicts

cat > factory/gates.lock.yaml <<YAML
image: "localhost/x:1@sha256:$(printf 'a%.0s' {1..64})"
verify_versions_at_startup: true
gates:
  - id: smoke
    run: ["true"]
YAML
cat > factory/risk-policy.yaml <<'YAML'
policy_version: test/2026-09-14
default_tier: 1
repo_allowed_paths: ["src/**"]
rules:
  - { match: "src/**", min_tier: 1, reason: "code" }
YAML
cat > factory/beans/bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: e/x
title: T
intent: t
status: approved
allowed_write_paths: ["src/**"]
acceptance_criteria:
  - id: ac1
    text: a exists
    verify: { kind: command, run: ["true"] }
suggested_risk_tier: 1
definition_of_done: ["ac1"]
YAML
echo readme > README.md
git add -A && git commit -q -m init
git checkout -q -b bean/bean-001
echo 'print(1)' > src/a.py
git add -A && git commit -q -m work
echo '{"run_id":"R","bean":"bean-001","base":"main"}' > factory/runs/R/run.json
printf '{"ts":"t","step":"audit-spec","event":"start","attempt":1,"verdict":null}\n{"ts":"t","step":"audit-spec","event":"end","attempt":1,"verdict":"FAIL"}\n' > factory/runs/R/steps.jsonl
printf '# spec\n' > factory/runs/R/spec.md
printf 'schema_version: tasks/1.0.0\n' > factory/runs/R/tasks.yaml

V=factory/runs/R/verdicts
judgement() { cat > "$V/spec.attempt-${2:-1}.judgement.json" <<<"$1"; }
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}

run_check() { bash "$PIPELINE_DIR/audit-check.sh" factory/runs/R --target spec --bean factory/beans/bean.yaml 2>&1; }

BASE='{"schema_version":"judgement/1.0.0","stage":"spec_audit","target":"spec",
 "criteria":[{"id":"ac1","met":true,"evidence":"the named test fails on the unmodified tree",
              "quote":"allowed_write_paths: [\"src/**\"]"}],
 "document_quality":{"risk_called_out":true,"blast_radius_called_out":true,"code_blocks_teach":true,"no_assumed_stack_knowledge":true,"matches_diff":true}}'

printf '\n== no judgement is not a silent pass ==\n\n'
out="$(run_check)"; rc=$?
check "a missing judgement is reported" "the judge wrote no judgement file" "$out"
want  "and it exits 2"                  "expected 2" test "$rc" -eq 2

judgement 'not json at all'
out="$(run_check)"; rc=$?
check "unparseable JSON is reported"    "is not valid JSON" "$out"
want  "and it exits 2"                  "expected 2" test "$rc" -eq 2

judgement "$(jq -c '. + {verdict:"looks fine to me"}' <<<"$BASE")"
out="$(run_check)"; rc=$?
check "a verdict outside the enum fails" "expected accept|revise|block" "$out"
want  "and it exits 2"                   "expected 2" test "$rc" -eq 2

printf '\n== an accepted judgement becomes a schema-valid verdict ==\n\n'
judgement "$(jq -c '. + {verdict:"accept", confidence:0.8}' <<<"$BASE")"
out="$(run_check)"; rc=$?
check "it reports the verdict"     "AUDIT spec   accept" "$out"
want  "and exits 0"                "expected 0" test "$rc" -eq 0
want  "the verdict file exists"    "expected spec.attempt-1.json" test -f "$V/spec.attempt-1.json"
v="$(cat "$V/spec.attempt-1.json")"
check "schema version is the real one" '"schema_version": "verdict/2.0.0"' "$v"
check "the stage is derived"           '"stage": "spec_audit"' "$v"
check "the base sha is a real sha"     "$(git rev-parse main)" "$v"
check "the candidate sha is HEAD"      "$(git rev-parse HEAD)" "$v"
check "the gate image digest is carried" '"gate_manifest_digest": "sha256:aaaa' "$v"
check "the policy version is carried"  '"policy_version": "test/2026-09-14"' "$v"
check "the prompt is identified"       '"prompt_version": "factory-audit@' "$v"
check "the documents are hash-bound"   '"kind": "spec"' "$v"
check "and so is the task list"        '"kind": "tasks"' "$v"
check "the judge's evidence survives"  "fails on the unmodified tree" "$v"

printf '\n== the step record is amended, not duplicated ==\n\n'
ends="$(jq -s '[.[] | select(.step == "audit-spec" and .event == "end")] | length' factory/runs/R/steps.jsonl)"
want "still exactly one end line"  "an unpaired end breaks telemetry" test "$ends" -eq 1
check "and it now reads PASS"      '"verdict":"PASS"' "$(tr -d ' ' < factory/runs/R/steps.jsonl)"

printf '\n== a revise is a failure the driver can route ==\n\n'
rm -f "$V"/spec.attempt-*
# With a finding, because a revise carrying none is refused — and rightly: it is
# routed back into the authoring step, and with nothing attached the step is
# asked the identical question again.
judgement "$(jq -c '. + {verdict:"revise", feedback_to_worker:"name a test that can fail",
  findings:[{severity:"major", summary:"the only named test cannot fail", evidence:"it asserts its own fixture"}]}' <<<"$BASE")"
out="$(run_check)"; rc=$?
check "it reports revise"          "AUDIT spec   revise" "$out"
want  "and exits non-zero"         "a revise must not read as success" test "$rc" -ne 0
check "the feedback is carried"    "name a test that can fail" "$(cat "$V/spec.attempt-1.json")"

printf '\n== a blocker cannot sit inside an accept ==\n\n'
rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"accept", findings:[{severity:"blocker",summary:"the only test is a tautology",evidence:"tests/test_x.py:3 asserts its own fixture"}]}' <<<"$BASE")"
out="$(run_check)"; rc=$?
check "the contradiction is called out" "blocker finding(s) with an \"accept\" verdict" "$out"
check "and it is recorded as revise"    '"verdict": "revise"' "$(cat "$V/spec.attempt-1.json")"
want  "and it exits non-zero"           "a blocker must not pass" test "$rc" -ne 0

printf '\n== the judge may raise the tier and may not lower it ==\n\n'
rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"accept", suggested_tier:3}' <<<"$BASE")"
out="$(run_check)"
check "a raise is honoured"        "raised the tier from 1 to 3" "$out"
check "and recorded"               '"effective_risk_tier": 3' "$(cat "$V/spec.attempt-1.json")"
rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"accept", suggested_tier:0}' <<<"$BASE")"
run_check >/dev/null
check "a lower suggestion is ignored" '"effective_risk_tier": 1' "$(cat "$V/spec.attempt-1.json")"

printf '\n== the judge can say it could not tell ==\n\n'
# Quote verification catches invented evidence. Nothing catches a confident
# accept whose quotes are all real, so the judge needs somewhere for doubt to go.
rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"abstain", feedback_to_worker:"the spec references a file that was not given to me"}' <<<"$BASE")"
out="$(run_check)"; rc=$?
check "an abstention is reported"     "the judge abstained" "$out"
check "with its reason"               "not given to me" "$out"
want  "and it exits 7, not 1"         "a human is needed, and that is not a revise" test "$rc" -eq 7
check "it is recorded as abstain"     '"verdict": "abstain"' "$(cat "$V/spec.attempt-1.json")"
check "and the step does not read PASS" '"verdict":"ABSTAIN"' "$(tr -d ' ' < factory/runs/R/steps.jsonl)"

rm -f "$V"/spec.attempt-*
printf '{"ts":"t","step":"audit-spec","event":"start","attempt":1,"verdict":null}\n{"ts":"t","step":"audit-spec","event":"end","attempt":1,"verdict":"FAIL"}\n' > factory/runs/R/steps.jsonl
judgement "$(jq -c '. + {verdict:"accept", confidence:0.2}' <<<"$BASE")"
out="$(run_check)"; rc=$?
check "a low-confidence accept becomes abstain" "below the 0.4 floor" "$out"
want  "and it exits 7"                "an unsure accept is a question, not a pass" test "$rc" -eq 7
rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"accept", confidence:0.9}' <<<"$BASE")"
run_check >/dev/null; rc=$?
want "a confident accept still passes" "expected 0" test "$rc" -eq 0

printf '\n== a judgement that quotes nothing, or quotes fiction, is refused ==\n\n'
# The failure this exists for: a real judge produced a fluent audit of a document
# it never read, describing sections that do not exist in this format at all.
rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"accept"} | .criteria[0] |= del(.quote)' <<<"$BASE")"
out="$(run_check)"; rc=$?
check "quoting nothing is refused"   "the judgement quotes nothing" "$out"
want  "and it exits 2"               "expected 2" test "$rc" -eq 2

rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"accept"} | .criteria[0].quote = "## Architecture\n\nThe pipeline reads from the Input section"' <<<"$BASE")"
out="$(run_check)"; rc=$?
check "a fabricated quote is caught"  "quotes text that is not on disk anywhere" "$out"
check "and the text is shown back"    "Architecture" "$out"
want  "and it exits 2"                "expected 2" test "$rc" -eq 2
want  "with no verdict written"       "a fabricated audit must leave nothing behind" \
  test ! -f "$V/spec.attempt-1.json"

rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"accept"}' <<<"$BASE")"
out="$(run_check)"
check "a real quote is verified"      "quote(s) verified against the artifacts" "$out"

# The gap between "all quotes are too short" and "every criterion is backed".
# The check counted verified QUOTES, not verified criteria, and the quotes it
# counted included the ones attached to findings. So a criterion quoting "the
# test" — eight characters, matching everything, proving nothing — rode along on
# a finding that quoted the artifact properly, and the output said
# "1 quote(s) verified" and passed. A verdict rests on every criterion.
rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"revise",
    findings:[{severity:"major", what:"the write paths are wrong", where:"spec",
               quote:"allowed_write_paths: [\"src/**\"]"}]}
  | .criteria[0].quote = "the test"' <<<"$BASE")"
out="$(run_check)"; rc=$?
check "a finding's quote does not back a criterion" "not backed by a quote long enough to check" "$out"
check "and the criterion is named"    "ac1" "$out"
want  "and it exits 2"                "expected 2" test "$rc" -eq 2
want  "with no verdict written"       "an unverified criterion must leave nothing behind" \
  test ! -f "$V/spec.attempt-1.json"

printf '\n== provenance that cannot be observed stops the verdict ==\n\n'
rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"accept"}' <<<"$BASE")"
mv factory/gates.lock.yaml "$WORK/gates.away"
out="$(run_check)"; rc=$?
check "a missing pinned image refuses" "every verdict names the toolchain" "$out"
want  "rather than writing a placeholder" "the verdict must not exist" test ! -f "$V/spec.attempt-1.json"
mv "$WORK/gates.away" factory/gates.lock.yaml

# A bean that names invariants the repo does not carry is a missing guarantee.
rm -f "$V"/spec.attempt-*
judgement "$(jq -c '. + {verdict:"accept"}' <<<"$BASE")"
printf 'invariants_ref: factory/invariants/nope.yaml\n' >> factory/beans/bean.yaml
out="$(run_check)"
check "a missing invariants file refuses" "not a guarantee" "$out"

printf '\n== a confidence outside 0..1 is refused, not clamped ==\n\n'
#
# A real judgement came back with `confidence: 100`, was stamped into a verdict,
# and passed the floor check because 100 is not below 0.4. Constrained decoding
# does not enforce numeric bounds — the grammar knows the field is a number, not
# that it is in range.
#
# Refused rather than clamped: 100 read as "certain" and 100 read as "percent"
# are not reconcilable by guessing, and clamping would invent a claim the model
# never made.
judgement '{"verdict":"accept","confidence":100,
  "criteria":[{"id":"ac1","met":true,"evidence":"the module is there and imports","quote":"allowed_write_paths: [\"src/**\"]"}],
  "findings":[]}'
out="$(run_check)"; rc=$?
check "the range is named"        "outside the contract range 0..1" "$out"
want  "and it does not pass"      "expected non-zero" test "$rc" -ne 0
want  "no verdict is stamped"     "a verdict must not exist" test ! -f "$V/spec.attempt-1.json"
want  "the judgement is kept"     "the rejected judgement must be on disk" \
      test -f "$V/spec.attempt-1.json.rejected"

printf '\n== and a confidence inside the range still works ==\n\n'
judgement '{"verdict":"accept","confidence":0.9,
  "criteria":[{"id":"ac1","met":true,"evidence":"the module is there and imports","quote":"allowed_write_paths: [\"src/**\"]"}],
  "findings":[]}'
out="$(run_check)"
check "it is accepted"            "quote(s) verified" "$out"

printf '\n== a quote from deep in the run directory is found ==\n\n'
#
# The haystack was limited to depth 2, which excluded everything under
# build/<task>/attempt-<n>/ — verify logs, containment records, the worker's own
# output. An impl audit quoting the output of a check that failed would have had
# its quote refused as invented, which is the one accusation this script must not
# make wrongly.
mkdir -p factory/runs/R/build/task-1/attempt-1
printf 'E   AssertionError: expected 3 but the function returned 4\n' \
  > factory/runs/R/build/task-1/attempt-1/verify-1.log
judgement '{"verdict":"revise","confidence":0.8,
  "criteria":[{"id":"ac1","met":false,"evidence":"the check failed and says why","quote":"AssertionError: expected 3 but the function returned 4"}],
  "findings":[{"severity":"major","summary":"the check fails","evidence":"AssertionError: expected 3 but the function returned 4"}]}'
out="$(run_check)"
check "the deep quote is verified"  "quote(s) verified" "$out"
nope  "and is not called invented"  "could not be found" "$out"

printf '\n== the judgement reports on every criterion, and invents none ==\n\n'
#
# judge.sh puts the bean's criteria in the prompt by id and says "one entry per
# line, using exactly these ids". Nothing read that back. Both halves are
# measured failure modes of this model:
#
#   too few  — bean-001's doc audit came back `accept` with zero criteria for a
#              bean with four, and the only thing that refused it was the quote
#              check, by accident: a judgement with no criteria has no quotes.
#   invented — without the id list in the prompt, this judge reported against
#              criteria nobody asked about ("C001: the spec must be valid JSON").
#
# A two-criterion bean, so "reported on one of them" is expressible.
cat > factory/beans/bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: e/x
title: t
intent: i
status: approved
allowed_write_paths: ["src/**"]
acceptance_criteria:
  - id: ac1
    text: a exists
    verify: { kind: command, run: ["true"] }
  - id: ac2
    text: b exists
    verify: { kind: command, run: ["true"] }
suggested_risk_tier: 1
definition_of_done: ["ac1"]
YAML
Q='allowed_write_paths: ["src/**"]'
two='{"schema_version":"judgement/1.0.0","stage":"spec_audit","target":"spec","verdict":"accept","confidence":0.9,"findings":[],
 "document_quality":{"risk_called_out":true,"blast_radius_called_out":true,"code_blocks_teach":true,"no_assumed_stack_knowledge":true,"matches_diff":true},
 "criteria":[{"id":"ac1","met":true,"evidence":"e","quote":"allowed_write_paths: [\"src/**\"]"},
             {"id":"ac2","met":true,"evidence":"e","quote":"allowed_write_paths: [\"src/**\"]"}]}'
judgement "$two"
out="$(run_check)"; rc=$?
want  "all of them is accepted"        "expected 0, got $rc" test "$rc" -eq 0
check "and it says so"                 "all 2 criterion(s) reported on, none invented" "$out"

printf '\n-- a verdict over some of them is not a verdict --\n\n'
rm -f "$V/spec.attempt-1.json"
judgement "$(jq -c '.criteria = [.criteria[0]]' <<<"$two")"
out="$(run_check)"; rc=$?
want  "it is refused"                  "expected 1, got $rc" test "$rc" -eq 1
check "and names the one skipped"      "not reported on: ac2" "$out"
check "and says what that shape is"    "the ones nobody looked at are the ones that were wrong" "$out"
want  "the judgement is kept"          "a rejected judgement should be on disk"       test -s "$V/spec.attempt-1.json.rejected"
want  "but no verdict is stamped"      "nothing may be stamped from it" test ! -f "$V/spec.attempt-1.json"

printf '\n-- and a criterion the bean never declared --\n\n'
judgement "$(jq -c '.criteria += [{id:"C001", met:true, evidence:"e", quote:"allowed_write_paths: [\"src/**\"]"}]' <<<"$two")"
out="$(run_check)"; rc=$?
want  "it is refused"                  "expected 1, got $rc" test "$rc" -eq 1
check "and names the invention"        "reported on, but not in the bean: C001" "$out"
check "and what the bean actually has" "bean-001 declares: ac1 ac2" "$out"

printf '\n-- and an abstention is held to the same list --\n\n'
#
# The first version of this check exempted abstentions, reasoning that a judge
# which cannot form a judgement should not be made to work through a list. The
# exemption permitted nothing: verdict.schema.json already requires `criteria` to
# be non-empty for every verdict, so the abstention was refused three lines later
# with "criteria: [] should be non-empty" — the same outcome, from a message that
# does not say which criteria. One rule, and the legible message.
rm -f "$V/spec.attempt-1.json"
judgement "$(jq -c '.verdict = "abstain" | .criteria = []' <<<"$two")"
out="$(run_check)"; rc=$?
want  "it is refused"                  "expected 1, got $rc" test "$rc" -eq 1
check "by the criteria check"          "not reported on: ac1 ac2" "$out"
nope  "not by the schema, later"       "should be non-empty" "$out"

rm -f "$V/spec.attempt-1.json"
judgement "$(jq -c '.verdict = "abstain"' <<<"$two")"
out="$(run_check)"; rc=$?
# 7, which is audit-check's code for "the judge abstained": not a pass, not a
# revise, and routed to a human. The point here is that the criteria check did
# not stand in its way.
want  "an abstention that reports on all of them stands" "expected 7, got $rc: $out" test "$rc" -eq 7
check "and still goes to a human"      "this goes to a human, not to a retry" "$out"

printf '\n== a revise with nothing to revise is not a verdict ==\n\n'
#
# orchestrate re-enters the authoring step WITH the findings — that is the only
# way an audit changes anything. A revise carrying none asks the identical
# question again, burns an attempt, and the second failure halts the run for a
# human whose only information is "the judge said revise".
#
# Not hypothetical: judge-variance, five identical runs at temperature 0, came
# back `revise` every time with findings counts of 4, 0, 4, 3 and 1.
rm -f "$V/spec.attempt-1.json"
judgement "$(jq -c '.verdict = "revise" | .findings = []' <<<"$two")"
out="$(run_check)"; rc=$?
want  "it is refused"                  "expected 1, got $rc" test "$rc" -eq 1
check "and says what findings are for" "routed back into the authoring step carrying its findings" "$out"
check "and what to say instead"        "the verdict is \"abstain\"" "$out"

rm -f "$V/spec.attempt-1.json"
judgement "$(jq -c '.verdict = "block" | .findings = []' <<<"$two")"
out="$(run_check)"; rc=$?
want  "and so is a block with none"    "expected 1, got $rc" test "$rc" -eq 1

# An abstention is the escape hatch, so it must not be caught by this.
rm -f "$V/spec.attempt-1.json"
judgement "$(jq -c '.verdict = "abstain" | .findings = []' <<<"$two")"
out="$(run_check)"; rc=$?
want  "an abstention with none stands" "expected 7, got $rc: $out" test "$rc" -eq 7

# And an accept with none is the normal happy path.
rm -f "$V/spec.attempt-1.json"
judgement "$two"
out="$(run_check)"; rc=$?
want  "an accept with none is fine"    "expected 0, got $rc: $out" test "$rc" -eq 0

printf '\n== counts it was handed, restated correctly or the verdict is refused ==\n\n'
#
# verdict.schema.json requires test_integrity on an impl audit, and the controller
# already counted deleted_tests and new_skips from the diff and handed the result
# to the judge as an artifact. Two sources for one number is one source that will
# disagree with itself — and disagreement here is evidence the judge did not read
# what it was in its own messages, which is what this line has already been
# burned by once.
printf '{"test_integrity":{"deleted_tests":2,"new_skips":1,"removed_asserts":0,"added_asserts":3}}\n' \
  > factory/runs/R/test-integrity.json
rm -f "$V/spec.attempt-1.json"
judgement "$(jq -c '.test_integrity = {deleted_tests:2, new_skips:1, weakened_asserts:false}' <<<"$two")"
out="$(run_check)"; rc=$?
want  "matching counts are accepted"   "expected 0, got $rc: $out" test "$rc" -eq 0
check "and it says they match"         "the counts it restates match the ones it was given" "$out"

rm -f "$V/spec.attempt-1.json"
judgement "$(jq -c '.test_integrity = {deleted_tests:0, new_skips:1, weakened_asserts:false}' <<<"$two")"
out="$(run_check)"; rc=$?
want  "a contradicted count is refused" "expected 1, got $rc" test "$rc" -eq 1
check "and names both numbers"         "deleted_tests(measured=2 claimed=0)" "$out"
check "and says what it means"         "did not read it" "$out"
check "and why it is not repaired"     "would hide that the judge contradicted its own evidence" "$out"
want  "the judgement is kept"          "a rejected judgement should be on disk" \
      test -s "$V/spec.attempt-1.json.rejected"

printf '\n-- a judgement that claims nothing about them is not held to it --\n\n'
#
# The field is required for an impl audit by the schema, not by this check. A
# spec audit has no tests to count and must not be refused for omitting a number
# nobody measured for it.
rm -f "$V/spec.attempt-1.json"
judgement "$two"
out="$(run_check)"; rc=$?
want  "no test_integrity is fine here" "expected 0, got $rc: $out" test "$rc" -eq 0
nope  "and nothing is claimed about it" "the counts it restates" "$out"
rm -f factory/runs/R/test-integrity.json

printf '\n== the verdict carries the controller\x27s test_integrity, not the judge\x27s ==\n\n'
#
# verdict.schema.json REQUIRES test_integrity on an impl audit. judge.sh's
# response schema does not contain the field at all, so the judge is never asked
# for it and an impl verdict could never validate — a contract that cannot be
# satisfied. On 2026-09-16 a real impl audit got through every other check, four
# criteria and two verified quotes, and died on "'test_integrity' is a required
# property".
#
# It is not asked for. test-integrity.sh measured it and the verdict is the
# controller's document.
printf '{"test_integrity":{"deleted_tests":1,"new_skips":2,"removed_asserts":5,"added_asserts":1}}\n' \
  > factory/runs/R/test-integrity.json
rm -f "$V/spec.attempt-1.json"
judgement "$two"
run_check >/dev/null 2>&1
ti="$(jq -c '.test_integrity' "$V/spec.attempt-1.json" 2>/dev/null)"
eq "the counts are the controller's"   "1" "$(jq -r '.deleted_tests' <<<"$ti")"
eq "both of them"                      "2" "$(jq -r '.new_skips' <<<"$ti")"
# The controller counts assertions removed against added and will not call that a
# boolean; the boolean the schema wants is derived to the only shape the counts
# support.
eq "weakened_asserts is derived"       "true" "$(jq -r '.weakened_asserts' <<<"$ti")"
eq "and coverage_delta says it is not measured" "not measured" "$(jq -r '.coverage_delta' <<<"$ti")"

printf '\n-- more added than removed is not a weakened assertion --\n\n'
printf '{"test_integrity":{"deleted_tests":0,"new_skips":0,"removed_asserts":1,"added_asserts":9}}\n' \
  > factory/runs/R/test-integrity.json
rm -f "$V/spec.attempt-1.json"
judgement "$two"
run_check >/dev/null 2>&1
eq "weakened_asserts is false"         "false" \
   "$(jq -r '.test_integrity.weakened_asserts' "$V/spec.attempt-1.json" 2>/dev/null)"
rm -f factory/runs/R/test-integrity.json

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
