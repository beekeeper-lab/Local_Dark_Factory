#!/usr/bin/env bash
# test-role-routing.sh — the routing properties the fork exists to provide.
#
# These run with a stub `pi`, so no model is loaded and nothing touches Ollama
# beyond `ollama list`. Two of them are Phase-2 fault injections from the
# implementation plan (frontier_provider_refused, wrong_model_tests) proved
# early — the point of a check is that it fails when broken, so each negative
# case asserts the specific refusal, not merely a non-zero exit.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

check() {
  # check <name> <expected-substring> <actual>
  if grep -qF -- "$2" <<<"$3"; then
    printf '  ok    %s\n' "$1"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n          expected to find: %s\n          got: %s\n' "$1" "$2" "$3"
    FAIL=$((FAIL + 1))
  fi
}

# -- fixture -------------------------------------------------------------------
cd "$WORK"
git init -q .
git commit -q --allow-empty -m init
mkdir -p run/verdicts sessions
echo '{"run_id":"T","bean":"BEAN-001","branch":"bean/BEAN-001-test"}' > run/run.json

cat > stub-pi <<'STUB'
#!/usr/bin/env bash
printf 'STUB-PI-ARGS: %s\n' "$*"
exit 0
STUB
chmod +x stub-pi

run_step() {
  PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" \
    bash "$PIPELINE_DIR/run-step.sh" run "$@" 2>&1
}

# -- authoring steps run on the developer --------------------------------------
out="$(run_step spec)"
check "spec routes to developer"        "role=developer" "$out"
check "spec passes --model to pi"       "--model ollama/qwen3.8:27b-mtp-q8_0" "$out"
check "spec passes thinking level"      "--thinking medium" "$out"
check "factory skills are loaded"       "--skill" "$out"

# -- auditing steps run on the judge, and it must be a different model ----------
out="$(run_step audit-spec)"
check "audit-spec routes to judge"      "role=judge" "$out"
check "judge uses a different model"    "--model ollama/gpt-oss:120b" "$out"

dev_model="$(jq -r '.roles[.step_roles.spec].model'       "$PIPELINE_DIR/roles.json")"
jdg_model="$(jq -r '.roles[.step_roles["audit-spec"]].model' "$PIPELINE_DIR/roles.json")"
if [ "$dev_model" != "$jdg_model" ]; then
  printf '  ok    judge and developer are not the same weights\n'; PASS=$((PASS + 1))
else
  printf '  FAIL  judge and developer are the same model (%s) — audits are self-review\n' "$dev_model"
  FAIL=$((FAIL + 1))
fi

# -- conditions are stamped, or runs are not comparable ------------------------
cond="$(jq -rs '[.[] | select(.event == "end") | .conditions] | last' run/steps.jsonl)"
for field in role model digest num_ctx thinking; do
  if [ "$(jq -r --arg f "$field" '.[$f] // "null"' <<<"$cond")" != "null" ]; then
    printf '  ok    conditions.%s stamped on the step record\n' "$field"; PASS=$((PASS + 1))
  else
    printf '  FAIL  conditions.%s missing — runs cannot be compared on this axis\n' "$field"
    FAIL=$((FAIL + 1))
  fi
done

# -- a frontier provider must be refused (spec §08) ----------------------------
jq '.roles.judge.provider = "anthropic" | .roles.judge.model = "claude-opus-5"' \
  "$PIPELINE_DIR/roles.json" > "$WORK/frontier-roles.json"
out="$(ROLES_FILE="$WORK/frontier-roles.json" run_step audit-impl)"
check "frontier provider refused"       "is not in the allow-list" "$out"

# -- a model that is not installed must be refused, not silently substituted ---
jq '.roles.judge.model = "definitely-not-pulled:70b"' \
  "$PIPELINE_DIR/roles.json" > "$WORK/missing-roles.json"
out="$(ROLES_FILE="$WORK/missing-roles.json" run_step audit-impl)"
check "absent model refused"            "is not present in ollama" "$out"

# -- an unbound step must not silently pick a default --------------------------
jq 'del(.step_roles.doc)' "$PIPELINE_DIR/roles.json" > "$WORK/unbound-roles.json"
out="$(ROLES_FILE="$WORK/unbound-roles.json" run_step doc)"
check "unbound step refused"            "no role bound to step" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
