#!/usr/bin/env bash
# verify.sh — a hidden suite has to fail against nothing AND pass against the
# real thing. Only the first was ever checked.
#
# `factory/pipeline/hidden-tests.sh` runs a control against an empty tree and
# refuses a suite that passes it: that proves the suite CAN fail. Nothing proved
# it can pass. A suite that can never pass is not the milder failure — it blocks
# every attempt of its bean forever, and all the worker is told is a count, so it
# cannot see that the test is wrong rather than its code. That is the worst
# failure this design can have and it had no check at all.
#
# Both directions, against a tree that is known good:
#
#   fails against an empty tree   — every test except the declared absences
#   passes against the real tree  — every test, no exceptions
#
# The real tree is the accepted output of the bean itself. It only exists after
# the bean has run, which is why this is a command rather than part of the gate:
# run it once when a bean lands, and whenever its hidden tests are edited.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
verify.sh — check a hidden suite fails against nothing and passes against the real tree.

usage: verify.sh <repo>/<bean> --tree <dir>
       verify.sh <repo>/<bean> --branch <ref> --repo <dir>

  <repo>/<bean>   e.g. seating-planner-py/bean-001
  --tree <dir>    a tree the suite must pass against
  --branch <ref>  export this ref from --repo into a temp tree and use that
  --repo <dir>    the git repository --branch lives in

Exit: 0 both directions hold · 1 one of them does not · 2 could not check
EOF
}

SUITE=""; TREE=""; BRANCH=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tree)   TREE="${2:?--tree needs a directory}"; shift 2 ;;
    --branch) BRANCH="${2:?--branch needs a ref}"; shift 2 ;;
    --repo)   REPO="${2:?--repo needs a directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    *)  [ -z "$SUITE" ] && SUITE="$1" || { usage >&2; exit 2; }; shift ;;
  esac
done
[ -n "$SUITE" ] || { usage >&2; exit 2; }
DIR="$HERE/$SUITE"
[ -d "$DIR" ] || { printf 'verify: no hidden suite at %s\n' "$DIR" >&2; exit 2; }

CLEANUP=""
trap '[ -n "$CLEANUP" ] && rm -rf "$CLEANUP"' EXIT
if [ -n "$BRANCH" ]; then
  [ -n "$REPO" ] || { printf 'verify: --branch needs --repo\n' >&2; exit 2; }
  TREE="$(mktemp -d)"; CLEANUP="$TREE"
  git -C "$REPO" archive "$BRANCH" 2>/dev/null | tar -x -C "$TREE" \
    || { printf 'verify: could not export %s from %s\n' "$BRANCH" "$REPO" >&2; exit 2; }
fi
# No tree is its own answer, not an error. Most beans have not run yet, and for
# those only half of this can be checked — which is worth saying, because "the
# control passed" has been the whole of hidden-test verification until now and
# that is exactly the half that does not catch a suite which can never pass.
HALF=0
if [ -z "$TREE" ]; then HALF=1
elif [ ! -d "$TREE" ]; then printf 'verify: no such tree: %s\n' "$TREE" >&2; exit 2; fi

command -v pytest >/dev/null 2>&1 || { printf 'verify: no pytest on PATH\n' >&2; exit 2; }

# The names that are supposed to pass against nothing, declared next to the tests.
DECLARED="$(sed 's/#.*//; s/[[:space:]]//g' "$DIR/absent-by-design.txt" 2>/dev/null | sed '/^$/d' | sort -u)"

passes_in() { # passes_in <tree> -> the test names that PASSED, one per line
  local t="$1" log; log="$(mktemp)"
  ( cd "$t" && HIDDEN_TREE="$t" PYTHONPATH="$t/src" pytest -q -p no:cacheprovider -rA "$DIR" ) > "$log" 2>&1
  { grep -oE '^PASSED[[:space:]]+[^[:space:]]+::test_[A-Za-z0-9_]+' "$log" | sed 's/.*:://'
    grep -oE '::test_[A-Za-z0-9_]+[[:space:]]+PASSED' "$log" | sed 's/^:://; s/[[:space:]]*PASSED$//'
  } | sort -u
  rm -f "$log"
}
all_tests() { grep -hoE '^[[:space:]]*def (test_[A-Za-z0-9_]+)' "$DIR"/*.py | sed 's/.*def //' | sort -u; }

printf '\nhidden suite: %s\n  real tree: %s\n\n' "$SUITE" "${BRANCH:-${TREE:-none given — this bean has not produced one yet}}"

ALL="$(all_tests)"; N_ALL="$(printf '%s\n' "$ALL" | grep -c . || true)"
EMPTY_TREE="$(mktemp -d)"; mkdir -p "$EMPTY_TREE/src"
PASS_EMPTY="$(passes_in "$EMPTY_TREE")"
rm -rf "$EMPTY_TREE"
PASS_REAL=""
[ "$HALF" -eq 0 ] && PASS_REAL="$(passes_in "$TREE")"

rc=0
# 1. Against the real tree: everything passes.
MISSING="$(comm -23 <(printf '%s\n' "$ALL") <(printf '%s\n' "$PASS_REAL"))"
if [ "$HALF" -eq 1 ]; then
  printf '  --      no tree given, so "does it pass on the real thing" was NOT checked\n'
elif [ -z "$MISSING" ]; then
  printf '  ok      all %s test(s) pass against the real tree\n' "$N_ALL"
else
  printf '  FAIL    these do not pass against the tree the bean actually produced:\n' >&2
  printf '%s\n' "$MISSING" | sed 's/^/            - /' >&2
  printf '\n          A hidden test that cannot pass blocks every attempt of its bean, and\n' >&2
  printf '          the worker is told only a count — so it cannot tell a wrong test from\n' >&2
  printf '          its own wrong code. This is the worst failure this design can have.\n' >&2
  rc=1
fi

# 2. Against nothing: only the declared absences pass.
UNDECLARED="$(comm -23 <(printf '%s\n' "$PASS_EMPTY") <(printf '%s\n' "$DECLARED"))"
N_EMPTY="$(printf '%s\n' "$PASS_EMPTY" | grep -c . || true)"
if [ -z "$UNDECLARED" ]; then
  printf '  ok      %s of %s fail against an empty tree; the %s that pass are declared absences\n' \
    "$((N_ALL - N_EMPTY))" "$N_ALL" "$N_EMPTY"
else
  printf '  FAIL    these pass against a tree with nothing in it and are not declared:\n' >&2
  printf '%s\n' "$UNDECLARED" | sed 's/^/            - /' >&2
  printf '\n          Add them to %s/absent-by-design.txt if they assert an ABSENCE, or\n' "$DIR" >&2
  printf '          fix them. A test that cannot fail inflates the count the judge is given.\n' >&2
  rc=1
fi

STALE="$(comm -13 <(printf '%s\n' "$PASS_EMPTY") <(printf '%s\n' "$DECLARED"))"
[ -n "$STALE" ] && printf '  note    declared as absence tests but failing against nothing: %s\n' "$(printf '%s ' $STALE)"

# Leave a record, because this check was the one thing in the line that ran and
# wrote nothing down.
#
# Its own header says what is at stake: a suite that can never pass "blocks every
# attempt of its bean forever, and all the worker is told is a count". Whether
# that had been ruled out for a given bean lived in whoever last ran this command
# and remembered. The hash is the useful half — a suite EDITED since it was
# verified is back to unknown, and editing hidden tests is exactly what happens
# when one turns out to be wrong.
SUITE_SHA="$(cat "$DIR"/*.py "$DIR"/absent-by-design.txt 2>/dev/null | sha256sum | cut -d' ' -f1)"
# Overridable so the suite for this script does not overwrite the real records.
# A test that verifies a suite half-way would otherwise downgrade a record a
# person had earned by running it both ways — tests that mutate the evidence
# they are testing are how a green suite ends up meaning less than it says.
VERIFIED_DIR="${HIDDEN_VERIFIED_DIR:-$HERE/verified}"
mkdir -p "$VERIFIED_DIR/$(dirname "$SUITE")" 2>/dev/null || true
TREE_REF="${BRANCH:-$TREE}"
TREE_SHA=""
[ -n "$BRANCH" ] && [ -n "$REPO" ] && TREE_SHA="$(git -C "$REPO" rev-parse "$BRANCH" 2>/dev/null || true)"
jq -n --arg suite "$SUITE" --arg sha "$SUITE_SHA" --arg ref "$TREE_REF" \
      --arg tsha "$TREE_SHA" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson rc "$rc" --argjson half "$HALF" --argjson n "$N_ALL" \
  '{schema:"hidden-verify/1.0.0", suite:$suite, suite_sha256:$sha, tests:$n,
    outcome:(if $rc != 0 then "not_verified" elif $half == 1 then "half_checked" else "ok" end),
    checked_against:(if $ref == "" then null else $ref end),
    tree_sha:(if $tsha == "" then null else $tsha end),
    both_directions:($rc == 0 and $half == 0), verified_at:$at}' \
  > "$VERIFIED_DIR/$SUITE.json" 2>/dev/null || true

printf '\n'
if [ "$rc" -ne 0 ]; then
  printf 'HIDDEN SUITE NOT VERIFIED.\n' >&2
  exit 1
fi
if [ "$HALF" -eq 1 ]; then
  printf 'HALF CHECKED — it can fail. Whether it can pass is unknown until this bean\n'
  printf 'produces a tree; re-run with --branch once it has.\n'
  exit 3
fi
printf 'HIDDEN SUITE OK — it can fail, and it does pass on the real thing.\n'
exit 0
