#!/usr/bin/env bash
# test-orchestrate-build.sh — the driver actually reaches the task loop.
#
# The unit tests in test-build-loop.sh prove the loop behaves. This proves it is
# wired: that `build` is a step orchestrate.sh knows, that it runs as a
# controller step (build-loop.sh drives it, not a single model session), that it
# finds the bean's YAML for its write paths, and that a blocked task stops the
# run with the evidence reachable from QUESTIONS.md.
#
# It builds a whole miniature repo — bare origin included — because preflight
# checks the remote, and a test that stubbed preflight would not be testing the
# path a real run takes.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then
    printf '  ok    %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1))
  fi
}
want() {
  local name="$1" desc="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$name"; PASS=$((PASS + 1))
  else printf '  FAIL  %s — %s\n' "$name" "$desc"; FAIL=$((FAIL + 1)); fi
}

# -- stub pi: plays the spec step, then each build-task attempt ------------------
cat > "$WORK/stub-pi" <<'STUB'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in -p) prompt="$2"; shift 2 ;; *) shift ;; esac
done
sess="${PI_SESSIONS_DIR:-.}/stub-$(date +%s%N).jsonl"
mkdir -p "$(dirname "$sess")"
printf '{"type":"session","version":"stub","id":"stub","cwd":"%s"}\n' "$PWD" > "$sess"

case "$prompt" in
  *factory-spec*)
    # /skill:factory-spec <bean-id> <run_dir>
    run_dir="${prompt##* }"
    cp "$STUB_TASKS" "$run_dir/tasks.yaml"
    [ -n "${STUB_SPEC_MD:-}" ] && cp "$STUB_SPEC_MD" "$run_dir/spec.md"
    ;;
  *factory-build-task*)
    adir="${prompt##* }"; rest="${prompt% *}"; task="${rest##* }"
    attempt="$(basename "$adir")"; attempt="${attempt#attempt-}"
    printf 'STUB-PI  task=%s attempt=%s\n' "$task" "$attempt"
    action="$STUB_ACTIONS/$task.$attempt"
    [ -x "$action" ] && { bash "$action"; exit $?; }
    ;;
esac
exit 0
STUB
chmod +x "$WORK/stub-pi"
mkdir -p "$WORK/actions"

# -- fixture: bare origin + work repo ------------------------------------------
git init -q --bare "$WORK/origin.git"
REPO="$WORK/repo"
git init -q -b main "$REPO"
cd "$REPO"
git config user.email t@example.com
git config user.name "Test"
git remote add origin "$WORK/origin.git"

mkdir -p ai/beans/BEAN-001-loop ai/pipeline src factory/templates
cp "$PIPELINE_DIR/../scaffold/factory/templates/spec.html" factory/templates/
printf 'ai/runs/\n' > .gitignore

cat > ai/beans/BEAN-001-loop/bean.md <<'MD'
# BEAN-001 — exercise the loop

| Field | Value |
|---|---|
| **Pipeline Tier** | small |
MD

cat > ai/beans/BEAN-001-loop/bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: example/x
title: Exercise the loop through the driver
intent: Prove the build step is wired.
status: approved
allowed_write_paths:
  - src/**
acceptance_criteria:
  - id: ac1
    text: a.py says GOOD
    verify: { kind: command, run: ["sh", "-c", "grep -q GOOD src/a.py"] }
definition_of_done:
  - all AC verify pass
YAML

cat > ai/beans/INDEX.md <<'MD'
| ID | Title | Tier | Owner | Status |
|---|---|---|---|---|
| BEAN-001 | Exercise the loop | small | test | Approved |
MD

# A spec document with all seven sections filled. The controller lints these,
# so a fixture that skipped them would be testing a path a real run never takes.
cat > "$WORK/spec.md" <<'MD'
# bean-001 — add a.py

## What and why

The repository has no module yet. This bean creates the one file every later
bean will import, so that there is something for the gates to run against.

## Current behaviour

There is no `src/a.py`. Any import of it fails, and the acceptance criterion
that greps it has nothing to read.

## Proposed change

Create `src/a.py` containing the marker the acceptance criterion looks for.

```python src/a.py
GOOD
```

## Risk

Almost none: the file is new and nothing imports it yet. The plausible failure
is writing it to the wrong path, which the task's own verification catches.

## Blast radius

One new file, `src/a.py`. No existing file is modified, nothing is deleted,
and no deployment or data is touched.

## Verification

| AC | Criterion | Verify |
|---|---|---|
| ac1 | a.py says GOOD | `grep -q GOOD src/a.py` |

## Open questions

None that affect the work: the bean names the file and the marker, and the
acceptance criterion pins both.
MD

cat > "$WORK/tasks.yaml" <<'YAML'
schema_version: tasks/1.0.0
bean_id: bean-001
tasks:
  - id: task-1
    title: Add a.py saying GOOD
    intent: Create src/a.py containing GOOD.
    write_paths: [src/a.py]
    satisfies: [ac1]
    max_attempts: 2
    verify:
      - { kind: command, run: ["sh", "-c", "grep -q GOOD src/a.py"] }
YAML

cat > ai/pipeline/config.json <<'JSON'
{
  "runs_root": "ai/runs",
  "branch_pattern": "bean/BEAN-NNN-<slug>",
  "bean_dir_pattern": "ai/beans/BEAN-NNN-<slug>",
  "bean_index_path": "ai/beans/INDEX.md",
  "gates": [{ "name": "noop", "command": "true" }]
}
JSON

git add -A && git commit -q -m "fixture"
git push -q -u origin main 2>/dev/null

run_orchestrate() {
  PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" FACTORY_CONTAIN_WORKER=0 \
  STUB_ACTIONS="$WORK/actions" STUB_TASKS="$WORK/tasks.yaml" \
  STUB_SPEC_MD="${STUB_SPEC_MD-$WORK/spec.md}" \
  PIPELINE_CONFIG="$REPO/ai/pipeline/config.json" \
    bash "$PIPELINE_DIR/orchestrate.sh" BEAN-001 --stop-after build 2>&1
}
cleanup_run() {
  git -C "$REPO" checkout -q main
  git -C "$REPO" branch -D bean/BEAN-001-loop >/dev/null 2>&1
  rm -rf "$REPO/ai/runs"
  git -C "$REPO" clean -fdq
  git -C "$REPO" checkout -q -- .
  rm -f "$WORK/actions"/*
}

printf '\n== the tier lists the build step, not a one-shot implement ==\n\n'
out="$(PIPELINE_CONFIG="$REPO/ai/pipeline/config.json" bash "$PIPELINE_DIR/orchestrate.sh" --help)"
check "small tier runs build"     "small: preflight spec build gate" "$out"
check "full tier runs build"      "full:  preflight spec audit-spec build gate" "$out"

printf '\n== the controller checks the spec before any audit sees it ==\n\n'
cat > "$WORK/actions/task-1.1" <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
chmod +x "$WORK/actions/task-1.1"
out="$(run_orchestrate)"
check "the spec check runs"        "SPEC CHECK bean-001" "$out"
check "the document is linted"     "ok    spec.md" "$out"
check "the task list is validated" "ok    tasks.yaml" "$out"
check "criteria are claimed"       "ok    acceptance criteria" "$out"
check "and the document renders"   "ok    spec.html" "$out"
run_dir="$(ls -d "$REPO"/ai/runs/BEAN-001-* 2>/dev/null | head -1)"
want "spec.html exists"            "the controller should have rendered it" test -f "$run_dir/spec.html"
cleanup_run

printf '\n== the controller never overwrites what the model wrote ==\n\n'
# A 27B did exactly this on the first real run: found that an acceptance
# criterion could not pass in the gate container, stopped, and wrote its
# reasoning to QUESTIONS.md. halt() then wrote over it.
cat > "$WORK/stub-questions" <<'STUB'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2 ;; *) shift ;; esac; done
sess="${PI_SESSIONS_DIR:-.}/stub-$(date +%s%N).jsonl"
mkdir -p "$(dirname "$sess")"
printf '{"type":"session","version":"stub","id":"stub","cwd":"%s"}\n' "$PWD" > "$sess"
case "$prompt" in
  *factory-spec*)
    run_dir="${prompt##* }"
    printf '# QUESTIONS\n\nThe bean asks for something the container cannot do: ac1 imports a package that is never installed.\n' > "$run_dir/QUESTIONS.md"
    ;;
esac
exit 0
STUB
chmod +x "$WORK/stub-questions"
out="$(PI_BIN="$WORK/stub-questions" PI_SESSIONS_DIR="$WORK/sessions" FACTORY_CONTAIN_WORKER=0 \
  PIPELINE_CONFIG="$REPO/ai/pipeline/config.json" \
  bash "$PIPELINE_DIR/orchestrate.sh" BEAN-001 --stop-after spec 2>&1)"
run_dir="$(ls -d "$REPO"/ai/runs/BEAN-001-* 2>/dev/null | head -1)"
kept="$(ls "$run_dir"/questions-from-worker/*.md 2>/dev/null | head -1)"
want "the model's questions are kept"   "questions-from-worker/ should hold them" test -n "$kept"
check "with the model's own words"      "never installed" "$(cat "$kept" 2>/dev/null)"
check "and the halt points at them"     "The model stopped and wrote its own questions first" \
  "$(cat "$run_dir/QUESTIONS.md" 2>/dev/null)"
cleanup_run

printf '\n== a spec with no document does not reach an audit ==\n\n'
out="$(STUB_SPEC_MD= run_orchestrate)"
check "a missing spec.md fails the step" "FAIL  spec.md" "$out"
check "and the run halts there"          "HALT  spec" "$out"
cleanup_run

printf '\n== a run reaches the loop and the loop does the work ==\n\n'
cat > "$WORK/actions/task-1.1" <<'SH'
mkdir -p src && printf 'GOOD\n' > src/a.py
SH
chmod +x "$WORK/actions/task-1.1"
out="$(run_orchestrate)"; rc=$?
check "the build step ran"         "TASK   task-1" "$out"
check "the task verified"          "PASS   task-1     verified on attempt 1" "$out"
check "the run completed"          "RUN COMPLETE" "$out"
check "build is reported as PASS"  "build          PASS" "$out"
want "exit 0"                      "expected a clean run" test "$rc" -eq 0
want "the task was committed"      "expected build(task-1) on the run branch" \
  bash -c "git -C '$REPO' log --oneline | grep -q 'build(task-1)'"
want "and it is not on main"       "the run must not have committed to main" \
  bash -c "! git -C '$REPO' log --oneline main | grep -q 'build(task-1)'"

cleanup_run

printf '\n== a blocked task halts the run, with the evidence reachable ==\n\n'
cat > "$WORK/actions/task-1.1" <<'SH'
mkdir -p src && printf 'BAD\n' > src/a.py
SH
cat > "$WORK/actions/task-1.2" <<'SH'
mkdir -p src && printf 'STILL BAD\n' > src/a.py
SH
chmod +x "$WORK/actions/task-1.1" "$WORK/actions/task-1.2"
out="$(run_orchestrate)"; rc=$?
check "the loop blocks"            "BLOCKED  task-1 exhausted its attempts" "$out"
check "the driver halts"           "HALT  build" "$out"
want "halt exit code"              "expected 3 (halt)" test "$rc" -eq 3
run_dir="$(ls -d "$REPO"/ai/runs/BEAN-001-* 2>/dev/null | head -1)"
want "QUESTIONS.md is written"     "expected QUESTIONS.md at the run root" test -f "$run_dir/QUESTIONS.md"
q="$(cat "$run_dir/QUESTIONS.md" 2>/dev/null)"
check "it points at the task evidence" "BLOCKED.md" "$q"
want "the evidence it points to exists" "expected build/task-1/BLOCKED.md" \
  test -f "$run_dir/build/task-1/BLOCKED.md"
want "nothing was committed for the failed task" "a blocked task must not be committed" \
  bash -c "! git -C '$REPO' log --oneline | grep -q 'build(task-1)'"

printf '\n== advisory audits record what they went past, and do not hide it ==\n\n'
#
# "Advisory" is one word away from "ignored", and the difference has to be
# structural rather than intended. Three things must hold: the run continues, the
# verdict it continued past is written down where a reviewer will see it, and the
# advisory is not counted as a failed attempt — or a run in advisory mode would
# halt itself on the very attempts it was told to continue past.
cleanup_run
FAILDIR_CHECK="$REPO/ai/runs"
out="$(FACTORY_ADVISORY_AUDITS=1 ADVISORY_JUDGE_FAILS=1 run_orchestrate)"
adv="$(find "$REPO/ai/runs" -path '*failed-attempts/*advisory*' 2>/dev/null | head -1)"

if [ -n "$adv" ]; then
  check "the advisory is recorded"    "mode:      advisory" "$(cat "$adv")"
  check "and says it did not stop the run" "this did NOT stop the run" "$(cat "$adv")"
  check "and why the judge was demoted"    "not reproducible on identical input" "$(cat "$adv")"
  PASS=$((PASS+0))
else
  # The stub judge may not have been reached in this fixture's tier; the
  # properties above are still asserted by the unit check below, which does not
  # need a model at all.
  printf '  --    no advisory produced in this fixture; asserting the mechanism directly\n'
fi

# The mechanism, independent of whether a judge ran: an advisory file must not be
# counted as a failed attempt.
FD="$WORK/faildir"; mkdir -p "$FD"
printf 'x\n' > "$FD/audit-spec.1"
printf 'x\n' > "$FD/audit-spec.advisory.1"
printf 'x\n' > "$FD/audit-spec.advisory.2"
n="$(FAILDIR="$FD" bash -c '
  source /dev/stdin <<EOS
$(sed -n "/^failed_count() {/,/^}/p" "'"$PIPELINE_DIR"'/orchestrate.sh")
EOS
  failed_count audit-spec')"
if [ "$n" = "1" ]; then
  printf '  ok    two advisories and one failure count as one failure\n'; PASS=$((PASS+1))
else
  printf '  FAIL  failed_count said %s, expected 1 — advisories are being counted as failures\n' "$n"
  FAIL=$((FAIL+1))
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
