#!/usr/bin/env bash
# test-reconcile.sh — the state log made to agree with GitHub, the runs and the
# tree. GitHub is a stub that answers from a file, so every case says exactly
# what the world looked like. The kill -9 crash itself is in test-faults.sh,
# where a real orchestrator run can be killed.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PIPELINE_DIR/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PY="${PIPELINE_PYTHON:-$ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

REPO="$WORK/repo"; mkdir -p "$REPO/factory/runs" && cd "$REPO"
git init -q -b main . && git config user.email t@example.com && git config user.name T
printf 'factory/runs/\n' > .gitignore && printf 'x\n' > a.txt && git add -A && git commit -qm init
export FACTORY_STATE_DIR="$REPO/factory/runs/.state"
# gh pr view <url> --json ... answers from $WORK/gh/<pr number>.json
mkdir -p "$WORK/gh" "$WORK/bin"
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
n="${3##*/}"; f="$GH_DIR/$n.json"
[ -f "$f" ] && cat "$f" || { echo "no such pr" >&2; exit 1; }
SH
chmod +x "$WORK/bin/gh"
export FACTORY_GH="$WORK/bin/gh" GH_DIR="$WORK/gh"
BS=("$PY" "$PIPELINE_DIR/beanstate.py")
rec() { "$PY" "$PIPELINE_DIR/reconcile.py" "$@" 2>&1; }
state_of() { "${BS[@]}" state "$1" --json | jq -r --arg b "$1" '.[$b].state'; }
run_dir() { # run_dir <bean> <json fields>
  local d="$REPO/factory/runs/$1-20261002T000000Z"; mkdir -p "$d"
  jq -nc --arg b "$1" --argjson x "$2" '{run_id:($b + "-20261002T000000Z"), bean_id:$b, bean:$b} + $x' > "$d/run.json"
  printf '%s' "$d"
}
walk_to() { # walk_to <bean> <state...>
  local b="$1"; shift; local i=0
  for s in "$@"; do i=$((i+1)); "${BS[@]}" transition "$b" --to "$s" --key "$b-w$i" >/dev/null; done
}
TO_PR=(leased specifying spec_committing spec_auditing spec_accepted building containing gating
       committing_candidate impl_auditing impl_accepted documenting doc_committing pre_pr_auditing
       accepted pushing pushed pr_open ci_pending)

printf '\n== GitHub says merged: the bean is merged ==\n\n'
walk_to bean-001 "${TO_PR[@]}" merge_pending
run_dir bean-001 '{"pr_url":"https://github.com/x/y/pull/11"}' >/dev/null
printf '{"state":"MERGED","headRefOid":"abc","statusCheckRollup":[]}' > "$WORK/gh/11.json"
out="$(rec)"
check "the plan names it"              "merge_pending -> merged" "$out"
check "and changes nothing yet"        "merge_pending" "$(state_of bean-001)"
rec --apply >/dev/null
check "--apply makes it merged"        "merged" "$(state_of bean-001)"
check "recorded as an observation"     '"reconciled":true' "$(tail -1 "$FACTORY_STATE_DIR/events.jsonl")"
n="$(wc -l < "$FACTORY_STATE_DIR/events.jsonl")"; rec --apply >/dev/null
n2="$(wc -l < "$FACTORY_STATE_DIR/events.jsonl")"
if [ "$n" = "$n2" ]; then printf '  ok    a second run changes nothing\n'; PASS=$((PASS+1))
else printf '  FAIL  a second run changes nothing — %s events became %s\n' "$n" "$n2"; FAIL=$((FAIL+1)); fi

printf '\n== an open pull request takes its state from its checks ==\n\n'
walk_to bean-002 "${TO_PR[@]}"
run_dir bean-002 '{"pr_url":"https://github.com/x/y/pull/12"}' >/dev/null
printf '{"state":"OPEN","headRefOid":"abc","statusCheckRollup":[{"name":"gates","conclusion":"SUCCESS"}]}' > "$WORK/gh/12.json"
rec --apply >/dev/null
check "green checks: merge_pending"    "merge_pending" "$(state_of bean-002)"
walk_to bean-003 "${TO_PR[@]}"
run_dir bean-003 '{"pr_url":"https://github.com/x/y/pull/13"}' >/dev/null
printf '{"state":"OPEN","headRefOid":"abc","statusCheckRollup":[{"name":"gates","conclusion":"FAILURE"}]}' > "$WORK/gh/13.json"
rec --apply >/dev/null
check "a red check: ci_failed"         "ci_failed" "$(state_of bean-003)"

printf '\n== a halt the log never heard of ==\n\n'
walk_to bean-004 leased specifying
run_dir bean-004 '{"status":"halted","halted_at_step":"spec"}' >/dev/null
out="$(rec --apply)"
check "the bean is blocked"            "blocked" "$(state_of bean-004)"
check "and the plan says which run"    "halted at spec" "$out"

printf '\n== a dead owner'"'"'s lease is dropped ==\n\n'
"${BS[@]}" lease bean-005 --owner "$(hostname):999999" >/dev/null
out="$(rec --apply)"
check "the lease goes"                 "drop the lease held by $(hostname):999999" "$out"
check "and is gone from the file"      "{}" "$(jq -c . "$FACTORY_STATE_DIR/leases.json")"

printf '\n== in flight, nobody holding it: rolled back to the last commit ==\n\n'
git checkout -q -b bean/bean-006-thing
printf 'committed\n' > b.txt && git add b.txt && git commit -qm "task-1"
walk_to bean-006 leased specifying spec_committing spec_auditing spec_accepted building
RD="$(run_dir bean-006 '{"status":"running"}')"
printf 'half an attempt\n' >> b.txt; printf 'stray\n' > c.txt
out="$(rec)"
check "the plan says roll back"        "roll back the interrupted attempt's edits" "$out"
check "and how to resume"              "factory run bean-006 --resume $RD" "$out"
rec --apply >/dev/null
left="$(git status --porcelain --untracked-files=all | grep -v factory/runs || true)"
if [ -z "$left" ] && [ "$(cat b.txt)" = committed ]; then printf '  ok    the tree is back at the commit\n'; PASS=$((PASS+1))
else printf '  FAIL  the tree is back at the commit — left: %s\n' "$left"; FAIL=$((FAIL+1)); fi
check "the edits are kept as evidence" "half an attempt" "$(cat "$RD"/rolled-back-*.diff)"
check "including the untracked file"   "c.txt" "$(cat "$RD"/rolled-back-*.diff)"
check "the bean stays where it was"    "building" "$(state_of bean-006)"
git checkout -q main
printf 'dirty on main\n' >> a.txt
out="$(rec --apply)"
check "a dirty tree on another branch is left for a person" "left alone for a person" "$out"
check "and not touched"                "dirty on main" "$(cat a.txt)"
git checkout -q -- a.txt

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
