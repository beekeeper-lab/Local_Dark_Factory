#!/usr/bin/env bash
# test-snapshot.sh — the launcher every other harness depends on, and which had
# no test of its own.
#
# bash reads a script by byte offset as it executes, so editing one mid-run
# corrupts the run in progress. `bench/snapshot.sh` is the protection: every
# harness re-execs through it and runs from a copy. Three separate times today a
# measurement was lost to that hazard — a zero-byte results file, a corrupted
# reaudit, and a bash syntax error 899 seconds into a case — and each time the
# fix was somewhere in this file or in what it is handed.
#
# It also exited 2 after a completely successful seventy-five minute run, on a
# sixty-line file that passes `bash -n`, for a reason still not identified.
#
# So: the properties it has to have, asserted.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$BENCH/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -f "$BENCH/_probe.sh"; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# A probe harness, written into the real bench/ because that is what snapshot.sh
# copies. Removed by the trap.
probe() { printf '%s\n' "$1" > "$BENCH/_probe.sh"; }

printf '\n== the harness runs from the copy, not from the tree ==\n\n'
#
# The whole point. If it ran from the tree, editing a harness mid-measurement
# would corrupt the measurement — which is how a seventy-five minute run produced
# a zero-byte results file.
probe '#!/usr/bin/env bash
printf "ran-from: %s\n" "${BASH_SOURCE[0]}"
printf "root-is: %s\n" "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"'
out="$(bash "$BENCH/snapshot.sh" _probe.sh 2>&1)"
check "it announces the snapshot"      "bench snapshot: /tmp/" "$out"
check "and the harness runs from it"   "ran-from: /tmp/" "$out"
nope  "not from the repository"        "ran-from: $BENCH" "$out"

printf '\n-- with the repository layout around it, because harnesses climb --\n\n'
#
# judge-fitness reaches `$HERE/../factory/pipeline/judge.sh` and audit-check
# climbs to `../../bench/validate.py`. A copy of bench/ alone leaves both missing,
# quietly: the first snapshotted run failed six mutations in a row on it.
probe '#!/usr/bin/env bash
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for d in factory/pipeline schemas bench; do [ -e "$R/$d" ] && printf "have: %s\n" "$d"; done
[ -e "$R/.venv" ] && printf "have: venv\n"'
out="$(bash "$BENCH/snapshot.sh" _probe.sh 2>&1)"
check "factory/pipeline is beside it"  "have: factory/pipeline" "$out"
check "and schemas"                    "have: schemas" "$out"
check "and the venv, by symlink"       "have: venv" "$out"

printf '\n== the exit code is the harness'"'"'s ==\n\n'
#
# A launcher that swallows or invents an exit code turns a failed measurement into
# a passing one, or the reverse — and this file did exactly the second, exiting 2
# after a run that had succeeded completely.
probe '#!/usr/bin/env bash
exit 7'
out="$(bash "$BENCH/snapshot.sh" _probe.sh 2>&1)"; rc=$?
rc_is "a failing harness fails"        "$rc" 7
probe '#!/usr/bin/env bash
exit 0'
out="$(bash "$BENCH/snapshot.sh" _probe.sh 2>&1)"; rc=$?
rc_is "and a passing one passes"       "$rc" 0

printf '\n== arguments reach the harness verbatim ==\n\n'
probe '#!/usr/bin/env bash
printf "args: [%s]\n" "$*"
printf "count: %s\n" "$#"'
out="$(bash "$BENCH/snapshot.sh" _probe.sh --spec a.md --repeat 3 "two words" 2>&1)"
check "every one of them"              "args: [--spec a.md --repeat 3 two words]" "$out"
check "with the right count"           "count: 5" "$out"

printf '\n== results go to the real tree, not to the copy ==\n\n'
#
# The copy is deleted when the run ends. A figure written into it is a figure
# nobody ever sees, and a harness would report the path it wrote as if it existed.
probe '#!/usr/bin/env bash
R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -L "$R/results" ] && printf "results-is-a-link: %s\n" "$(readlink "$R/results")"'
out="$(bash "$BENCH/snapshot.sh" _probe.sh 2>&1)"
check "results is a link to the tree"  "results-is-a-link: $BENCH/results" "$out"

printf '\n== the copy is cleaned up ==\n\n'
probe '#!/usr/bin/env bash
printf "snap: %s\n" "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"'
out="$(bash "$BENCH/snapshot.sh" _probe.sh 2>&1)"
snap="$(sed -n 's/^snap: //p' <<<"$out" | head -1)"
if [ -n "$snap" ] && [ ! -d "$snap" ]; then
  printf '  ok    the snapshot directory is gone afterwards\n'; PASS=$((PASS+1))
else
  printf '  FAIL  %s still exists\n' "$snap"; FAIL=$((FAIL+1))
fi

printf '\n== FACTORY_NO_SNAPSHOT is the documented way out ==\n\n'
#
# For iterating on a harness, where seeing a change take effect is the point.
probe '#!/usr/bin/env bash
printf "ran-from: %s\n" "${BASH_SOURCE[0]}"'
out="$(FACTORY_NO_SNAPSHOT=1 bash "$BENCH/_probe.sh" 2>&1)"
check "the harness runs in place"      "ran-from: $BENCH/_probe.sh" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
