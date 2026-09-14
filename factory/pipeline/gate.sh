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
SANDBOX=1; SKIP_GATES=0
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
CHANGED="$(git -C "$ROOT" diff --name-only "$MERGE_BASE"...HEAD)"
CHANGED_N="$(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l)"
DIFF_LINES="$(git -C "$ROOT" diff --numstat "$MERGE_BASE"...HEAD | awk '{a+=$1; d+=$2} END {print a+d+0}')"

BEAN_PATHS="$(jq -c '.allowed_write_paths // []' <<<"$BEAN_JSON")"
REPO_PATHS="$(jq -c '.repo_allowed_paths // []' <<<"$POLICY_JSON")"

# Effective paths are the INTERSECTION (§08): a bean cannot widen its reach by
# declaring wider paths, and the repo cannot be edited outside what a human
# approved. Checking against each list separately is the same thing and gives a
# better message — it says which of the two bounds was crossed.
VIOL_BEAN="$(printf '%s\n' "$CHANGED" | sed '/^$/d' | "$PY" "$PIPELINE_DIR/contain.py" --patterns "$BEAN_PATHS" || true)"
VIOL_REPO="$(printf '%s\n' "$CHANGED" | sed '/^$/d' | "$PY" "$PIPELINE_DIR/contain.py" --patterns "$REPO_PATHS" || true)"

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
  | head -20 || true)"
if [ -n "$SECRETS" ]; then
  fail_part "secret_scan" "$(printf '%s' "$SECRETS" | wc -l) suspicious added line(s)"
  printf '%s\n' "$SECRETS" | sed 's/^/           /'
else
  pass_part "secret_scan" "no known credential shapes in the added lines"
fi

# --------------------------------------------- 5. gates, AC, and invariants --
GATE_ROWS="[]"; AC_ROWS="[]"; INV_ROW="null"
if [ "$SKIP_GATES" = 1 ]; then
  note skip "gates" "--skip-gates"
else
  SB_ARGS=()
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
      res="$("$PIPELINE_DIR/verify.sh" "$run_json" --out "$log" ${SB_ARGS+"${SB_ARGS[@]}"} 2>/dev/null)"
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
    res="$("$PIPELINE_DIR/verify.sh" "$v" --out "$log" ${SB_ARGS+"${SB_ARGS[@]}"} 2>/dev/null)"
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
      res="$("$PIPELINE_DIR/verify.sh" "$inv_v" --out "$log" ${SB_ARGS+"${SB_ARGS[@]}"} 2>/dev/null)"
      rc=$?
      INV_ROW="$(jq -c --arg ref "$INV_REF" --argjson r "${res:-{\}}" '{ref:$ref} + $r' <<<"{}")"
      if [ "$rc" -eq 0 ]; then pass_part "invariants" "$INV_REF"
      else fail_part "invariants" "$INV_REF — $(jq -r '.output_tail | last // .reason // ""' <<<"$res" | cut -c1-70)"; fi
    fi
  fi
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
  --arg secrets "$SECRETS" \
  --argjson ok "$([ "$FAILED" -eq 0 ] && echo true || echo false)" \
  '{schema:$schema, bean:$bean, base:$base, started_at:$started, finished_at:$finished,
    diff: {files:$changed, file_count:$changed_n, changed_lines:$diff_lines},
    containment: {violations:$viol, contained: (($viol|length) == 0)},
    tier: $tier,
    secret_scan: {suspicious_lines: ($secrets | if . == "" then [] else split("\n") end)},
    gates: $gates, acceptance_criteria: $acs, invariants: $inv,
    overall: (if $ok then "pass" else "fail" end)}' > "$RESULT"

printf '\n%s — %s\n' "$([ "$FAILED" -eq 0 ] && echo "GATE PASS" || echo "GATE FAIL")" "$RESULT"
exit "$FAILED"
