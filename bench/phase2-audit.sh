#!/usr/bin/env bash
# phase2-audit.sh — the thirteen phase_2_exit predicates, computed.
#
# Phase 2 is the fault-injection phase: the claim is not "the line works" but
# "here is what it does when each specific thing goes wrong". A checklist of
# thirteen ticks is exactly the artifact that rots — every one of them was true
# on the day it was written, and nothing notices when a refactor quietly removes
# the assertion behind one.
#
# So this does not read the plan. It runs the suites that hold each predicate and
# looks for the specific assertions by name. A predicate passes when its suite
# passes AND every assertion it rests on is present and green. An assertion that
# has been renamed is reported as missing, which is the right answer: the audit
# cannot tell a rename from a deletion, and neither can a reader of the plan.
#
# Slow on purpose — it runs real suites, about two minutes. A fast audit that
# greps for strings in source files would pass on a test that is commented out.
set -uo pipefail
# An audit is a measurement of this repository at a moment, so it carries the
# same provenance block as every figure under bench/results. "Which machine,
# which ollama, which pipeline version" is the question asked of any other
# number here, and there is no reason an audit should be exempt from it.
# shellcheck source=provenance.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/provenance.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TESTS="$ROOT/factory/pipeline/tests"

usage() {
  cat <<'EOF'
phase2-audit.sh — the thirteen phase_2_exit predicates, computed from the suites.

usage: phase2-audit.sh [--json <path>] [--quick]

  --json   also write the result as JSON
  --quick  reuse suite output from a previous run in this shell session if the
           cache file is younger than 10 minutes (development only; the audit of
           record runs the suites)
EOF
}

JSON_OUT=""; QUICK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json)  JSON_OUT="${2:?}"; shift 2 ;;
    --quick) QUICK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

PASS_N=0; FAIL_N=0; FINDINGS='[]'; PREDICATES='{}'
ok()   { PASS_N=$((PASS_N+1)); printf '  ok    %-28s %s\n' "$1" "$2"; }
bad()  { FAIL_N=$((FAIL_N+1)); printf '  FAIL  %-28s [%s] %s\n' "$1" "$2" "$3"
         FINDINGS="$(jq -c --arg id "$1" --arg s "$2" --arg e "$3" \
           '. + [{predicate:$id, severity:$s, evidence:$e}]' <<<"$FINDINGS")"; }
pred() { PREDICATES="$(jq -c --arg k "$1" --arg v "$2" '. + {($k): $v}' <<<"$PREDICATES")"; }

CACHE="${TMPDIR:-/tmp}/factory-phase2-audit-cache"
mkdir -p "$CACHE"

run_suite() { # run_suite <name> -> caches output, echoes the cache path
  # Two assignments in one `local`: bash expands the whole argument list before
  # the first name is bound, so `f="$CACHE/$name.out"` reads the outer $name and
  # dies under `set -u`. Third time in this repository.
  local name="$1"
  local f="$CACHE/$name.out"
  if [ "$QUICK" = 1 ] && [ -f "$f" ] && [ -n "$(find "$f" -mmin -10 2>/dev/null)" ]; then
    printf '%s' "$f"; return 0
  fi
  if [ -f "$TESTS/test-$name.sh" ]; then
    timeout 900 bash "$TESTS/test-$name.sh" > "$f" 2>&1
    printf '%s' "$f"
  else
    printf 'MISSING SUITE: test-%s.sh\n' "$name" > "$f"
    printf '%s' "$f"
  fi
}

# assert_in <predicate> <severity> <default-suite> <assertion>...
#
# Every assertion must appear as a green line in a suite that finished with no
# failures. A predicate resting on one green assertion inside a suite that failed
# elsewhere is resting on a suite nobody can trust.
#
# An assertion may name its own suite as `suite::assertion`. Some faults are not
# one file's business: the remote-CI one is ci.sh writing the re-open list and
# build-loop consuming it, and a predicate that could only look in one place
# would have to pretend otherwise.
assert_in() {
  local id="$1" sev="$2" default_suite="$3"; shift 3
  local missing="" suites="" n=0 a suite text f tally
  for a in "$@"; do
    n=$((n + 1))
    case "$a" in
      *::*) suite="${a%%::*}"; text="${a#*::}" ;;
      *)    suite="$default_suite"; text="$a" ;;
    esac
    case " $suites " in *" $suite "*) ;; *) suites="$suites $suite" ;; esac
    f="$(run_suite "$suite")"
    tally="$(grep -oE '[0-9]+ passed, [0-9]+ failed' "$f" | tail -1)"
    if [ -z "$tally" ]; then
      bad "$id" "$sev" "test-$suite.sh produced no tally — it did not finish"
      pred "$id" fail; return
    fi
    if [ "$(awk '{print $3}' <<<"$tally")" != "0" ]; then
      bad "$id" "$sev" "test-$suite.sh: $tally"
      pred "$id" fail; return
    fi
    grep -qF "  ok    $text" "$f" || missing="$missing \"$suite::$text\""
  done
  if [ -n "$missing" ]; then
    bad "$id" "$sev" "the suites pass but these assertions are not in them:$missing"
    pred "$id" fail; return
  fi
  ok "$id" "$n assertion(s) across$suites"
  pred "$id" pass
}

printf '\nphase-2 audit — fault injection, computed from the suites\n\n'

assert_in controller_restart_tests blocker faults \
  "the tree is clean after the kill" \
  "the resume skips what passed" \
  "and finishes the build" \
  "the tree is still clean" \
  "the killed step is not skipped"

assert_in unauthorized_path_tests blocker faults \
  "the attempt is rejected" \
  "and it is rejected every attempt, not stripped once" \
  "the stray file is gone from the tree" \
  "the gate names the stray file" \
  "and fails on containment"

assert_in unclaimed_ac_test blocker faults \
  "the spec check names the criterion" \
  "and refuses the spec"

assert_in size_budget_test blocker faults \
  "the budget is enforced" \
  "and calls for a split, not a retry"

assert_in doc_mismatch_test blocker faults \
  "the document is refused" \
  "and no pull request opens" \
  "the code is still committed"

assert_in duplicate_pr_tests blocker faults \
  "the existing PR is recognised" \
  "and gh was asked to create at most twice"

assert_in credential_exposure_tests blocker faults \
  "no ssh directory in the image" \
  "no git identity in the image"

# Two files: ci.sh decides which tasks the failure touches and writes the list;
# build-loop consumes it and rebuilds only those, once.
assert_in remote_ci_failure_tests blocker ci \
  "back to build" \
  "and recording the task list" \
  "and re-opens nothing" \
  "a skip is not green (exit 9)" \
  "it refuses at once (exit 3)" \
  "build-loop::the named task is built again" \
  "build-loop::and the other one is skipped" \
  "build-loop::the list is consumed" \
  "build-loop::a later run rebuilds nothing"

# And the honest caveat on that one. Every other predicate here has been
# exercised against the thing it is about; this one has only ever met a stubbed
# `gh`. A required check cannot have run for real while the manifest still pins a
# `localhost/` image, because CI cannot pull one — so that is decidable from this
# repository, and the predicate says which it is rather than claiming the stronger
# thing.
GATE_IMAGE="$("$ROOT/factory/pipeline/yaml2json.sh" "$ROOT/factory/scaffold/factory/gates.lock.yaml" 2>/dev/null | jq -r '.image // ""')"
case "$GATE_IMAGE" in
  localhost/*|"")
    if [ "$(jq -r '.remote_ci_failure_tests' <<<"$PREDICATES")" = pass ]; then
      pred remote_ci_failure_tests pass_in_tests
      printf '  --    %-28s the suites pass; no real CI run has happened — gates.lock.yaml still pins %s,
' \
        "remote_ci_failure_tests" "${GATE_IMAGE:-nothing}"
      printf '        %-28s which CI cannot pull. factory/gate-image/publish.sh, then re-run this.
' ""
    fi ;;
esac

assert_in stale_branch_tests blocker sync \
  "it reports the rebase" \
  "it rewinds to the gate" \
  "it forces exactly three steps" \
  "it does not force the spec audit" \
  "the stale gate is moved, not deleted"

assert_in pr_head_violation_tests blocker pr \
  "a moved HEAD is caught" \
  "a revise does not open a PR" \
  "nothing was pushed"

assert_in wrong_model_tests blocker role-routing \
  "absent model refused" \
  "a changed digest stops the run" \
  "a run record with no digest passes"

assert_in frontier_provider_refused blocker role-routing \
  "frontier provider refused"

# human_merge_required is not a test, it is a property of the code: no path in
# this repository merges anything. Asserted by absence, which is the only way to
# assert a negative — and checked against the source rather than a test, because
# a test can only prove that the paths it knows about do not merge.
# Comments are where this repository explains that it never merges, so a search
# that counts them finds thirteen reasons to fail. `grep -rn` prefixes each hit
# with `path:lineno:`, which is why an anchored `^#` does not match — strip the
# prefix before deciding whether the line is a comment.
MERGES="$(grep -rn 'gh pr merge\|--auto\b\|--merge\b' "$ROOT/factory/pipeline" "$ROOT/factory/bin" 2>/dev/null \
  | grep -vE ':[0-9]+: *#' \
  | grep -viE 'never merge|does not merge|no path|refus|nocheck|assert|printf|echo' || true)"
if [ -z "$MERGES" ]; then
  ok "human_merge_required" "no merge call anywhere under factory/pipeline or factory/bin"
  pred human_merge_required verified
else
  bad "human_merge_required" blocker "something here can merge: $(printf '%s' "$MERGES" | head -2 | tr '\n' ' ')"
  pred human_merge_required fail
fi

printf '\nphase_2_exit:\n'
jq -r --argjson p "$PREDICATES" -n '$p | to_entries[] | "  \(.key): \(.value)"'
printf '\n%s ok, %s finding(s)\n' "$PASS_N" "$FAIL_N"

if [ -n "$JSON_OUT" ]; then
  jq -n --argjson p "$PREDICATES" --argjson f "$FINDINGS" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson prov "$(provenance_block)" \
    '{schema:"phase2-audit/1.0.0", audited_at:$ts, provenance:$prov, phase_2_exit:$p, findings:$f,
      note:"Computed by running the suites and looking for named assertions, not by reading the plan. A renamed assertion reports as missing, which is correct: this cannot tell a rename from a deletion, and neither can a reader of a checklist."}' \
    > "$JSON_OUT"
  printf 'written: %s\n' "$JSON_OUT"
fi
[ "$FAIL_N" -eq 0 ]
