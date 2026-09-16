#!/usr/bin/env bash
# run-all.sh — every suite, one command, with a verdict at the end.
#
# There was no such command. Running the tests meant typing a for-loop over a
# remembered list of filenames, which is a thing that gets typed less and less
# often, and a suite nobody runs is a suite that does not exist. Twice today a
# change went in with a sibling test left failing, because "all the tests" meant
# "the ones I thought to name".
#
# It discovers the files rather than listing them, so a new suite is covered the
# moment it is written.
#
# Ordering is deliberate: the fast unit-shaped suites first, so a broken helper
# is reported in seconds rather than after the slow end-to-end one. --fast stops
# before anything that drives the whole line.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAST=0; ONLY=""; VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fast)    FAST=1; shift ;;
    --only)    ONLY="${2:?--only needs a name}"; shift 2 ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help)
      cat <<'EOF'
run-all.sh — run every test suite.

  --fast        skip the end-to-end suites (full-line, orchestrate-build)
  --only <n>    run just the suite whose name contains <n>
  --verbose     show each suite's output, not just its tally

Exit: 0 every suite passed · 1 one or more failed.
EOF
      exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Slow ones last, and named here rather than inferred from a timing run so the
# order is stable and reviewable.
SLOW="full-line orchestrate-build build-loop"

ordered() {
  local f n
  for f in "$HERE"/test-*.sh; do
    n="$(basename "$f" .sh)"; n="${n#test-}"
    case " $SLOW " in *" $n "*) continue ;; esac
    printf '%s\n' "$n"
  done
  [ "$FAST" = 1 ] && return 0
  for n in $SLOW; do [ -f "$HERE/test-$n.sh" ] && printf '%s\n' "$n"; done
}

TOTAL_PASS=0; TOTAL_FAIL=0; FAILED_SUITES=""
START="$(date +%s)"

printf '\n'
while IFS= read -r name; do
  [ -n "$name" ] || continue
  [ -n "$ONLY" ] && case "$name" in *"$ONLY"*) : ;; *) continue ;; esac

  out="$(timeout 900 bash "$HERE/test-$name.sh" 2>&1)"; rc=$?
  tally="$(grep -oE '[0-9]+ passed, [0-9]+ failed' <<<"$out" | tail -1)"
  p="$(awk '{print $1}' <<<"$tally")"; f="$(awk '{print $3}' <<<"$tally")"
  TOTAL_PASS=$((TOTAL_PASS + ${p:-0})); TOTAL_FAIL=$((TOTAL_FAIL + ${f:-0}))

  if [ "$rc" -eq 124 ]; then
    printf '  %-22s TIMED OUT after 900s\n' "$name"
    FAILED_SUITES="$FAILED_SUITES $name(timeout)"
  elif [ "$rc" -ne 0 ] || [ "${f:-0}" -ne 0 ]; then
    printf '  %-22s %s\n' "$name" "${tally:-no tally — exit $rc}"
    FAILED_SUITES="$FAILED_SUITES $name"
    # A failing suite prints its failures whether or not --verbose was asked for.
    # The whole point of a runner is to not have to re-run one by hand to see why.
    grep -E '^\s+FAIL|^==' <<<"$out" | sed 's/^/      /' | head -20
  else
    printf '  %-22s %s\n' "$name" "$tally"
  fi
  [ "$VERBOSE" = 1 ] && sed 's/^/      /' <<<"$out"
done < <(ordered)

printf '\n  %s assertions, %s failed, %ss\n' \
  "$((TOTAL_PASS + TOTAL_FAIL))" "$TOTAL_FAIL" "$(( $(date +%s) - START ))"
# Leave the count where a commit hook can check it. Several commit messages in
# this repository quote an assertion count written from memory before the suite
# was read, and every one of them is a small false claim in a record whose value
# is that its claims are true.
printf '%s\n' "$((TOTAL_PASS + TOTAL_FAIL))" > "${TMPDIR:-/tmp}/factory-last-suite-count" 2>/dev/null || true
if [ -n "$FAILED_SUITES" ]; then
  printf '  failing:%s\n\n' "$FAILED_SUITES"
  exit 1
fi
printf '  all green\n\n'
