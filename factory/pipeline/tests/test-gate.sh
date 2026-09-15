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
  unset FACTORY_SANDBOX_ROOT
else
  printf '  SKIP  podman or the gate image unavailable; execution not exercised\n'
fi

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
