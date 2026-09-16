#!/usr/bin/env bash
# test-gate.sh — whole-diff containment, the binding tier, and the gate stage.
#
# The property that matters most here is the asymmetry: every term can RAISE the
# tier and none can lower it. The forked pipeline read the tier out of a line the
# model wrote about its own change, so a model that believed its change was small
# was believed. These cases try to talk the tier down and require it not to move.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PY="${PIPELINE_PYTHON:-$PIPELINE_DIR/../../.venv/bin/python}"
[ -x "$PY" ] || PY=python3

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nocheck() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}

REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main .
git config user.email t@example.com
git config user.name "Test"
mkdir -p src/solver tests factory ai/runs/R

cat > .gitignore <<'EOF'
ai/runs/
EOF

cat > factory/risk-policy.yaml <<'YAML'
policy_version: test/2026-09-14
default_tier: 1
repo_allowed_paths:
  - src/**
  - tests/**
  - docs/**
rules:
  - { match: "docs/**", min_tier: 0, reason: "documents" }
  - { match: "src/solver/**", min_tier: 2, reason: "constraint solving" }
  - { match: "{pyproject.toml,*.lock}", min_tier: 2, reason: "dependencies" }
  - { match: "{factory/**,CLAUDE.md}", min_tier: 3, reason: "agent-control" }
YAML

cat > bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: example/x
title: A bean under the gate
intent: Exercise the gate.
status: approved
allowed_write_paths:
  - src/**
  - tests/**
acceptance_criteria:
  - id: ac1
    text: a.py exists and says GOOD
    verify: { kind: command, run: ["sh", "-c", "grep -q GOOD src/a.py"] }
suggested_risk_tier: 1
size_budget: { max_tasks: 4, max_files: 3, max_diff_lines: 60 }
definition_of_done: ["all AC verify pass"]
YAML

echo "readme" > README.md
# Infrastructure lives on main: a manifest committed on the bean branch vanishes
# the next time the branch is recreated, and the gate then cannot find its image.
if command -v podman >/dev/null 2>&1 && podman image exists localhost/factory-gate-python:20260914 2>/dev/null; then
  sed -E '/^gates:/,$d' "$PIPELINE_DIR/../scaffold/factory/gates.lock.yaml" > factory/gates.lock.yaml
  printf 'gates:\n  - id: smoke\n    run: ["python", "-c", "print(2+2)"]\n' >> factory/gates.lock.yaml
fi
git add -A && git commit -q -m init
BASE_SHA="$(git rev-parse HEAD)"
git checkout -q -b bean/bean-001
echo '{"run_id":"R","bean":"bean-001"}' > ai/runs/R/run.json

commit_all() { # commit_all <message> — refuse to "succeed" with nothing staged
  git add -A
  if git diff --cached --quiet; then
    printf '  FIXTURE ERROR: nothing staged for "%s" — the test would gate an empty diff\n' "$1"
    FAIL=$((FAIL+1))
    return 1
  fi
  git commit -q -m "$1"
}

nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}

gate() { bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean bean.yaml --policy factory/risk-policy.yaml "$@" 2>&1; }
reset_branch() {
  git checkout -q main
  git branch -qD bean/bean-001 2>/dev/null
  git checkout -q -b bean/bean-001
  git clean -fdq -e /ai
  rm -f ai/runs/R/gate.json
}

printf '\n== a clean change passes ==\n\n'
mkdir -p src && printf 'GOOD\n' > src/a.py
commit_all "task-1"
out="$(gate --skip-gates)"; rc=$?
check "containment passes"        "ok     containment" "$out"
check "the tier is computed"      "ok     tier                   1" "$out"
check "the size budget holds"     "ok     size_budget" "$out"
check "the secret scan is clean"  "ok     secret_scan" "$out"
check "the gate passes"           "GATE PASS" "$out"
want  "and exits 0"               "expected 0" test "$rc" -eq 0
g="$(cat ai/runs/R/gate.json)"
check "gate.json records the outcome" '"overall": "pass"' "$g"
check "and the files it judged"       '"file_count": 1' "$g"

printf '\n== an edit outside the bean is rejected, not stripped ==\n\n'
reset_branch
mkdir -p src && printf 'GOOD\n' > src/a.py
mkdir -p deploy && printf 'prod: true\n' > deploy/prod.yaml
commit_all "escape"
out="$(gate --skip-gates)"; rc=$?
check "containment fails"         "FAIL   containment" "$out"
check "the file is named"         "- deploy/prod.yaml" "$out"
check "and it says why not strip" "rejected, not stripped" "$out"
want  "the gate exits non-zero"   "a contained gate must fail" test "$rc" -ne 0
check "gate.json says uncontained" '"contained": false' "$(cat ai/runs/R/gate.json)"

printf '\n== the repo bound holds even when the bean claims wider paths ==\n\n'
reset_branch
cat > wide-bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: example/x
title: A bean claiming the whole repo
intent: Try to widen the surface.
status: approved
allowed_write_paths: ["**"]
acceptance_criteria:
  - id: ac1
    text: anything
    verify: { kind: command, run: ["true"] }
suggested_risk_tier: 1
definition_of_done: ["nothing"]
YAML
mkdir -p deploy && printf 'prod: true\n' > deploy/prod.yaml
commit_all "wide"
out="$(bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean wide-bean.yaml --policy factory/risk-policy.yaml --skip-gates 2>&1)"
check "a bean cannot widen its own reach" "FAIL   containment" "$out"
check "the repo's approved surface binds" "deploy/prod.yaml" "$out"

printf '\n== the tier comes from the diff, and nothing talks it down ==\n\n'
reset_branch
mkdir -p src/solver && printf 'GOOD\n' > src/a.py && printf 'x=1\n' > src/solver/cpsat.py
commit_all "solver"
out="$(gate --skip-gates)"
check "a solver path raises the tier to 2" "ok     tier                   2" "$out"
check "and names the rule that did it"     "constraint solving" "$out"

# The bean says 1. The diff says 2. The diff wins.
check "a bean's lower suggestion does not lower it" "set by policy" "$out"

reset_branch
mkdir -p src && printf 'GOOD\n' > src/a.py
commit_all "plain"
out="$(gate --skip-gates --judge-tier 3)"
check "the judge can raise the tier"   "ok     tier                   3" "$out"
check "and tier 3 is called out"       "never auto-merged" "$out"

printf '\n== tier arithmetic, directly ==\n\n'
t() { printf '%s\n' "$1" | $PY "$PIPELINE_DIR/tier.py" --policy factory/risk-policy.yaml "${@:2}" --json; }
check "docs are tier 0"            '"final_tier": 0' "$(t 'docs/x.md')"
check "unmatched paths take the default" '"final_tier": 1' "$(t 'src/a.py')"
check "dependency manifests are 2" '"final_tier": 2' "$(t 'pyproject.toml')"
check "agent-control is 3"         '"final_tier": 3' "$(t 'CLAUDE.md')"
check "the highest match wins"     '"final_tier": 3' "$($PY "$PIPELINE_DIR/tier.py" --policy factory/risk-policy.yaml --paths '["docs/x.md","CLAUDE.md"]' --json)"
check "a bean may raise it"        '"final_tier": 3' "$(t 'src/a.py' --bean-tier 3)"
check "but may not lower it"       '"final_tier": 2' "$(t 'pyproject.toml' --bean-tier 0)"
check "and the binding term is named" '"policy"' "$(t 'pyproject.toml' --bean-tier 0)"

printf '\n== the size budget is enforced ==\n\n'
reset_branch
mkdir -p src && printf 'GOOD\n' > src/a.py
mkdir -p src; for i in 1 2 3; do printf 'x\n' > "src/extra$i.py"; done
commit_all "too many files"
out="$(gate --skip-gates)"
check "too many files fails"       "FAIL   size_budget" "$out"
check "with the numbers"           "against a budget of 3" "$out"

printf '\n== the secret scan looks at added lines ==\n\n'
reset_branch
mkdir -p src && printf 'GOOD\n' > src/a.py
mkdir -p src && printf 'aws_key = "AKIAIOSFODNN7EXAMPLE"\n' > src/creds.py
commit_all "oops"
out="$(gate --skip-gates)"
check "an AWS key is caught"       "FAIL   secret_scan" "$out"
reset_branch
mkdir -p src && printf 'GOOD\n' > src/a.py
mkdir -p src && printf 'token = "ghp_%s"\n' "$(printf 'a%.0s' {1..36})" > src/creds.py
commit_all "oops2"
out="$(gate --skip-gates)"
check "a github token is caught"   "FAIL   secret_scan" "$out"

printf '\n== gates, acceptance criteria and invariants actually run ==\n\n'
if command -v podman >/dev/null 2>&1 && podman image exists localhost/factory-gate-python:20260914 2>/dev/null; then
  export FACTORY_SANDBOX_ROOT="$WORK/sb"
  reset_branch
  mkdir -p src && printf 'GOOD\n' > src/a.py
  commit_all "good"
  out="$(gate --gates factory/gates.lock.yaml)"
  check "the gate from the manifest runs"  "ok     gate:smoke" "$out"
  check "the acceptance criterion runs"    "ok     ac:ac1" "$out"
  check "it ran in the sandbox"            "note   sandbox" "$out"
  check "and the run passes"               "GATE PASS" "$out"
  check "gate.json records the gate"       '"id": "smoke"' "$(cat ai/runs/R/gate.json)"
  check "and where the AC ran"             '"ran_in": "sandbox"' "$(cat ai/runs/R/gate.json)"

  # The defect a real run found: `python -c "import pkg"` cannot pass in a bare
  # synced tree, because nothing installs the package and the gate has no network.
  reset_branch
  mkdir -p src/pkg && printf 'GOOD\n' > src/a.py && : > src/pkg/__init__.py
  commit_all "a src-layout package"
  cat > "$WORK/import-bean.yaml" <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: example/x
title: importable
intent: i
status: approved
allowed_write_paths: ["src/**"]
acceptance_criteria:
  - id: ac1
    text: the package imports
    verify: { kind: command, run: ["python", "-c", "import pkg"] }
suggested_risk_tier: 1
definition_of_done: ["ac1"]
YAML
  out="$(PIPELINE_CONFIG=/nonexistent bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean "$WORK/import-bean.yaml" \
    --policy factory/risk-policy.yaml --gates factory/gates.lock.yaml 2>&1)"
  check "without sandbox_env the import fails" "FAIL   ac:ac1" "$out"
  printf '{"sandbox_env":{"PYTHONPATH":"/work/src"}}\n' > "$WORK/cfg.json"
  out="$(PIPELINE_CONFIG="$WORK/cfg.json" bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean "$WORK/import-bean.yaml" \
    --policy factory/risk-policy.yaml --gates factory/gates.lock.yaml 2>&1)"
  check "with it, the package imports"        "ok     ac:ac1" "$out"

  reset_branch
  mkdir -p src && printf 'BAD\n' > src/a.py
  commit_all "bad"
  out="$(gate --gates factory/gates.lock.yaml)"
  check "a failing acceptance criterion fails the gate" "FAIL   ac:ac1" "$out"
  check "and the gate fails overall"                    "GATE FAIL" "$out"

  # An invariant the bean names but the repo does not carry is a missing
  # guarantee, not a missing file to shrug at.
  reset_branch
  mkdir -p src && printf 'GOOD\n' > src/a.py
  commit_all "good again"
  # --bean reads a file; it need not be tracked. Committing a modified bean.yaml
  # would trip containment (it is outside repo_allowed_paths) and the test would
  # be measuring the wrong refusal.
  sed 's|^definition_of_done|invariants_ref: factory/invariants/nope.yaml\ndefinition_of_done|' \
    bean.yaml > "$WORK/inv-bean.yaml"
  out="$(bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean "$WORK/inv-bean.yaml" \
    --policy factory/risk-policy.yaml --gates factory/gates.lock.yaml 2>&1)"
  check "a missing invariants file fails"  "FAIL   invariants" "$out"
  check "and says what that means"         "not a guarantee" "$out"

  # And the case that matters for closing Phase 1: an invariant this repo DOES
  # carry, run by the controller against a real build, both ways.
  #
  # `tests/test-invariants.sh` proves the invariants catch their own violations
  # against a reference implementation. What that does not show is the controller
  # running them as part of a gate — which is the predicate the plan actually
  # asks for, and which was asserted here only in its failure case. A mechanism
  # tested only by making it fail is a mechanism nobody has seen work.
  # The invariants have to be on MAIN, not on the bean branch. That is the whole
  # independence guarantee: `factory/invariants/**` is outside repo_allowed_paths,
  # so a bean writing one is a containment violation — which is what the first
  # version of this test produced, correctly, and it is the right refusal about
  # the wrong thing. Put them in the base the branch is cut from.
  git checkout -q main
  mkdir -p factory/invariants
  cat > factory/invariants/fixture.yaml <<'INV'
schema_version: invariants/1.0.0
id: fixture-core
title: A property any answer must have, whoever wrote the code
authored_by: "the test, standing in for a different model family"
# The shape seating.yaml uses, not an invented one: a single `kind: command`
# with a `run` array, which is what verify.sh reads.
verify:
  kind: command
  run: ["python3", "-m", "pytest", "-q", "--no-header", "factory/invariants/test_fixture.py"]
INV
  cat > factory/invariants/test_fixture.py <<'INVPY'
"""An invariant about the ANSWER, not about how it is produced.

It imports only the seam the bean is obliged to provide, so it constrains the
result without dictating the architecture — the same shape as seating.yaml.
"""
import pathlib


def answer() -> str:
    return pathlib.Path("src/a.py").read_text().strip()


def test_the_answer_is_the_agreed_one():
    assert answer() == "GOOD", f"the answer is {answer()!r}"
INVPY
  git add -A factory/invariants && git commit -q -m "invariants, authored outside the bean's reach"
  reset_branch
  mkdir -p src && printf 'GOOD\n' > src/a.py
  commit_all "an implementation that satisfies the invariant"
  sed 's|^definition_of_done|invariants_ref: factory/invariants/fixture.yaml\ndefinition_of_done|' \
    bean.yaml > "$WORK/inv-real.yaml"
  out="$(bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean "$WORK/inv-real.yaml" \
    --policy factory/risk-policy.yaml --gates factory/gates.lock.yaml 2>&1)"
  if ! grep -qF 'ok     invariants' <<<"$out"; then
    printf '  --- the invariants log ---\n'
    sed 's/^/  | /' ai/runs/R/invariants.log 2>/dev/null | tail -20
    printf '  --- end ---\n'
  fi
  check "the controller runs the bean's invariants" "ok     invariants" "$out"
  check "and names the file it ran"                 "factory/invariants/fixture.yaml" "$out"
  check "the gate passes with them"                 "GATE PASS" "$out"
  check "gate.json records the result"              '"status":"pass"' \
        "$(jq -c '.invariants' ai/runs/R/gate.json)"
  check "and which invariants ran"                  "fixture.yaml" \
        "$(jq -r '.invariants.ref' ai/runs/R/gate.json)"
  want "the output is kept, not just the verdict"   "invariants.log should exist" \
       test -s ai/runs/R/invariants.log

  # The same invariant against an implementation that violates it. This is the
  # half that makes the passing half mean something: a check that passes on
  # everything has not been shown to be running at all.
  printf 'ALSO GOOD ENOUGH SURELY\n' > src/a.py
  commit_all "an implementation that does not"
  out="$(bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean "$WORK/inv-real.yaml" \
    --policy factory/risk-policy.yaml --gates factory/gates.lock.yaml 2>&1)"
  check "a violated invariant fails the gate"       "FAIL   invariants" "$out"
  check "and the gate fails overall"                "GATE FAIL" "$out"
  # The gate line is one truncated summary; the assertion itself lives in the log,
  # which is the point of keeping the log.
  check "the failure names the file"                "fixture.yaml" "$out"
  check "and the assertion is in the log"           "the answer is" \
        "$(cat ai/runs/R/invariants.log 2>/dev/null)"
  unset FACTORY_SANDBOX_ROOT
else
  printf '  SKIP  podman or the gate image unavailable; execution not exercised\n'
fi

printf '\n== the record says which image the gates ran in ==\n\n'
#
# gates.lock.yaml pins the image by digest precisely because a tag can be
# repointed, and every "the gates passed" in this repo's history is a claim about
# a specific toolchain. gate.json — the record of what the gates did — did not say
# which one. The manifest pinned it and the result forgot it, so a reader of a run
# directory could not tell what the green was about.
out="$(gate --skip-gates)" || true
want "gate.json names the manifest"   "gate_manifest.ref should be set" \
     test -n "$(jq -r '.gate_manifest.ref // ""' ai/runs/R/gate.json)"
want "and the image it pins"          "gate_manifest.image should be set" \
     test -n "$(jq -r '.gate_manifest.image // ""' ai/runs/R/gate.json)"
want "with the digest split out"      "gate_manifest.digest should be a sha256" \
     bash -c "jq -re '.gate_manifest.digest | startswith(\"sha256:\")' ai/runs/R/gate.json >/dev/null"
want "and it is the manifest's digest" "the record must agree with the file it read" \
     test "$(jq -r '.gate_manifest.image' ai/runs/R/gate.json)" = \
          "$(bash "$PIPELINE_DIR/yaml2json.sh" factory/gates.lock.yaml | jq -r '.image')"

printf '\n== a diff it cannot read is not a clean diff ==\n\n'
#
# `git diff` failing produces an empty list, and every check below reads that as
# nothing to object to: containment finds no violations, the secret scan finds no
# secrets, the size budget is 0 of 5. The failure mode is every check passing at
# once, which is the most convincing possible way to be wrong.
out="$(bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean bean.yaml --policy factory/risk-policy.yaml \
  --base 0000000000000000000000000000000000000000 --skip-gates 2>&1)" || true
nope "it does not report a clean gate" "GATE PASS" "$out"
check "it says it could not read the diff" "could not read the diff" "$out"

printf '\n== a found secret is located, never reproduced ==\n\n'
#
# The scan used to print the matching lines. A check that finds a credential and
# copies it into the run log has spread it: the run directory is evidence, it is
# read by a judge, quoted in findings and summarised into a pull request. The
# detection would have been the largest single act of disclosure in the process.
mkdir -p src
printf 'AWS_KEY = "AKIAIOSFODNN7EXAMPLE"\n' > src/leak.py
git add src/leak.py >/dev/null 2>&1
git commit -q -m "a key committed by accident" >/dev/null 2>&1
out="$(gate --skip-gates || true)"
check "the scan fires"              "suspicious added line" "$out"
check "and says where"              "of the diff matches a known credential shape" "$out"
nope  "but never prints the secret" "AKIAIOSFODNN7EXAMPLE" "$out"
check "and says so explicitly"      "deliberately not reproduced" "$out"

printf '\n== a containment check that cannot run does not report "contained" ==\n\n'
#
# contain.py exits 1 for "violations found" and 2 for "I could not run" — bad
# patterns, an unreadable list. Both print nothing to stdout, and the call site
# swallowed every non-zero exit with `|| true`. So a crashed containment check
# produced an empty violation list, which reads exactly like a clean diff, and
# the one boundary the gate exists to enforce failed open.
cat > broken-bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: example/x
title: A bean whose allowed_write_paths cannot be read
intent: Prove the gate refuses when containment cannot be computed.
status: approved
allowed_write_paths: "src/** (a string, not a list)"
acceptance_criteria:
  - id: ac1
    text: anything
    verify: { kind: command, run: ["true"] }
definition_of_done: ["ac1"]
YAML
out="$(bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean broken-bean.yaml --policy factory/risk-policy.yaml --skip-gates 2>&1 || true)"
check "it refuses to compute"   "containment could not be computed" "$out"
nope  "and never says contained" '"contained": true' "$out"

printf '\n== hidden tests reach the gate, and what they are is not a pass ==\n\n'
#
# hidden-tests.sh has its own suite. What this asserts is the wiring: that the
# gate runs it, records it in gate.json, and turns each of its three outcomes
# into the right thing. The one that matters is could_not_run — a hidden suite
# that did not run, arriving at the audit as silence, is the fail-open shape this
# project keeps finding, so it is a gate FAILURE and not a note.
reset_branch
mkdir -p src && printf 'GOOD\n' > src/a.py
commit_all "task-hidden"

printf '{}\n' > "$WORK/cfg-nohidden.json"
out="$(PIPELINE_CONFIG="$WORK/cfg-nohidden.json" gate --skip-gates)"
nope "skip-gates skips them too"       "hidden tests: " "$out"

out="$(PIPELINE_CONFIG="$WORK/cfg-nohidden.json" gate --no-sandbox)"; rc=$?
check "a repo with none says so"       "none configured" "$out"
if [ "$(jq -r '.hidden_tests.status' ai/runs/R/gate.json 2>/dev/null)" = "not_configured" ]; then
  printf '  ok    and the gate record says which\n'; PASS=$((PASS+1))
else
  printf '  FAIL  gate.json does not record hidden_tests: %s\n' "$(jq -c '.hidden_tests' ai/runs/R/gate.json 2>/dev/null)"; FAIL=$((FAIL+1))
fi
# not_configured is a note, so it must not contribute a failing part. Asserted on
# the part and not on `overall`: this fixture's real gates fail for their own
# reasons, and an assertion on the whole verdict would be measuring those.
if grep -E '^(FAIL|fail)' <<<"$out" | grep -q 'hidden tests'; then
  printf '  FAIL  "none configured" was counted as a gate failure\n'; FAIL=$((FAIL+1))
else
  printf '  ok    and it is a note, not a failing part\n'; PASS=$((PASS+1))
fi

printf '\n-- a configured suite that cannot run FAILS the gate --\n\n'
#
# Not a note. "The hidden tests did not run" reaching the audit as silence is
# indistinguishable from "they passed", and the audit is what authorises the PR.
jq -n --arg d "/definitely/not/here" '{hidden_tests:{dir:$d}}' > "$WORK/cfg-badhidden.json"
out="$(PIPELINE_CONFIG="$WORK/cfg-badhidden.json" gate --no-sandbox)"; rc=$?
check "the gate says it could not run" "hidden tests" "$out"
check "as a failure"                   "could not run" "$out"
if [ "$rc" -ne 0 ]; then printf '  ok    and the gate exits non-zero\n'; PASS=$((PASS+1))
else printf '  FAIL  a hidden suite that could not run left the gate green\n'; FAIL=$((FAIL+1)); fi
check "and gate.json records it"       '"status": "could_not_run"' "$(cat ai/runs/R/gate.json)"

printf '\n-- and a passing suite passes, recorded by its hash --\n\n'
HID="$WORK/hidden-ok"; rm -rf "$HID"; mkdir -p "$HID"
printf 'def test_h():\n    assert True\n' > "$HID/test_h.py"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/yes-pytest"; chmod +x "$WORK/yes-pytest"
jq -n --arg d "$HID" --arg p "$WORK/yes-pytest" --arg r "$WORK/hidden-results" \
  '{hidden_tests:{dir:$d, command:[$p], results_dir:$r, control:false}}' > "$WORK/cfg-goodhidden.json"
out="$(PIPELINE_CONFIG="$WORK/cfg-goodhidden.json" gate --no-sandbox)"; rc=$?
check "the gate reports the pass"      "hidden tests" "$out"
if [ "$(jq -r '.hidden_tests.status' ai/runs/R/gate.json 2>/dev/null)" = "passed" ]; then
  printf '  ok    and gate.json says passed\n'; PASS=$((PASS+1))
else
  printf '  FAIL  gate.json: %s\n' "$(jq -c '.hidden_tests' ai/runs/R/gate.json 2>/dev/null)"; FAIL=$((FAIL+1))
fi
# The record identifies WHICH tests ran without being a copy of them, and carries
# no test text at all — gate.json goes to the judge, whose findings reach the
# worker.
if [ -n "$(jq -r '.hidden_tests.dir_sha256 // ""' ai/runs/R/gate.json 2>/dev/null)" ]; then
  printf '  ok    hashed, so it says which without quoting them\n'; PASS=$((PASS+1))
else
  printf '  FAIL  no dir_sha256 in the gate record\n'; FAIL=$((FAIL+1))
fi
nope "and no test text in gate.json"   "test_h" "$(jq -c '.hidden_tests' ai/runs/R/gate.json)"

printf '\n== the bean\x27s own non-goals, over the diff rather than the plan ==\n\n'
#
# spec-check decides this over the PLAN. The gate decides it over what was
# actually written, which is not the same question: a task can stay inside its
# declared write_paths and still add an import the bean forbids, and the plan is a
# promise while the diff is the change.
reset_branch
cat > "$WORK/ng-bean.yaml" <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: e/x
title: t
intent: i
status: approved
allowed_write_paths: ["src/**"]
acceptance_criteria:
  - id: ac1
    text: a
    verify: { kind: command, run: ["true"] }
non_goals:
  - text: no solver code
    forbidden_imports: [ortools]
    forbidden_paths: ["src/**/solver/**"]
YAML
mkdir -p src && printf 'GOOD\n' > src/a.py
commit_all "task-ng-clean"
out="$(bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean "$WORK/ng-bean.yaml" --policy factory/risk-policy.yaml --no-sandbox 2>&1)"
check "a clean diff passes the check"  "non-goals" "$out"
if [ "$(jq -r '.non_goals.checkable_rules' ai/runs/R/gate.json 2>/dev/null)" = "1" ]; then
  printf '  ok    and the gate record counts the rule\n'; PASS=$((PASS+1))
else
  printf '  FAIL  gate.json non_goals: %s\n' "$(jq -c '.non_goals' ai/runs/R/gate.json 2>/dev/null)"; FAIL=$((FAIL+1))
fi

printf '\n-- an import the bean forbids, inside a path it allows --\n\n'
#
# `src/a.py` is inside allowed_write_paths, so containment is clean and every
# gate is green. The only thing that catches this is the bean's own statement of
# what it is not for.
printf 'import ortools\nGOOD\n' > src/a.py
commit_all "task-ng-import"
out="$(bash "$PIPELINE_DIR/gate.sh" ai/runs/R --bean "$WORK/ng-bean.yaml" --policy factory/risk-policy.yaml --no-sandbox 2>&1)"; rc=$?
check "the gate names the non-goal"    "no solver code" "$out"
if [ "$rc" -ne 0 ]; then printf '  ok    and the gate fails\n'; PASS=$((PASS+1))
else printf '  FAIL  a forbidden import left the gate green\n'; FAIL=$((FAIL+1)); fi
if [ "$(jq -r '.non_goals.violations[0].kind' ai/runs/R/gate.json 2>/dev/null)" = "import" ]; then
  printf '  ok    recorded as an import violation\n'; PASS=$((PASS+1))
else
  printf '  FAIL  gate.json non_goals: %s\n' "$(jq -c '.non_goals' ai/runs/R/gate.json 2>/dev/null)"; FAIL=$((FAIL+1))
fi

printf '\n-- a bean whose non-goals are prose is a note, not a pass --\n\n'
#
# Nothing was checked, and the judge is still the only thing between the change
# and the bean's own non-goals. Saying "pass" would claim a check that did not run.
reset_branch
mkdir -p src && printf 'GOOD\n' > src/a.py
commit_all "task-ng-prose"
out="$(gate --no-sandbox)"
check "it says none are machine-readable" "none in machine-readable form" "$out"
check "and whose job they remain"      "remain the audit" "$out"
if grep -E '^(FAIL|fail)' <<<"$out" | grep -q 'non-goals'; then
  printf '  FAIL  a prose-only bean was counted as a gate failure\n'; FAIL=$((FAIL+1))
else
  printf '  ok    and it is not a failing part\n'; PASS=$((PASS+1))
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
