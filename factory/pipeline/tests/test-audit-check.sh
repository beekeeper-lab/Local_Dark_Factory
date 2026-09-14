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
judgement "$(jq -c '. + {verdict:"revise", feedback_to_worker:"name a test that can fail"}' <<<"$BASE")"
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
