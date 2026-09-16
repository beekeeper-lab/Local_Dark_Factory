#!/usr/bin/env bash
# gate.sh — contain, classify, gate (spec §06 step 6).
#
# The build loop contained each task against its own write paths. This contains
# the WHOLE diff against the bean's, intersected with the repo's human-approved
# surface, and then decides what the change is worth worrying about and runs
# everything that can fail.
#
# The order is deliberate. Containment first: a diff that touched something it
# had no business touching is not a change with a failing gate, it is a change
# that should never have been assembled, and running its tests would only give
# it a number to argue with. Then the tier, computed from the paths the diff
# actually touched — §08's "a model that under-reads its change cannot
# down-classify it" is only true if the controller does this arithmetic and
# nobody else does. Then the gates, the acceptance criteria, and the independent
# invariants, all inside the sandbox.
#
# Writes <run_dir>/gate.json. Exit 0 only if every part passed.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
gate.sh — whole-diff containment, tier computation, gates, AC verifies, invariants.

usage: gate.sh <run_dir> --bean <bean.yaml> [options]

  --bean <path>      the bean being built (required)
  --base <ref>       what to diff against (default: main)
  --policy <path>    risk policy (default: factory/risk-policy.yaml)
  --gates <path>     gate manifest (default: factory/gates.lock.yaml)
  --repo-config <p>  repo.yaml, for repo_allowed_paths via the policy
  --judge-tier <n>   the judge's suggested tier, if there is one
  --no-sandbox       run gates and verifies on the host (for a repo with no image)
  --skip-gates       containment, tier and size only — no execution

Exit: 0 everything passed · 1 something failed · 2 the gate could not run.
EOF
}

RUN_DIR=""; BEAN_FILE=""; BASE="main"; POLICY=""; GATES=""; JUDGE_TIER=""
# One environment variable governs "verification runs in the pinned container"
# everywhere it happens — here and in the build loop — so a test or an operator
# turns it off in one place rather than discovering that half the line is still
# reaching for an image that is not there. It announces itself either way.
SANDBOX="${FACTORY_VERIFY_SANDBOX:-1}"; SKIP_GATES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bean)        BEAN_FILE="${2:?}"; shift 2 ;;
    --base)        BASE="${2:?}"; shift 2 ;;
    --policy)      POLICY="${2:?}"; shift 2 ;;
    --gates)       GATES="${2:?}"; shift 2 ;;
    --judge-tier)  JUDGE_TIER="${2:?}"; shift 2 ;;
    --no-sandbox)  SANDBOX=0; shift ;;
    --skip-gates)  SKIP_GATES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --version)     cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*)            usage >&2; die "unknown flag: $1" ;;
    *)             [ -z "$RUN_DIR" ] || die "only one run dir"; RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] || { usage >&2; exit 2; }
[ -d "$RUN_DIR" ] || die "run directory not found: $RUN_DIR"
[ -n "$BEAN_FILE" ] && [ -f "$BEAN_FILE" ] || die "--bean is required and must exist"
require_cmd jq; require_cmd git

ROOT="$(repo_root)"
PY="$(factory_python)"
[ -n "$POLICY" ] || POLICY="$ROOT/factory/risk-policy.yaml"
[ -n "$GATES" ]  || GATES="$ROOT/factory/gates.lock.yaml"
[ -f "$POLICY" ] || die "risk policy not found: $POLICY (the tier cannot be computed without it)"

BEAN_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$BEAN_FILE")" || die "cannot read bean: $BEAN_FILE"
POLICY_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$POLICY")"  || die "cannot read policy: $POLICY"
BEAN_ID="$(jq -r '.id' <<<"$BEAN_JSON")"

# How this project becomes importable/runnable inside the container. Found the
# hard way: bean-001's acceptance criterion is `python -c "import
# seating_planner"`, and a src-layout package is not importable in a bare synced
# tree — there is no install step and §08 gives the gate no network to do one.
# The developer model spotted that and refused to write a spec around it, which
# was the correct call: it is a hole in the controller, not in the bean.
SANDBOX_ENV_ARGS=()
if [ -f "$CONFIG_PATH" ]; then
  while IFS= read -r kv; do
    [ -n "$kv" ] && SANDBOX_ENV_ARGS+=( --env "$kv" )
  done < <(jq -r '(.sandbox_env // {}) | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_PATH" 2>/dev/null)
fi

RESULT="$RUN_DIR/gate.json"
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAILED=0
note() { printf '  %-6s %-22s %s\n' "$1" "$2" "$3"; }
fail_part() { FAILED=1; note FAIL "$1" "$2"; }
pass_part() { note ok "$1" "$2"; }

printf '\nGATE %s (base %s)\n\n' "$BEAN_ID" "$BASE"

# ------------------------------------------------- 1. whole-diff containment --
git -C "$ROOT" rev-parse --verify "$BASE" >/dev/null 2>&1 \
  || die "base ref '$BASE' does not exist; nothing to diff against"
MERGE_BASE="$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null || echo "$BASE")"
# The diff every check below reads, taken once and required to succeed.
#
# `git diff` failing — an unresolvable merge base, a corrupt object — produces an
# empty list, and every check downstream reads "no files changed" as "nothing to
# object to": containment finds no violations, the secret scan finds no secrets,
# the size budget is 0 of 5. A gate that cannot see the diff must not report on
# it, and the failure mode is the whole set of checks passing at once.
CHANGED="$(git -C "$ROOT" diff --name-only "$MERGE_BASE"...HEAD)" \
  || die "could not read the diff between $MERGE_BASE and HEAD. Every check below reads it, and an empty diff is indistinguishable from a clean one."
CHANGED_N="$(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l)"
DIFF_LINES="$(git -C "$ROOT" diff --numstat "$MERGE_BASE"...HEAD | awk '{a+=$1; d+=$2} END {print a+d+0}')"

BEAN_PATHS="$(jq -c '.allowed_write_paths // []' <<<"$BEAN_JSON")"
REPO_PATHS="$(jq -c '.repo_allowed_paths // []' <<<"$POLICY_JSON")"

# Effective paths are the INTERSECTION (§08): a bean cannot widen its reach by
# declaring wider paths, and the repo cannot be edited outside what a human
# approved. Checking against each list separately is the same thing and gives a
# better message — it says which of the two bounds was crossed.
# `|| true` is right for exit 1 — that is "violations found", and the output is
# the answer. It is wrong for exit 2, which is contain.py refusing to run at all
# (patterns that are not JSON, an unreadable list). Both produce empty output, so
# without separating them a crashed containment check reports a clean diff, and
# the one boundary the gate exists to enforce fails open.
contained_or_die() { # contained_or_die <patterns-json> <what>
  local out rc=0
  out="$(printf '%s\n' "$CHANGED" | sed '/^$/d' | "$PY" "$PIPELINE_DIR/contain.py" --patterns "$1")" || rc=$?
  if [ "$rc" -ge 2 ]; then
    die "containment could not be computed against the $2 paths (contain.py exit $rc). Refusing to report a diff as contained when the check did not run."
  fi
  printf '%s' "$out"
}
VIOL_BEAN="$(contained_or_die "$BEAN_PATHS" "bean's")"
VIOL_REPO="$(contained_or_die "$REPO_PATHS" "repository's approved")"

VIOL_ALL="$(printf '%s\n%s\n' "$VIOL_BEAN" "$VIOL_REPO" | sed '/^$/d' | sort -u)"
if [ -n "$VIOL_ALL" ]; then
  fail_part "containment" "$(printf '%s' "$VIOL_ALL" | tr '\n' ' ' | cut -c1-70)"
  printf '\n         the diff touches paths this bean may not write:\n'
  printf '%s\n' "$VIOL_ALL" | sed 's/^/           - /'
  printf '         rejected, not stripped: a diff nobody authored is worse than no diff.\n\n'
else
  pass_part "containment" "$CHANGED_N file(s), all inside the bean's paths and the repo's"
fi

RUN_REL=""
case "$(cd "$RUN_DIR" && pwd)/" in "$ROOT"/*) RUN_REL="$(cd "$RUN_DIR" && pwd)"; RUN_REL="${RUN_REL#"$ROOT"/}" ;; esac
if [ -n "$RUN_REL" ] && printf '%s\n' "$CHANGED" | grep -q "^$RUN_REL/"; then
  note note "run dir tracked" "$RUN_REL is committed inside the change under review — gitignore it (the scaffold does); its files are counted below because hiding them would be worse"
fi

# ------------------------------------------------------------- 2. the tier --
BEAN_TIER="$(jq -r '.suggested_risk_tier // empty' <<<"$BEAN_JSON")"
tier_args=( --policy "$POLICY" --paths "$(printf '%s\n' "$CHANGED" | sed '/^$/d' | jq -Rsc 'split("\n") | map(select(length>0))')" --json )
[ -n "$BEAN_TIER" ] && tier_args+=( --bean-tier "$BEAN_TIER" )
[ -n "$JUDGE_TIER" ] && tier_args+=( --judge-tier "$JUDGE_TIER" )
TIER_JSON="$("$PY" "$PIPELINE_DIR/tier.py" "${tier_args[@]}" 2>/dev/null)" || TIER_JSON=""
if [ -z "$TIER_JSON" ]; then
  fail_part "tier" "could not be computed — a change with no tier cannot be merged by policy"
  TIER_JSON='{"final_tier":null}'
else
  FINAL_TIER="$(jq -r '.final_tier' <<<"$TIER_JSON")"
  BINDING="$(jq -r '.binding_term | join(", ")' <<<"$TIER_JSON")"
  TOP_PATH="$(jq -r --argjson t "$FINAL_TIER" '[.paths[] | select(.tier == $t)] | first | "\(.path) — \(.reason)"' <<<"$TIER_JSON" 2>/dev/null)"
  TOP_PATH="$(jq -r --argjson t "$FINAL_TIER" '[.paths[] | select(.tier == $t)] | first | "\(.path) — \(.reason)"' <<<"$TIER_JSON" 2>/dev/null)"
  pass_part "tier" "$FINAL_TIER (set by $BINDING; bean suggested ${BEAN_TIER:-none})"
  # A tier without its reason is a number to argue with. Name the path that set it.
  [ -n "$TOP_PATH" ] && [ "$TOP_PATH" != "null" ] && note "" "" "$TOP_PATH"
  # A tier without its reason is a number to argue with. Name the path that set it.
  [ -n "$TOP_PATH" ] && [ "$TOP_PATH" != "null" ] && note "" "" "$TOP_PATH"
  if [ "$(jq -r '.never_auto_merged' <<<"$TIER_JSON")" = "true" ]; then
    note note "tier 3" "never auto-merged in any merge mode"
  fi
fi

# ------------------------------------------------------- 3. the size budget --
MAX_FILES="$(jq -r '.size_budget.max_files // empty' <<<"$BEAN_JSON")"
MAX_LINES="$(jq -r '.size_budget.max_diff_lines // empty' <<<"$BEAN_JSON")"
if [ -n "$MAX_FILES" ] && [ "$CHANGED_N" -gt "$MAX_FILES" ]; then
  fail_part "size_budget" "$CHANGED_N files against a budget of $MAX_FILES"
elif [ -n "$MAX_LINES" ] && [ "${DIFF_LINES:-0}" -gt "$MAX_LINES" ]; then
  fail_part "size_budget" "${DIFF_LINES} changed lines against a budget of $MAX_LINES"
else
  pass_part "size_budget" "${CHANGED_N}/${MAX_FILES:-∞} files · ${DIFF_LINES:-0}/${MAX_LINES:-∞} lines"
fi

# ----------------------------------------------------------- 4. secret scan --
# Deliberately narrow and deliberately not called a security review: it catches
# the shapes that have actually been committed by accident. A real scanner is a
# separate tool and this does not pretend to be one.
SECRETS="$(git -C "$ROOT" diff "$MERGE_BASE"...HEAD -U0 \
  | grep -E '^\+' \
  | grep -nEi 'BEGIN (RSA|OPENSSH|DSA|EC|PGP) PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN CERTIFICATE-----|(secret|password|passwd|api[_-]?key)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}' \
  || true)"
if [ -n "$SECRETS" ]; then
  # Report WHERE, never WHAT.
  #
  # This used to print the matching lines. A scan that finds a credential and
  # then copies it into the run log has spread it: the run directory is kept as
  # evidence, gets read by a judge, quoted in findings, and summarised into a
  # pull request. The detection would have been the largest single act of
  # disclosure in the process.
  #
  # The line number and the shape that matched are enough to find it, and the
  # person who goes looking has the diff in front of them anyway.
  # Count them all, show the first twenty. `head -20` used to truncate before the
  # count, so fifty leaked lines reported as twenty — a check that understates a
  # credential leak by however much worse than expected it turned out to be.
  N_SECRETS="$(printf '%s\n' "$SECRETS" | sed '/^$/d' | wc -l)"
  fail_part "secret_scan" "$N_SECRETS suspicious added line(s) — locations only, the content is deliberately not reproduced here"
  printf '%s\n' "$SECRETS" | head -20 \
    | sed -E 's/^([0-9]+):.*/           added line \1 of the diff matches a known credential shape/'
  [ "$N_SECRETS" -gt 20 ] && printf '           ... and %s more\n' "$((N_SECRETS - 20))"
else
  pass_part "secret_scan" "no known credential shapes in the added lines"
fi

# --------------------------------------------- 5. gates, AC, and invariants --
GATE_ROWS="[]"; AC_ROWS="[]"; INV_ROW="null"; TREE=""
if [ "$SKIP_GATES" = 1 ]; then
  note skip "gates" "--skip-gates"
else
  SB_ARGS=()
  [ "$SANDBOX" = 1 ] || note note "sandbox" "off — gates and criteria run on the host, which is not the environment their versions are pinned for"
  if [ "$SANDBOX" = 1 ]; then
    [ -f "$GATES" ] || die "--gates manifest not found: $GATES (use --no-sandbox to run on the host)"
    TREE="${FACTORY_SANDBOX_ROOT:-${TMPDIR:-/tmp}}/darkfactory/$(basename "$RUN_DIR")/gate-tree"
    "$PIPELINE_DIR/sync-tree.sh" "$ROOT" "$TREE" --exclude "factory/runs" >/dev/null \
      || die "could not sync the editable tree for the gate run"
    SB_ARGS=( --sandbox "$TREE" --gates "$GATES" )
    note note "sandbox" "$TREE"
  fi

  # The gates, from the pinned manifest.
  if [ -f "$GATES" ]; then
    while IFS= read -r g; do
      gid="$(jq -r '.id' <<<"$g")"
      run_json="$(jq -c '{kind:"command", run:.run}' <<<"$g")"
      log="$RUN_DIR/gate-$gid.log"
      res="$("$PIPELINE_DIR/verify.sh" "$run_json" --out "$log" ${SB_ARGS+"${SB_ARGS[@]}"} ${SANDBOX_ENV_ARGS+"${SANDBOX_ENV_ARGS[@]}"} 2>/dev/null)"
      rc=$?
      GATE_ROWS="$(jq -c --arg id "$gid" --argjson r "${res:-{\}}" '. + [{id:$id} + $r]' <<<"$GATE_ROWS")"
      if [ "$rc" -eq 0 ]; then pass_part "gate:$gid" "$(jq -r '.duration_s' <<<"$res")s"
      else fail_part "gate:$gid" "exit $(jq -r '.exit_code' <<<"$res") — $(jq -r '.output_tail | last // ""' <<<"$res")"; fi
    done < <("$PIPELINE_DIR/yaml2json.sh" "$GATES" | jq -c '.gates[]')
  else
    note skip "gates" "no manifest at $GATES"
  fi

  # Every acceptance criterion the bean declares, run by the controller.
  while IFS= read -r ac; do
    acid="$(jq -r '.id' <<<"$ac")"
    v="$(jq -c '.verify' <<<"$ac")"
    log="$RUN_DIR/ac-$acid.log"
    res="$("$PIPELINE_DIR/verify.sh" "$v" --out "$log" ${SB_ARGS+"${SB_ARGS[@]}"} ${SANDBOX_ENV_ARGS+"${SANDBOX_ENV_ARGS[@]}"} 2>/dev/null)"
    rc=$?
    AC_ROWS="$(jq -c --arg id "$acid" --argjson r "${res:-{\}}" '. + [{id:$id} + $r]' <<<"$AC_ROWS")"
    if [ "$rc" -eq 0 ]; then pass_part "ac:$acid" "$(jq -r '.command' <<<"$res" | cut -c1-48)"
    else fail_part "ac:$acid" "$(jq -r '.reason // .command' <<<"$res" | cut -c1-70)"; fi
  done < <(jq -c '.acceptance_criteria[]? | select(.verify)' <<<"$BEAN_JSON")

  # Independent invariants, if this bean is bound by any.
  INV_REF="$(jq -r '.invariants_ref // empty' <<<"$BEAN_JSON")"
  if [ -n "$INV_REF" ]; then
    inv_path="$(resolve_repo_path "$INV_REF")"
    if [ ! -f "$inv_path" ]; then
      fail_part "invariants" "$INV_REF is referenced by the bean but not present — an invariant that cannot run is not a guarantee"
    else
      inv_v="$("$PIPELINE_DIR/yaml2json.sh" "$inv_path" | jq -c '.verify')"
      log="$RUN_DIR/invariants.log"
      # Invariants live outside the package, so they need it importable.
      res="$("$PIPELINE_DIR/verify.sh" "$inv_v" --out "$log" ${SB_ARGS+"${SB_ARGS[@]}"} ${SANDBOX_ENV_ARGS+"${SANDBOX_ENV_ARGS[@]}"} 2>/dev/null)"
      rc=$?
      INV_ROW="$(jq -c --arg ref "$INV_REF" --argjson r "${res:-{\}}" '{ref:$ref} + $r' <<<"{}")"
      if [ "$rc" -eq 0 ]; then pass_part "invariants" "$INV_REF"
      else fail_part "invariants" "$INV_REF — $(jq -r '.output_tail | last // .reason // ""' <<<"$res" | cut -c1-70)"; fi
    fi
  fi
fi

# ------------------------------------------------- 6. do the tests mean it? --
# The impl rubric's hardest question, decided by running something rather than
# asked of a model that cannot run anything: revert the source half of the diff
# and require the tests to stop passing. See test-integrity.sh for what it is and
# is not able to claim.
TEST_INTEGRITY="null"
if [ "$SKIP_GATES" = 1 ]; then
  note skip "test integrity" "--skip-gates"
else
  ti_args=( "$RUN_DIR" --base "$BASE" )
  [ "$SANDBOX" = 1 ] && ti_args+=( --sandbox --gates "$GATES" )
  ti_args+=( ${SANDBOX_ENV_ARGS+"${SANDBOX_ENV_ARGS[@]}"} )
  ti_rc=0
  "$PIPELINE_DIR/test-integrity.sh" "${ti_args[@]}" > "$RUN_DIR/test-integrity.out" 2>&1 || ti_rc=$?
  ti_why="$(jq -r '.fails_on_revert.why // "see test-integrity.out"' "$RUN_DIR/test-integrity.json" 2>/dev/null)"
  case "$ti_rc" in
    0) pass_part "test-integrity" "the tests fail without this change" ;;
    # 2 is undecided, not failed: no tests written, or they do not pass to begin
    # with. Neither is decidable, both are facts the audit should weigh, and a
    # gate that failed on them would be switched off inside a week — taking the
    # one decidable check with it.
    2) note note "test-integrity" "undecided — $ti_why" ;;
    *) fail_part "test-integrity" "$ti_why" ;;
  esac
  [ -f "$RUN_DIR/test-integrity.json" ] && TEST_INTEGRITY="$(cat "$RUN_DIR/test-integrity.json")"
fi

# ------------------------------------- 6b. the bean's own non-goals, over the diff --
#
# spec-check decided this over the PLAN. This decides it over what was actually
# written, which is not the same question: a task can stay inside its declared
# write_paths and still add an import the bean forbids, and the plan is a promise
# while the diff is the change.
#
# A bean whose non-goals are prose reports that nothing was checked, and that is
# a note rather than a pass — the judge is then still the only thing between the
# change and the bean's own statement of what it is not for, and on 2026-09-16
# that judge was measured missing this exact case 2 times in 3.
NON_GOALS="null"
if [ "$SKIP_GATES" = 1 ]; then
  note skip "non-goals" "--skip-gates"
else
  # The diff, written here rather than reached for. orchestrate writes
  # $RUN_DIR/diff.txt for the doc step, and the gate runs before it — so reading
  # that path would work on a full-tier run and silently check an empty file on a
  # small one, which is the shape of a check that passes because it looked at
  # nothing.
  NG_DIFF="$RUN_DIR/gate-diff.txt"
  git -C "$ROOT" diff "$MERGE_BASE"...HEAD > "$NG_DIFF" 2>/dev/null \
    || die "could not read the diff for the non-goal check; refusing to report that nothing is forbidden without having looked"
  ng_rc=0
  ng_out="$("$PIPELINE_DIR/non-goals.sh" --bean "$BEAN_FILE" --diff "$NG_DIFF" \
    --json "$RUN_DIR/non-goals.json" 2>&1)" || ng_rc=$?
  case "$ng_rc" in
    0) if grep -q 'declares none in machine-readable form' <<<"$ng_out"; then
         note note "non-goals" "none in machine-readable form; the bean's are prose and remain the audit's"
       else
         pass_part "non-goals" "$(printf '%s' "$ng_out" | sed 's/^non-goals: //')"
       fi ;;
    1) fail_part "non-goals" "$(printf '%s\n' "$ng_out" | grep -E '^  - ' | sed 's/^  - //' | paste -sd'; ' - | cut -c1-120)" ;;
    *) fail_part "non-goals" "could not be checked — $(printf '%s' "$ng_out" | head -1)" ;;
  esac
  [ -f "$RUN_DIR/non-goals.json" ] && NON_GOALS="$(cat "$RUN_DIR/non-goals.json")"
fi

# --------------------------------------------- 7. tests the worker never saw --
# Everything above runs code the worker could read. `allowed_write_paths` stops it
# writing the tests; nothing stops it reading them, and code written against
# visible assertions satisfies those assertions. These do not live in the tree.
#
# not_configured is a note, not a pass: a repo with no hidden suite and a repo
# whose hidden suite passed are different facts. could_not_run is a FAILURE,
# because "the hidden tests did not run" reaching the audit as silence is the
# whole fail-open shape this line keeps finding.
HIDDEN_TESTS="null"
if [ "$SKIP_GATES" = 1 ]; then
  note skip "hidden tests" "--skip-gates"
else
  ht_args=( "$RUN_DIR" )
  [ "$SANDBOX" = 1 ] && ht_args+=( --sandbox --gates "$GATES" --tree "$TREE" )
  ht_args+=( ${SANDBOX_ENV_ARGS+"${SANDBOX_ENV_ARGS[@]}"} )
  ht_rc=0
  "$PIPELINE_DIR/hidden-tests.sh" "${ht_args[@]}" > "$RUN_DIR/hidden-tests.out" 2>&1 || ht_rc=$?
  ht_why="$(jq -r '.why // "see hidden-tests.out"' "$RUN_DIR/hidden-tests.json" 2>/dev/null)"
  case "$ht_rc" in
    0) pass_part "hidden tests" "$ht_why" ;;
    3) note note "hidden tests" "none configured for this repository" ;;
    2) fail_part "hidden tests" "could not run — $ht_why" ;;
    *) fail_part "hidden tests" "$ht_why" ;;
  esac
  [ -f "$RUN_DIR/hidden-tests.json" ] && HIDDEN_TESTS="$(cat "$RUN_DIR/hidden-tests.json")"
fi

# ------------------------------------------------------------------ record --
jq -n \
  --arg schema "gate-run/1.0.0" \
  --arg bean "$BEAN_ID" --arg base "$MERGE_BASE" --arg started "$started" \
  --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson changed "$(printf '%s\n' "$CHANGED" | sed '/^$/d' | jq -Rsc 'split("\n") | map(select(length>0))')" \
  --argjson changed_n "$CHANGED_N" --argjson diff_lines "${DIFF_LINES:-0}" \
  --argjson viol "$(printf '%s\n' "$VIOL_ALL" | sed '/^$/d' | jq -Rsc 'split("\n") | map(select(length>0))')" \
  --argjson tier "$TIER_JSON" \
  --argjson gates "$GATE_ROWS" --argjson acs "$AC_ROWS" --argjson inv "$INV_ROW" \
  --arg secrets "$SECRETS" --argjson ti "$TEST_INTEGRITY" \
  --argjson ht "$HIDDEN_TESTS" --argjson ng "$NON_GOALS" \
  --argjson ok "$([ "$FAILED" -eq 0 ] && echo true || echo false)" \
  --arg gates_ref "$(realpath --relative-to="$ROOT" "$GATES" 2>/dev/null || printf '%s' "$GATES")" \
  --arg gate_image "$("$PIPELINE_DIR/yaml2json.sh" "$GATES" 2>/dev/null | jq -r '.image // ""')" \
  '{schema:$schema, bean:$bean, base:$base, started_at:$started, finished_at:$finished,
    gate_manifest: {ref:$gates_ref, image:$gate_image,
                    digest:(if ($gate_image | test("@")) then ($gate_image | split("@")[1]) else null end)},
    diff: {files:$changed, file_count:$changed_n, changed_lines:$diff_lines},
    containment: {violations:$viol, contained: (($viol|length) == 0)},
    tier: $tier,
    secret_scan: {suspicious_lines: ($secrets | if . == "" then [] else split("\n") end)},
    gates: $gates, acceptance_criteria: $acs, invariants: $inv,
    test_integrity: $ti,
    hidden_tests: $ht, non_goals: $ng,
    overall: (if $ok then "pass" else "fail" end),
    note:"gate_manifest names the image these gates ran in. Every \"the gates passed\" is a claim about a specific toolchain, and until 2026-09-15 this record did not say which one — the manifest pinned it and the result forgot it."}' > "$RESULT"

printf '\n%s — %s\n' "$([ "$FAILED" -eq 0 ] && echo "GATE PASS" || echo "GATE FAIL")" "$RESULT"
exit "$FAILED"
