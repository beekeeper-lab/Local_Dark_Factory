#!/usr/bin/env bash
# preflight.sh — verify the branch/bean/workspace preconditions for a pipeline run.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="preflight.sh <BEAN-ID>"
case "${1:-}" in
  --version)
    cat "$PIPELINE_DIR/VERSION"
    exit 0
    ;;
  -h|--help)
    echo "preflight.sh — fail fast before a pipeline run starts."
    echo "$USAGE"
    echo ""
    echo "Checks: clean working tree, on main, main not behind origin/main,"
    echo "bean status is Approved, and no existing branch for the bean."
    exit 0
    ;;
esac
require_args "$#" 1 "$USAGE"
require_cmd jq

BEAN_ID="$1"
[[ "$BEAN_ID" =~ ^([Bb][Ee][Aa][Nn])-[0-9]+$ ]] || die "bean id must look like bean-NNN (got: $BEAN_ID)"

require_config
root="$(repo_root)"
cd "$root"

fail() {
  printf 'FAIL  %-22s %s\n' "$1" "$2"
  exit 1
}
pass() {
  printf 'PASS  %-22s %s\n' "$1" "$2"
}

# 1. Clean working tree
dirty="$(git status --porcelain)"
if [ -n "$dirty" ]; then
  fail "clean-tree" "working tree is dirty:
$dirty"
fi
pass "clean-tree" "working tree is clean"

# 2. On main
branch="$(git branch --show-current)"
[ "$branch" = "main" ] || fail "on-main" "current branch is '$branch', expected 'main'"
pass "on-main" "on main"

# 3. main not behind origin/main
if git remote get-url origin >/dev/null 2>&1; then
  if ! git fetch origin main >/dev/null 2>&1; then
    fail "up-to-date" "git fetch origin main failed; cannot verify main is up to date"
  fi
  behind="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo '?')"
  if [ "$behind" != "0" ]; then
    fail "up-to-date" "local main is $behind commit(s) behind origin/main"
  fi
  pass "up-to-date" "main is up to date with origin/main"
else
  fail "up-to-date" "no 'origin' remote; cannot verify main is up to date"
fi

# 4. Bean status is Approved in the index
index_path="$(resolve_repo_path "$(jq -r '.bean_index_path' "$CONFIG_PATH")")"
[ -f "$index_path" ] || fail "bean-approved" "bean index not found: $index_path"
status="$(awk -F'|' -v id="$BEAN_ID" '
  {
    cell = $2
    gsub(/^[ \t]+|[ \t]+$/, "", cell)
    if (cell == id) {
      gsub(/^[ \t]+|[ \t]+$/, "", $6)
      print $6
      exit
    }
  }' "$index_path")"
[ -n "$status" ] || fail "bean-approved" "bean $BEAN_ID not found in $index_path"
[ "$status" = "Approved" ] || fail "bean-approved" "bean $BEAN_ID status is '$status', expected 'Approved'"
pass "bean-approved" "bean $BEAN_ID is Approved"

# 4b. The bean's definition_of_done names criteria the bean actually declares.
#
# bean.schema.json requires this field and, until now, nothing read it. A bean
# could say "done means ac1, ac2 and ac7" while declaring only ac1 through ac4,
# and every check downstream would pass: the gate runs the acceptance_criteria it
# finds, so ac7 is never missed because nothing ever looks for it. The bean would
# be built, gated, audited and merged against a definition of done that was
# partly fiction.
#
# Checked here rather than at spec time because it is a property of the bean, and
# the cheapest moment to refuse a malformed bean is before the line spends a
# model on it.
# A plain glob, and a correction to what an earlier version of this comment said.
#
# It blamed `compgen -G` for not resolving inside a command substitution. That is
# not true — it resolves fine non-interactively, which took one command to check
# and which I should have checked before writing an explanation into the source.
# The actual failure was a typo: this file's repository root is `$root`, and I
# used `$ROOT`, so the lookup died on an unbound variable and the check never ran.
#
# The real lesson is the one that survives either way: a bean lookup that
# silently finds nothing turns this into a check that never runs, reports
# nothing, and looks fine. Hence the explicit failure below when no bean.yaml is
# found, rather than a quietly skipped block.
BEAN_YAML=""
BEANS_DIR="$root/$(dirname "$(jq -r '.bean_dir_pattern // "factory/beans/BEAN-NNN-<slug>"' "$CONFIG_PATH")")"
for cand in "$BEANS_DIR/$BEAN_ID"-*/bean.yaml "$BEANS_DIR/$BEAN_ID/bean.yaml"; do
  [ -f "$cand" ] && { BEAN_YAML="$cand"; break; }
done
if [ -z "$BEAN_YAML" ]; then
  fail "definition-of-done" "cannot find a bean.yaml for $BEAN_ID under $BEANS_DIR — the bean is in the index but its machine-readable form is missing"
fi
if [ -n "$BEAN_YAML" ] && [ -f "$BEAN_YAML" ]; then
  BJ="$("$PIPELINE_DIR/yaml2json.sh" "$BEAN_YAML" 2>/dev/null)" || BJ=""
  if [ -n "$BJ" ]; then
    # Only entries that LOOK like criterion ids are resolved.
    #
    # The first version of this check treated every entry as an id and would have
    # failed all twenty beans in this corpus, because they use the field the way
    # the schema actually permits — `items: {type: string}`, no pattern — and put
    # a prose sentence in it: "all AC verify pass, gates green, spec and
    # impl-detail docs accepted".
    #
    # That would have been the exact defect this project spent a day removing: a
    # check confident enough to overrule the thing it measures, imposing a
    # convention the contract never stated. So it asks a narrower question, and
    # one that is unambiguous when it fires: an entry shaped like `ac7` that
    # names no declared criterion is a dangling reference, whatever the field is
    # being used for.
    UNKNOWN="$(jq -r '
      (.acceptance_criteria // [] | map(.id)) as $have
      | [ (.definition_of_done // [])[]
          | select(test("^[a-z]+[0-9]+$"))
          | select(. as $d | ($have | index($d)) == null) ]
      | join(", ")' <<<"$BJ" 2>/dev/null)"
    if [ -n "$UNKNOWN" ]; then
      fail "definition-of-done" "names criteria the bean does not declare: $UNKNOWN — a dangling reference in the bean's own definition of done"
    fi
    pass "definition-of-done" "no dangling criterion references"
  fi
fi

# 5. No existing branch for the bean
pattern="$(jq -r '.branch_pattern' "$CONFIG_PATH")"
glob="$(printf '%s' "$pattern" \
  | sed -e "s/BEAN-NNN/$BEAN_ID/" -e 's/<slug>/*/')"
existing="$(git branch --list -- "$glob" 2>/dev/null | sed 's/^[ *]*//' || true)"
[ -z "$existing" ] || fail "no-branch" "a branch for this bean already exists: $existing"
pass "no-branch" "no existing branch matching $glob"

# 6. Every role that declares a thinking level must be a model pi believes can
#    think. Measured 2026-09-14: pi accepts `--thinking high` for a model whose
#    catalog entry lacks `reasoning: true`, silently records `thinkingLevel:
#    "off"`, and runs it with reasoning disabled. gpt-oss:120b was in exactly
#    that state, so the judge -- the role whose entire value is careful,
#    independent review -- had been running with its reasoning off while
#    roles.json said "high". run-step.sh stamps conditions.thinking from
#    roles.json, so the run record would have asserted a thinking level the run
#    never used. A false provenance figure is worse than a missing one: it
#    survives into the telemetry that later decisions are made from.
#
#    The check must not be able to skip itself. An earlier version guarded the
#    whole block with `[ -f "$PI_MODELS" ]`, so a pi upgrade that moved or
#    rewrote the catalog would have made the tripwire vanish silently while
#    preflight still printed PASS — the exact scenario it was written for.
ROLES_JSON="$PIPELINE_DIR/roles.json"
PI_MODELS="${PI_MODELS_JSON:-$HOME/.pi/agent/models.json}"
[ -f "$ROLES_JSON" ] || fail "role-thinking" "roles.json not found at $ROLES_JSON"
[ -f "$PI_MODELS" ] || fail "role-thinking" \
  "pi model catalog not found at $PI_MODELS — cannot verify that roles declaring a thinking level map to reasoning-capable models, and pi disables thinking silently when they do not. Set PI_MODELS_JSON if pi has moved its catalog."
while IFS=$'\t' read -r rname rprov rmodel; do
  [ -n "$rmodel" ] || continue
  declares="$(jq -r --arg p "$rprov" --arg m "$rmodel" \
    '.providers[$p].models[]? | select(.id == $m) | (.reasoning // false)' "$PI_MODELS" 2>/dev/null)"
  [ -n "$declares" ] || fail "role-thinking" \
    "role '$rname' uses $rprov/$rmodel, absent from $PI_MODELS — pi would fall back to a default model"
  [ "$declares" = "true" ] || fail "role-thinking" \
    "role '$rname' declares a thinking level but $rprov/$rmodel has reasoning=false in $PI_MODELS; pi will silently run it with thinking off while the run record claims otherwise"
done < <(jq -r '.roles | to_entries[]
           | select((.value.thinking // "") | . != "" and . != "off")
           | [.key, .value.provider, .value.model] | @tsv' "$ROLES_JSON")
pass "role-thinking" "every thinking role maps to a reasoning-capable model in pi's catalog"

# 7. If this repository has hidden tests, they are runnable and they are hidden.
#
#    The gate checks all of this, and the gate runs after the build. A config
#    error here costs an hour of model time before anyone finds out, for a fact
#    that is knowable in milliseconds and knowable now.
#
#    `dir` inside the repository is the one that matters. The worker mounts the
#    whole tree at /work, so a hidden test in the repo is a test it reads and
#    writes code against — and the failure is invisible: the tests run, they pass,
#    and nothing says the worker had already read them.
HT_CFG=""
[ -f "$CONFIG_PATH" ] && HT_CFG="$(jq -c '.hidden_tests // empty' "$CONFIG_PATH" 2>/dev/null || true)"
if [ -z "$HT_CFG" ]; then
  pass "hidden-tests" "none configured for this repository"
else
  ht_dir="$(jq -r '.dir // empty' <<<"$HT_CFG")"
  [ -n "$ht_dir" ] || fail "hidden-tests" "hidden_tests is configured with no dir"
  case "$ht_dir" in
    /*) ;;
    *)  ht_dir="$(cd "$(dirname "$CONFIG_PATH")" && pwd)/$ht_dir" ;;
  esac
  [ -d "$ht_dir" ] || fail "hidden-tests" \
    "hidden_tests.dir does not exist: $ht_dir — the gate would refuse, after the build"
  ht_dir="$(cd "$ht_dir" && pwd)"
  case "$ht_dir/" in
    "$(repo_root)"/*) fail "hidden-tests" \
      "hidden_tests.dir is inside the repository ($ht_dir). The worker mounts the whole tree at /work, so these are tests it can read — and code written against assertions it can read satisfies exactly those." ;;
  esac
  [ "$(find "$ht_dir" -type f -name '*.py' | wc -l)" -gt 0 ] || fail "hidden-tests" \
    "no test files in $ht_dir — an empty hidden suite that reports success reads exactly like a check that passed"
  pass "hidden-tests" "$(find "$ht_dir" -type f -name '*.py' | wc -l) file(s), outside the repository"
fi

echo "PASS  preflight: all checks passed for $BEAN_ID"
