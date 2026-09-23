#!/usr/bin/env bash
# test-build-loop.sh — the properties the task loop exists to provide.
#
# These run with a stub `pi` whose every attempt is scripted, so the loop's
# behaviour is observed rather than hoped for. The cases are the ones that
# matter when a 27B is on the other end of the loop: it will write outside its
# paths, it will declare a task done that is not, and it will sometimes make no
# progress at all across three sessions. Each of those must end somewhere
# specific.
#
# Every negative case asserts the *specific* outcome, never merely non-zero:
# "the attempt was rejected AND the in-scope work was discarded too AND the
# feedback names the offending file" is the property. A test that only checks
# the exit code would pass against a loop that silently stripped the bad file.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() { # check <name> <expected-substring> <actual>
  if grep -qF -- "$2" <<<"$3"; then
    printf '  ok    %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n          expected to find: %s\n          got: %s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}
want() { # want <name> <condition-description> <test-command...>
  local name="$1"; shift
  local desc="$1"; shift
  if "$@"; then
    printf '  ok    %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %s — %s\n' "$name" "$desc"; FAIL=$((FAIL + 1))
  fi
}
nope() { # nope <name> <condition-description> <test-command...>
  local name="$1"; shift
  local desc="$1"; shift
  if "$@"; then
    printf '  FAIL  %s — %s\n' "$name" "$desc"; FAIL=$((FAIL + 1))
  else
    printf '  ok    %s\n' "$name"; PASS=$((PASS + 1))
  fi
}

# -- the stub worker -----------------------------------------------------------
# It plays the part of a pi session: parses the attempt directory out of its
# prompt, runs whatever the test scripted for that (task, attempt), and writes a
# session file so run-step.sh can observe the conditions it now records.
cat > "$WORK/stub-pi" <<'STUB'
#!/usr/bin/env bash
prompt=""; model=""; thinking=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="$2"; shift 2 ;;
    --model) model="${2#*/}"; shift 2 ;;
    --thinking) thinking="$2"; shift 2 ;;
    *) shift ;;
  esac
done
sess="${PI_SESSIONS_DIR:-.}/stub-$(date +%s%N).jsonl"
mkdir -p "$(dirname "$sess")"
{
  printf '{"type":"session","version":"stub","id":"stub","cwd":"%s"}\n' "$PWD"
  [ -n "$model" ]    && printf '{"type":"model_change","model":"%s"}\n' "$model"
  [ -n "$thinking" ] && printf '{"type":"thinking_level_change","thinkingLevel":"%s"}\n' "$thinking"
} > "$sess"

# /skill:factory-build-task <run_dir> <task-id> <attempt-dir>
adir="${prompt##* }"
rest="${prompt% *}"
task="${rest##* }"
attempt="$(basename "$adir")"; attempt="${attempt#attempt-}"
printf 'STUB-PI  task=%s attempt=%s\n' "$task" "$attempt"

action="$STUB_ACTIONS/$task.$attempt"
if [ -x "$action" ]; then
  ATTEMPT_DIR="$adir" TASK_ID="$task" ATTEMPT="$attempt" bash "$action"
  exit $?
fi
exit 0
STUB
chmod +x "$WORK/stub-pi"

mkdir -p "$WORK/actions"
act() { # act <task>.<attempt> <<'SH' ... SH
  cat > "$WORK/actions/$1"
  chmod +x "$WORK/actions/$1"
}

# -- fixture -------------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO"
git init -q -b main .
git config user.email t@example.com
git config user.name "Test"
mkdir -p src tests ai/runs/R1
echo "placeholder" > README.md
# Run directories are evidence, not source: a target repo keeps them out of the
# index. They must also survive a branch switch, which is how this fixture found
# out it had been committing them.
printf 'ai/runs/\n' > .gitignore
git add -A && git commit -q -m "init"
git checkout -q -b bean/bean-001-loop

cat > bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: example/x
title: A bean with two tasks
intent: Exercise the loop.
status: approved
allowed_write_paths:
  - src/**
  - tests/**
acceptance_criteria:
  - id: ac1
    text: a.py says GOOD
    verify: { kind: command, run: ["sh", "-c", "grep -q GOOD src/a.py"] }
  - id: ac2
    text: b.py exists
    verify: { kind: command, run: ["sh", "-c", "test -f src/b.py"] }
definition_of_done:
  - all AC verify pass
YAML

# task-2 is authored FIRST and depends on task-1, so a loop that simply walked
# the file in order would run them backwards.
cat > tasks.yaml <<'YAML'
schema_version: tasks/1.0.0
bean_id: bean-001
tasks:
  - id: task-2
    title: Add b.py
    intent: Create src/b.py.
    depends_on: [task-1]
    write_paths: [src/b.py]
    satisfies: [ac2]
    verify:
      - { kind: command, run: ["sh", "-c", "test -f src/b.py"] }
  - id: task-1
    title: Add a.py saying GOOD
    intent: Create src/a.py containing GOOD.
    write_paths: [src/a.py]
    satisfies: [ac1]
    max_attempts: 3
    verify:
      - { kind: command, run: ["sh", "-c", "grep -q GOOD src/a.py"] }
YAML

RUN_DIR="$REPO/ai/runs/R1"
cat > "$RUN_DIR/run.json" <<'JSON'
{"run_id":"R1","bean":"bean-001","branch":"bean/bean-001-loop","status":"running"}
JSON

# FACTORY_CONTAIN_WORKER=0: the stub pi is not in a container and cannot be. The
# factory ships a worker manifest, so containment is the default now, and without
# this every scenario here would fail at sandbox startup rather than testing the
# loop.
run_loop() {
  PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" STUB_ACTIONS="$WORK/actions" FACTORY_CONTAIN_WORKER=0 \
    bash "$PIPELINE_DIR/build-loop.sh" "$RUN_DIR" \
      --bean "$REPO/bean.yaml" --tasks "$REPO/tasks.yaml" "$@" 2>&1
}
reset_run() {
  rm -rf "$RUN_DIR/build" "$RUN_DIR/tasks.jsonl" "$RUN_DIR/steps.jsonl"
  cat > "$RUN_DIR/run.json" <<'JSON'
{"run_id":"R1","bean":"bean-001","branch":"bean/bean-001-loop","status":"running"}
JSON
  git -C "$REPO" checkout -q bean/bean-001-loop
  git -C "$REPO" reset -q --hard "$BASE_SHA"
  git -C "$REPO" clean -fdq -e /ai
  rm -f "$WORK/actions"/*
}

# bean.yaml and tasks.yaml are committed so `git clean` during a reset cannot
# eat the loop's own inputs.
git add -A && git commit -q -m "bean and tasks"
BASE_SHA="$(git rev-parse HEAD)"

printf '\n== the plan: dependency order, not file order ==\n\n'
out="$(run_loop --dry-run)"
order="$(grep -oE 'task-[0-9]' <<<"$out" | head -2 | tr '\n' ' ')"
check "dry run orders by dependency"   "1. task-1" "$out"
check "dry run puts task-2 second"     "2. task-2" "$out"
check "dry run shows the write paths"  "write_paths: src/a.py" "$out"

printf '\n== happy path ==\n\n'
act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
act task-2.1 <<'SH'
mkdir -p src && printf 'b\n' > src/b.py
SH
out="$(run_loop)"; rc=$?
check "loop reports completion"        "BUILD COMPLETE  2 task(s) verified" "$out"
want "loop exits 0"                    "expected exit 0" test "$rc" -eq 0
want "task-1 committed on its own"     "expected a commit for task-1" \
  bash -c "git -C '$REPO' log --oneline | grep -q 'build(task-1)'"
want "task-2 committed on its own"     "expected a commit for task-2" \
  bash -c "git -C '$REPO' log --oneline | grep -q 'build(task-2)'"
want "tree is clean after the loop"    "expected no uncommitted worker files" \
  bash -c "[ -z \"\$(git -C '$REPO' status --porcelain -- src tests)\" ]"
check "telemetry records the outcome"  '"event":"task","task":"task-1","result":"verified"' \
  "$(tr -d ' ' < "$RUN_DIR/tasks.jsonl")"

printf '\n== resume: a verified task is not redone ==\n\n'
out="$(run_loop)"
check "verified tasks are skipped"     "SKIP   task-1     already verified" "$out"
check "nothing left to do"             "BUILD COMPLETE  0 task(s) verified, 2 already done" "$out"

reset_run

printf '\n== an edit outside write_paths is rejected, not stripped ==\n\n'
act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
printf 'oops\n' > escaped.txt
mkdir -p tests && printf 'x\n' > tests/stray.py
SH
act task-1.2 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
act task-2.1 <<'SH'
mkdir -p src && printf 'b\n' > src/b.py
SH
out="$(run_loop)"
check "attempt 1 is a containment failure" "FAIL   task-1     attempt 1: containment_violation" "$out"
nope "the out-of-path file is gone"        "escaped.txt survived the reset" test -f "$REPO/escaped.txt"
nope "in-path work is discarded too"       "tests/stray.py survived; the whole attempt must go" test -f "$REPO/tests/stray.py"
fb="$(cat "$RUN_DIR/build/task-1/attempt-2/feedback.md")"
check "feedback names the offending file"  "escaped.txt" "$fb"
check "feedback says the attempt was discarded" "discarded and the tree reset" "$fb"
check "feedback lists the allowed paths"   "- src/a.py" "$fb"
check "containment evidence is kept"       '"contained":false' \
  "$(tr -d ' \n' < "$RUN_DIR/build/task-1/attempt-1/containment.json")"
check "the retry then succeeds"            "PASS   task-1     verified on attempt 2" "$out"

# A stray file inside the bean's paths but outside the TASK's paths is still a
# violation: the task list is the tighter bound and it is the one being tested.
check "task paths bind, not just bean paths" "tests/stray.py" \
  "$(jq -rc '.violations_task[]' "$RUN_DIR/build/task-1/attempt-1/containment.json" | tr '\n' ' ')"

printf '\n== the reset must not eat the evidence ==\n\n'
want "the run dir survived the reset"      "the loop reset away its own evidence" \
  test -f "$RUN_DIR/build/task-1/attempt-1/containment.json"
want "the worker log survived"             "worker.log was cleaned away" \
  test -f "$RUN_DIR/build/task-1/attempt-1/worker.log"

reset_run

printf '\n== a failed verify keeps the edits and feeds back the real output ==\n\n'
act task-1.1 <<'SH'
mkdir -p src && printf 'BAD\n' > src/a.py
SH
act task-1.2 <<'SH'
test -f src/a.py || { echo "previous attempt was discarded"; exit 1; }
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
act task-2.1 <<'SH'
mkdir -p src && printf 'b\n' > src/b.py
SH
out="$(run_loop)"
check "attempt 1 fails verification"   "FAIL   task-1     attempt 1: verify_failed" "$out"
fb="$(cat "$RUN_DIR/build/task-1/attempt-2/feedback.md")"
check "feedback says edits are kept"   "Your edits are kept" "$fb"
check "feedback carries the command"   "grep -q GOOD src/a.py" "$fb"
check "verify result is recorded"      '"status":"fail"' \
  "$(tr -d ' \n' < "$RUN_DIR/build/task-1/attempt-1/verify-failed.json")"
check "the retry succeeds"             "PASS   task-1     verified on attempt 2" "$out"

reset_run

printf '\n== attempts run out: blocked, with evidence ==\n\n'
act task-1.1 <<'SH'
mkdir -p src && printf 'BAD\n' > src/a.py
SH
act task-1.2 <<'SH'
mkdir -p src && printf 'STILL BAD\n' > src/a.py
SH
act task-1.3 <<'SH'
mkdir -p src && printf 'NOPE\n' > src/a.py
SH
out="$(run_loop)"; rc=$?
want "blocked exits 4"                 "expected exit 4 (blocked)" test "$rc" -eq 4
check "the block is announced"         "BLOCKED  task-1 exhausted its attempts" "$out"
want "BLOCKED.md is written"           "expected build/task-1/BLOCKED.md" \
  test -f "$RUN_DIR/build/task-1/BLOCKED.md"
bl="$(cat "$RUN_DIR/build/task-1/BLOCKED.md")"
check "every attempt is listed"        "attempt 3" "$bl"
check "the last failure is quoted"     "grep -q GOOD src/a.py" "$bl"
check "it asks a human the real question" "Is the task wrong" "$bl"
check "run.json records the block"     '"status":"blocked"' "$(tr -d ' \n' < "$RUN_DIR/run.json")"
nope "the later task never ran"        "task-2 ran despite task-1 blocking" \
  test -d "$RUN_DIR/build/task-2"
nope "nothing was committed"           "a failed task must not be committed" \
  bash -c "git -C '$REPO' log --oneline | grep -q 'build(task-1)'"

reset_run

printf '\n== a worker that changes nothing is not a pass ==\n\n'
act task-1.1 <<'SH'
exit 0
SH
act task-1.2 <<'SH'
exit 0
SH
act task-1.3 <<'SH'
exit 0
SH
out="$(run_loop)"; rc=$?
check "no-change attempts are failures" "attempt 1: no_changes" "$out"
want "and they block like any other"    "expected exit 4" test "$rc" -eq 4

reset_run

printf '\n== the loop refuses inputs it cannot bound ==\n\n'
cat > "$WORK/bad-tasks.yaml" <<'YAML'
schema_version: tasks/1.0.0
bean_id: bean-001
tasks:
  - id: task-1
    title: Escape
    intent: Write outside the bean.
    write_paths: [/etc/passwd, deploy/prod.yaml]
    verify: [{ kind: command, run: ["true"] }]
YAML
out="$(PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" STUB_ACTIONS="$WORK/actions" FACTORY_CONTAIN_WORKER=0 \
  bash "$PIPELINE_DIR/build-loop.sh" "$RUN_DIR" --bean "$REPO/bean.yaml" --tasks "$WORK/bad-tasks.yaml" 2>&1)"
check "task paths outside the bean are refused" "outside the bean's allowed_write_paths" "$out"
check "and it names the offender"               "deploy/prod.yaml" "$out"

cat > "$WORK/cycle-tasks.yaml" <<'YAML'
schema_version: tasks/1.0.0
bean_id: bean-001
tasks:
  - id: task-1
    title: A
    intent: a
    depends_on: [task-2]
    write_paths: [src/a.py]
    verify: [{ kind: command, run: ["true"] }]
  - id: task-2
    title: B
    intent: b
    depends_on: [task-1]
    write_paths: [src/b.py]
    verify: [{ kind: command, run: ["true"] }]
YAML
out="$(PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" STUB_ACTIONS="$WORK/actions" FACTORY_CONTAIN_WORKER=0 \
  bash "$PIPELINE_DIR/build-loop.sh" "$RUN_DIR" --bean "$REPO/bean.yaml" --tasks "$WORK/cycle-tasks.yaml" 2>&1)"
check "a dependency cycle is caught"   "dependency cycle" "$out"

cat > "$WORK/other-bean-tasks.yaml" <<'YAML'
schema_version: tasks/1.0.0
bean_id: bean-999
tasks:
  - id: task-1
    title: A
    intent: a
    write_paths: [src/a.py]
    verify: [{ kind: command, run: ["true"] }]
YAML
out="$(PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" STUB_ACTIONS="$WORK/actions" FACTORY_CONTAIN_WORKER=0 \
  bash "$PIPELINE_DIR/build-loop.sh" "$RUN_DIR" --bean "$REPO/bean.yaml" --tasks "$WORK/other-bean-tasks.yaml" 2>&1)"
check "a task list for another bean is refused" "task list is for 'bean-999'" "$out"

printf '\n== a dirty tree cannot be blamed on the worker ==\n\n'
mkdir -p "$REPO/src"
printf 'unrelated\n' > "$REPO/src/preexisting.py"
out="$(run_loop)"
check "a dirty tree stops the loop"    "working tree is dirty before the loop starts" "$out"
check "and it says which files"        "src/preexisting.py" "$out"
rm -f "$REPO/src/preexisting.py"
reset_run

printf '\n== the loop never runs on main ==\n\n'
git -C "$REPO" checkout -q main
out="$(run_loop)"
check "main is refused"                "refusing to run the build loop on main" "$out"
git -C "$REPO" checkout -q bean/bean-001-loop

printf '\n== verify kinds that cannot be machine-checked are failures, not passes ==\n\n'
out="$(bash "$PIPELINE_DIR/verify.sh" '{"kind":"manual","note":"a human looks at it"}' 2>&1)"; rc=$?
check "manual is refused"              '"status":"unrunnable"' "$(tr -d ' ' <<<"$out")"
want "manual exits non-zero"           "a manual verify must never pass" test "$rc" -ne 0
out="$(bash "$PIPELINE_DIR/verify.sh" '{"kind":"judge","rubric":"is it nice"}' 2>&1)"; rc=$?
check "judge is refused in the loop"   '"status":"unrunnable"' "$(tr -d ' ' <<<"$out")"
want "judge exits non-zero"            "a judge verify must not pass silently here" test "$rc" -ne 0
out="$(bash "$PIPELINE_DIR/verify.sh" '{"kind":"gate","gate_id":"nonexistent"}' 2>&1)"; rc=$?
check "an undefined gate is refused"   "is not defined" "$out"
want "undefined gate exits non-zero"   "an undefined gate must not pass" test "$rc" -ne 0
out="$(bash "$PIPELINE_DIR/verify.sh" '{"kind":"nonsense"}' 2>&1)"
check "an unknown kind is refused"     "unknown verify kind" "$out"

printf '\n== an argv element with a newline in it is ONE element ==\n\n'
# bean-004's task-1 verify was `python -c "<31-line script>"`. verify.sh read the
# argv with `mapfile -t < <(jq -r '.run[]')`, which splits on newlines, so it ran
# `python -c 'import sqlite3, tempfile'` with the other thirty lines as sys.argv
# — and passed. The script's second assertion called the one branch of
# AuditLog.entries that is a SQL syntax error, and the bug shipped with a
# verified task in front of it. A multi-line `python -c` is the commonest verify
# a spec writes, so the whole script has to arrive, and a failure on its LAST
# line has to be a failure.
out="$(bash "$PIPELINE_DIR/verify.sh" '{"kind":"command","run":["python3","-c","import sys\nsys.exit(3)"]}' 2>&1)"; rc=$?
want "a multi-line script's last line runs" "exit 3 on line 2 must fail the verify (rc=$rc)" test "$rc" -ne 0
check "and it is reported as a failure" '"status":"fail"' "$(tr -d ' ' <<<"$out")"
out="$(bash "$PIPELINE_DIR/verify.sh" '{"kind":"command","run":["python3","-c","import sys\nassert sys.argv[1:] == [\"a\\nb\", \"\"], sys.argv","a\nb",""]}' 2>&1)"; rc=$?
want "newlines and empty elements survive into argv" "argv was not passed through intact: $out" test "$rc" -eq 0

printf '\n== with --sandbox, the verify runs in the gate container ==\n\n'
if command -v podman >/dev/null 2>&1 && podman image exists localhost/factory-gate-python:20260914 2>/dev/null; then
  reset_run
  act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
  act task-2.1 <<'SH'
mkdir -p src && printf 'b\n' > src/b.py
SH
  export FACTORY_SANDBOX_ROOT="$WORK/sandboxes"
  out="$(run_loop --sandbox --gates "$PIPELINE_DIR/../scaffold/factory/gates.lock.yaml")"
  check "the loop announces the sandbox"  "SANDBOX" "$out"
  check "and still verifies the task"     "PASS   task-1     verified on attempt 1" "$out"
  check "the verify records where it ran" '"ran_in":"sandbox"' \
    "$(tr -d ' \n' < "$RUN_DIR/build/task-1/attempt-1/verify-1.json")"
  tree="$WORK/sandboxes/darkfactory/$(basename "$RUN_DIR")/tree"
  want "the container's tree exists"      "expected a synced editable tree" test -d "$tree"
  nope "and it carries no .git"           ".git reached the container — the boundary is open" \
    test -e "$tree/.git"
  want "the worker's file reached it"     "the synced tree is missing the change under test" \
    test -f "$tree/src/a.py"

  # A test is code the model wrote. This one tries to leave the tree.
  reset_run
  cat > "$WORK/escape-tasks.yaml" <<'YAML'
schema_version: tasks/1.0.0
bean_id: bean-001
tasks:
  - id: task-1
    title: A verify that tries to escape
    intent: Prove the sandbox stops a test, not just a worker.
    write_paths: [src/a.py]
    max_attempts: 1
    verify:
      - { kind: command, run: ["sh", "-c", "touch /escaped && echo ESCAPED"] }
YAML
  act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD
' > src/a.py
SH
  out="$(PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" STUB_ACTIONS="$WORK/actions" FACTORY_CONTAIN_WORKER=0 \
    bash "$PIPELINE_DIR/build-loop.sh" "$RUN_DIR" --bean "$REPO/bean.yaml" \
      --tasks "$WORK/escape-tasks.yaml" --sandbox \
      --gates "$PIPELINE_DIR/../scaffold/factory/gates.lock.yaml" 2>&1)"
  # Assert against what the verify actually printed, not against the loop's
  # transcript: the transcript quotes the failing command back, so the escape
  # marker appears there whether or not the escape worked.
  vlog="$(cat "$RUN_DIR/build/task-1/attempt-1/verify-1.log" 2>/dev/null)"
  if grep -qF "ESCAPED" <<<"$vlog"; then
    printf '  FAIL  a verify escaped the tree — it wrote outside and said so\n'; FAIL=$((FAIL+1))
  else
    printf '  ok    a verify cannot write outside the tree\n'; PASS=$((PASS+1))
  fi
  check "and the attempt is told why"     "Read-only file system" "$vlog"
  check "and the task blocks on it"       "BLOCKED  task-1" "$out"
  unset FACTORY_SANDBOX_ROOT
else
  printf '  SKIP  podman or the gate image is unavailable; sandbox mode not exercised\n'
fi

printf '\n== containment matcher: dotfiles are paths, not prefixes to strip ==\n\n'
# Found on the first real run. `lstrip("./")` strips CHARACTERS, so `.gitignore`
# became `gitignore` and failed to match its own pattern — the bean explicitly
# allowed it and the controller called the model's correct plan an escape.
viol="$(printf '.gitignore\n.github/workflows/ci.yml\n' | python3 "$PIPELINE_DIR/contain.py" --patterns '[".gitignore",".github/**"]' || true)"
if [ -z "$viol" ]; then
  printf '  ok    a dotfile matches its own pattern\n'; PASS=$((PASS+1))
else
  printf '  FAIL  a dotfile was mangled into a violation: %s\n' "$viol"; FAIL=$((FAIL+1))
fi
viol="$(printf './src/a.py\n' | python3 "$PIPELINE_DIR/contain.py" --patterns '["src/**"]' || true)"
if [ -z "$viol" ]; then
  printf '  ok    a leading ./ is still stripped\n'; PASS=$((PASS+1))
else
  printf '  FAIL  ./src/a.py should match src/**\n'; FAIL=$((FAIL+1))
fi
viol="$(printf '.secret\n' | python3 "$PIPELINE_DIR/contain.py" --patterns '["src/**"]' || true)"
if [ -n "$viol" ]; then
  printf '  ok    and a dotfile outside the paths is still a violation\n'; PASS=$((PASS+1))
else
  printf '  FAIL  .secret should not match src/**\n'; FAIL=$((FAIL+1))
fi

printf '\n== containment matcher: * does not cross a slash ==\n\n'
viol="$(printf 'src/a.py\nsrc/deep/evil.py\n' | python3 "$PIPELINE_DIR/contain.py" --patterns '["src/*.py"]' || true)"
check "nested path is a violation"     "src/deep/evil.py" "$viol"
nope "shallow path is not"             "src/a.py was wrongly flagged" grep -q "src/a.py" <<<"$viol"
viol="$(printf 'src/deep/evil.py\n' | python3 "$PIPELINE_DIR/contain.py" --patterns '["src/**"]' || true)"
want "** does cross slashes"           "src/** should match a nested path" test -z "$viol"

printf '\n== a worker that writes into the run record blocks the bean ==\n\n'
#
# The run directory is exempt from the change scan so that evidence survives the
# reset. That exemption is exactly what makes this worth a test: without the
# hash-and-compare, a session editing the record of its own attempts would leave
# no trace anywhere — the scan skips it and `git status` never sees it, because
# the run dir is gitignored.
reset_run
printf 'a prior verdict the worker should not be able to reach\n' > "$RUN_DIR/spec.md"
act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
# ... and, on the way past, quietly improve the record.
printf 'a much more flattering account\n' > "$ATTEMPT_DIR/../../../spec.md"
SH
out="$(run_loop)"; rc=$?

check "the loop names it"              "TAMPERED" "$out"
check "and says which file"            "spec.md" "$out"
check "it does not try again"          "not retrying" "$out"
want  "the bean is blocked"            "expected exit 4" test "$rc" -eq 4
want  "the tampering is kept as evidence" "touched-the-record.txt should exist" \
      test -f "$RUN_DIR/build/task-1/attempt-1/touched-the-record.txt"
check "the attempt is recorded as tampered" '"result":"tampered"' \
      "$(tr -d ' ' < "$RUN_DIR/build/task-1/attempt-1/result.json")"
want  "only one attempt was made"      "expected exactly 1 attempt dir" \
      test "$(ls -1d "$RUN_DIR"/build/task-1/attempt-* | wc -l)" -eq 1
nope  "and nothing was committed"      "task-1 should not have been committed" \
      git -C "$REPO" log --oneline -1 --format=%s | grep -q task-1

printf '\n== the controller\'s own writes are never tampering, however the path was typed ==\n\n'
#
# The run directory is passed to build-loop.sh as whatever the caller typed, and
# `factory run` types a relative path. `find` emits absolute ones. The attempt
# directory exemption compared the two directly, matched nothing, and the first
# real build attempt of bean-001 was failed for tampering by this script's own
# worker.log — written into the attempt directory during the session it was
# measuring. A containment check that accuses the controller is worse than none.
reset_run
act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
out="$(cd "$REPO" && PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" \
  STUB_ACTIONS="$WORK/actions" FACTORY_CONTAIN_WORKER=0 \
  bash "$PIPELINE_DIR/build-loop.sh" ai/runs/R1 \
    --bean "$REPO/bean.yaml" --tasks "$REPO/tasks.yaml" --task task-1 2>&1)"
nope  "a relative run dir does not produce a false accusation" "TAMPERED" "$out"
check "and the task verifies"  "PASS   task-1" "$out"

printf '\n== but its own attempt directory is its channel, not the record ==\n\n'
reset_run
act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
printf '# I could not tell what this task wanted\n' > "$ATTEMPT_DIR/QUESTIONS.md"
SH
out="$(run_loop --task task-1)"
nope  "writing to its own attempt dir is not tampering" "QUESTIONS.md was treated as tampering" \
      grep -q TAMPERED <<<"$out"
check "and the task still verifies"    "PASS   task-1" "$out"

printf '\n== running verifies on the host is announced, never silent ==\n\n'
#
# bean-001's first real build ran its task verifies on the host because
# orchestrate.sh never passed --sandbox, and the host has no `python` — the
# pinned toolchain lives in the gate image. The task failed with "command not
# found" and the worker was told its code did not verify. It had not been checked
# at all. The sandbox is now the default; this asserts that when it cannot be, the
# run says so rather than quietly producing host-shaped answers.
reset_run
act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
out="$(run_loop --task task-1 --no-sandbox)"
check "the run says it is uncontained" "UNCONTAINED" "$out"
check "and says why it matters"        "environment the pinned toolchain lives in" "$out"

printf '\n== every task runs, even when the worker reads stdin ==\n\n'
#
# bean-001 built task-1, verified it, committed it, and announced "BUILD COMPLETE
# 1 task(s) verified" with two tasks never attempted. The spec was fine and the
# ordering was fine: the loop read its task list from stdin, and the worker
# session inside the loop reads stdin too, so pi consumed the remaining ids.
#
# A silent, plausible success is the worst failure this line can produce, so the
# stub here deliberately drains stdin the way a real agent does.
reset_run
cat > "$WORK/stub-drains-stdin" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true   # what pi does, and what ate the task list
exec "$STUB_REAL" "$@"
STUB
chmod +x "$WORK/stub-drains-stdin"

act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
act task-2.1 <<'SH'
mkdir -p src && printf 'b\n' > src/b.py
SH
out="$(PI_BIN="$WORK/stub-drains-stdin" STUB_REAL="$WORK/stub-pi" \
       PI_SESSIONS_DIR="$WORK/sessions" STUB_ACTIONS="$WORK/actions" \
       FACTORY_CONTAIN_WORKER=0 \
       bash "$PIPELINE_DIR/build-loop.sh" "$RUN_DIR" \
         --bean "$REPO/bean.yaml" --tasks "$REPO/tasks.yaml" --no-sandbox 2>&1)"
check "the first task runs"   "PASS   task-1" "$out"
check "and so does the second" "PASS   task-2" "$out"
check "both are counted"      "2 task(s) verified" "$out"

printf '\n== a task the remote gates sent back is rebuilt, once ==\n\n'
#
# ci.sh writes `reopened-tasks.txt` when a required check fails: the tasks whose
# write paths the failing log names. The build loop treats those as unverified
# again, and the earlier `verified` line stays in tasks.jsonl — it happened, and
# what changed is that something else found a problem this machine did not.
#
# The half that is easy to get wrong is the other one: left in place after a
# successful rebuild, the list would make every later resume rebuild the same
# tasks and the run could never finish.
reset_run
rm -f "$WORK/actions"/*
act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
act task-2.1 <<'SH'
mkdir -p src && printf 'second\n' > src/b.py
SH
run_loop > "$WORK/o-first" 2>&1 || true
first="$(cat "$WORK/o-first")"
check "the first build verifies both"  "2 task(s) verified" "$first"

# CI sends task-1 back. Its action is needed again; task-2's must not be.
act task-1.2 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
printf 'task-1\n' > "$RUN_DIR/reopened-tasks.txt"
run_loop > "$WORK/o-reopen" 2>&1 || true
reopened="$(cat "$WORK/o-reopen")"
check "the named task is built again"  "TASK   task-1" "$reopened"
check "and the other one is skipped"   "SKIP   task-2     already verified" "$reopened"
check "which the loop says out loud"   "REBUILT the tasks the remote gates sent back" "$reopened"
want  "the list is consumed"           "reopened-tasks.txt must not survive a complete rebuild" \
      test ! -f "$RUN_DIR/reopened-tasks.txt"
want  "but kept as evidence"           "the list should be filed under ci/" \
      bash -c 'ls "$0"/ci/reopened-tasks.*.txt >/dev/null 2>&1' "$RUN_DIR"

run_loop > "$WORK/o-third" 2>&1 || true
third="$(cat "$WORK/o-third")"
nope  "a later run rebuilds nothing"   "task-1 must not be attempted a third time" \
      grep -qF "ATTEMPT 1/3  task-1" <<<"$third"
check "everything is already done"     "already done" "$third"

printf '\n== a build-task step records how long it really took ==\n\n'
#
# `factory status` on the first complete run showed every build-task attempt at
# 0s while the `build` step around them showed 1136s — and the tasks took 947, 89
# and 95 seconds of model time. Both boundaries were being written at the end.
# A per-attempt duration of zero is the number every later question about cost
# reads from, and it is silently wrong rather than missing.
reset_run
rm -f "$WORK/actions"/*
act task-1.1 <<'SH'
sleep 2
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
act task-2.1 <<'SH'
mkdir -p src && printf 'second\n' > src/b.py
SH
run_loop > "$WORK/o-elapsed" 2>&1 || true
bt_elapsed="$(jq -rs '
  def t($x): ($x | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601);
  [.[] | select(.step == "build-task" and .attempt == 1)] as $r
  | if ($r | length) < 2 then 0 else (t($r[-1].ts) - t($r[0].ts)) end' \
  "$RUN_DIR/steps.jsonl" 2>/dev/null || echo 0)"
if [ "${bt_elapsed:-0}" -ge 2 ] 2>/dev/null; then
  printf '  ok    the boundaries are two seconds apart (%ss)\n' "$bt_elapsed"; PASS=$((PASS + 1))
else
  printf '  FAIL  the boundaries are %ss apart for work that took at least 2\n' "${bt_elapsed:-0}"; FAIL=$((FAIL + 1))
fi
# And independently of the boundaries: the end line carries a duration measured
# in the process that ran the step, so a bad start stamp cannot make a long step
# look instantaneous. On the first complete run every build-task attempt read 0s.
bt_dur="$(jq -rs '[.[] | select(.step == "build-task" and .attempt == 1 and .event == "end")] | last.duration_s // -1' \
  "$RUN_DIR/steps.jsonl" 2>/dev/null || echo -1)"
if [ "${bt_dur:--1}" -ge 2 ] 2>/dev/null; then
  printf '  ok    and the end line says so on its own (%ss)\n' "$bt_dur"; PASS=$((PASS + 1))
else
  printf '  FAIL  duration_s on the end line is %s, for work that took at least 2\n' "${bt_dur:--1}"; FAIL=$((FAIL + 1))
fi

printf '\n== a containment check that cannot run does not mean contained ==\n\n'
#
# `|| true` swallows exit 1 (violations found, output is the answer) and exit 2
# (contain.py refusing to run) alike, and both produce empty output — so a crashed
# check reports a clean diff and the attempt passes the one boundary this loop
# exists to enforce. gate.sh was fixed for this and this copy was not; the gate is
# the second line of defence, and this is the first, running once per attempt.
reset_run
rm -f "$WORK/actions"/*
act task-1.1 <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
# A contain.py that refuses. Shadowed on PATH is not enough — the loop calls it by
# path — so the fixture points PIPELINE_DIR's copy at a stub for one run.
BROKEN="$WORK/broken-pipeline"; rm -rf "$BROKEN"; cp -r "$PIPELINE_DIR" "$BROKEN"
cat > "$BROKEN/contain.py" <<'PYSTUB'
import sys
print("contain.py: patterns are not JSON", file=sys.stderr)
sys.exit(2)
PYSTUB
out="$(PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" STUB_ACTIONS="$WORK/actions" \
  FACTORY_CONTAIN_WORKER=0 bash "$BROKEN/build-loop.sh" "$RUN_DIR" \
  --bean "$REPO/bean.yaml" --tasks "$REPO/tasks.yaml" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  printf '  ok    it refuses rather than passing (exit %s)\n' "$rc"; PASS=$((PASS + 1))
else
  printf '  FAIL  a broken containment check let the loop proceed\n'; FAIL=$((FAIL + 1))
fi
check "and says the check did not run" "the check did not run" "$out"
# nope() in this file takes a COMMAND, not a string — the one above and this one
# are different helpers than in the other suites, and passing text here runs it.
if grep -qF "outside the bean" <<<"$out"; then
  printf '  FAIL  it blamed the task paths for a check that did not run\n'; FAIL=$((FAIL + 1))
else
  printf '  ok    and does not blame the task paths\n'; PASS=$((PASS + 1))
fi
nope  "no attempt is recorded contained"  "a broken check must not produce a contained record" \
      grep -rq 'contained": true' "$RUN_DIR/build" 2>/dev/null

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
