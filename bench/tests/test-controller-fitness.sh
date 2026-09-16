#!/usr/bin/env bash
# test-controller-fitness.sh — the scoring that decides what the judge is still for.
#
# "1 of 5 named by a check, 4 not decidable" was the sentence this harness
# produced, and the closing line — "the ones marked not decidable are the judge's
# actual job" — is how the project decided where to spend effort. It has been
# wrong twice in one day:
#
#   * `tautological-verify` was scored a miss because its fixture was not seeding
#     the defect, so the controller was credited with missing something it catches.
#   * `contradicts-non-goal` is decidable for any bean that says where its
#     non-goals live, and reporting it as the judge's job hides a mechanism that
#     exists and is simply unused by the bean at hand.
#
# The invariant this file exists for is the general one: **a catch requires a
# rejection.** A catchphrase that also appears in a passing line would otherwise
# score a miss as a catch, which is exactly how the first of those two happened.
#
# Driven against a stub spec-check, so no container and no model.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$BENCH/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}

# A repository on its default branch with a clean tree — the harness refuses
# otherwise, correctly, because a spec measured against a tree where the work is
# already done is not a measurement.
REPO="$WORK/repo"; mkdir -p "$REPO/factory"
( cd "$REPO" && git init -q -b main . && git config user.email t@e.com && git config user.name T )
printf 'schema_version: repo-config/1.0.0\nrepo: e/x\ndefault_branch: main\nmerge_mode: human_required\n' \
  > "$REPO/factory/repo.yaml"
printf '{"runs_root":"factory/runs"}\n' > "$REPO/factory/pipeline-config.json"
cat > "$REPO/factory/bean.yaml" <<'YAML'
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
  - no solver code
YAML
printf '# spec\n\n## Proposed change\n\nsomething\n' > "$WORK/spec.md"
printf 'schema_version: tasks/1.0.0\ntasks:\n  - id: task-1\n    intent: do it\n    write_paths: [src/a.py]\n    verify:\n      - { kind: command, run: ["true"] }\n' > "$WORK/tasks.yaml"
( cd "$REPO" && git add -A && git commit -q -m init )

# A pipeline copy whose spec-check is a stub: it prints whatever STUB_OUT says and
# exits STUB_RC. The mutations still run, from the real judge-fitness.sh.
SNAP="$WORK/snap"; mkdir -p "$SNAP/factory" "$SNAP/bench"
cp -r "$ROOT/factory/." "$SNAP/factory/"
cp -r "$ROOT/bench/." "$SNAP/bench/"
cat > "$SNAP/factory/pipeline/spec-check.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_OUT:-ok    everything    fine}"
exit "${STUB_RC:-0}"
STUB
chmod +x "$SNAP/factory/pipeline/spec-check.sh"

cf() {
  FACTORY_NO_SNAPSHOT=1 bash "$SNAP/bench/controller-fitness.sh" \
    --spec "$WORK/spec.md" --tasks "$WORK/tasks.yaml" --bean "$REPO/factory/bean.yaml" \
    --repo "$REPO" --out "$WORK/out.json" "$@" 2>&1
}

printf '\n== a catch requires a rejection ==\n\n'
#
# The catchphrase for `tautological-verify` is "every verify already passes", and
# spec-check prints that in its FAILING line. If the same words could appear in a
# passing line — as "non-goals" does, being both the name of a check and the start
# of its failure message — a miss would be scored a catch.
out="$(STUB_RC=0 STUB_OUT='ok    verify can fail    every verify already passes for: none, which may be fine' \
       cf --only tautological-verify)"
check "the phrase in a PASSING line is not a catch" "not decidable" "$out"
check "and it is counted as a miss"    "named by a check 0" "$out"

out="$(STUB_RC=1 STUB_OUT='FAIL  verify can fail    every verify already passes for: task-1' \
       cf --only tautological-verify)"
check "the same phrase in a failure is" "every verify already passes" "$out"
check "and it is counted as a catch"   "named by a check 1" "$out"

printf '\n-- a rejection for the wrong reason is neither --\n\n'
#
# The distinction the whole harness turns on: the controller refused, but not for
# the defect that was seeded. Counting that as a catch would credit a check with
# finding something it never looked at.
out="$(STUB_RC=1 STUB_OUT='FAIL  schema    tasks.yaml is not valid' cf --only tautological-verify)"
check "it says so"                     "rejected, but not for the seeded defect" "$out"
check "and is not a catch"             "named by a check 0" "$out"
nope  "nor a miss"                     "not decidable 1" "$out"

printf '\n== the clean control ==\n\n'
out="$(STUB_RC=0 cf --only clean)"
nope "a pass on the control is no false alarm" "false alarms 1" "$out"
out="$(STUB_RC=1 STUB_OUT='FAIL  something    anything' cf --only clean)"
check "rejecting it is a false alarm"  "false alarms 1" "$out"

printf '\n== not decidable, and not decidable FOR THIS BEAN ==\n\n'
#
# contradicts-non-goal became decidable for any bean that says where its non-goals
# live. Against one whose non_goals are prose there is nothing to check, and
# reporting that as "the judge's actual job" hides a mechanism that exists.
out="$(STUB_RC=0 cf --only contradicts-non-goal)"
check "the closing text says which bean" "bean-001 declares no non-goal in" "$out"
check "and that the mechanism exists"  "bean-forbids.sh" "$out"

python3 - "$REPO/factory/bean.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("non_goals:\n  - no solver code\n",
  'non_goals:\n  - text: no solver code\n    forbidden_paths: ["src/**/solver/**"]\n')
open(p, "w").write(s)
PY
( cd "$REPO" && git add -A && git commit -q -m annotate )
out="$(STUB_RC=0 cf --only contradicts-non-goal)"
nope "an annotated bean gets no such note" "declares no non-goal in" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
