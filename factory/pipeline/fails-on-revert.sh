#!/usr/bin/env bash
# fails-on-revert.sh — verify a test actually pins a change by reverting the source and requiring the test to fail.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="fails-on-revert.sh <source-file> <test-command>"
case "${1:-}" in
  --version)
    cat "$PIPELINE_DIR/VERSION"
    exit 0
    ;;
  -h|--help)
    echo "fails-on-revert.sh — prove a test pins a change."
    echo "$USAGE"
    echo ""
    echo "Reverts <source-file> to its content on main, runs <test-command>, and"
    echo "requires a NON-ZERO exit (the test must fail without the change)."
    echo "The file is restored via trap even if the test command is killed;"
    echo "restoring matters more than the result."
    exit 0
    ;;
esac
require_args "$#" 2 "$USAGE"

SRC="$1"
TEST_CMD="$2"

[ -f "$SRC" ] || die "source file not found: $SRC"
root="$(repo_root)"
case "$SRC" in
  "$root"/*) rel="${SRC#"$root"/}" ;;
  /*) die "source file $SRC is not inside the repo at $root" ;;
  *) rel="${SRC#./}" ;;
esac

if ! git -C "$root" cat-file -e "main:$rel" 2>/dev/null; then
  die "main:$rel does not exist — the file must exist on main to compare against"
fi

backup="$(mktemp)"
cp "$SRC" "$backup"

critical_restore_failed=0

printf 'fails-on-revert: reverting %s to main content\n' "$rel"
git -C "$root" show "main:$rel" > "$SRC"

child=   # pid of the in-flight test command, for signal traps
restore() {
  if [ -n "${child:-}" ]; then kill "$child" 2>/dev/null || true; fi
  if [ -f "$backup" ]; then
    if cp -f "$backup" "$SRC" 2>/dev/null && cmp -s "$backup" "$SRC"; then
      :
    else
      printf 'fails-on-revert: CRITICAL: failed to restore %s from backup\n' "$SRC" >&2
      critical_restore_failed=1
    fi
    rm -f "$backup"
  fi
}
# Any exit path — including signals while the test command runs — restores the file.
trap 'restore' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'fails-on-revert: running test command\n'
test_out="$(mktemp)"
rc=0
# Run in the background and `wait` so signal traps fire immediately, not after the command exits.
bash -c "$TEST_CMD" >"$test_out" 2>&1 &
child=$!
wait "$child" || rc=$?
child=
tail_out="$(tail -n 10 "$test_out")"
rm -f "$test_out"

# Restore explicitly and verify before reporting the verdict.
restore
if [ "$critical_restore_failed" -ne 0 ]; then
  printf 'FAIL  file was NOT restored cleanly: %s\n' "$SRC"
  exit 2
fi

if [ "$rc" -eq 0 ]; then
  echo "FAIL  test PASSED while source was reverted — the test does not pin the change"
  echo "      source: $rel"
  echo "      test:   $TEST_CMD"
  exit 1
fi

echo "PASS  test failed (exit $rc) while source was reverted — the test pins the change"
echo "      source: $rel"
echo "      (file restored to its pre-check contents)"
exit 0
