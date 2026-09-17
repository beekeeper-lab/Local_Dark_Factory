#!/usr/bin/env bash
# test-worker-entrypoint.sh — the container exits with pi's status, not the
# forwarder's.
#
# It did not, for two days. The entrypoint backgrounds the model-socket
# forwarder, runs pi, then kills and reaps it — under `set -e`. `wait` on a job
# that died by signal returns 143, `set -e` ends the shell on that status, and
# the `exit "$rc"` below it never ran. So every contained worker exited 143: a
# successful session, a failed one, or `pi --version` in one second with no model
# and nobody near the machine.
#
# It was read as an external SIGTERM the whole time, because 143 is what an
# external SIGTERM looks like and the evidence fit — unreproducible, unlogged,
# mid-session. The comment one layer up in this same file describes the same
# misreading, found earlier, and fixed at the MESSAGE the shell prints rather
# than at the status it exits with.
#
# pi and node are stubbed. What is under test is the shell, which is where the
# bug was.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY="$(cd "$HERE/../../worker-image" && pwd)/entrypoint.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
rc_is() { if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi }
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:200}"; FAIL=$((FAIL+1)); fi }

[ -f "$ENTRY" ] || { printf '  SKIP  no entrypoint.sh\n\n0 passed, 0 failed\n'; exit 0; }

mkdir -p "$WORK/bin" "$WORK/lib"
: > "$WORK/lib/model-socket.js"

# node has two jobs here and they must be told apart: `node /usr/.../model-socket.js`
# is the forwarder and has to stay alive long enough to be killed, and `node -e`
# is the readiness probe and has to exit 0 at once. A stub that conflated them
# would make the entrypoint exit before reaching the line under test.
# The forwarder's stdout is closed on the way in. It is backgrounded by the
# entrypoint and inherits the script's stdout, and `out="$(run 0)"` waits for
# every holder of that pipe to let go — so a forwarder that outlives the capture
# hangs the test rather than failing it, which took a 300-second timeout to see.
cat > "$WORK/bin/node" <<'EOF'
#!/bin/sh
case "$1" in
  -e) exit 0 ;;
  *)  exec sleep 300 >/dev/null 2>&1 ;;
esac
EOF
# pi exits with whatever the test asks for, so the assertion is about whether
# that status survives the reaping below it.
cat > "$WORK/bin/pi" <<'EOF'
#!/bin/sh
printf 'pi ran: %s\n' "$*"
exit "${STUB_PI_RC:-0}"
EOF
chmod +x "$WORK/bin/node" "$WORK/bin/pi"

# The real path is /usr/local/lib/model-socket.js. The entrypoint is run through
# a copy with that path rewritten, rather than by creating a directory on this
# machine: a test that needs root to set itself up is a test nobody runs.
sed "s|/usr/local/lib/model-socket.js|$WORK/lib/model-socket.js|" "$ENTRY" > "$WORK/entrypoint.sh"
chmod +x "$WORK/entrypoint.sh"

run() { PATH="$WORK/bin:$PATH" STUB_PI_RC="$1" sh "$WORK/entrypoint.sh" --version 2>&1; }

printf '\n== the container exits with pi status, not the forwarder it just killed ==\n\n'
out="$(run 0)"; rc=$?
rc_is "a session that succeeded exits 0" "$rc" 0
check "and pi really ran"                "pi ran: --version" "$out"

printf '\n-- and a real failure is still a real failure --\n\n'
#
# The mirror image of the bug matters as much: if the fix were `|| true` on the
# wrong line, or an unconditional `exit 0`, every failed session would come back
# green and the line would build on top of it.
out="$(run 3)"; rc=$?
rc_is "pi's own non-zero survives"       "$rc" 3
out="$(run 1)"; rc=$?
rc_is "so does 1"                        "$rc" 1

printf '\n-- 143 in particular is never invented --\n\n'
#
# The regression this suite exists for. Assert the number itself, because it is
# the number that cost the two days: a reader who sees 143 goes looking for a
# signal, and there was never one to find.
for want in 0 2 3; do
  run "$want" >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq 143 ]; then
    printf '  FAIL  pi exited %s and the entrypoint turned it into 143\n' "$want"; FAIL=$((FAIL+1))
  else
    printf '  ok    pi exited %s and the entrypoint did not say 143\n' "$want"; PASS=$((PASS+1))
  fi
done

printf '\n-- the forwarder is still reaped --\n\n'
#
# The fix must not be "stop killing it". A forwarder left running holds the one
# route out of the sandbox open after the session that was allowed to use it has
# ended.
# Matched against the CODE lines, not the file: the comment above them explains
# the fix in prose, so a grep for `|| true` alone passed against the buggy
# version too — a check that reads the explanation instead of the thing.
CODE="$(grep -vE '^[[:space:]]*#' "$ENTRY")"
check "kill is still there"   'kill "$FORWARDER" 2>/dev/null || true' "$CODE"
check "and wait still reaps"  'wait "$FORWARDER" 2>/dev/null || true' "$CODE"

printf '\n-- and the reap runs even when the session failed --\n\n'
#
# `set -e` aborts on a bare `pi "$@"` that returns non-zero, which skipped both
# lines above on exactly the runs most likely to leave something behind.
check "pi's status is captured, not asserted" 'if pi "$@"; then rc=0; else rc=$?; fi' "$CODE"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
