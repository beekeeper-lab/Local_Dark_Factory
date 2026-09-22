#!/usr/bin/env bash
# test-worker-agent-dir.sh — what the controller writes into the contained
# worker's ~/.pi/agent, and why any of it is the controller's business.
#
# The contained worker gets a fresh agent directory per step, built here and
# mounted at /home/worker/.pi/agent. Nothing of the user's own ~/.pi/agent goes
# in except the model catalogue, which means every pi setting the worker runs
# under is a DEFAULT unless this script sets it. Two of those defaults have now
# been wrong, in the same way:
#
#   contextWindow      262144 from the user's catalogue, against a roles.json
#                      that asked for 65536. Reported honestly as drift for a
#                      while before anyone noticed the controller could simply
#                      write the number instead.
#
#   httpIdleTimeoutMs  300000 — five minutes — applied by pi to undici's
#                      headersTimeout and bodyTimeout. Against a frontier
#                      endpoint a five-minute gap between chunks means a dead
#                      connection. Against a 27B Q8 on this box it means the
#                      model is thinking. bean-004's spec step died four times
#                      running on it, 2026-09-22.
#
# So the property under test is not "a file exists". It is that a value the line
# depends on is SET rather than inherited, and that it is the value roles.json
# and the measurement asked for.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:300}"; FAIL=$((FAIL+1)); fi }
eq()    { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi }

command -v jq >/dev/null 2>&1 || { printf 'jq is required\n' >&2; exit 2; }

# -- fixture -------------------------------------------------------------------
cd "$WORK"
git init -q .
git commit -q --allow-empty -m init
mkdir -p run/verdicts sandbox gw

echo '{"run_id":"T","bean":"BEAN-001","branch":"bean/BEAN-001-test"}' > run/run.json

# A models.json in the user's shape, with the wrong context window in it — the
# one the controller has to overwrite rather than report.
mkdir -p home/.pi/agent
# The real developer model, because run-step asserts the weights exist in ollama
# before it spends a step on them — the "wrong model loaded" fault, blocked
# rather than tolerated. Same coupling test-role-routing.sh already accepts.
MODEL="$(jq -r '.roles.developer.model' "$PIPELINE_DIR/roles.json")"
jq -n --arg m "$MODEL" '{providers:[{baseUrl:"http://localhost:11434/v1",
  api:"openai-completions",
  models:[{id:$m, contextWindow:262144, maxTokens:32768}]}]}' \
  > home/.pi/agent/models.json

# roles.json asking for a context the catalogue does not offer, so the rewrite
# has something to do and the assertion is not tautological.
jq -n --arg m "$MODEL" '{provider_allowlist:["ollama"],
  roles:{developer:{provider:"ollama", model:$m, num_ctx:65536, thinking:"medium"}},
  step_roles:{spec:"developer"}}' > roles.json

# The pipeline runs from a copy, so worker-sandbox.sh can be replaced with a stub
# that records what it was handed. Containment is the subject here and podman is
# not: the question is what is in the directory at the moment it would be
# mounted, which is exactly what the real sandbox receives.
cp -r "$PIPELINE_DIR" pipe
cat > pipe/worker-sandbox.sh <<'SB'
#!/usr/bin/env bash
# Records --agent-dir and writes the session file run-step reads back, then
# stands in for the container it would otherwise start.
agent=""
while [ $# -gt 0 ]; do
  case "$1" in
    --agent-dir) agent="$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
printf '%s\n' "$agent" > "$STUB_AGENT_RECORD"
mkdir -p "$agent/sessions"
{
  printf '{"type":"session","version":"stub","id":"stub","cwd":"/work"}\n'
  printf '{"type":"model_change","model":"%s"}\n' "$STUB_MODEL"
  printf '{"type":"thinking_level_change","thinkingLevel":"medium"}\n'
} > "$agent/sessions/stub.jsonl"
printf '%s\n' "written" > "$STUB_TREE/run/spec.md"
printf '%s\n' "written" > "$STUB_TREE/run/tasks.yaml"
exit 0
SB
chmod +x pipe/worker-sandbox.sh

# FACTORY_MODEL_SOCKET_DIR short-circuits the gateway; FACTORY_ENSURE_LOADED=0
# the preload. Neither is the subject and both need a real model.
out="$(HOME="$WORK/home" ROLES_FILE="$WORK/roles.json" \
  FACTORY_CONTAIN_WORKER=1 FACTORY_ENSURE_LOADED=0 \
  FACTORY_MODEL_SOCKET_DIR="$WORK/gw" FACTORY_SANDBOX_ROOT="$WORK/sandbox" \
  FACTORY_SKILLS="$WORK/pipe" \
  STUB_AGENT_RECORD="$WORK/agent-dir.txt" STUB_TREE="$WORK" STUB_MODEL="$MODEL" \
  bash "$WORK/pipe/run-step.sh" run spec 2>&1)"

AGENT="$(cat "$WORK/agent-dir.txt" 2>/dev/null || true)"

printf '\n== the controller builds the agent directory it mounts ==\n\n'
if [ -n "$AGENT" ] && [ -d "$AGENT" ]; then
  printf '  ok    the worker was handed an agent directory\n'; PASS=$((PASS+1))
else
  printf '  FAIL  no agent directory was recorded\n          got: %s\n' "${out:0:400}"
  FAIL=$((FAIL+1))
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi

check "and it is outside the tree"  "$WORK/sandbox" "$AGENT"

printf '\n-- the model catalogue carries the context roles.json asked for --\n\n'
#
# Not the 262144 the user's own catalogue offers. pi has no num_ctx flag, so a
# number the controller does not write is a number it can only report afterwards.
eq "contextWindow is the declared one" "65536" \
   "$(jq -r '.providers[].models[] | select(.id==$m) | .contextWindow' --arg m "$MODEL" "$AGENT/models.json")"

printf '\n-- and pi'"'"'s five-minute HTTP idle timeout is off --\n\n'
#
# bean-004, 2026-09-22. Four consecutive spec turns recorded stopReason=error
# and errorMessage="terminated", each one after the model had finished reasoning
# and announced it was about to write tasks.yaml. Ollama answered all four with
# HTTP 200, truncated = 0, 36.5k-39.5k tokens against a 65536 window, and logged
# `srv stop: cancel task` AFTER the handler returned — a client that hung up,
# not a server that failed. Three of the four ran 5m07s, 5m11s and 5m16s against
# pi's DEFAULT_HTTP_IDLE_TIMEOUT_MS of 300000.
#
# 0 is pi's own "disabled", and its settings text names this exact case:
# "Disable for local models that pause longer than five minutes." It is bounded
# by worker-sandbox.sh's 3600s wall clock, so a request that truly hangs still
# dies — on a limit the controller chose rather than one it inherited.
if [ -f "$AGENT/settings.json" ]; then
  printf '  ok    a settings.json is written at all\n'; PASS=$((PASS+1))
else
  printf '  FAIL  no settings.json — pi takes every default, including the 5m idle timeout\n'
  FAIL=$((FAIL+1))
fi
eq "the idle timeout is disabled" "0" \
   "$(jq -r '.httpIdleTimeoutMs // "absent"' "$AGENT/settings.json" 2>/dev/null)"

# Disabled, specifically — not merely raised. A bigger number is the same bug
# with a longer fuse, and the next model that thinks for eleven minutes finds it.
eq "as a number, not a string"    "number" \
   "$(jq -r '.httpIdleTimeoutMs | type' "$AGENT/settings.json" 2>/dev/null)"

printf '\n-- and nothing else of the user'"'"'s settings is carried in --\n\n'
#
# The user's ~/.pi/agent/settings.json belongs to them: their theme, their
# default model, their default thinking level. A worker that inherited those
# would run under whatever they last changed, and the run record would say
# otherwise. Every setting the line depends on is passed as a flag or written
# here on purpose.
eq "only the timeout is set"      "httpIdleTimeoutMs" \
   "$(jq -r 'keys | join(",")' "$AGENT/settings.json" 2>/dev/null)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
