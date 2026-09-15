#!/usr/bin/env bash
# test-sync.sh — the step that asks whether the candidate is still measured
# against the tree it will merge into.
#
# The fault this covers is quiet: main moves while a bean builds, every verdict
# names a base that no longer matters, the PR opens green, and the merge produces
# a tree nothing in the run has ever gated. So the fixtures here are a branch
# that is current, a branch that is behind, a branch that conflicts, and a branch
# that has already been rebased twice — and the check has to tell them apart.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# A bare repository stands in for origin. There is no network here and there
# should not be: what sync needs is a ref that moves independently of the branch
# being built, and a second clone is exactly that.
ORIGIN="$WORK/origin.git"; git init -q --bare -b main "$ORIGIN"
SEED="$WORK/seed"; git init -q -b main "$SEED"; cd "$SEED"
git config user.email t@e.com; git config user.name T
printf 'factory/runs/\n' > .gitignore
printf 'one\n' > shared.txt
git add -A && git commit -q -m init
git remote add origin "$ORIGIN" && git push -q origin main

fresh_repo() { # <name> -> path; a clone with a run dir and a bean branch
  # Two assignments in one `local` is a trap: bash expands the whole argument
  # list before the first name is bound, so `r="$WORK/$name"` reads the *outer*
  # $name and dies under `set -u`. It died on every call, and every negative
  # assertion in this file went on passing, because `test ! -f ""/x` is true.
  local name="$1"
  local r="$WORK/$name"
  git clone -q "$ORIGIN" "$r"
  git -C "$r" config user.email t@e.com; git -C "$r" config user.name T
  mkdir -p "$r/factory/runs/R/verdicts"
  printf '{"schema_version":"run/1.0.0","run_id":"R","bean_id":"bean-001","branch":"factory/bean-001"}\n' \
    > "$r/factory/runs/R/run.json"
  printf '{"overall":"pass","gates":[]}\n' > "$r/factory/runs/R/gate.json"
  printf '{"stage":"audit-impl","verdict":"accept"}\n' > "$r/factory/runs/R/verdicts/impl.attempt-1.json"
  printf '{"stage":"audit-package","verdict":"accept"}\n' > "$r/factory/runs/R/verdicts/package.attempt-1.json"
  printf '{"findings":[]}\n' > "$r/factory/runs/R/verdicts/impl.attempt-1.judgement.json"
  git -C "$r" checkout -q -b factory/bean-001
  printf 'work\n' > "$r/feature.txt"
  git -C "$r" add -A && git -C "$r" commit -q -m "the bean's work"
  printf '%s' "$r"
}

advance_origin() { # <text> — someone else lands a commit on main
  ( cd "$SEED" && git checkout -q main \
    && printf '%s\n' "$1" >> other.txt && git add -A \
    && git commit -q -m "someone else's work" && git push -q origin main )
}

# A fixture that failed to build must stop the run. Without this, R is empty,
# every path becomes an absolute path under /, and the negative assertions all
# pass while measuring nothing — which is the failure this whole file exists to
# catch, one level up.
use_repo() { # <name> — sets R
  R="$(fresh_repo "$1")"
  if [ -z "$R" ] || [ ! -d "$R/.git" ]; then
    printf '\nFATAL: fixture "%s" was not created — the rest of this file would measure nothing\n' "$1"
    exit 1
  fi
}

sync_in() { # <repo> [args...]
  local r="$1"; shift
  ( cd "$r" && bash "$PIPELINE_DIR/sync.sh" factory/runs/R --no-fetch "$@" 2>&1 )
}

# --------------------------------------------------------------------------
printf '\n== a branch that is current is left alone ==\n\n'
use_repo current
out="$(sync_in "$R")"; rc=$?
rc_is "exit 0"                        "$rc" 0
check "it says so"                    "SYNC CURRENT" "$out"
want  "no rewind is asked for"        "rewind.json should not exist" \
      test ! -f "$R/factory/runs/R/rewind.json"
want  "the gate result is untouched"  "gate.json should still be in place" \
      test -f "$R/factory/runs/R/gate.json"
want  "run.json records no rebase"    "rebases should be absent" \
      test "$(jq -r '.rebases // "none"' "$R/factory/runs/R/run.json")" = none

# --------------------------------------------------------------------------
printf '\n== a branch that is behind is rebased, and says what is now stale ==\n\n'
use_repo behind
advance_origin "landed while the bean was building"
git -C "$R" fetch -q origin main
OLD_HEAD="$(git -C "$R" rev-parse HEAD)"
out="$(sync_in "$R")"; rc=$?
rc_is "exit 9"                        "$rc" 9
check "it reports the rebase"         "SYNC REBASED" "$out"
check "and names what must run again" "gate, audit-impl and audit-package" "$out"
want  "HEAD actually moved"           "the candidate should be a new commit" \
      test "$(git -C "$R" rev-parse HEAD)" != "$OLD_HEAD"
want  "the branch now contains origin/main" "the rebase should have replayed onto it" \
      git -C "$R" merge-base --is-ancestor origin/main HEAD
want  "the bean's work survived"      "feature.txt should still be there" \
      test -f "$R/feature.txt"

want  "a rewind is asked for"         "rewind.json should exist" \
      test -f "$R/factory/runs/R/rewind.json"
want  "it rewinds to the gate"        "to should be gate" \
      test "$(jq -r '.to' "$R/factory/runs/R/rewind.json")" = gate
want  "it forces exactly three steps" "gate, audit-impl, audit-package" \
      test "$(jq -rc '.force' "$R/factory/runs/R/rewind.json")" = '["gate","audit-impl","audit-package"]'
nope  "it does not force the spec audit" "audit-spec" "$(cat "$R/factory/runs/R/rewind.json")"
nope  "it does not force the document"   '"doc"'     "$(cat "$R/factory/runs/R/rewind.json")"

want  "the stale gate is moved, not deleted" "pre-rebase-1/gate.json should exist" \
      test -f "$R/factory/runs/R/pre-rebase-1/gate.json"
want  "and is out of the run's working path" "gate.json should be gone from the run root" \
      test ! -f "$R/factory/runs/R/gate.json"
want  "the stale impl verdict is moved"      "pre-rebase-1/verdicts/impl.attempt-1.json" \
      test -f "$R/factory/runs/R/pre-rebase-1/verdicts/impl.attempt-1.json"
want  "the stale package verdict is moved"   "pre-rebase-1/verdicts/package.attempt-1.json" \
      test -f "$R/factory/runs/R/pre-rebase-1/verdicts/package.attempt-1.json"
want  "the judgement travels with its verdict" "impl.attempt-1.judgement.json" \
      test -f "$R/factory/runs/R/pre-rebase-1/verdicts/impl.attempt-1.judgement.json"
want  "the moved results explain themselves" "pre-rebase-1/README.md should exist" \
      test -f "$R/factory/runs/R/pre-rebase-1/README.md"

want  "run.json records the rebase"   "one entry in rebases" \
      test "$(jq -r '[.rebases[]] | length' "$R/factory/runs/R/run.json")" = 1
want  "it names the commit that was judged" "old_head should be the pre-rebase HEAD" \
      test "$(jq -r '.rebases[0].old_head' "$R/factory/runs/R/run.json")" = "$OLD_HEAD"
want  "it names the new candidate"    "new_head should be HEAD" \
      test "$(jq -r '.rebases[0].new_head' "$R/factory/runs/R/run.json")" = "$(git -C "$R" rev-parse HEAD)"
want  "the run record still validates" "run-record.schema.json" \
      bash -c "cd '$PIPELINE_DIR/../..' && jq -e '.rebases[0] | has(\"at\") and has(\"base_ref\") and has(\"from_base\") and has(\"to_base\")' '$R/factory/runs/R/run.json' >/dev/null"

printf '\n-- and running it again, now current, is a no-op --\n\n'
out="$(sync_in "$R")"; rc=$?
rc_is "exit 0 the second time"        "$rc" 0
check "it says current"               "SYNC CURRENT" "$out"

# --------------------------------------------------------------------------
printf '\n== a conflict leaves the branch exactly as it was ==\n\n'
use_repo conflict
# The bean and someone else both change the same line.
printf 'the bean changed this\n' > "$R/shared.txt"
git -C "$R" add -A && git -C "$R" commit -q -m "bean touches shared.txt"
( cd "$SEED" && git checkout -q main && printf 'someone else changed this\n' > shared.txt \
  && git add -A && git commit -q -m "conflicting change" && git push -q origin main )
git -C "$R" fetch -q origin main
OLD_HEAD="$(git -C "$R" rev-parse HEAD)"
out="$(sync_in "$R")"; rc=$?
rc_is "exit 3"                        "$rc" 3
check "it says a human decides"       "SYNC CONFLICT" "$out"
want  "HEAD did not move"             "an aborted rebase leaves the branch alone" \
      test "$(git -C "$R" rev-parse HEAD)" = "$OLD_HEAD"
want  "no rebase is in progress"      "the rebase should have been aborted" \
      test ! -d "$R/.git/rebase-merge" -a ! -d "$R/.git/rebase-apply"
want  "the question is written down"  "QUESTIONS.md should exist" \
      test -f "$R/factory/runs/R/QUESTIONS.md"
check "and names the conflicted file" "shared.txt" "$(cat "$R/factory/runs/R/QUESTIONS.md")"
want  "nothing was moved aside"       "the gate result is still authoritative until someone decides" \
      test -f "$R/factory/runs/R/gate.json"
want  "no rewind is asked for"        "nothing ran, so nothing needs re-running" \
      test ! -f "$R/factory/runs/R/rewind.json"

# --------------------------------------------------------------------------
printf '\n== a base that keeps moving becomes a question, not a loop ==\n\n'
use_repo churn
advance_origin "first"
git -C "$R" fetch -q origin main
out="$(sync_in "$R" --max-rebases 1)"; rc=$?
rc_is "the first rebase is allowed"   "$rc" 9
rm -f "$R/factory/runs/R/rewind.json"
advance_origin "second"
git -C "$R" fetch -q origin main
out="$(sync_in "$R" --max-rebases 1)"; rc=$?
rc_is "the second is refused"         "$rc" 3
check "it says why"                   "SYNC BLOCKED" "$out"
check "the question names the cost"   "a fresh gate and two fresh audits" \
      "$(cat "$R/factory/runs/R/QUESTIONS.md")"
want  "and it did not rebase anyway"  "only one rebase should be recorded" \
      test "$(jq -r '[.rebases[]] | length' "$R/factory/runs/R/run.json")" = 1

# --------------------------------------------------------------------------
printf '\n== preconditions ==\n\n'
use_repo dirty
advance_origin "so there is something to rebase onto"
git -C "$R" fetch -q origin main
printf 'uncommitted\n' > "$R/feature.txt"
out="$(sync_in "$R")"; rc=$?
rc_is "a dirty tree refuses"          "$rc" 1
check "it says what it would rewrite" "a rebase would rewrite them" "$out"
want  "and did not rebase"            "no rebase should be recorded" \
      test "$(jq -r '.rebases // "none"' "$R/factory/runs/R/run.json")" = none

use_repo onmain
git -C "$R" checkout -q main
out="$(sync_in "$R")"; rc=$?
rc_is "running on main refuses"       "$rc" 1
check "sync moves the bean branch"    "never the base" "$out"

# A run directory living inside the repository must not make the tree look dirty
# to its own step — the same trap pr.sh has.
use_repo evidence
advance_origin "base moves"
git -C "$R" fetch -q origin main
printf 'evidence written mid-run\n' > "$R/factory/runs/R/notes.txt"
out="$(sync_in "$R")"; rc=$?
rc_is "the run dir is not dirt"       "$rc" 9
check "it rebased"                    "SYNC REBASED" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
