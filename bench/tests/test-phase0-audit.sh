#!/usr/bin/env bash
# test-phase0-audit.sh — the audit that says "32 checks passed".
#
# That sentence is quoted in the handoff document and is how anyone decides the
# repository is in the state it claims. Nothing tested the script that produces
# it, and the failure mode is specific: a check that is deleted, renamed, or
# guarded into never running does not make the audit fail. It makes the audit
# report a smaller number, in a line whose shape is identical to the line it
# printed yesterday.
#
# The same reason this project's commit hook refuses a typed assertion count: a
# total nobody can check is a total that drifts.
#
# It also asserts that the two checks which fired on real problems today are
# still there by name — `results_ledger` caught two figures written and not
# indexed, and `figures_have_provenance` is the standing finding — because those
# are the two most tempting to silence.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
AUDIT="$ROOT/bench/phase0-audit.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:200}"; FAIL=$((FAIL+1)); fi }

[ -f "$AUDIT" ] || { printf '  SKIP  no phase0-audit.sh\n\n0 passed, 0 failed\n'; exit 0; }

# The names it can report on, taken from the script rather than from a list kept
# beside it — a second list is a second thing to keep in sync.
NAMES="$(grep -oE '(ok|finding) "[a-z_.]+"' "$AUDIT" | awk '{print $2}' | tr -d '"' | sort -u)"
N="$(printf '%s\n' "$NAMES" | grep -c .)"

printf '\n== every check it can report is one it can also fail ==\n\n'
# A check with an `ok` and no `finding` cannot fail: it is a line that always
# reads green. A check with a `finding` and no `ok` can never pass, which reads
# as a permanent fault nobody can clear. Both are bugs in an audit.
only_ok=""; only_fail=""
while IFS= read -r nm; do
  [ -n "$nm" ] || continue
  grep -qE "ok \"$nm\"" "$AUDIT"      || only_fail="$only_fail $nm"
  grep -qE "finding \"$nm\"" "$AUDIT" || only_ok="$only_ok $nm"
done <<< "$NAMES"
if [ -z "$only_ok" ]; then printf '  ok    none of the %s checks is green-only\n' "$N"; PASS=$((PASS+1))
else printf '  FAIL  these can report ok and never a finding:%s\n' "$only_ok"; FAIL=$((FAIL+1)); fi
# `artifacts.sweep` is the exception and is one on purpose: it is the guard that
# fires when there is no phase0 result file at all, in which case every predicate
# below it is unverifiable. There is nothing for it to report on success — the
# success case is the twenty-eight checks that follow being able to run.
only_fail="$(printf '%s' "$only_fail" | sed 's/ artifacts\.sweep//')"
if [ -z "$only_fail" ]; then printf '  ok    and the only finding-only check is the one that guards the rest\n'; PASS=$((PASS+1))
else printf '  FAIL  these can report a finding and never ok:%s\n' "$only_fail"; FAIL=$((FAIL+1)); fi

printf '\n== the two that fired on real problems today are still here ==\n\n'
check "results_ledger"            "results_ledger" "$NAMES"
check "figures_have_provenance"   "figures_have_provenance" "$NAMES"
check "harnesses_emit_provenance" "harnesses_emit_provenance" "$NAMES"

printf '\n== every check it declares actually reports something ==\n\n'
#
# Not an arithmetic identity: a check can report more than once — some run per
# file — so "passed + findings" legitimately exceeds the number of NAMES. What
# must hold is that no declared name goes missing from the output, because that
# is what a check deleted, renamed, or guarded into never running looks like:
# the audit still prints a total, and the total is smaller.
out="$(cd "$ROOT" && timeout 600 bash "$AUDIT" 2>&1 || true)"
silent=""
while IFS= read -r nm; do
  [ -n "$nm" ] || continue
  # artifacts.sweep only speaks when the results are missing, which they are not.
  [ "$nm" = "artifacts.sweep" ] && continue
  grep -qF -- "$nm" <<<"$out" || silent="$silent $nm"
done <<< "$NAMES"
if [ -z "$silent" ]; then
  printf '  ok    all %s declared checks reported\n' "$((N - 1))"; PASS=$((PASS+1))
else
  printf '  FAIL  declared but silent — deleted, renamed, or guarded into never running:%s\n' "$silent"
  FAIL=$((FAIL+1))
fi
passed="$(grep -oE '[0-9]+ checks passed' <<<"$out" | grep -oE '[0-9]+' | head -1)"
if [ -n "$passed" ] && [ "$passed" -ge "$((N - 4))" ]; then
  printf '  ok    and it still reports a total (%s passed)\n' "$passed"; PASS=$((PASS+1))
else
  printf '  FAIL  the audit printed no plausible total: %s\n' "${passed:-<none>}"; FAIL=$((FAIL+1))
fi
check "and it names the standing finding" "figures_have_provenance" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
