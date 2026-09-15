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
check "run-step says whose file it is"    "That file is a previous attempt's" "$stale"
nope  "and does not call it work done"    "failure after the work" "$stale"
check "the finding says so too"           "byte-for-byte what an earlier attempt" \
      "$(cat "$DOC_R/doc-findings.md" 2>/dev/null)"
want  "the earlier document is left on disk" "a bad attempt must not destroy a good file" \
      test "$(sha256sum "$DOC_R/impl-detail.md" | cut -d' ' -f1)" = "$STALE_SUM"

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
