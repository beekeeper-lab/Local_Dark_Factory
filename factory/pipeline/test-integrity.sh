#!/usr/bin/env bash
# test-integrity.sh — do the tests in this diff actually pin the change?
#
# The audit rubric asks the judge: "Are the tests real? An assertion that would
# pass with the change reverted — truthy-by-construction, asserting the test's own
# setup — is a blocker." It is the most important question in the impl rubric and
# the one a model is worst at, because answering it properly means executing the
# test against code that does not have the change in it, and a judge cannot
# execute anything.
#
# The controller can. Revert the SOURCE half of the diff in a throwaway copy of
# the tree, keep the test half, and run the tests. If they still pass, they do not
# test the change: whatever they assert was true before the work was done.
#
# Three things this is honest about:
#
#   * A test that fails on revert for an unrelated reason — an import error,
#     because the module it imports is not there yet — counts as pinning. That is
#     a weaker claim than "this assertion tests this behaviour", and it is
#     recorded as such rather than dressed up.
#   * A diff with no source changes has nothing to revert, and one with no test
#     changes has nothing to run. Both are reported as not-applicable, never as a
#     pass. "No tests were added" is a finding for a human, not a green tick.
#   * Deleted tests, new skips and weakened assertions are counted from the diff
#     text. That is a text measure of a semantic thing; it catches the blatant
#     cases and says so.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
test-integrity.sh — prove the diff's tests fail without the diff's source.

usage: test-integrity.sh <run_dir> [--base <ref>] [--sandbox] [--gates <file>]
                         [--test-gate <id>] [--env K=V]

  --base <ref>       what the branch is measured against (default: main)
  --sandbox          run the tests in the pinned gate container
  --gates <file>     gate manifest (default: factory/gates.lock.yaml)
  --test-gate <id>   which gate runs the tests (default: the first gate whose
                     command looks like a test runner)
  --env K=V          passed through to the sandbox (repeatable)

Writes <run_dir>/test-integrity.json.

Exit: 0 the tests pin the change, or there was nothing to check
      1 tests exist and do NOT pin it — the one thing here that is decidable
      2 undecided: no tests were written, or they do not pass to begin with
EOF
}

RUN_DIR=""; BASE="main"; SANDBOX=0; GATES=""; TEST_GATE=""; ENV_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base)      BASE="${2:?--base needs a ref}"; shift 2 ;;
    --sandbox)   SANDBOX=1; shift ;;
    --gates)     GATES="${2:?--gates needs a file}"; shift 2 ;;
    --test-gate) TEST_GATE="${2:?--test-gate needs an id}"; shift 2 ;;
    --env)       ENV_ARGS+=( --env "${2:?--env needs K=V}" ); shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    --version)   cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*)          usage >&2; die "unknown flag: $1" ;;
    *)           [ -z "$RUN_DIR" ] || die "only one run dir"; RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] || { usage >&2; exit 1; }
[ -d "$RUN_DIR" ] || die "run directory not found: $RUN_DIR"
require_cmd jq
require_cmd git

ROOT="$(repo_root)"
[ -n "$GATES" ] || GATES="$ROOT/factory/gates.lock.yaml"

# Exactly one thing here is decidable, and only it is allowed to fail a run:
# tests were written, they pass now, and they still pass with the change taken
# out. Everything else this script measures is a fact a person or a judge should
# weigh — a change with no tests may be a config bump, a deleted test may be a
# deliberate part of a refactor — and a check that fails a run on those would be
# turned off inside a week, taking the decidable one with it.
FAILED=0
UNDECIDED=0
ok()    { printf '  ok    %-24s %s\n' "$1" "$2"; }
bad()   { printf '  FAIL  %-24s %s\n' "$1" "$2"; FAILED=1; }
weigh() { printf '  ?     %-24s %s\n' "$1" "$2"; UNDECIDED=1; }
note()  { printf '  --    %-24s %s\n' "$1" "$2"; }

printf '\nTEST INTEGRITY  %s\n\n' "$(basename "$RUN_DIR")"

# ------------------------------------------------- 1. split the diff in two --
# Which paths are tests is a property of the project, not of this script. The
# defaults cover the Python layouts this line builds; a repo that arranges tests
# differently says so in its config rather than being silently mis-split.
TEST_PATTERNS="$(jq -c '.test_paths // ["tests/**", "**/test_*.py", "**/*_test.py", "**/tests/**"]' \
  "$CONFIG_PATH" 2>/dev/null || echo '["tests/**","**/test_*.py","**/*_test.py","**/tests/**"]')"

git -C "$ROOT" rev-parse --verify "$BASE" >/dev/null 2>&1 \
  || die "base ref '$BASE' does not exist; there is nothing to revert to"
MERGE_BASE="$(git -C "$ROOT" merge-base "$BASE" HEAD)" || die "no merge base with $BASE"

# The run directory is this script's own output as much as anyone's, and in a
# scaffolded repo it is gitignored anyway. A fixture that commits it would
# otherwise see test-integrity.json itself listed as source code needing a test.
RUN_REL=""
RUN_ABS="$(cd "$RUN_DIR" && pwd)"
case "$RUN_ABS/" in "$ROOT"/*) RUN_REL="${RUN_ABS#"$ROOT"/}" ;; esac

CHANGED="$(git -C "$ROOT" diff --name-only "$MERGE_BASE"...HEAD \
  | { [ -n "$RUN_REL" ] && grep -v "^$RUN_REL/" || cat; })"
[ -n "$CHANGED" ] || { note "diff" "no changes against $BASE — nothing to check"; }

# Not everything that is not a test is code that needs one. A README, a licence
# or a diagram changes nothing a test could observe, and asking "where are the
# tests for this documentation change?" is how a useful check earns a reputation
# for noise and gets turned off.
PROSE_PATTERNS="$(jq -c '.no_behaviour_paths // ["**/*.md","**/*.rst","**/*.txt","docs/**","LICENSE","**/*.png","**/*.svg",".gitignore"]' \
  "$CONFIG_PATH" 2>/dev/null || echo '["**/*.md","**/*.rst","**/*.txt","docs/**","LICENSE","**/*.png","**/*.svg",".gitignore"]')"

TEST_FILES=(); SRC_FILES=(); PROSE_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # contain.py prints the paths that do NOT match its patterns, so silence means
  # this path IS a test. Reading its exit code instead would classify everything
  # the same way, which is the sort of bug that makes a check pass forever.
  if [ -z "$(printf '%s\n' "$f" | python3 "$PIPELINE_DIR/contain.py" --patterns "$TEST_PATTERNS" 2>/dev/null)" ]; then
    TEST_FILES+=( "$f" )
  elif [ -z "$(printf '%s\n' "$f" | python3 "$PIPELINE_DIR/contain.py" --patterns "$PROSE_PATTERNS" 2>/dev/null)" ]; then
    PROSE_FILES+=( "$f" )
  else
    SRC_FILES+=( "$f" )
  fi
done <<<"$CHANGED"

printf '  %s test file(s), %s source file(s), %s prose file(s)\n\n' \
  "${#TEST_FILES[@]}" "${#SRC_FILES[@]}" "${#PROSE_FILES[@]}"

# ------------------------------------------- 2. what the diff did to tests --
# Counted from the diff text. A text measure of a semantic property: it catches a
# test deleted outright or a skip marker added, and it will not catch an assertion
# hollowed out in place. Reported as counts so a reader can tell the difference
# between "none" and "not looked for".
DELETED_TESTS=0; NEW_SKIPS=0; REMOVED_ASSERTS=0; ADDED_ASSERTS=0
if [ "${#TEST_FILES[@]}" -gt 0 ]; then
  DIFF_TEXT="$(git -C "$ROOT" diff "$MERGE_BASE"...HEAD -- "${TEST_FILES[@]}")"
  DELETED_TESTS="$(grep -cE '^-[[:space:]]*(def|async def) test_' <<<"$DIFF_TEXT" || true)"
  NEW_SKIPS="$(grep -cE '^\+.*(@pytest\.mark\.(skip|xfail)|pytest\.skip\(|unittest\.skip)' <<<"$DIFF_TEXT" || true)"
  REMOVED_ASSERTS="$(grep -cE '^-[[:space:]]*assert[[:space:]]' <<<"$DIFF_TEXT" || true)"
  ADDED_ASSERTS="$(grep -cE '^\+[[:space:]]*assert[[:space:]]' <<<"$DIFF_TEXT" || true)"
fi
# Files removed entirely count too — a deleted test file deletes every test in it.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  DELETED_TESTS=$((DELETED_TESTS + 1))
done < <(git -C "$ROOT" diff --diff-filter=D --name-only "$MERGE_BASE"...HEAD -- ${TEST_FILES+"${TEST_FILES[@]}"} 2>/dev/null)

[ "$DELETED_TESTS" -eq 0 ] && ok "deleted tests" "none" \
  || weigh "deleted tests" "$DELETED_TESTS removed — a change that deletes tests owes an explanation"
[ "$NEW_SKIPS" -eq 0 ] && ok "new skips" "none" \
  || weigh "new skips" "$NEW_SKIPS skip/xfail marker(s) added"
if [ "$REMOVED_ASSERTS" -gt "$ADDED_ASSERTS" ]; then
  weigh "assertions" "$REMOVED_ASSERTS removed, $ADDED_ASSERTS added — net loss of $((REMOVED_ASSERTS - ADDED_ASSERTS))"
else
  ok "assertions" "$ADDED_ASSERTS added, $REMOVED_ASSERTS removed"
fi

# -------------------------------------------- 3. do the tests pin anything? --
PINS="not_applicable"; PIN_WHY=""; PIN_CMD=""; PIN_RC=""
if [ "${#SRC_FILES[@]}" -eq 0 ]; then
  PIN_WHY="the diff changes no files that could alter behaviour, so there is nothing to revert"
  note "fails on revert" "$PIN_WHY"
elif [ "${#TEST_FILES[@]}" -eq 0 ]; then
  PINS="no_tests"
  PIN_WHY="the diff changes source but adds or changes no tests, so nothing was written to pin it"
  weigh "fails on revert" "$PIN_WHY"
else
  # The test command. Prefer the named gate; otherwise the first gate that looks
  # like a test runner. Guessing is acceptable here and refusing is not: a repo
  # whose gates are named unusually should still get this check, and the command
  # actually used is recorded so the guess is inspectable.
  TEST_RUN=""
  if [ -f "$GATES" ]; then
    GJ="$("$PIPELINE_DIR/yaml2json.sh" "$GATES")"
    if [ -n "$TEST_GATE" ]; then
      TEST_RUN="$(jq -c --arg i "$TEST_GATE" '.gates[] | select(.id == $i) | .run' <<<"$GJ")"
      [ -n "$TEST_RUN" ] && [ "$TEST_RUN" != null ] || die "no gate '$TEST_GATE' in $GATES"
    else
      TEST_RUN="$(jq -c '[.gates[] | select(.run[0] | test("pytest|unittest|jest|vitest|go$|cargo"))] | first | .run // empty' <<<"$GJ")"
    fi
  fi
  [ -n "$TEST_RUN" ] && [ "$TEST_RUN" != null ] \
    || TEST_RUN="$(jq -c '.test_command // ["pytest","-q"]' "$CONFIG_PATH" 2>/dev/null || echo '["pytest","-q"]')"

  # A throwaway copy, never the real worktree. Reverting source files in place and
  # restoring them afterwards works right up until something interrupts it, and
  # what it leaves behind is a repository half on one commit and half on another.
  SB_ROOT="${FACTORY_SANDBOX_ROOT:-${TMPDIR:-/tmp}}/darkfactory/$(basename "$RUN_DIR")"
  TREE="$SB_ROOT/revert-tree"
  CONTROL_TREE="$SB_ROOT/control-tree"
  rm -rf "$TREE" "$CONTROL_TREE"
  "$PIPELINE_DIR/sync-tree.sh" "$ROOT" "$TREE" --exclude "factory/runs" >/dev/null \
    || die "could not copy the tree to revert in"
  "$PIPELINE_DIR/sync-tree.sh" "$ROOT" "$CONTROL_TREE" --exclude "factory/runs" >/dev/null \
    || die "could not copy the tree to use as a control"

  REVERTED=()
  for f in "${SRC_FILES[@]}"; do
    if git -C "$ROOT" cat-file -e "$MERGE_BASE:$f" 2>/dev/null; then
      mkdir -p "$TREE/$(dirname "$f")"
      git -C "$ROOT" show "$MERGE_BASE:$f" > "$TREE/$f" 2>/dev/null && REVERTED+=( "$f" )
    else
      # The file is new in this branch. Reverting it means removing it.
      rm -f "$TREE/$f" && REVERTED+=( "$f (removed — new in this branch)" )
    fi
  done

  PIN_CMD="$(jq -r 'join(" ")' <<<"$TEST_RUN")"
  vjson="$(jq -c --argjson r "$TEST_RUN" '{kind:"command", run:$r}' <<<'{}')"

  # run_tests <tree> <logfile> — the same command, twice, against two trees.
  run_tests() {
    local tree="$1" log="$2" sb=()
    [ "$SANDBOX" = 1 ] && sb=( --sandbox "$tree" --gates "$GATES" )
    if [ "$SANDBOX" = 1 ]; then
      "$PIPELINE_DIR/verify.sh" "$vjson" --out "$log" --timeout 900 \
        "${sb[@]}" ${ENV_ARGS+"${ENV_ARGS[@]}"} >/dev/null 2>&1
    else
      ( cd "$tree" && jq -r '.[]' <<<"$TEST_RUN" | xargs -d '\n' -- timeout 900 ) > "$log" 2>&1
    fi
  }

  # The control, first. "The tests failed with the source reverted" only means
  # anything if they passed with it. Measured the hard way in this script's own
  # fixture: the test command named `python`, which does not exist on this box,
  # so every revert run "failed" and every tautological test was reported as
  # pinning the change. A missing binary, a broken import, a machine without the
  # dependency installed — all of them fail on revert, and none of them is a test
  # doing its job. verify.sh has the same rule from the other side: a check it
  # cannot run is a failure, never a pass.
  run_tests "$CONTROL_TREE" "$RUN_DIR/test-integrity-control.log"
  CONTROL_RC=$?
  if [ "$CONTROL_RC" -ne 0 ]; then
    PINS="inconclusive"
    PIN_RC="$CONTROL_RC"
    PIN_WHY="the tests do not pass on the tree as it is, so a failure after reverting proves nothing about them"
    weigh "fails on revert" "not decidable — $PIN_CMD exits $CONTROL_RC WITH the change (see test-integrity-control.log)"
  else
    run_tests "$TREE" "$RUN_DIR/test-integrity-revert.log"
    PIN_RC=$?
    if [ "$PIN_RC" -ne 0 ]; then
      PINS="yes"
      PIN_WHY="the tests pass with the change and fail without it, so something in them depends on it"
      ok "fails on revert" "$PIN_CMD passes with the change and exits $PIN_RC without it, as it must"
    else
      PINS="no"
      PIN_WHY="the tests pass with the source reverted — whatever they assert was already true"
      bad "fails on revert" "$PIN_CMD passed without the change; these tests do not pin it"
    fi
  fi
fi

# ------------------------------------------------------------------ record --
jq -n --arg schema "test-integrity/1.0.0" \
  --arg base "$MERGE_BASE" --arg pins "$PINS" --arg why "$PIN_WHY" \
  --arg cmd "$PIN_CMD" --arg rc "${PIN_RC:-}" --arg crc "${CONTROL_RC:-}" \
  --argjson tests "$(printf '%s\n' ${TEST_FILES+"${TEST_FILES[@]}"} | jq -Rs 'split("\n") | map(select(. != ""))')" \
  --argjson src "$(printf '%s\n' ${SRC_FILES+"${SRC_FILES[@]}"} | jq -Rs 'split("\n") | map(select(. != ""))')" \
  --argjson prose "$(printf '%s\n' ${PROSE_FILES+"${PROSE_FILES[@]}"} | jq -Rs 'split("\n") | map(select(. != ""))')" \
  --argjson deleted "$DELETED_TESTS" --argjson skips "$NEW_SKIPS" \
  --argjson removed_asserts "$REMOVED_ASSERTS" --argjson added_asserts "$ADDED_ASSERTS" \
  '{schema:$schema, base:$base,
    test_files:$tests, source_files:$src, prose_files:$prose,
    fails_on_revert:{result:$pins, why:$why, command:$cmd,
                     exit_code:(if $rc == "" then null else ($rc|tonumber) end),
                     control_exit_code:(if $crc == "" then null else ($crc|tonumber) end),
                     caveat:"The same command is run twice: once on the tree as it is, once with the source reverted. It must pass the first and fail the second. A test that fails on revert because of an import error still counts as pinning — weaker than proving the assertion tests the behaviour, and the strongest thing that can be decided by running something."},
    test_integrity:{deleted_tests:$deleted, new_skips:$skips,
                    removed_asserts:$removed_asserts, added_asserts:$added_asserts,
                    caveat:"Counted from the diff text. Catches a test deleted or a skip added; will not catch an assertion hollowed out in place."}}' \
  > "$RUN_DIR/test-integrity.json"

printf '\n'
if [ "$FAILED" -ne 0 ]; then
  printf 'TEST INTEGRITY FAIL — the tests pass without this change, so they do not test it\n'
  exit 1
elif [ "$UNDECIDED" -ne 0 ]; then
  printf 'TEST INTEGRITY UNDECIDED — nothing here is false, and nothing here is settled.\n'
  printf 'The facts are in test-integrity.json and go to the audit; a person decides.\n'
  exit 2
fi
printf 'TEST INTEGRITY PASS\n'
exit 0
