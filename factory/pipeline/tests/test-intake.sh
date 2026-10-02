#!/usr/bin/env bash
# test-intake.sh — the intake refinery's checks and the approval stamp, with no model.
#
# The model's half is a session in the worker sandbox and is exercised on a real
# transcript. What is asserted here is the controller's half, which is the half
# that decides what a person is asked to approve:
#   - an excerpt must be in the transcript, or the item is refused
#   - a draft is schema-checked on save, and a draft cannot approve itself
#   - every criterion has a verify a machine or a named person can run
#   - nothing is drafted over an open question
#   - only `approve` writes status: approved, and only over valid drafts
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PIPELINE_DIR/lib.sh"
PY="$(factory_python)"
INTAKE="$PIPELINE_DIR/intake.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export FACTORY_INTAKE_ROOT="$WORK/intake"

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}

S="$FACTORY_INTAKE_ROOT/demo/s1"
mkdir -p "$S/drafts"
cat > "$S/source.md" <<'EOF'
# Transcript

I would like a tic-tac-toe app. The human user goes first and clicks
on an area inside the grid to perform an X.
EOF
cat > "$S/session.json" <<'EOF'
{"schema": "intake-session/1", "id": "s1", "repo": "acme/demo", "repo_dir": "/nonexistent",
 "source_ref": "t.md", "date": "2026-09-30", "developer_sessions": []}
EOF

# -- extract checks ------------------------------------------------------------
cat > "$S/work-items.yaml" <<'EOF'
items:
  - id: wi-1
    title: Human places an X
    summary: Clicking a cell puts an X there.
    excerpts: ["clicks on an area inside the grid to perform an X"]
  - id: wi-2
    title: Invented
    summary: Something nobody said.
    excerpts: ["the app supports online multiplayer"]
EOF
cat > "$S/questions.yaml" <<'EOF'
questions:
  - id: q-1
    about: [wi-1]
    question: What happens on a draw?
    why: Not said.
    recommendation: Show a draw message.
  - id: q-2
    about: [wi-9]
    question: No recommendation here
    why: x
EOF
out="$("$PY" -c "
import sys; sys.path.insert(0, '$PIPELINE_DIR'); import intake
for f in intake.check_extract(intake.Session.find('$S')): print(f)")"
nope  "an excerpt split across a line break still matches" "wi-1): excerpt" "$out"
check "an excerpt that is not in the transcript is refused" 'excerpt not found in source.md: "the app supports online multiplayer"' "$out"
check "a question without a recommendation is refused" "(q-2): no recommendation" "$out"
check "a question about an unknown item is refused" "about names unknown item wi-9" "$out"

# -- nothing is drafted over an open question ----------------------------------
out="$("$PY" "$INTAKE" draft "$S" 2>&1)"
check "draft refuses while a question is open" "questions still open: q-1, q-2" "$out"
out="$("$PY" "$INTAKE" answer "$S" --set "q-1=Show It's a draw." --accept-all --by tester 2>&1)"
check "answers are recorded" "2 answered, 0 open" "$out"
check "an explicit answer is kept" "Show It's a draw." "$(cat "$S/answers.yaml")"

# -- draft checks --------------------------------------------------------------
good() { # good <id> [deps...]
  local id="$1"; shift
  cat <<EOF
schema_version: bean/2.0.0
id: $id
repo: acme/demo
title: Board model
intent: A board that knows whose turn it is.
status: draft
source: {kind: transcript, ref: source.md, date: "2026-09-30", excerpt: "The human user goes first"}
allowed_write_paths: ["src/demo/board.py", "tests/test_board.py"]
acceptance_criteria:
  - id: ac1
    text: X moves first.
    verify: {kind: test, test_id: "tests/test_board.py::test_x_first"}
  - id: ac2
    text: The window looks right.
    verify: {kind: manual, note: "Open the app and look at the grid."}
size_budget: {max_tasks: 3, max_files: 2, max_diff_lines: 150}
definition_of_done: ["all AC verify pass", "gates green", "spec and impl-detail docs accepted"]
dependencies: [$(IFS=,; echo "$*")]
EOF
}
good bean-001 > "$S/drafts/bean-001.yaml"
good bean-002 bean-001 > "$S/drafts/bean-002.yaml"
good bean-003 bean-001 | sed -e 's/status: draft/status: approved/' \
  -e 's/kind: manual, note: "Open the app and look at the grid."/kind: judge, rubric: looks fine/' \
  -e 's#tests/test_board.py::test_x_first#tests/test_other.py::test_x_first#' \
  -e 's/excerpt: "The human user goes first"/excerpt: "the computer always wins"/' \
  -e '/^size_budget/d' > "$S/drafts/bean-003.yaml"
good bean-004 bean-009 | sed -e 's/^repo: acme\/demo/repo: acme\/other/' > "$S/drafts/bean-004.yaml"

out="$("$PY" "$INTAKE" check "$S" 2>&1)"; rc=$?
check "a valid draft passes" "ok    bean-001" "$out"
check "a valid dependent draft passes" "ok    bean-002" "$out"
check "a draft cannot approve itself" "bean-003.yaml: status 'approved'" "$out"
check "a judge verify is refused" "verify kind judge is not accepted" "$out"
check "a test outside the write paths is refused" "tests/test_other.py is outside allowed_write_paths" "$out"
check "a source excerpt must be in the transcript" "source.excerpt is not found in source.md" "$out"
check "size_budget must be set" "size_budget.max_tasks is not set" "$out"
check "the repo must be the session's" "repo 'acme/other' is not acme/demo" "$out"
check "a dependency must exist" "depends on bean-009, which is not a bean in this intake" "$out"
check "check exits non-zero on findings" "1" "$rc"
check "findings are written for the developer's next round" "bean-003.yaml: status" "$(cat "$S/check-findings.md")"

# -- a bean path the repo's policy does not allow --------------------------------
# The gate enforces the intersection, so this would be built and then rejected
# (tic-tac-toe-py bean-005, README.md, 2026-10-01). Said at check time instead.
R2="$WORK/repo2"; S2="$FACTORY_INTAKE_ROOT/demo/s2"
mkdir -p "$R2/factory" "$S2/drafts"
printf 'repo_allowed_paths:\n  - src/**\n  - tests/**\n' > "$R2/factory/risk-policy.yaml"
git -C "$R2" init -q -b main && git -C "$R2" add -A \
  && git -C "$R2" -c user.email=t@example.com -c user.name=T commit -qm policy
cp "$S/source.md" "$S2/"
sed -e 's/"id": "s1"/"id": "s2"/' -e "s#/nonexistent#$R2#" "$S/session.json" > "$S2/session.json"
good bean-001 | sed 's#allowed_write_paths: \["src/demo/board.py", "tests/test_board.py"\]#allowed_write_paths: ["src/demo/board.py", "tests/test_board.py", "README.md"]#' \
  > "$S2/drafts/bean-001.yaml"
out="$("$PY" "$INTAKE" check "$S2" 2>&1)"
check "a path outside the repo policy is refused" "README.md is outside the repo's repo_allowed_paths" "$out"
nope  "and the paths inside it are not" "src/demo/board.py is outside the repo's" "$out"

# -- approval ------------------------------------------------------------------
out="$("$PY" "$INTAKE" approve "$S" --by tester 2>&1)"
check "approval refuses while drafts fail" "approval stamps only valid beans" "$out"
nope  "nothing was stamped" "approved_by" "$(cat "$S/drafts/bean-001.yaml")"

"$PY" "$INTAKE" reject "$S" bean-003 --why "invented" >/dev/null
"$PY" "$INTAKE" reject "$S" bean-004 --why "wrong repo" >/dev/null
out="$("$PY" "$INTAKE" review "$S" 2>&1)"
check "review lists manual criteria" "bean-001 ac2: Open the app and look at the grid." "$out"
check "review shows a rejection" "bean-003  REJECTED: invented" "$out"
out="$("$PY" "$INTAKE" order "$S" bean-002 bean-001 2>&1)"
check "an order that breaks a dependency is warned" "bean-002 depends on bean-001, which now runs after it" "$out"
out="$("$PY" "$INTAKE" approve "$S" --by tester 2>&1)"
check "approval refuses an order that breaks a dependency" "bean-002 runs before its dependency bean-001" "$out"
"$PY" "$INTAKE" order "$S" bean-001 bean-002 >/dev/null
out="$("$PY" "$INTAKE" approve "$S" --by "Test Owner" 2>&1)"
check "approval stamps the valid beans" "approved 2 bean(s) by Test Owner: bean-001, bean-002" "$out"
b1="$(cat "$S/drafts/bean-001.yaml")"
check "status is approved" "status: approved" "$b1"
check "the approval names who" "approved_by: Test Owner" "$b1"
check "the approval carries the order" "order: 1" "$(cat "$S/drafts/bean-001.yaml")"
check "a rejected bean stays rejected" "status: rejected" "$(cat "$S/drafts/bean-003.yaml")"
out="$("$PY" "$PIPELINE_DIR/../../bench/validate.py" bean "$S/drafts/bean-001.yaml" "$S/drafts/bean-002.yaml")"
check "the stamped beans are schema-valid" "2 payload(s) against bean.schema.json, 0 invalid" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
