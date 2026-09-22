#!/usr/bin/env bash
# test-queue.sh — what is runnable, and the one rule that is not about ordering.
#
# §04 gates what enters the line: a bean reaches the queue only with
# `status: approved`. Everything else here is bookkeeping about order and
# dependencies, and that one is a checkpoint — a queue that quietly included a
# draft would route around the only human decision before a model starts work.
#
# So the draft case is asserted three ways: it is not in `ready`, it is reported
# as `refused` rather than skipped, and `factory go --bean <it>` refuses too,
# because a flag that bypassed the gate would make the gate optional.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FACTORY="$PIPELINE_DIR/../bin/factory"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

REPO="$WORK/repo"; git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e.com; git -C "$REPO" config user.name T
mkdir -p "$REPO/factory/runs"
cat > "$REPO/factory/pipeline-config.json" <<'CFG'
{"runs_root":"factory/runs","branch_pattern":"bean/BEAN-NNN-<slug>",
 "bean_dir_pattern":"factory/beans/BEAN-NNN-<slug>","bean_index_path":"factory/beans/INDEX.md",
 "corpus":{"name":"fix","bean_set":"v1","requirements_sha256":"9f2c1a4b7d3e8056f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f701"}}
CFG
bean() { # bean <id> <order> <status> <title> [deps...]
  local id="$1" order="$2" status="$3" title="$4"; shift 4
  local d="$REPO/factory/beans/$id-x"; mkdir -p "$d"
  { printf 'schema_version: bean/2.0.0\nid: %s\ntitle: %s\nstatus: %s\n' "$id" "$title" "$status"
    printf 'approval:\n  order: %s\n' "$order"
    if [ "$#" -gt 0 ]; then
      printf 'dependencies:\n'
      for dep in "$@"; do printf '  - %s\n' "$dep"; done
    else
      printf 'dependencies: []\n'
    fi
  } > "$d/bean.yaml"
}
bean bean-001 1 approved "The scaffold"
bean bean-002 2 approved "The models"        bean-001
bean bean-003 3 approved "The rules"         bean-002
bean bean-004 4 draft    "Not approved yet"  bean-001
bean bean-005 5 approved "Needs the draft"   bean-004
printf 'x\n' > "$REPO/keep.txt"
# Run directories are gitignored in a scaffolded repo, and the fixture has to
# mirror that: without it, `git add -A` on a bean branch commits the run record
# and checking out main deletes it — so the queue would see no runs at all, which
# is a fixture failure that looks exactly like a queue bug.
printf 'factory/runs/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init

q()  { ( cd "$REPO" && bash "$PIPELINE_DIR/queue.sh" "$@" 2>&1 ); }
qj() { ( cd "$REPO" && bash "$PIPELINE_DIR/queue.sh" --json 2>/dev/null ); }
fac(){ ( cd "$REPO" && PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" "$FACTORY" "$@" 2>&1 ); }
pr_opened() { # pr_opened <bean-id> — a run that reached a pull request, unmerged
  local d="$REPO/factory/runs/$1-20260101T000000Z"; mkdir -p "$d"
  printf '{"run_id":"r","bean":"%s","branch":"bean/%s-x","pr_url":"https://github.com/x/y/pull/9"}\n' \
    "$1" "$1" > "$d/run.json"
  git -C "$REPO" branch -q "bean/$1-x" 2>/dev/null || true
  # A branch with a commit on it, so "is this merged" has something to answer.
  git -C "$REPO" checkout -q "bean/$1-x"
  printf '%s\n' "$1" > "$REPO/$1.txt"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "$1 work"
  git -C "$REPO" checkout -q main
}
merge_it() { # merge_it <bean-id> — a human merges the pull request
  git -C "$REPO" merge -q --no-ff -m "merge $1" "bean/$1-x"
}
built() { # built <bean-id> — reached a pull request AND was merged
  pr_opened "$1"; merge_it "$1"
}

# --------------------------------------------------------------------------
printf '\n== nothing is built yet: only the first bean is ready ==\n\n'
out="$(q --all)"
eq "one bean is ready"            "bean-001" "$(jq -r '.ready | join(" ")' <<<"$(qj)")"
check "and the rest wait on it"   "waiting on: bean-001(not built)" "$out"
check "in order"                  "bean-002" "$out"

printf '\n-- the unapproved one is refused, not skipped --\n\n'
#
# Skipped and refused look the same in a list and mean opposite things: one is
# "later", the other is "this never enters the line without a human".
eq "its state is refused"         "refused" \
   "$(jq -r '.beans[] | select(.id=="bean-004") | .state' <<<"$(qj)")"
check "and the reason is its status" "status is 'draft', not approved" "$out"
check "the summary counts it"     "refused: 1 bean(s) not approved" "$out"
nope "it is never ready"          '"bean-004"' "$(jq -c '.ready' <<<"$(qj)")"

printf '\n-- and a bean that depends on it can never run --\n\n'
eq "it is blocked"                "blocked" \
   "$(jq -r '.beans[] | select(.id=="bean-005") | .state' <<<"$(qj)")"
check "by the draft, named"       "bean-004(draft)" "$out"

# --------------------------------------------------------------------------
printf '\n-- a bean nobody can parse is refused, not lost --\n\n'
#
# `|| continue` on a failed parse made a malformed bean.yaml vanish: no row, no
# reason, nothing anywhere saying a file under factory/beans/ had been skipped.
# That is failing open against §04 — the gate is "a human approved this", and a
# bean whose status cannot be read has not been approved, it has been lost.
mkdir -p "$REPO/factory/beans/bean-099-broken"
printf 'schema_version: bean/2.0.0\nid: bean-099\n  this: is not valid yaml: [\n' \
  > "$REPO/factory/beans/bean-099-broken/bean.yaml"
out="$(q --all)"
check "the unreadable bean has a row"  "bean-099-broken" "$out"
check "and says it could not be read"  "could not be read as a bean" "$out"
eq "its state is refused"              "refused" \
   "$(jq -r '.beans[] | select(.status == "unreadable" or .status == "no id") | .state' <<<"$(qj)" | head -1)"
nope "and it is never ready"           "bean-099" "$(jq -c '.ready' <<<"$(qj)")"
rm -rf "$REPO/factory/beans/bean-099-broken"

printf '\n== an open pull request is not a merged one ==\n\n'
#
# The distinction the first version of this file did not draw, found by running
# it: bean-001's run recorded a pull request, the queue called it done, bean-002
# started — and the developer model opened a tree with no `src/`, no
# `pyproject.toml` and no `tests/`, because `merge_mode: human_required` means
# that pull request is still open. It cross-checked the tree against bean-001's
# own spec, refused to plan around a missing precondition, and stopped. It was
# right and the queue was wrong.
pr_opened bean-001
out="$(q --all)"
eq "the bean is pr_open, not done"   "pr_open" \
   "$(jq -r '.beans[] | select(.id=="bean-001") | .state' <<<"$(qj)")"
check "and says what is missing"     "pull request open, not merged" "$out"
eq "nothing downstream is ready"     "" "$(jq -r '.ready | join(" ")' <<<"$(qj)")"
check "the dependent names the cause" "bean-001(pull request not merged)" "$out"
check "and the summary asks for the human" "waiting on a human to merge: bean-001" "$out"
check "saying it is by design"       "stops here by design" "$out"

# What merging actually unblocks. "ready: nothing" is a true and unhelpful answer
# to the question the operator is asking, and it is computable from the graph this
# queue has already walked: bean-002's only blocker is the open pull request, so it
# becomes ready the moment that lands. bean-003 waits on bean-002 and does not.
#
# The first version reported BOTH, and every other blocked bean with it. It asked
# `$open | index(.)` — and inside `$open | ...` the `.` is $open, so that asks
# whether the array contains itself: 0, truthy, every dependency "found". Valid jq
# that runs and answers a different question, the same class as `jq -e` on a string.
check "it says what merging unblocks"  "Merging bean-001 makes these ready: bean-002" "$out"
nope  "and not a bean two deep"        "bean-002 bean-003" "$out"

printf '\n-- and merging it moves the line on --\n\n'
merge_it bean-001
out="$(q --all)"
eq "now it is done"                  "done" "$(jq -r '.beans[] | select(.id=="bean-001") | .state' <<<"$(qj)")"
eq "and the next is ready"            "bean-002" "$(jq -r '.ready | join(" ")' <<<"$(qj)")"

printf '\n-- a merged branch that no longer exists locally is still merged --\n\n'
#
# Found on the real line, 2026-09-22: bean-003 was merged and the queue still
# said `pr_open`, so bean-004 and bean-005 stayed blocked and the summary asked a
# human to merge a pull request they had merged an hour earlier.
#
# Nothing was wrong with the merge. A merged pull request usually takes the
# branch with it — GitHub deletes the remote branch, `fetch --prune` deletes the
# tracking ref — and here the local branch never existed at all, because the
# pull request was opened by `gh` from a worktree rather than from a checkout.
# The fallback rev-parsed the bare name recorded in run.json, nothing by that
# name resolved, and no sha is reported as not merged. Which is the safe
# direction for an unknown and the wrong answer for this one: the sha was
# sitting in refs/remotes, unasked.
git -C "$REPO" update-ref "refs/remotes/origin/bean/bean-001-x" "$(git -C "$REPO" rev-parse bean/bean-001-x)"
git -C "$REPO" branch -qD "bean/bean-001-x"
git -C "$REPO" remote add origin "$REPO" 2>/dev/null || true
out="$(q --all)"
eq "the merge is still seen"      "done" "$(jq -r '.beans[] | select(.id=="bean-001") | .state' <<<"$(qj)")"
eq "and the next is still ready"  "bean-002" "$(jq -r '.ready | join(" ")' <<<"$(qj)")"
nope "nobody is asked to re-merge it" "waiting on a human to merge: bean-001" "$out"

printf '\n-- and a branch that is nowhere at all is still not merged --\n\n'
#
# The other half of the same rule: widening the lookup must not turn "I cannot
# find this" into "this landed". An unknown blocks.
git -C "$REPO" update-ref -d "refs/remotes/origin/bean/bean-001-x"
eq "an unresolvable branch blocks" "pr_open" \
   "$(jq -r '.beans[] | select(.id=="bean-001") | .state' <<<"$(qj)")"
git -C "$REPO" branch -q "bean/bean-001-x" "$(git -C "$REPO" rev-parse main^2)"

printf '\n== building one unblocks exactly the next ==\n\n'
out="$(q --all)"
eq "the built one is done"        "done" "$(jq -r '.beans[] | select(.id=="bean-001") | .state' <<<"$(qj)")"
check "and says how it knows"     "merged: https" "$out"
eq "the next is ready"            "bean-002" "$(jq -r '.ready | join(" ")' <<<"$(qj)")"
eq "and only the next"            "1" "$(jq -r '.ready | length' <<<"$(qj)")"

printf '\n-- and a later run that halted does not un-build it --\n\n'
#
# The first version read only the newest run.json. A bean that opened a pull
# request and was then re-run, with the second run halting before `pr`, went back
# to looking unbuilt: the queue would offer it again and `factory go` would run
# it again. pr.sh has an idempotency check for the second pull request precisely
# because it must not get that far.
mkdir -p "$REPO/factory/runs/bean-001-20260202T000000Z"
printf '{"run_id":"r2","bean":"bean-001","status":"halted"}\n' \
  > "$REPO/factory/runs/bean-001-20260202T000000Z/run.json"
eq "it is still done"             "done" "$(jq -r '.beans[] | select(.id=="bean-001") | .state' <<<"$(qj)")"
eq "and nothing new is ready"     "bean-002" "$(jq -r '.ready | join(" ")' <<<"$(qj)")"

printf '\n-- a branch without a pull request is in progress, not ready --\n\n'
#
# The difference matters on a resume: a bean whose branch exists has been started,
# and starting it again would cut a second branch off main and lose the work.
git -C "$REPO" branch -q "bean/bean-002-x"
eq "it is in progress"            "in_progress" \
   "$(jq -r '.beans[] | select(.id=="bean-002") | .state' <<<"$(qj)")"
eq "and nothing is ready"         "" "$(jq -r '.ready | join(" ")' <<<"$(qj)")"
check "with the branch named"     "branch bean/bean-002-x already exists" "$(q --all)"
git -C "$REPO" branch -qD "bean/bean-002-x"

# --------------------------------------------------------------------------
printf '\n== factory go ==\n\n'
out="$(fac go --dry-run)"
check "it would run the ready one" "would run  bean-002" "$out"
nope "and not a blocked one"       "bean-003" "$out"

out="$(fac go --bean bean-004)"; rc=$?
rc_is "an unapproved bean is refused" "$rc" 1
check "and the gate is named"      "§04 gates what enters the line" "$out"
check "with the status quoted"     "not approved" "$out"

out="$(fac go --bean bean-001)"; rc=$?
rc_is "a finished bean is refused"  "$rc" 1
check "and says why"                "already reached a pull request" "$out"

out="$(fac go --bean bean-003)"; rc=$?
rc_is "a blocked bean is refused"   "$rc" 1
check "naming what blocks it"       "bean-002(not built)" "$out"

# `[ abc -gt 0 ]` prints an error and evaluates false, so an unvalidated --limit
# would run the whole queue while the operator believed it would run one bean.
out="$(fac go --limit abc)"; rc=$?
rc_is "a non-numeric limit refuses"  "$rc" 1
check "and says what it wanted"      "takes a whole number" "$out"
nope  "and nothing was started"      "=== bean-" "$out"

out="$(fac go --bean bean-404)"; rc=$?
rc_is "an unknown bean is refused"  "$rc" 1
check "and says so plainly"         "no bean 'bean-404'" "$out"

printf '\n-- and it will not start a bean into a full disk --\n\n'
#
# A twenty-bean queue is hours of writing into TMPDIR. When it filled last night
# the contained worker reported "Unknown system error -122" and the run recorded a
# doc step that produced nothing — every part true, none of it saying the disk was
# full. A queue that kept starting beans would turn one environmental failure into
# twenty runs of wasted model time.
out="$( cd "$REPO" && PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
        TMPDIR=/nonexistent-for-df "$FACTORY" go --dry-run 2>&1 )" || true
# A --dry-run never gets as far as the check; what matters is that a real one does.
# Point TMPDIR at something with no free space by using a path df cannot read, and
# assert the check does not fire on an unreadable answer — refusing to run because
# df failed would be its own kind of wrong.
check "an unreadable temp root does not stop the queue" "would run" "$out"

printf '\n-- with everything built, there is nothing to do and it says so --\n\n'
built bean-002; built bean-003
out="$(fac go --dry-run)"
# Not "nothing to do" — the reason is usually one merge away, and making someone
# run a second command to find that out is how a queue that stopped for a good
# reason gets read as a queue that broke.
check "it says nothing is ready"   "ready: nothing" "$out"
# The whole summary, inlined — whatever it happens to say. Here every bean is
# merged or refused, so the line that matters is the refusal count; in the real
# repository this morning it was "waiting on a human to merge: bean-001". Either
# way the reason travels with the stop.
check "and the queue's own summary" "refused: 1 bean(s) not approved" "$out"

printf '\n== the loop stops at a halt, for real ==\n\n'
#
# Everything above is the queue deciding. This is `go` acting on it: the run
# itself fails — here because preflight refuses a dirty tree, which is a real
# refusal and not a stub — and what matters is that the queue stops rather than
# carrying on to the next bean. Whatever stopped one bean would stop the next,
# and a queue that kept going would turn one question into twenty.
git -C "$REPO" checkout -q main
rm -rf "$REPO/factory/runs"/*
git -C "$REPO" branch -q -D bean/bean-001-x bean/bean-002-x bean/bean-003-x 2>/dev/null || true
printf 'uncommitted\n' > "$REPO/dirty.txt"
out="$(fac go --limit 2)"; rc=$?
rc_is "it exits non-zero"            "$rc" 1
check "it names the bean it stopped at" "STOPPED at bean-001" "$out"
check "and says why it does not go on" "would stop the next bean too" "$out"
nope  "the second bean is never started" "=== bean-002 ===" "$out"
rm -f "$REPO/dirty.txt"

printf '\n== a count that does not match the rows under it ==\n\n'
#
# "queue — 20 bean(s)" followed by one row reads as a bug. It is not: the table
# shows the states a reader can act on. But a number that disagrees with the rows
# beneath it is exactly the shape of something broken, so the difference is said.
out="$(q)"
n_rows="$(grep -cE '^bean-[0-9]+ ' <<<"$out" || true)"
n_total="$(sed -n 's/^queue — \([0-9]*\) bean.*/\1/p' <<<"$out" | head -1)"
if [ "${n_total:-0}" -gt "${n_rows:-0}" ]; then
  check "the hidden ones are counted"  "more, blocked or done" "$out"
  check "and how to see them"          "factory queue --all" "$out"
else
  printf '  ok    nothing was hidden, so nothing to say about it\n'; PASS=$((PASS+1))
  printf '  ok    (the same assertion, vacuous here by construction)\n'; PASS=$((PASS+1))
fi

printf '\n== a halted run beside a bean that is not finished ==\n\n'
#
# bean-002 halted on a precondition that merging bean-001's pull request fixes.
# The moment that merge lands the bean is runnable and the old run directory is
# still there — `factory go` starts a second one and leaves the first, which is
# right (the halt had an external cause and the evidence should not be
# overwritten) and confusing if nobody says so, at exactly the moment the operator
# is least able to check.
mkdir -p "$REPO/factory/runs/bean-001-20260101T000000Z"
printf '{"run_id":"r","bean":"bean-001","status":"halted"}\n' \
  > "$REPO/factory/runs/bean-001-20260101T000000Z/run.json"
out="$(q)"
check "the halted run is named"        "halted run(s) still on disk" "$out"
check "with the bean and the path"     "bean-001 — " "$out"
check "and that a new run does not touch it" "left alone" "$out"
check "and why they are worth reading" "QUESTIONS.md in them is often the most useful" "$out"

printf '\n-- a finished run is not reported as one --\n\n'
printf '{"run_id":"r","bean":"bean-001","status":"complete"}\n' \
  > "$REPO/factory/runs/bean-001-20260101T000000Z/run.json"
out="$(q)"
nope "a complete run says nothing"     "halted run(s) still on disk" "$out"
rm -rf "$REPO/factory/runs/bean-001-20260101T000000Z"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
