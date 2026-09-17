#!/usr/bin/env bash
# test-smoke-line.sh — the setup half of the real-model smoke, without a model.
#
# bench/smoke-line.sh builds a throwaway repository, scaffolds it, gives it an
# origin, and runs the line against it with live models. The run costs fifteen
# minutes of GPU and cannot be a unit test. **The setup can**, and the setup is
# where it failed twice by hand: preflight refuses a repo with no `origin`, and
# `factory doctor` refuses a `hidden_tests.dir` that is not there because the path
# is relative to a sibling this scratch repo does not have.
#
# So these assertions stop at `doctor`, which is the last thing before a model is
# asked anything — and which is exactly the boundary the script has to get right.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SMOKE="$ROOT/bench/smoke-line.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:300}"; FAIL=$((FAIL+1)); fi }
nope()  { if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
          else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi }

[ -x "$SMOKE" ] || { printf '  SKIP  no smoke-line.sh\n\n0 passed, 0 failed\n'; exit 0; }

printf '\n== it builds a repo the line will accept ==\n\n'
#
# Run with a --stop-after nothing recognises, so the setup happens in full and
# the RUN refuses immediately. Everything asserted below is upstream of a model.
D="$WORK/smoke"
out="$(bash "$SMOKE" --dir "$D" --stop-after not-a-step 2>&1)"
check "it scaffolds"                 "doctor" "$out"
check "and doctor says ready"        "ready" "$out"
nope  "with nothing unready"         "not ready — fix the above" "$out"

printf '\n== the two refusals it exists to avoid ==\n\n'
#
# preflight cannot verify main against a remote that is not there.
check "the scratch repo has an origin" "origin.git" "$(git -C "$D/repo" remote -v 2>&1)"
# hidden_tests.dir is relative to the config and assumes a sibling layout. A
# scratch repo in /tmp is not one, and doctor refuses rather than skipping the
# hidden tests quietly — which is right on a real target and noise here.
# The KEY, not the word: the scaffold writes a `_comment` array that explains what
# hidden_tests is for, so grepping the file finds it whether or not the key is
# there. An assertion that cannot tell a key from a sentence about the key would
# have passed for the wrong reason forever.
if jq -e 'has("hidden_tests") | not' "$D/repo/factory/pipeline-config.json" >/dev/null 2>&1; then
  printf '  ok    and no hidden_tests key\n'; PASS=$((PASS+1))
else
  printf '  FAIL  the hidden_tests key is still in the config\n'; FAIL=$((FAIL+1))
fi
check "doctor agrees there are none"   "none configured" "$out"

printf '\n== what it leaves behind ==\n\n'
#
# A failed run keeps the repo, always: a smoke that deletes the evidence of its
# own failure is worse than no smoke.
if [ -d "$D/repo/factory/runs" ] || [ -d "$D/repo" ]; then
  printf '  ok    a failed run keeps the repo\n'; PASS=$((PASS+1))
else
  printf '  FAIL  the repo was removed after a failure\n'; FAIL=$((FAIL+1))
fi
check "and says where it is"         "$D" "$out"

printf '\n== it says why it is not a unit test ==\n\n'
SRC="$(cat "$SMOKE")"
check "the stub suite's limit is stated" "cannot catch a break BETWEEN two real components" "$SRC"
check "with the one that got through"    "request.json" "$SRC"
check "and that it is not cheap"         "941 seconds" "$SRC"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
