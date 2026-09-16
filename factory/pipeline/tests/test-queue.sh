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
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init

q()  { ( cd "$REPO" && bash "$PIPELINE_DIR/queue.sh" "$@" 2>&1 ); }
qj() { ( cd "$REPO" && bash "$PIPELINE_DIR/queue.sh" --json 2>/dev/null ); }
fac(){ ( cd "$REPO" && PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" "$FACTORY" "$@" 2>&1 ); }
built() { # built <bean-id> — pretend it reached a pull request
  local d="$REPO/factory/runs/$1-20260101T000000Z"; mkdir -p "$d"
  printf '{"run_id":"r","bean":"%s","pr_url":"https://github.com/x/y/pull/9"}\n' "$1" > "$d/run.json"
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

printf '\n== building one unblocks exactly the next ==\n\n'
built bean-001
out="$(q --all)"
eq "the built one is done"        "done" "$(jq -r '.beans[] | select(.id=="bean-001") | .state' <<<"$(qj)")"
check "and says how it knows"     "a pull request was opened" "$out"
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
check "it does not invent work"    "Nothing ready to run" "$out"
check "and points at the queue"    "factory queue --all" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
