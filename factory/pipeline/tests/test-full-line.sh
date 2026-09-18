#!/usr/bin/env bash
# test-full-line.sh — the whole line, every step, with no model and no GPU.
#
# Everything up to now tests one script, or the orchestrator as far as `build`.
# The two worst bugs this project has had both lived past that boundary and both
# were found by running a real bean for an hour:
#
#   the task loop read its work list from stdin, the worker ate it, and a bean
#   that was one third built recorded "BUILD COMPLETE"
#
#   a pipeline snapshot left worker.lock.yaml behind, containment fell back to
#   off, and pi ran on the host while the record said the run was contained
#
# Neither needed a model to reproduce. Both needed the line to be driven end to
# end, which nothing did. This does: preflight through pull request, with pi,
# the judge and gh all stubbed, in seconds.
#
# The stubs are deliberately hostile where a real component is hostile. The pi
# stub drains stdin, because pi does, and that is what ate the task list.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
# The run directory is the evidence. Keeping a copy when something fails turns
# "the audit said a step never ended" into a question you can answer by looking,
# instead of re-running the whole thing with a print statement added.
KEEP="${FULL_LINE_KEEP:-}"
cleanup() {
  if [ -n "$KEEP" ] && [ -d "$REPO/factory/runs" ]; then
    mkdir -p "$KEEP" && cp -r "$REPO"/factory/runs/. "$KEEP/" 2>/dev/null || true
    printf '\n  run directory kept: %s\n' "$KEEP"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$(tail -c 220 <<<"$3")"; FAIL=$((FAIL+1)); fi
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

# ---------------------------------------------------------------- the repo --
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
rules: []
YAML
cat > factory/beans/bean-001-scaffold/bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: example/x
title: A bean that goes all the way to a pull request
intent: Prove the line runs end to end without a model in it.
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
YAML
printf '| Field | Value |\n|---|---|\n| **Pipeline Tier** | full |\n' > factory/beans/bean-001-scaffold/bean.md
# audit-check refuses a verdict that cannot name the toolchain it was judged
# under, so the fixture pins one. The image is never pulled — no gate in it runs
# in this test — but the digest has to be there for the verdict to be stampable.
cat > factory/gates.lock.yaml <<'YAML'
schema_version: gate-manifest/1.0.0
image: "localhost/factory-test-image:fixture@sha256:0000000000000000000000000000000000000000000000000000000000000000"
verify_versions_at_startup: false
gates: []
YAML
cat > factory/pipeline-config.json <<'JSON'
{
 "corpus":{"name":"test-corpus","bean_set":"v0","requirements_sha256":"0000000000000000000000000000000000000000000000000000000000000000"},
 "runs_root":"factory/runs",
 "bean_dir_pattern":"factory/beans/BEAN-NNN-<slug>",
 "bean_index_path":"factory/beans/INDEX.md",
 "branch_pattern":"bean/BEAN-NNN-<slug>",
 "repo_config":"factory/repo.yaml",
 "verify_timeout_s":60,
 "test_command":["sh","-c","true"]}
JSON
# The index's column order is load-bearing: preflight reads the id from column 2
# and the status from column 6.
printf '| ID | Title | Tier | Approved by | Status |\n|---|---|---|---|---|\n| bean-001 | A bean that reaches a pull request | full | test | Approved |\n' \
  > factory/beans/INDEX.md
mkdir -p "$WORK/sessions"
# Minimal templates, so the render step actually runs. Without them the line
# prints "no template; not rendered" and the documents predicate fails on the
# half a script can check, hiding the half it cannot — which is the one worth
# asserting.
for t in spec impl-detail; do
  printf '<!doctype html><html><head><title>{{TITLE}}</title></head>\n<body><nav>{{TOC}}</nav><main>{{BODY}}</main><footer>{{META}}</footer></body></html>\n' \
    > "factory/templates/$t.html"
done
printf 'factory/runs/\n' > .gitignore
printf '# x\n' > README.md
git add -A && git commit -q -m init && git push -q -u origin main

# The spec the stub "writes". Long enough to pass doclint; its Current behaviour
# states absence, which the claims check must read as true rather than as a
# claim about missing files.
cat > "$WORK/spec.md" <<'MD'
# Scaffold spec

## What and why

This bean exists so the line can be driven from preflight to pull request without
a model in the loop. Every step is real; only the things that would need weights
or a network are stubbed.

## Current behaviour

There is no `src/a.py` and no `src/b.py`. Nothing imports either of them and no
test covers them, so there is no behaviour here that a change could break.

## Proposed change

Add the two modules, each with content the acceptance criteria can check for, and
nothing else. The work is deliberately trivial because what is under test is the
controller, not the change.

## Risk

Low. Two new files that nothing else refers to yet, both covered by the bean's
own acceptance criteria, both inside the allowed write paths.

## Blast radius

Two files under src/, and nothing outside them. No configuration, no dependency,
and no public interface changes.

## Verification

Each task carries its own check and the controller runs every one of them. The
bean's acceptance criteria are re-run at the gate against the whole diff.

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

# ------------------------------------------------------------- the stubs --
mkdir -p "$WORK/bin" "$WORK/actions"

# pi. It DRAINS STDIN, because the real one does, and that is what ate the task
# list. A stub that does not do this cannot catch the bug it was written for.
cat > "$WORK/bin/pi" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in -p) prompt="$2"; shift 2 ;; *) shift ;; esac
done
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
    esac ;;
  *factory-doc*)
    run_dir="${prompt##* }"
    cat > "$run_dir/impl-detail.md" <<'DOC'
# What was built

## Summary

Two modules under `src/`, one per task, each satisfying one acceptance criterion.
Nothing else changed, nothing imports them yet, and the whole change is two files
of one line each.

## What changed and why

Two modules were added under `src/`, one per task, each satisfying one of the
bean's acceptance criteria. Nothing else in the tree was touched, and neither
file is imported by anything yet.

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
their declared paths, and passed their own checks on the first attempt with no
feedback round needed.

## Risk & blast radius, as built

Two new files that nothing imports. Reverting either restores the previous state
exactly, no other file refers to them, and no configuration or dependency
changed, so the blast radius is the two files themselves.

## Evidence

Each task's verify ran in the controller rather than in the session that wrote
the code, and the bean's two acceptance criteria were re-run against the whole
diff at the gate. Both passed.

## How to verify locally

Check out the branch and run `grep GOOD src/a.py` and `test -f src/b.py`. Those
are the bean's acceptance criteria verbatim, which is why they are worth running
by hand rather than paraphrasing.

## Rollback

Revert the branch's two commits, or delete both files. Nothing else refers to
them, so there is no ordering to respect and no data to migrate back.
DOC
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/pi"

# gh. Records what it was asked to do so the test can assert on the verbs.
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "pr create") echo "https://github.com/example/x/pull/1" ;;
  "pr view")   echo "https://github.com/example/x/pull/1" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/gh"
export GH_CALLS="$WORK/gh-calls.txt"

# The judge. judge.sh talks to ollama directly, so the whole script is replaced
# in a copy of the pipeline. It writes the judgement the real one would.
cp -r "$PIPELINE_DIR" "$WORK/pipeline"
cat > "$WORK/pipeline/judge.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
RUN_DIR="$1"; shift
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in --target) TARGET="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$RUN_DIR/verdicts"
n=1
while [ -f "$RUN_DIR/verdicts/$TARGET.attempt-$n.judgement.json" ]; do n=$((n+1)); done

# A real quote from a real artifact. audit-check requires quotes long enough to
# prove the judge read something and verifies each one exists on disk — a guard
# worth keeping, so the stub satisfies it honestly rather than the test loosening
# it. Take the longest prose line from whichever artifact this target audits.
src=""
for cand in "$RUN_DIR/impl-detail.md" "$RUN_DIR/spec.md"; do
  [ -f "$cand" ] && { src="$cand"; break; }
done
Q="$(grep -v '^[#|`-]' "$src" 2>/dev/null | awk '{ if (length($0) > 40 && length($0) < 120) { print; exit } }')"
[ -n "$Q" ] || Q="the stub judge could not find a line to quote"
Q="${Q//\"/}"

cat > "$RUN_DIR/verdicts/$TARGET.attempt-$n.judgement.json" <<JSON
{"schema_version":"judgement/1.0.0","stage":"stub","target":"$TARGET",
 "verdict":"${STUB_VERDICT:-accept}","confidence":0.9,
 "criteria":[{"id":"ac1","met":true,"evidence":"the stub judge read the artifact and found the criterion met","quote":"$Q"},
             {"id":"ac2","met":true,"evidence":"the stub judge read the artifact and found the criterion met","quote":"$Q"}],
 "findings":[],
 "document_quality":{"matches_diff":true,"risk_called_out":true,"blast_radius_called_out":true,"code_blocks_teach":true,"no_assumed_stack_knowledge":true},
 "test_integrity":{"deleted_tests":0,"new_skips":0,"weakened_asserts":false,"coverage_delta":"n/a"},
 "judged_by":{"model":"stub","digest":"stub","num_ctx":0,"thinking":"none","seconds":0}}
JSON
printf 'JUDGE  %s  %s (stub)\n' "$TARGET" "${STUB_VERDICT:-accept}" >&2
# STUB_JUDGE_SILENT: write nothing and fail, the way the real judge does when it
# spends its budget reasoning, calls a tool that does not exist, or returns an
# answer that is not JSON. On 2026-09-16 that was seven of twelve real audits.
if [ "${STUB_JUDGE_SILENT:-0}" = 1 ]; then
  rm -f "$RUN_DIR/verdicts/$TARGET.attempt-$n.judgement.json"
  printf 'JUDGE  %s: the stub wrote no judgement\n' "$TARGET" >&2
  exit 1
fi
exit 0
STUB
chmod +x "$WORK/pipeline/judge.sh"

export PATH="$WORK/bin:$PATH"

run_line() {
  PI_SESSIONS_DIR="$WORK/sessions" \
  STUB_TASKS="$WORK/tasks.yaml" STUB_SPEC_MD="$WORK/spec.md" \
  SPEC_CHECK_VALIDATOR="$PIPELINE_DIR/../../bench/validate.py" \
  PIPELINE_PYTHON="$PIPELINE_DIR/../../.venv/bin/python" \
  FACTORY_CONTAIN_WORKER=0 FACTORY_VERIFY_SANDBOX=0 FACTORY_SANDBOX_ROOT="$WORK/sb" \
  PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
    bash "$WORK/pipeline/orchestrate.sh" bean-001 "$@" 2>&1
}

printf '\n== the whole line, preflight to pull request ==\n\n'
# Streamed to a file rather than captured in a subshell: when the line hangs,
# a captured $( ) shows nothing at all and the failure is invisible.
run_line > "$WORK/line.log" 2>&1
out="$(cat "$WORK/line.log")"
R="$(ls -1dt "$REPO"/factory/runs/*/ 2>/dev/null | head -1)"

# The line's own output, once, before the assertions. Twenty checks each
# printing a fragment of the same log is unreadable, and the fragment is never
# the part that explains the failure.
if ! grep -q 'PR OPEN' <<<"$out"; then
  printf '  --- the line did not reach a pull request; its log ---\n'
  sed 's/^/  | /' <<<"$out" | tail -40
  printf '  --- end ---\n\n'
fi

check "preflight ran"              "preflight: all checks passed" "$out"
check "the spec was written"       "SPEC CHECK PASS" "$out"
check "the spec was audited"       "JUDGE  spec" "$out"
check "the build loop ran"         "TASK   task-1" "$out"
check "BOTH tasks ran"             "TASK   task-2" "$out"
check "and both are counted"       "2 task(s) verified" "$out"
check "each task was committed"    "COMMIT task-2" "$out"
check "the gate ran"               "GATE bean-001" "$out"
check "the implementation was audited" "JUDGE  impl" "$out"
check "the document was written"   "DOC CHECK" "$out"
check "the package was audited"    "PACKAGE CHECK" "$out"
check "and a pull request opened"  "PR OPEN" "$out"

printf '\n== and the record says what happened ==\n\n'
want "a run directory exists"      "no run dir" test -n "$R"
check "the run completed"          '"status":"completed"' "$(tr -d ' ' < "$R/run.json")"
check "and records the pull request" '"pr_url":"https://github.com/example/x/pull/1"' \
      "$(tr -d ' ' < "$R/run.json")"
check "the gate passed"            '"overall":"pass"' "$(tr -d ' ' < "$R/gate.json")"
check "the package check is consistent" '"internally_consistent":true' \
      "$(tr -d ' ' < "$R/package-check.json")"
want "every verify was precheck-ed" "verify-precheck.json missing" test -f "$R/verify-precheck.json"
want "the claims check ran"         "claims-check.json missing" test -f "$R/claims-check.json"
check "gh opened exactly one PR"   "pr create" "$(cat "$GH_CALLS")"
nope  "and never merged it"        "pr merge" "$(cat "$GH_CALLS")"

printf '\n== the phase-1 exit predicates, computed from this run ==\n\n'
#
# bench/phase1-audit.sh reads the seven `phase_1_exit` predicates out of a run
# directory rather than out of the plan. The only complete run that exists on
# demand is this one, so it is audited here — which means the predicates are
# exercised against a finished run every time the suite runs, instead of being
# tried for the first time on the day someone wants to close the phase.
#
# Not every predicate can pass here and that is the point of checking. A stubbed
# judge cannot make a document teach, and this fixture's bean declares no
# invariants_ref. What must hold is that the computable ones compute.
AUDIT="$(bash "$PIPELINE_DIR/../../bench/phase1-audit.sh" "${R%/}" --repo "$REPO" 2>&1)"

if ! grep -q 'ok    seven_stages_completed' <<<"$AUDIT"; then
  printf '  --- the phase-1 audit in full ---\n'
  sed 's/^/  | /' <<<"$AUDIT"
  printf '  --- end ---\n\n'
fi
check "the stages predicate passes"   "ok    seven_stages_completed" "$AUDIT"
# One attempt per audit, not two. judge.sh used to record its own PENDING
# boundary as well as the orchestrator's real one, and PENDING sorted first.
n_audit="$(jq -rs '[.[] | select(.step == "audit-spec" and .event == "end")] | length' "$R/steps.jsonl")"
want "an audit is recorded once, not twice" "audit-spec has $n_audit end lines, expected 1" \
     test "$n_audit" -eq 1
nope "and never as PENDING"  '"verdict":"PENDING"' "$(tr -d ' ' < "$R/steps.jsonl")"
check "the verdicts validate"         "ok    three_verdicts_schema_valid" "$AUDIT"
check "every handoff was a commit"    "ok    every_handoff_is_commit" "$AUDIT"
check "paths were enforced at both levels" "ok    allowed_path_enforced_task_and_bean" "$AUDIT"

# The two that cannot pass from a script, asserted as *not* passing, so that a
# change which quietly makes them pass is caught. A predicate that goes green
# without a human is a predicate that stopped meaning anything.
check "reading the documents is left to a human" "no human has recorded reading them" "$AUDIT"
check "and it says what to write"                "documents-read-by.txt" "$AUDIT"

printf '\n== the run history is listable ==\n\n'
#
# Run directories are the record. They looked like scratch space because nothing
# showed them together, and they were duly deleted between attempts all through
# the day this was written — taking every spec a model had produced with them.
runs_out="$(cd "$REPO" && PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
  bash "$PIPELINE_DIR/../bin/factory" runs 2>&1)"
check "it lists the run"        "$(basename "${R%/}")" "$runs_out"
check "with how it ended"       "completed" "$runs_out"
check "and how long it took"    "ELAPSED" "$runs_out"

printf '\n== main moving under a finished run sends the line backwards ==\n\n'
#
# The quiet version of this fault: someone lands on main while a bean builds,
# every verdict still names the base it was built on, the PR opens green, and the
# merge produces a tree that neither the gate nor any audit has ever seen. sync
# is the step that refuses to let that happen, and a rewind is the orchestrator
# agreeing to pay for it.
#
# This runs against the completed line above, which is the point: every step is
# PASS, so anything that runs again does so because the rebase made it stale.
git -C "$REPO" checkout -q main
printf 'landed while the bean was building\n' > "$REPO/unrelated.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "someone else's work"
git -C "$REPO" push -q origin main
BEAN_BRANCH="$(jq -r '.branch' "$R/run.json")"
git -C "$REPO" checkout -q "$BEAN_BRANCH"
OLD_CANDIDATE="$(git -C "$REPO" rev-parse HEAD)"
OLD_GATE_TS="$(stat -c %Y "$R/gate.json" 2>/dev/null || echo 0)"

run_line --resume "$R" --stop-after sync > "$WORK/o-sync" 2>&1 || true
sync_out="$(cat "$WORK/o-sync")"

check "sync notices the base moved"    "SYNC REBASED" "$sync_out"
check "it is not skipped as already-PASS" "SYNC " "$sync_out"
want  "the candidate is a new commit"  "HEAD should have moved" \
      test "$(git -C "$REPO" rev-parse HEAD)" != "$OLD_CANDIDATE"
want  "the stale gate result is filed, not deleted" "pre-rebase-1/gate.json" \
      test -f "$R/pre-rebase-1/gate.json"
want  "and the run record says a rebase happened" "rebases[0]" \
      test "$(jq -r '[.rebases[]?] | length' "$R/run.json")" = 1

printf '\n-- and resuming replays exactly the steps the rebase invalidated --\n\n'
run_line --resume "$R" --stop-after audit-package > "$WORK/o-rewind" 2>&1 || true
rewind_out="$(cat "$WORK/o-rewind")"

check "the orchestrator rewinds"       "REWIND to gate" "$rewind_out"
check "and says why"                   "rebased onto origin/main" "$rewind_out"
check "the gate runs again"            "GATE bean-001" "$rewind_out"
check "the implementation is re-audited" "JUDGE  impl" "$rewind_out"
check "the package is re-audited"      "PACKAGE CHECK" "$rewind_out"
# The two that must NOT run again. The spec audit judged the plan and the plan
# did not change; the document describes the same implementation. Re-running them
# would cost two model sessions to reach the same answer.
nope  "the spec audit is not re-run"   "JUDGE  spec" "$rewind_out"
# Not "skipped" — never reached. The rewind lands on the gate, so the four steps
# before it are not visited at all, which is the difference between deciding they
# are still good and never asking.
nope  "the spec is not rewritten"      "STEP   spec " "$rewind_out"
check "the document is skipped"        "SKIP   doc" "$rewind_out"
want  "a fresh gate result exists"     "gate.json should have been rewritten" \
      test "$(stat -c %Y "$R/gate.json" 2>/dev/null || echo 0)" -gt "$OLD_GATE_TS"
want  "the rewind is consumed, not sticky" "rewind.json should be gone" \
      test ! -f "$R/rewind.json"
want  "the new verdict names the new candidate" "candidate_sha should be HEAD" \
      test "$(jq -r 'select(.candidate_sha) | .candidate_sha' "$R"/verdicts/impl.attempt-*.json | tail -1)" \
         = "$(git -C "$REPO" rev-parse HEAD)"

printf '\n== a doc step that writes nothing is asked again ==\n\n'
#
# Two real doc sessions ended with the model saying it was about to write the
# document and closing without writing it — thirty-odd minutes each, and the run
# halted for a human whose whole job would have been to say "you did not write
# the file". That is not a judgement call: the file is there or it is not.
cat > "$WORK/bin/pi-nodoc" <<'STUB'
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
    cp "$STUB_TASKS" "$run_dir/tasks.yaml"; cp "$STUB_SPEC_MD" "$run_dir/spec.md" ;;
  *factory-build-task*)
    adir="${prompt##* }"; rest="${prompt% *}"; task="${rest##* }"
    case "$task" in
      task-1) mkdir -p src && printf 'GOOD\n' > src/a.py ;;
      task-2) mkdir -p src && printf 'second\n' > src/b.py ;;
    esac ;;
  *factory-doc*)
    # First time: narrate and write nothing. On the retry — recognisable by the
    # findings file in the prompt — actually write it.
    case "$prompt" in
      *doc-findings.md*)
        # Derive the run dir from the findings path, which is inside it. Parsing
        # by field position is one trailing token away from writing nowhere.
        findings="$(printf '%s' "$prompt" | tr ' ' '\n' | grep 'doc-findings.md$' | head -1)"
        run_dir="$(dirname "$findings")"
        cat > "$run_dir/impl-detail.md" <<'DOC'
# What was built

## Summary

Two modules under `src/`, one per task, each satisfying one acceptance criterion.
Nothing else changed, nothing imports them yet, and the whole change is two files
of one line each.

## What changed and why

Two modules were added under `src/`, one per task, each satisfying one of the
bean's acceptance criteria. Nothing else in the tree was touched, and neither
file is imported by anything yet.

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
their declared paths, and passed their own checks on the first attempt with no
feedback round needed.

## Risk & blast radius, as built

Two new files that nothing imports. Reverting either restores the previous state
exactly, no other file refers to them, and no configuration or dependency
changed, so the blast radius is the two files themselves.

## Evidence

Each task's verify ran in the controller rather than in the session that wrote
the code, and the bean's two acceptance criteria were re-run against the whole
diff at the gate. Both passed.

## How to verify locally

Check out the branch and run `grep GOOD src/a.py` and `test -f src/b.py`. Those
are the bean's acceptance criteria verbatim, which is why they are worth running
by hand rather than paraphrasing.

## Rollback

Revert the branch's two commits, or delete both files. Nothing else refers to
them, so there is no ordering to respect and no data to migrate back.
DOC
        ;;
      *) printf 'I am currently writing the documentation.\n' ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/pi-nodoc"

rm -rf "$REPO/factory/runs"
git -C "$REPO" checkout -q main 2>/dev/null
git -C "$REPO" branch -D bean/bean-001-scaffold >/dev/null 2>&1
git -C "$REPO" clean -fdq
rm -f "$GH_CALLS"
cp "$WORK/bin/pi" "$WORK/bin/pi-keep"
cp "$WORK/bin/pi-nodoc" "$WORK/bin/pi"
run_line > "$WORK/o-nodoc" 2>&1 || true
cp "$WORK/bin/pi-keep" "$WORK/bin/pi"
nodoc="$(cat "$WORK/o-nodoc")"

check "the empty step is noticed"   "doc produced no document" "$nodoc"
check "and asked again"             "asking again, with that as the finding" "$nodoc"
check "the second attempt writes it" "DOC CHECK" "$nodoc"
if grep -qF 'HALT  doc' <<<"$nodoc"; then
  printf '  --- the doc-retry run, in full ---\n'
  sed 's/^/  | /' <<<"$nodoc" | tail -24
  printf '  --- end ---\n'
fi
nope  "so the run does not halt on it" "HALT  doc" "$nodoc"

printf '\n-- and a doc step that leaves an earlier attempt'"'"'s file alone is the same failure --\n\n'
#
# The version of this that actually cost an evening. A resumed run arrives with
# the previous attempt'"'"'s document already on disk; the session narrates and
# writes nothing; "does the file exist" answers yes; no retry is offered and the
# run halts for a human. The output was present and it was not this attempt'"'"'s.
DOC_R="$(ls -1dt "$REPO"/factory/runs/*/ 2>/dev/null | head -1)"
STALE_SUM="$(sha256sum "$DOC_R/impl-detail.md" | cut -d' ' -f1)"
# Put the run back to just-before-doc, with the good document still sitting there.
python3 - "$DOC_R/steps.jsonl" <<'PYEOF'
import json, sys
p = sys.argv[1]
keep = []
for line in open(p):
    line = line.strip()
    if not line:
        continue
    r = json.loads(line)
    # Everything the document depends on stays PASS; doc and what follows it go.
    if r.get("step") in ("doc", "audit-doc", "audit-package", "sync", "pr"):
        continue
    keep.append(r)
open(p, "w").write("".join(json.dumps(r) + "\n" for r in keep))
PYEOF
rm -f "$DOC_R/QUESTIONS.md"
cp "$WORK/bin/pi" "$WORK/bin/pi-keep2"
cat > "$WORK/bin/pi" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2 ;; *) shift ;; esac; done
sess="${PI_SESSIONS_DIR:-.}/stub-$(date +%s%N).jsonl"
mkdir -p "$(dirname "$sess")"
printf '{"type":"session","version":"stub","id":"stub","cwd":"%s"}\n' "$PWD" > "$sess"
# Narrate, never write — whatever the prompt says, including on the retry.
printf 'Now writing the full document.\n'
exit 1
STUB
chmod +x "$WORK/bin/pi"
run_line --resume "$DOC_R" --stop-after doc > "$WORK/o-stale" 2>&1 || true
cp "$WORK/bin/pi-keep2" "$WORK/bin/pi"
stale="$(cat "$WORK/o-stale")"

check "the untouched document is noticed" "left the previous attempt's document untouched" "$stale"
check "run-step says whose file it is"    "Those files are a previous attempt's, and nothing else was written" "$stale"
nope  "and does not call it work done"    "failure after the work" "$stale"
check "the finding says so too"           "byte-for-byte what an earlier attempt" \
      "$(cat "$DOC_R/doc-findings.md" 2>/dev/null)"
want  "the earlier document is left on disk" "a bad attempt must not destroy a good file" \
      test "$(sha256sum "$DOC_R/impl-detail.md" | cut -d' ' -f1)" = "$STALE_SUM"

printf '\n-- a doc step that writes the document and THEN dies still counts --\n\n'
#
# A real doc session wrote a complete 18KB document, printed its report, and then
# returned 143. Seventeen minutes of model time were thrown away over a signal
# that arrived after the work was finished, and the run halted for a human whose
# job would have been to look at the file and say "that is fine".
#
# The exit status of a `pi -p` session is fallback evidence — already the rule
# here for a verdict the child stamped. It is the same for a step whose output is
# a file, and it is safe because it is not the last word: doc-check reads the
# document immediately afterwards, so a half-written one fails on its contents.
DOC_R2="$(ls -1dt "$REPO"/factory/runs/*/ 2>/dev/null | head -1)"
python3 - "$DOC_R2/steps.jsonl" <<'PYLATE'
import json, sys
p = sys.argv[1]
rows = [json.loads(l) for l in open(p) if l.strip()]
rows = [r for r in rows if r.get("step") not in ("doc", "audit-doc", "audit-package", "sync", "pr")]
open(p, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PYLATE
# Keep the good document the earlier stub wrote; it is what this stub will write
# back, so the test is about the exit code and nothing else.
cp "$DOC_R2/impl-detail.md" "$WORK/doc.md"
export STUB_DOC="$WORK/doc.md"
rm -f "$DOC_R2/QUESTIONS.md" "$DOC_R2/impl-detail.md" "$DOC_R2/doc-findings.md"
cp "$WORK/bin/pi" "$WORK/bin/pi-keep3"
# Writes a real document on its first call and then exits 143, exactly as a
# session killed after its last turn does.
cat > "$WORK/bin/pi" <<'LATESTUB'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2 ;; *) shift ;; esac; done
sess="${PI_SESSIONS_DIR:-.}/stub-$(date +%s%N).jsonl"
mkdir -p "$(dirname "$sess")"
printf '{"type":"session","version":"stub","id":"stub","cwd":"%s"}\n' "$PWD" > "$sess"
case "$prompt" in
  *factory-doc*)
    run_dir="$(printf '%s' "$prompt" | tr ' ' '\n' | grep '/factory/runs/' | head -1)"
    run_dir="${run_dir%/doc-findings.md}"
    cp "$STUB_DOC" "$run_dir/impl-detail.md"
    printf 'Document written. Now I will be killed.\n' ;;
esac
exit 143
LATESTUB
chmod +x "$WORK/bin/pi"
run_line --resume "$DOC_R2" --stop-after doc > "$WORK/o-latedeath" 2>&1 || true
cp "$WORK/bin/pi-keep3" "$WORK/bin/pi"
late="$(cat "$WORK/o-latedeath")"

want "the document was written"         "impl-detail.md should exist" \
     test -s "$DOC_R2/impl-detail.md"
check "the late exit is not fatal"      "the output stands" "$late"
check "and the exit code is still said" "child exited 143" "$late"
nope  "the run does not halt on it"     "HALT  doc" "$late"
check "and the step is recorded PASS"   "STEP   doc   PASS" "$late"

printf '\n== the question a run halted on is cleared when the run reaches its step ==\n\n'
#
# `finish()` archives QUESTIONS.md when a run completes, which is right and far
# too late: `pr` runs before the finish and refuses while one sits at the run
# root — "something asked for a human and never got one". bean-002 halted at
# `doc`, was resumed, passed `doc` on the retry, walked the rest of the line and
# had its pull request refused over a question about a step that had since
# succeeded.
rm -rf "$REPO/factory/runs"
git -C "$REPO" checkout -q main 2>/dev/null
git -C "$REPO" branch -D bean/bean-001-scaffold >/dev/null 2>&1
git -C "$REPO" clean -fdq
run_line --stop-after spec > /dev/null 2>&1 || true
QR="$(ls -d "$REPO"/factory/runs/*/ 2>/dev/null | tail -1)"
# A run that halted at `spec` and was left with the question on disk.
printf '# QUESTIONS — halted at spec\n\nwhat does spec need?\n' > "${QR}QUESTIONS.md"
jq -c '. + {status:"halted", halted_at_step:"spec", halted_at:"2026-09-18T00:00:00Z"}' \
  "${QR}run.json" > "${QR}run.json.tmp" && mv "${QR}run.json.tmp" "${QR}run.json"
out="$(run_line --resume "$QR" --stop-after spec 2>&1 || true)"
check "it says the question is resolved" "RESOLVED" "$out"
want  "QUESTIONS.md is off the run root"  "it must not block the pull request" \
      test ! -f "${QR}QUESTIONS.md"
want  "and kept, not deleted"             "the history is the point" \
      bash -c "ls '${QR}resolved-questions/' 2>/dev/null | grep -q QUESTIONS"
want  "run.json no longer says halted"    "halted_at_step should be gone" \
      bash -c "[ \"\$(jq -r '.halted_at_step // \"none\"' '${QR}run.json')\" = none ]"

printf '\n-- and a question about the step that WROTE it does not deadlock --\n\n'
#
# The case that tells the two designs apart, and the reason the first version of
# this fix shipped broken. When `pr` is what halted, the file blocking `pr` is
# the one `pr` wrote: clearing it only AFTER the step passes means `pr` must
# pass to clear the thing stopping it from passing. bean-002 halted at `pr`
# twice under that version, one step from a finished bean.
#
# It has to be a step that actually RUNS and would fail — a question about a
# step already recorded PASS clears under either design, which is why the first
# version of this section passed against the broken code.
rm -rf "$REPO/factory/runs"
git -C "$REPO" checkout -q main 2>/dev/null
git -C "$REPO" branch -D bean/bean-001-scaffold >/dev/null 2>&1
git -C "$REPO" clean -fdq
rm -f "$GH_CALLS"
run_line --stop-after sync > /dev/null 2>&1 || true
DL="$(ls -d "$REPO"/factory/runs/*/ 2>/dev/null | tail -1)"
printf '# QUESTIONS — bean-001: pipeline halted at `pr`\n\nQUESTIONS.md was at the run root.\n' > "${DL}QUESTIONS.md"
jq -c '. + {status:"halted", halted_at_step:"pr"}' \
  "${DL}run.json" > "${DL}run.json.tmp" && mv "${DL}run.json.tmp" "${DL}run.json"
out="$(run_line --resume "$DL" --stop-after pr 2>&1 || true)"
check "the question clears on arrival"  "RESOLVED" "$out"
nope  "so pr does not refuse for it"    "something asked for a human and never got one" "$out"
check "and records none outstanding"    "questions                none outstanding" "$out"
nope  "so the step is not refused"       "PR REFUSED" "$out"
# Deliberately not asserting that the push succeeds: this fixture shares one
# origin across sections, so the branch is already there from an earlier run and
# the push is a non-fast-forward. What is under test is the precondition, and
# reaching the push is proof it passed.

printf '\n-- but a question about a DIFFERENT step is left alone --\n\n'
#
# Resolving on "some step ran" would clear a question about a step the run has
# not reached, which is the whole failure mode in reverse.
#
# Against $DL, the run the section above left behind: the section before that
# wiped factory/runs, so a run dir captured earlier no longer exists — and the
# only sign was two "No such file or directory" lines above a failing
# assertion. Sixth fixture in this repository to break by sharing state across
# sections.
printf '# QUESTIONS — halted at gate\n\nwhat does gate need?\n' > "${DL}QUESTIONS.md"
jq -c '. + {status:"halted", halted_at_step:"gate"}' \
  "${DL}run.json" > "${DL}run.json.tmp" && mv "${DL}run.json.tmp" "${DL}run.json"
out="$(run_line --resume "$QR" --stop-after spec 2>&1 || true)"
want  "it is still there"                 "a question about gate is not answered by spec" \
      test -f "${DL}QUESTIONS.md"
nope  "and nothing claims otherwise"      "RESOLVED" "$out"
rm -f "${DL}QUESTIONS.md"

printf '\n== a resume closes attempts the previous process left open ==\n\n'
#
# step.sh refuses a second `start` while one is open, which is right: without it
# steps.jsonl could carry an `end` with no `start`, and telemetry joins them on
# (step, attempt). But a process that was KILLED leaves exactly that shape, and
# the resume then cannot record the step at all:
#
#   pipeline: error: step audit-doc already has an open attempt
#             (starts=1, ends=0); close it before starting another
#
# Seen on bean-002 after I stopped a run mid-audit to fix the bug it had just
# exposed. The run carried on and the step went unrecorded — the invariant held
# and the record lost the step, which is the worst of both.
rm -rf "$REPO/factory/runs"
git -C "$REPO" checkout -q main 2>/dev/null
git -C "$REPO" branch -D bean/bean-001-scaffold >/dev/null 2>&1
git -C "$REPO" clean -fdq
run_line --stop-after spec > /dev/null 2>&1 || true
ORPH="$(ls -d "$REPO"/factory/runs/*/ 2>/dev/null | tail -1)"
# An attempt left open by a process that is gone.
printf '{"ts":"2026-09-18T00:00:00.000Z","step":"audit-doc","event":"start","attempt":1,"verdict":null}\n' \
  >> "${ORPH}steps.jsonl"
out="$(run_line --resume "$ORPH" --stop-after spec 2>&1 || true)"
check "the resume says it closed one"  "closing an attempt the previous process left open" "$out"
want  "and it is closed"               "starts and ends must balance for audit-doc" \
      bash -c "[ \"\$(jq -rs '[.[] | select(.step == \"audit-doc\" and .event == \"start\")] | length' '${ORPH}steps.jsonl')\" = \"\$(jq -rs '[.[] | select(.step == \"audit-doc\" and .event == \"end\")] | length' '${ORPH}steps.jsonl')\" ]"
want  "as ABANDONED, not as a pass"    "nothing judged the work" \
      bash -c "[ \"\$(jq -rs '[.[] | select(.step == \"audit-doc\" and .event == \"end\")] | last.verdict' '${ORPH}steps.jsonl')\" = ABANDONED ]"
nope  "and step.sh no longer refuses"  "already has an open attempt" "$out"

printf '\n== a document the controller rejects is handed the findings, once ==\n\n'
#
# doc-check produces more actionable complaints than any judge has managed, and
# the run used to halt on them. bean-002 stopped on "deviations from the spec —
# section missing" and "changed files the walkthrough never covers: ...", and the
# person reading that halt would have had exactly one job: retyping those two
# lines into a prompt. The spec branch has re-entered its authoring step with
# spec-check's findings since 2026-09-16 for precisely this reason; doc did not,
# and the machinery — doc-findings.md, the `--` EXTRA argument — was already
# there and used by the rarer "you wrote nothing" retry.
#
# The stub writes a document missing one required section the first time, and the
# real one when it sees the findings file in its prompt.
sed "s|\*) printf 'I am currently writing the documentation.*|*) run_dir=\"\${prompt##* }\"; printf '# What was built\\n\\n## Summary\\n\\nOne sentence, and none of the sections the check wants.\\n' > \"\$run_dir/impl-detail.md\" ;;|" \
  "$WORK/bin/pi-nodoc" > "$WORK/bin/pi-baddoc"
chmod +x "$WORK/bin/pi-baddoc"

rm -rf "$REPO/factory/runs"
git -C "$REPO" checkout -q main 2>/dev/null
git -C "$REPO" branch -D bean/bean-001-scaffold >/dev/null 2>&1
git -C "$REPO" clean -fdq
rm -f "$GH_CALLS"
cp "$WORK/bin/pi-baddoc" "$WORK/bin/pi"
run_line > "$WORK/o-baddoc" 2>&1 || true
cp "$WORK/bin/pi-keep" "$WORK/bin/pi"
baddoc="$(cat "$WORK/o-baddoc")"

check "the check rejects it"          "DOC CHECK FAIL" "$baddoc"
check "and the step is re-entered"    "re-entering \`doc\` with the findings" "$baddoc"
BADR="$(ls -d "$REPO"/factory/runs/*/ 2>/dev/null | tail -1)"
check "the findings are the check's own words" "deviations from the spec" \
      "$(cat "${BADR}doc-findings.md" 2>/dev/null)"
check "and they say these are not opinions" "not opinions" \
      "$(cat "${BADR}doc-findings.md" 2>/dev/null)"
check "the re-check passes"           "DOC CHECK PASS" "$baddoc"
nope  "so the run does not halt on it" "HALT  doc" "$baddoc"

printf '\n-- but only once: a second failure is a question for a person --\n\n'
#
# A model that cannot act on findings this specific is not going to act on them
# the third time either, and spending attempts on it hides the real problem.
sed "s|\*doc-findings.md\*)|*doc-findings-never-matches*)|" \
  "$WORK/bin/pi-baddoc" > "$WORK/bin/pi-baddoc2"
chmod +x "$WORK/bin/pi-baddoc2"
rm -rf "$REPO/factory/runs"
git -C "$REPO" checkout -q main 2>/dev/null
git -C "$REPO" branch -D bean/bean-001-scaffold >/dev/null 2>&1
git -C "$REPO" clean -fdq
cp "$WORK/bin/pi-baddoc2" "$WORK/bin/pi"
run_line > "$WORK/o-baddoc2" 2>&1 || true
cp "$WORK/bin/pi-keep" "$WORK/bin/pi"
baddoc2="$(cat "$WORK/o-baddoc2")"
check "it says it will not try again" "Not retrying further" "$baddoc2"
check "and the run halts"             "HALT  doc" "$baddoc2"

printf '\n-- and the halt shows what the check said, instead of denying it exists --\n\n'
#
# This file used to tell a person "the failure carries no findings a retry could
# address" while doc-check.txt sat beside it naming two. The sentence was
# written for steps that genuinely have nothing to hand back, and `doc` is not
# one of them — saying it here sends a reader away from the answer.
BADQ="$(ls -d "$REPO"/factory/runs/*/ 2>/dev/null | tail -1)QUESTIONS.md"
want  "QUESTIONS.md was written"      "$BADQ should exist" test -s "$BADQ"
q="$(cat "$BADQ" 2>/dev/null)"
check "it quotes the check"           "doc-check" "$q"
check "with the failing line"         "FAIL" "$q"
check "and says it was handed back"   "handed back verbatim" "$q"
nope  "and no longer denies findings" "carries no findings a retry could address" "$q"
want  "exactly two doc attempts"      "one, plus the single retry" \
      bash -c "[ \"\$(grep -c 're-entering .doc. with the findings' <<<\"\$1\")\" = 1 ]" _ "$baddoc2"

printf '\n-- and a resumed run does not walk past the document it rejected --\n\n'
#
# The hole this closes. run-step records `doc` as PASS because the model wrote a
# document and exited cleanly; doc-check then rejects it and the run halts,
# correctly. On resume, the skip rule reads that PASS, prints "SKIP doc already
# PASS", and the run continues with the document the controller refused — which
# is what bean-002 did on 2026-09-17, carrying a document missing a required
# section into its own audit.
#
# A halt that a resume forgets is not a halt. The step's end record now says FAIL
# and why, so the resume re-enters it.
BADR2="$(ls -d "$REPO"/factory/runs/*/ 2>/dev/null | tail -1)"
want  "the step record says FAIL"     "the last doc end must not be PASS" \
      bash -c "[ \"\$(jq -rs '[.[] | select(.step == \"doc\" and .event == \"end\")] | last.verdict' '${BADR2}steps.jsonl')\" = FAIL ]"
want  "and names what rejected it"    "rejected_by should be doc-check" \
      bash -c "[ \"\$(jq -rs '[.[] | select(.step == \"doc\" and .event == \"end\")] | last.rejected_by' '${BADR2}steps.jsonl')\" = doc-check ]"
# And it is still JSONL. jq reads a stream of values, so every reader in this
# repository keeps working against a pretty-printed steps.jsonl — which is how
# the first version of the amend shipped: `jq -s` without `-c`, one object over
# five lines, and the assertion above still green because it asked for the value
# and not the shape.
want  "steps.jsonl is still one object per line" "the amend must not pretty-print" \
      bash -c "while IFS= read -r l; do printf '%s' \"\$l\" | jq -e . >/dev/null || exit 1; done < '${BADR2}steps.jsonl'"
cp "$WORK/bin/pi-baddoc" "$WORK/bin/pi"
run_line --resume "$BADR2" --stop-after doc > "$WORK/o-badresume" 2>&1 || true
cp "$WORK/bin/pi-keep" "$WORK/bin/pi"
badresume="$(cat "$WORK/o-badresume")"
nope  "the resume does not skip doc"  "SKIP   doc" "$badresume"
check "it runs the step again"        "DOC CHECK" "$badresume"

printf '\n== a spec the controller rejects is handed back once, not halted ==\n\n'
#
# spec-check produces the most actionable complaints in the line — "proposed
# change: only 77 characters (min 80)" — and used to halt the run with them,
# so the commonest spec defect needed a human to transcribe a specific
# instruction to a model that was right there. An audit that says revise already
# re-enters the authoring step with its findings; this does the same.
SPEC_THIN="$WORK/spec-thin.md"
# Replace the WHOLE section, not its first line: a one-line sed left the rest of
# the paragraph behind and the section was still comfortably over the minimum,
# so the first version of this test asserted a complaint that never happened.
"$PIPELINE_DIR/../../.venv/bin/python" - "$WORK/spec.md" "$SPEC_THIN" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r"(## Proposed change\n\n).*?(?=\n## )", r"\1Too short.\n", text, count=1, flags=re.S)
open(sys.argv[2], "w").write(text)
PY
# The stub writes the thin spec first, then the good one, so the retry has
# something different to produce — a model that rewrites identically is a
# different failure and is not what this tests.
cat > "$WORK/bin/pi-retry" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
prompt=""
while [ $# -gt 0 ]; do case "$1" in -p) prompt="$2"; shift 2 ;; *) shift ;; esac; done
sess="${PI_SESSIONS_DIR:-.}/stub-$(date +%s%N).jsonl"
mkdir -p "$(dirname "$sess")"
printf '{"type":"session","version":"stub","id":"stub","cwd":"%s"}\n' "$PWD" > "$sess"
case "$prompt" in
  *factory-spec*)
    # A findings file as the last argument means this is the retry.
    case "$prompt" in
      *spec-check-findings.md*)
        run_dir="$(printf '%s' "$prompt" | awk '{print $(NF-1)}')"
        cp "$STUB_SPEC_MD" "$run_dir/spec.md"
        cp "$STUB_TASKS" "$run_dir/tasks.yaml" ;;
      *)
        run_dir="${prompt##* }"
        cp "$STUB_SPEC_THIN" "$run_dir/spec.md"
        cp "$STUB_TASKS" "$run_dir/tasks.yaml" ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/pi-retry"

rm -rf "$REPO/factory/runs"
git -C "$REPO" checkout -q main 2>/dev/null
git -C "$REPO" branch -D bean/bean-001-scaffold >/dev/null 2>&1
git -C "$REPO" clean -fdq
cp "$WORK/bin/pi" "$WORK/bin/pi-real"
cp "$WORK/bin/pi-retry" "$WORK/bin/pi"
STUB_SPEC_THIN="$SPEC_THIN" run_line --stop-after spec > "$WORK/o-retry" 2>&1 || true
cp "$WORK/bin/pi-real" "$WORK/bin/pi"
retry_out="$(cat "$WORK/o-retry")"

check "the thin section is caught"      "too thin to be worth a reader" "$retry_out"
check "and handed back, not halted"     "re-entering \`spec\` with the findings" "$retry_out"
check "the second attempt passes"       "SPEC CHECK PASS" "$retry_out"
nope  "so the run does not halt"        "HALT  spec" "$retry_out"

# Deliberately no cleanup run afterwards. The first version re-ran the whole
# line here to restore state for the checks below, which pushed a rebuilt branch
# to an origin that already had the first one; pr.sh refused, correctly, and the
# phase-1 audit reported pr(FAIL) for a run that had never been meant to open one.
# This block now runs last and leaves the repository however it likes.

printf '\n== an audit that halts the run says the advisory option exists ==\n\n'
#
# FACTORY_ADVISORY_AUDITS defaults to 0 and stays that way: a default that quietly
# weakens a gate is the fail-open shape this project keeps finding. But on
# 2026-09-16 twelve audits of a real run at the best known configuration produced
# zero stampable verdicts, so an operator hitting this halt is looking at the
# normal outcome, not an exception — and should not have to read RESUME.md to
# find that out.
rm -rf "$REPO/factory/runs"
git -C "$REPO" checkout -q main 2>/dev/null
git -C "$REPO" branch -D bean/bean-001-scaffold >/dev/null 2>&1
git -C "$REPO" clean -fdq
rm -f "$GH_CALLS"
out="$(STUB_JUDGE_SILENT=1 run_line 2>&1 || true)"
check "the halt names the judge"        "NO JUDGEMENT" "$out"
check "and says it may not be the artifact" "may not be a defect in the artifact" "$out"
check "with the measurement behind that" "zero verdicts the" "$out"
check "and the flag that changes it"    "FACTORY_ADVISORY_AUDITS=1" "$out"
check "and that advisory is not silent" "recorded either way" "$out"
check "and how to measure it here"      "factory reaudit" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
