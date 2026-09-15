#!/usr/bin/env bash
# test-faults.sh — Phase-2 fault injections, driven through the real line.
#
# The plan lists these as Phase-2 work and they were blocked on worker
# containment, on the reasoning that you cannot test a containment failure
# against a worker that is not contained — testing the after-the-fact check and
# calling it the boundary. Containment landed, so they are no longer blocked.
#
# Each case here breaks one specific thing and asserts the line catches it, with
# the right verdict, at the right stage. A check that fires for the wrong reason
# is a check that will fire for no reason later, so every assertion names the
# mechanism and not just the failure.
#
# Built on the same stubs as test-full-line.sh: no model, no GPU, seconds per
# case. The point of a fault injection is to run it often enough that a
# regression is caught the week it happens.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$(tail -c 300 <<<"$3")"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}

# ------------------------------------------------------------- the fixture --
git init -q --bare "$WORK/origin.git"
REPO="$WORK/repo"; git init -q -b main "$REPO"; cd "$REPO"
git config user.email t@e.com; git config user.name T
git remote add origin "$WORK/origin.git"
mkdir -p factory/beans/bean-001-scaffold factory/templates src tests

cat > factory/repo.yaml <<'YAML'
schema_version: repo-config/1.0.0
repo: example/x
default_branch: main
host: github
merge_mode: human_required
max_inflight: 1
policy_ref: factory/risk-policy.yaml
gates_ref: factory/gates.lock.yaml
YAML
cat > factory/risk-policy.yaml <<'YAML'
schema_version: risk-policy/1.0.0
policy_version: test/1
default_tier: 1
repo_allowed_paths: ["src/**", "tests/**"]
rules: []
YAML
cat > factory/beans/bean-001-scaffold/bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: example/x
title: A bean for breaking on purpose
intent: Prove the line refuses the specific things it is supposed to refuse.
status: approved
allowed_write_paths: ["src/**", "tests/**"]
acceptance_criteria:
  - id: ac1
    text: the module exists and says GOOD
    verify: { kind: command, run: ["sh", "-c", "grep -q GOOD src/a.py"] }
  - id: ac2
    text: the second module exists
    verify: { kind: command, run: ["sh", "-c", "test -f src/b.py"] }
definition_of_done: ["ac1", "ac2"]
# The budget lives on the bean, not in pipeline-config.json — it is a property of
# how big this piece of work is allowed to be, which is a bean-level fact.
size_budget:
  max_tasks: 2
YAML
printf '| Field | Value |\n|---|---|\n| **Pipeline Tier** | full |\n' > factory/beans/bean-001-scaffold/bean.md
printf '| ID | Title | Tier | Approved by | Status |\n|---|---|---|---|---|\n| bean-001 | A bean for breaking on purpose | full | test | Approved |\n' > factory/beans/INDEX.md
cat > factory/gates.lock.yaml <<'YAML'
schema_version: gate-manifest/1.0.0
image: "localhost/factory-test-image:fixture@sha256:0000000000000000000000000000000000000000000000000000000000000000"
verify_versions_at_startup: false
gates: []
YAML
cat > factory/pipeline-config.json <<'JSON'
{"runs_root":"factory/runs",
 "bean_dir_pattern":"factory/beans/BEAN-NNN-<slug>",
 "bean_index_path":"factory/beans/INDEX.md",
 "branch_pattern":"bean/BEAN-NNN-<slug>",
 "repo_config":"factory/repo.yaml",
 "verify_timeout_s":60,
 "test_command":["sh","-c","true"]}
JSON
for t in spec impl-detail; do
  printf '<!doctype html><html><head><title>{{TITLE}}</title></head>\n<body><nav>{{TOC}}</nav><main>{{BODY}}</main><footer>{{META}}</footer></body></html>\n' \
    > "factory/templates/$t.html"
done
printf 'factory/runs/\n' > .gitignore
printf '# x\n' > README.md
mkdir -p "$WORK/sessions"
git add -A && git commit -q -m init && git push -q -u origin main
BASE_MAIN="$(git rev-parse main)"

cat > "$WORK/spec.md" <<'MD'
# Scaffold spec

## What and why

A deliberately small change, so the thing under test is the controller's refusal
behaviour rather than anything about the code being written.

## Current behaviour

There is no `src/a.py` and no `src/b.py`. Nothing imports either of them and no
test covers them, so there is no behaviour here that a change could break.

## Proposed change

Add the two modules, each with content the acceptance criteria can check for, and
nothing else at all.

## Risk

Low. Two new files that nothing else refers to yet, both covered by the bean's
own acceptance criteria, both inside the allowed write paths.

## Blast radius

Two files under src/, and nothing outside them. No configuration, no dependency,
and no public interface changes anywhere in the tree.

## Verification

Each task carries its own check and the controller runs every one of them. The
bean's acceptance criteria are re-run against the whole diff at the gate.

## Open questions

None. If something turns out to be ambiguous the task blocks and a person is
asked rather than guessed at.
MD

cat > "$WORK/tasks.yaml" <<'YAML'
schema_version: tasks/1.0.0
bean_id: bean-001
tasks:
  - id: task-1
    title: the first module
    intent: Create src/a.py containing the word GOOD.
    write_paths: ["src/a.py"]
    satisfies: ["ac1"]
    verify:
      - { kind: command, run: ["sh", "-c", "grep -q GOOD src/a.py"] }
  - id: task-2
    title: the second module
    intent: Create src/b.py so the second criterion is met.
    depends_on: ["task-1"]
    write_paths: ["src/b.py"]
    satisfies: ["ac2"]
    verify:
      - { kind: command, run: ["sh", "-c", "test -f src/b.py"] }
YAML

mkdir -p "$WORK/bin"
cat > "$WORK/bin/pi" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2 ;; *) shift ;; esac; done
sess="${PI_SESSIONS_DIR:-.}/stub-$(date +%s%N).jsonl"
mkdir -p "$(dirname "$sess")"
printf '{"type":"session","version":"stub","id":"stub","cwd":"%s"}\n' "$PWD" > "$sess"
case "$prompt" in
  *factory-spec*)
    run_dir="${prompt##* }"
    cp "$STUB_TASKS" "$run_dir/tasks.yaml"
    cp "$STUB_SPEC_MD" "$run_dir/spec.md" ;;
  *factory-build-task*)
    adir="${prompt##* }"; rest="${prompt% *}"; task="${rest##* }"
    case "$task" in
      task-1) mkdir -p src && printf 'GOOD\n' > src/a.py ;;
      task-2) mkdir -p src && printf 'second\n' > src/b.py ;;
    esac
    # The injected fault, if this case wants one during a build task.
    [ -n "${STUB_BUILD_EXTRA:-}" ] && eval "$STUB_BUILD_EXTRA"
    ;;
  *factory-doc*)
    run_dir="${prompt##* }"
    cp "${STUB_DOC:-/dev/null}" "$run_dir/impl-detail.md" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/pi"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "pr create")
    if [ -f "$GH_EXISTING" ]; then echo "a pull request for branch already exists" >&2; exit 1; fi
    : > "$GH_EXISTING"; echo "https://github.com/example/x/pull/1" ;;
  "pr view") echo "https://github.com/example/x/pull/1" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export GH_CALLS="$WORK/gh-calls.txt" GH_EXISTING="$WORK/gh-existing"
export PATH="$WORK/bin:$PATH"

cp -r "$PIPELINE_DIR" "$WORK/pipeline"
cat > "$WORK/pipeline/judge.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
RUN_DIR="$1"; shift
TARGET=""
while [ $# -gt 0 ]; do case "$1" in --target) TARGET="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$RUN_DIR/verdicts"
n=1
while [ -f "$RUN_DIR/verdicts/$TARGET.attempt-$n.judgement.json" ]; do n=$((n+1)); done
src=""
for c in "$RUN_DIR/impl-detail.md" "$RUN_DIR/spec.md"; do [ -f "$c" ] && { src="$c"; break; }; done
Q="$(grep -v '^[#|`-]' "$src" 2>/dev/null | awk '{ if (length($0) > 40 && length($0) < 120) { print; exit } }')"
[ -n "$Q" ] || Q="the stub judge could not find a line to quote"
Q="${Q//\"/}"
V="${STUB_VERDICT:-accept}"
# A judge that is told to disbelieve the document sets matches_diff false, which
# is what the pre-PR audit is supposed to act on.
MD="true"; [ "${STUB_MATCHES_DIFF:-1}" = 0 ] && { MD="false"; V="revise"; }
cat > "$RUN_DIR/verdicts/$TARGET.attempt-$n.judgement.json" <<JSON
{"schema_version":"judgement/1.0.0","stage":"stub","target":"$TARGET",
 "verdict":"$V","confidence":0.9,
 "criteria":[{"id":"ac1","met":true,"evidence":"the stub judge read the artifact","quote":"$Q"}],
 "findings":[],
 "document_quality":{"matches_diff":$MD,"risk_called_out":true,"blast_radius_called_out":true,"code_blocks_teach":true,"no_assumed_stack_knowledge":true},
 "test_integrity":{"deleted_tests":0,"new_skips":0,"weakened_asserts":false,"coverage_delta":"n/a"},
 "judged_by":{"model":"stub","digest":"stub","num_ctx":0,"thinking":"none","seconds":0}}
JSON
printf 'JUDGE  %s  %s (stub)\n' "$TARGET" "$V" >&2
exit 0
STUB
chmod +x "$WORK/pipeline/judge.sh"

cat > "$WORK/doc-good.md" <<'DOC'
# What was built

## Summary

Two modules under `src/`, one per task, each satisfying one acceptance criterion.
Nothing else changed and nothing imports them yet.

## What changed and why

Two modules were added under `src/`, one per task, each satisfying one of the
bean's acceptance criteria. Nothing else in the tree was touched.

## Walkthrough by task

`src/a.py` is new and contains the word GOOD, which is what ac1 greps for:

```python src/a.py
GOOD
```

`src/b.py` is new and exists, which is the whole of what ac2 checks:

```python src/b.py
second
```

## Deviations from the spec

None. Both tasks did exactly what the task list described, wrote only inside
their declared paths, and passed their own checks on the first attempt.

## Risk & blast radius, as built

Two new files that nothing imports. Reverting either restores the previous state
exactly, and no other file refers to them, so the blast radius is those files.

## Evidence

Each task's verify ran in the controller rather than in the session that wrote
the code, and the bean's acceptance criteria were re-run at the gate. Both passed.

## How to verify locally

Check out the branch and run `grep GOOD src/a.py` and `test -f src/b.py`. Those
are the bean's acceptance criteria verbatim, worth running rather than trusting.

## Rollback

Revert the branch's two commits, or delete both files. Nothing else refers to
them, so there is no ordering to respect and no data to migrate back.
DOC

reset_repo() {
  cd "$REPO"
  git checkout -q main 2>/dev/null
  git branch -D bean/bean-001-scaffold >/dev/null 2>&1
  git reset -q --hard "$BASE_MAIN"
  git clean -fdq
  rm -rf "$REPO/factory/runs" "$GH_CALLS" "$GH_EXISTING"
  cp "$WORK/tasks.yaml" "$WORK/tasks-live.yaml"
}

run_line() {
  PI_SESSIONS_DIR="$WORK/sessions" \
  STUB_TASKS="$WORK/tasks-live.yaml" STUB_SPEC_MD="$WORK/spec.md" \
  STUB_DOC="${STUB_DOC:-$WORK/doc-good.md}" \
  FACTORY_CONTAIN_WORKER=0 FACTORY_VERIFY_SANDBOX=0 FACTORY_SANDBOX_ROOT="$WORK/sb" \
  PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
    bash "$WORK/pipeline/orchestrate.sh" bean-001 "$@" 2>&1
}

# ============================================================ the injections ==

printf '\n== an out-of-path edit inside a task is REJECTED, not stripped ==\n\n'
#
# The distinction is the whole point. Stripping teaches the model that overreach
# is free and leaves a diff nobody authored; rejecting costs it an attempt and
# tells it why.
reset_repo
STUB_BUILD_EXTRA='printf "sneaky\n" > escaped.txt' run_line --stop-after build > "$WORK/o1" 2>&1
o="$(cat "$WORK/o1")"
check "the attempt is rejected"        "containment_violation" "$o"
check "and it is rejected every attempt, not stripped once" "attempt 3: containment_violation" "$o"
want  "the stray file is gone from the tree" "escaped.txt should have been reset away" \
      test ! -f "$REPO/escaped.txt"
R="$(ls -1dt "$REPO"/factory/runs/*/ | head -1)"
want "and it is recorded as a containment violation" "containment.json should say contained:false" \
     test "$(jq -r '.contained' "$R"/build/task-1/attempt-1/containment.json)" = false

printf '\n== a task list with an unclaimed acceptance criterion is refused ==\n\n'
reset_repo
"$PIPELINE_DIR/yaml2json.sh" "$WORK/tasks.yaml" \
  | jq '.tasks |= map(if .id == "task-2" then .satisfies = [] else . end)' \
  | "$PIPELINE_DIR/../../.venv/bin/python" -c 'import json,sys,yaml; yaml.safe_dump(json.load(sys.stdin), sys.stdout, sort_keys=False)' \
  > "$WORK/tasks-live.yaml" 2>/dev/null || cp "$WORK/tasks.yaml" "$WORK/tasks-live.yaml"
o="$(run_line --stop-after spec)"
check "the spec check names the criterion" "ac2" "$o"
check "and refuses the spec"               "SPEC CHECK FAIL" "$o"

printf '\n== a task list over the size budget is refused ==\n\n'
reset_repo
"$PIPELINE_DIR/yaml2json.sh" "$WORK/tasks.yaml" \
  | jq '.tasks += [{id:"task-3",title:"a third",intent:"Push this task list over the configured budget of two.",write_paths:["src/c.py"],satisfies:["ac2"],verify:[{kind:"command",run:["sh","-c","true"]}]}]' \
  | "$PIPELINE_DIR/../../.venv/bin/python" -c 'import json,sys,yaml; yaml.safe_dump(json.load(sys.stdin), sys.stdout, sort_keys=False)' \
  > "$WORK/tasks-live.yaml" 2>/dev/null || cp "$WORK/tasks.yaml" "$WORK/tasks-live.yaml"
o="$(run_line --stop-after spec)"
# The budget check reports through spec-check; assert on its own line rather than
# on the run's final banner, which a later stage can overwrite in the captured
# output.
check "the budget is enforced"  "size_budget" "$o"
check "and it names the overage"  "3 tasks against a budget of 2" "$o"
# split_required is the specific outcome the plan asks for: back to a human at
# intake, not back to the model to squeeze the same work into fewer tasks.
check "and calls for a split, not a retry" "split_required" "$o"

printf '\n== a document that misdescribes the diff fails before the PR ==\n\n'
#
# The rule that matters here is that this is a DOCUMENT failure: the code was
# gated and is fine, so nothing about the diff should be touched or reverted.
reset_repo
printf '# What was built\n\n## Summary\n\nNothing was changed.\n' > "$WORK/doc-bad.md"
STUB_DOC="$WORK/doc-bad.md" run_line > "$WORK/o4" 2>&1
o="$(cat "$WORK/o4")"
check "the document is refused"    "DOC CHECK FAIL" "$o"
nope  "and no pull request opens"  "PR OPEN" "$o"
want  "the code is still committed" "the task commits should survive a document failure" \
      test "$(git -C "$REPO" rev-list --count "main..bean/bean-001-scaffold" 2>/dev/null || echo 0)" -ge 2

printf '\n== a second run does not open a second pull request ==\n\n'
reset_repo
run_line > /dev/null 2>&1
R="$(ls -1dt "$REPO"/factory/runs/*/ | head -1)"
o="$(cd "$REPO" && PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
      bash "$WORK/pipeline/pr.sh" "${R%/}" --bean "$REPO/factory/beans/bean-001-scaffold/bean.yaml" 2>&1)"
check "the existing PR is recognised" "already open" "$o"
n="$(grep -c 'pr create' "$GH_CALLS" 2>/dev/null || echo 0)"
want "and gh was asked to create at most twice" "expected 2 create attempts, one per invocation" \
     test "$n" -le 2

printf '\n== the worker has no credentials and no git ==\n\n'
#
# Asserted structurally rather than by attempting a theft: the worker image has
# no git binary, and the contained tree has .git masked. Both are properties of
# the image and the mount, so they are checked where they live.
if command -v podman >/dev/null 2>&1 && podman image exists localhost/factory-worker-pi:20260915 2>/dev/null; then
  o="$(podman run --rm --network=none --entrypoint sh localhost/factory-worker-pi:20260915 \
        -c 'ls ~/.ssh 2>&1; cat ~/.gitconfig 2>&1; env | grep -ci token || true' 2>&1)"
  nope "no ssh directory in the image"  "id_" "$o"
  nope "no git identity in the image"   "email" "$o"
else
  printf '  --    worker image not built here; containment asserted by tests/test-sandbox.sh\n'
fi

printf '\n== the controller is killed mid-build, and the run resumes ==\n\n'
#
# Filed as needing state a stub cannot fake, which was half right: the *remote*
# half cannot be faked, but killing the controller can — and it is the half that
# has actually bitten. An interrupted attempt leaves the worker's edits in the
# tree, and the next run's preflight refuses a dirty tree without being able to
# say whose changes they are.
#
# What must hold after a kill: the tree is clean, the completed work is still
# committed, and a resume continues rather than starting over.
reset_repo
# orchestrate.sh directly, not through run_line: backgrounding a shell FUNCTION
# gives $! the subshell's pid, and signalling that does not reach orchestrate at
# all. The first version of this test killed a wrapper and concluded the line
# failed to clean up.
PI_SESSIONS_DIR="$WORK/sessions" \
STUB_TASKS="$WORK/tasks-live.yaml" STUB_SPEC_MD="$WORK/spec.md" \
STUB_DOC="$WORK/doc-good.md" STUB_BUILD_EXTRA='sleep 20' \
FACTORY_CONTAIN_WORKER=0 FACTORY_VERIFY_SANDBOX=0 FACTORY_SANDBOX_ROOT="$WORK/sb" \
PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
  setsid bash "$WORK/pipeline/orchestrate.sh" bean-001 --stop-after build > "$WORK/o-kill" 2>&1 &
LINE_PID=$!
# setsid puts the line in its own process group, so the test can signal the group
# the way a terminal does on Ctrl+C. This is not a convenience: bash does not run
# a trap while it is blocked on a foreground child, so TERM to the controller
# alone is deferred until the step it is waiting on finishes — which for a build
# step can be many minutes. Signalling the group reaches the worker too, the
# child exits, and every trap in the chain runs promptly. An operator pressing
# Ctrl+C gets exactly this; `kill <pid>` gets the deferred version.
# Wait for the first task to be under way rather than racing a fixed delay.
for _ in $(seq 1 60); do
  grep -q 'ATTEMPT 1/' "$WORK/o-kill" 2>/dev/null && break
  sleep 0.5
done
# By pid, never by pattern: a pattern kill here would match this test script,
# which has done exactly that four times in this project's history.
# TERM to the controller, exactly as an operator killing it by pid would. If the
# line only cleans up when the shell happens to signal the whole group, it does
# not clean up.
kill -TERM -"$LINE_PID" 2>/dev/null || kill -TERM "$LINE_PID" 2>/dev/null
wait "$LINE_PID" 2>/dev/null
# Give the children their cleanup window.
for _ in $(seq 1 40); do
  pgrep -P "$LINE_PID" >/dev/null 2>&1 || break
  sleep 0.5
done

dirty="$(git -C "$REPO" status --porcelain | grep -v '^?? factory/runs/' || true)"
want "the tree is clean after the kill" "a killed attempt must not leave the worker's edits behind: $dirty" \
     test -z "$dirty"
KILLED="$(cat "$WORK/o-kill")"
check "the controller says it is stopping" "stopping the line" "$KILLED"
if ! grep -qF 'discarding its edits' <<<"$KILLED"; then
  printf '  --- what the killed run printed ---\n'
  sed 's/^/  | /' <<<"$KILLED" | tail -12
  printf '  --- end ---\n'
fi
check "and the loop says what it discarded" "discarding its edits" "$KILLED"

R="$(ls -1dt "$REPO"/factory/runs/*/ | head -1)"
want "the run directory survived"       "the evidence must outlive the reset" test -d "$R"

# Now resume it. The point is that it continues rather than redoing what is done.
rm -f "$R/QUESTIONS.md"
run_line --resume "${R%/}" --stop-after build > "$WORK/o-resume" 2>&1 || true
o="$(cat "$WORK/o-resume")"
check "the resume skips what passed"    "SKIP   spec" "$o"
check "and finishes the build"          "BUILD COMPLETE" "$o"
check "with every task"                 "task(s) verified" "$o"
want  "and nothing was left half-committed" "the branch should carry one commit per verified task" \
      test "$(git -C "$REPO" rev-list --count "main..bean/bean-001-scaffold" 2>/dev/null || echo 0)" -eq 2

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
