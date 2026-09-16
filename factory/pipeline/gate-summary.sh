#!/usr/bin/env bash
# gate-summary.sh — what a failing gate found, in lines a human can act on.
#
# This was a jq program embedded in orchestrate.sh's halt(), which meant it could
# only be tested by driving a whole run to a failing gate. It was therefore not
# tested, and it was wrong: a run halted by a hidden-test failure produced a
# QUESTIONS.md that said "the gate failed" and then listed nothing, because the
# program knew about containment, gates, criteria and invariants and not about
# the two checks added after it was written.
#
# One rule about what may appear here: **no hidden test text**. QUESTIONS.md is
# written into the run directory, which is inside the repository, which the
# worker mounts whole. A count and a path to output kept outside the repo; never
# a name, an assertion or a line of output.
set -uo pipefail

usage() {
  cat <<'EOF'
gate-summary.sh — the failing parts of a gate.json, one per line.

usage: gate-summary.sh <gate.json>

Prints nothing and exits 0 when nothing failed. Exit 2 if the file is unreadable:
"the gate found nothing wrong" and "I could not read the gate" are different
answers and a caller that cannot tell them apart will print the first.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
esac
GATE="$1"
[ -f "$GATE" ] || { printf 'gate-summary: no such file: %s\n' "$GATE" >&2; exit 2; }
jq -e . >/dev/null 2>&1 < "$GATE" || { printf 'gate-summary: not JSON: %s\n' "$GATE" >&2; exit 2; }

jq -r '
  (if (.containment.contained | not) then "  - containment: " + (.containment.violations | join(", ")) else empty end),
  (.gates[]? | select(.status != "pass") | "  - gate " + .id + ": exit " + (.exit_code|tostring)),
  (.acceptance_criteria[]? | select(.status != "pass") | "  - " + .id + ": " + (.reason // .command // "failed")),
  (if (.invariants != null and .invariants.status != "pass")
     then "  - invariants: " + (.invariants.reason // .invariants.ref) else empty end),
  (if (.secret_scan != null and ((.secret_scan.suspicious_lines // []) | length) > 0)
     then "  - secret scan: " + (((.secret_scan.suspicious_lines) | length)|tostring) + " suspicious line(s) — see gate.json, not this file"
     else empty end),
  (if (.hidden_tests != null and .hidden_tests.status != "passed" and .hidden_tests.status != "not_configured")
     then "  - hidden tests: " + .hidden_tests.status
          + (if (.hidden_tests.failed_count // 0) > 0 then " — " + ((.hidden_tests.failed_count)|tostring) + " failing" else "" end)
          + ". They are not in this repository and neither is their output: " + (.hidden_tests.output_path // "(no path recorded)")
     else empty end),
  (if (.test_integrity != null and .test_integrity.fails_on_revert != null and .test_integrity.fails_on_revert.result == "no")
     then "  - test integrity: " + (.test_integrity.fails_on_revert.why // "the tests pass with the change reverted")
     else empty end),
  (if (.bean_forbids != null and ((.bean_forbids.violations // []) | length) > 0)
     then (.bean_forbids.violations[]
           | "  - " + (.field // "non-goal") + " \"" + .non_goal + "\": "
             + (if .kind == "path" then (.offending | join(", ")) + " is inside " + (.patterns | join(", "))
                else "imports " + .module end))
     else empty end)
' "$GATE"
