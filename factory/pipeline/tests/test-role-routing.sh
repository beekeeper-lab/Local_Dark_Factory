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

# The stub writes a session file in pi's shape, because run-step.sh now reads
# the conditions back out of it rather than trusting roles.json. A stub that
# only echoes its arguments would leave the observation path untested — and the
# thinking level being silently different from the declared one is exactly the
# bug that path exists to catch.
cat > stub-pi <<'STUB'
#!/usr/bin/env bash
printf 'STUB-PI-ARGS: %s\n' "$*"
model=""; thinking=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="${2#*/}"; shift 2 ;;
    --thinking) thinking="$2"; shift 2 ;;
    *) shift ;;
  esac
done
# Emulate the bug this path exists to catch: pi accepting --thinking and running
# with a different level anyway, recording the truth only in its session file.
[ -n "${STUB_PI_THINKING_OVERRIDE:-}" ] && thinking="$STUB_PI_THINKING_OVERRIDE"
sess="${PI_SESSIONS_DIR:-.}/stub-$(date +%s%N).jsonl"
mkdir -p "$(dirname "$sess")"
{
  printf '{"type":"session","version":"stub","id":"stub","cwd":"%s"}\n' "$PWD"
  [ -n "$model" ]    && printf '{"type":"model_change","model":"%s"}\n' "$model"
  [ -n "$thinking" ] && printf '{"type":"thinking_level_change","thinkingLevel":"%s"}\n' "$thinking"
} > "$sess"
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
for field in role model digest thinking; do
  if [ "$(jq -r --arg f "$field" '.[$f] // "null"' <<<"$cond")" != "null" ]; then
    printf '  ok    conditions.%s stamped on the step record\n' "$field"; PASS=$((PASS + 1))
  else
    printf '  FAIL  conditions.%s missing — runs cannot be compared on this axis\n' "$field"
    FAIL=$((FAIL + 1))
  fi
done

# The declared value is kept, but it is not what `thinking` reports: that comes
# back from the session pi actually wrote.
check "conditions.declared retained"    "\"thinking\":\"high\"" "$(jq -c '.declared' <<<"$cond")"
if [ "$(jq -r '.thinking' <<<"$cond")" = "$(jq -r '.declared.thinking' <<<"$cond")" ]; then
  printf '  ok    conditions.thinking is the observed level, matching what was asked for\n'; PASS=$((PASS + 1))
else
  printf '  FAIL  observed thinking (%s) != declared (%s) and the run was not flagged\n' \
    "$(jq -r '.thinking' <<<"$cond")" "$(jq -r '.declared.thinking' <<<"$cond")"
  FAIL=$((FAIL + 1))
fi

if [ "$(jq -r '.declared_matches_observed' <<<"$cond")" = "true" ]; then
  printf '  ok    matching conditions are recorded as matching\n'; PASS=$((PASS + 1))
else
  printf '  FAIL  declared_matches_observed is false on a run with no drift: %s\n' "$cond"
  FAIL=$((FAIL + 1))
fi

# The real case: roles.json asks for "high", the model runs with thinking off,
# and only the session file knows. That is the bug verbatim — the judge spent a
# session with its reasoning disabled while the record claimed otherwise.
out="$(STUB_PI_THINKING_OVERRIDE=off run_step audit-doc)"
drift_cond="$(jq -rs '[.[] | select(.event == "end") | .conditions] | last' run/steps.jsonl)"
check "drift is warned about"           "conditions drift" "$out"
if [ "$(jq -r '.thinking' <<<"$drift_cond")" = "off" ] \
   && [ "$(jq -r '.declared.thinking' <<<"$drift_cond")" = "high" ] \
   && [ "$(jq -r '.declared_matches_observed' <<<"$drift_cond")" = "false" ]; then
  printf '  ok    silent thinking downgrade is recorded as off, not as the declared level\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL  a run that ran with thinking off recorded: %s\n' "$drift_cond"
  FAIL=$((FAIL + 1))
fi

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
