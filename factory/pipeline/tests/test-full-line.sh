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
trap 'rm -rf "$WORK"' EXIT

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
{"runs_root":"factory/runs",
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
