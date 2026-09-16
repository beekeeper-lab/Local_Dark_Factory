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

# FACTORY_CONTAIN_WORKER=0 throughout, except where containment IS the subject.
# These run with a stub pi and no container; the factory ships a worker manifest,
# so without this every one of them would try to start a sandbox and fail for a
# reason that has nothing to do with what it is testing.
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}

run_step() {
  PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" FACTORY_CONTAIN_WORKER=0 \
    bash "$PIPELINE_DIR/run-step.sh" run "$@" 2>&1
}

# -- authoring steps run on the developer --------------------------------------
out="$(run_step spec)"
check "spec routes to developer"        "role=developer" "$out"
check "spec passes --model to pi"       "--model ollama/qwen3.8:27b-mtp-q8_0" "$out"
check "spec passes thinking level"      "--thinking medium" "$out"
check "factory skills are loaded"       "--skill" "$out"

# -- the harness surface is closed: nothing pi would discover on its own -------
# ~/.pi/agent on this box holds 24 extensions and a prompt directory. A worker
# that loads them is running a harness nobody specified.
check "extension discovery is off"      "--no-extensions" "$out"
check "prompt-template discovery is off" "--no-prompt-templates" "$out"
check "context-file injection is off"   "--no-context-files" "$out"
check "exactly the four tools, by name" "--tools read,write,edit,bash" "$out"

# -- an audit cannot be run from here at all -----------------------------------
# run-step used to build a `factory-audit` pi session for `audit-*`. Nothing in
# the live line reached it, and it was the way that was measured not to work: as
# a pi session this model reaches for a `repo_browser` namespace that does not
# exist and answers anyway. It is gone, and the step name is now an error that
# says where audits live — otherwise the next person to want one finds a branch
# that runs and believes it.
out="$(run_step audit-spec 2>&1 || true)"
check "an audit step is refused here"   "audits do not run through run-step" "$out"
check "and it names the path that works" "judge.sh" "$out"
nope "no factory-audit session is built" "factory-audit" "$out"

# -- the judge must not be the developer's weights -----------------------------
# Read .roles.judge directly, which is what judge.sh reads. It was read through
# step_roles["audit-spec"] until that entry was removed with the dead branch —
# an indirection through a table the judge never consulted.
dev_model="$(jq -r '.roles[.step_roles.spec].model' "$PIPELINE_DIR/roles.json")"
jdg_model="$(jq -r '.roles.judge.model'             "$PIPELINE_DIR/roles.json")"
if [ "$dev_model" != "$jdg_model" ]; then
  printf '  ok    judge and developer are not the same weights\n'; PASS=$((PASS + 1))
else
  printf '  FAIL  judge and developer are the same model (%s) — audits are self-review\n' "$dev_model"
  FAIL=$((FAIL + 1))
fi

# -- conditions are stamped, or runs are not comparable ------------------------
out="$(run_step spec)"
cond="$(jq -rs '[.[] | select(.event == "end") | .conditions] | last' run/steps.jsonl)"
for field in role model digest thinking harness; do
  if [ "$(jq -r --arg f "$field" '.[$f] // "null"' <<<"$cond")" != "null" ]; then
    printf '  ok    conditions.%s stamped on the step record\n' "$field"; PASS=$((PASS + 1))
  else
    printf '  FAIL  conditions.%s missing — runs cannot be compared on this axis\n' "$field"
    FAIL=$((FAIL + 1))
  fi
done

# The declared value is kept, but it is not what `thinking` reports: that comes
# back from the session pi actually wrote.
# Read the declared level rather than hardcoding one: this asserts that the
# record is faithful to the configuration, not that any particular level is
# configured. The judge's level has already changed once on measured grounds.
declared_thinking="$(jq -r '.roles.developer.thinking' "$PIPELINE_DIR/roles.json")"
check "conditions.declared retained"    "\"thinking\":\"$declared_thinking\"" "$(jq -c '.declared' <<<"$cond")"
if [ "$(jq -r '.thinking' <<<"$cond")" = "$(jq -r '.declared.thinking' <<<"$cond")" ]; then
  printf '  ok    conditions.thinking is the observed level, matching what was asked for\n'; PASS=$((PASS + 1))
else
  printf '  FAIL  observed thinking (%s) != declared (%s) and the run was not flagged\n' \
    "$(jq -r '.thinking' <<<"$cond")" "$(jq -r '.declared.thinking' <<<"$cond")"
  FAIL=$((FAIL + 1))
fi

# Do not assert that this machine has no drift — it has some, and that is the
# point of recording it. Assert that the flag TELLS THE TRUTH about whatever the
# machine is doing: false exactly when something declared differs from what was
# observed. An earlier version of this test asserted a clean environment and
# failed the day the environment stopped being clean, which is the wrong thing
# to learn from a flag whose job is to notice.
expected_match=true
for field in num_ctx thinking; do
  obs="$(jq -r --arg f "$field" '.[$f] // "null"' <<<"$cond")"
  dec="$(jq -r --arg f "$field" '.declared[$f] // "null"' <<<"$cond")"
  if [ "$obs" != "null" ] && [ "$dec" != "null" ] && [ "$obs" != "$dec" ]; then
    expected_match=false
  fi
done
if [ "$(jq -r '.declared_matches_observed' <<<"$cond")" = "$expected_match" ]; then
  printf '  ok    declared_matches_observed reports the truth (%s here)\n' "$expected_match"
  PASS=$((PASS + 1))
else
  printf '  FAIL  declared_matches_observed says %s but the fields say %s: %s\n' \
    "$(jq -r '.declared_matches_observed' <<<"$cond")" "$expected_match" "$cond"
  FAIL=$((FAIL + 1))
fi

# The real case: roles.json asks for a thinking level, the model runs with it off,
# and only the session file knows. That is the bug verbatim — the judge spent a
# session with its reasoning disabled while the record claimed otherwise.
out="$(STUB_PI_THINKING_OVERRIDE=off run_step doc)"
drift_cond="$(jq -rs '[.[] | select(.event == "end") | .conditions] | last' run/steps.jsonl)"
check "drift is warned about"           "conditions drift" "$out"
if [ "$(jq -r '.thinking' <<<"$drift_cond")" = "off" ] \
   && [ "$(jq -r '.declared.thinking' <<<"$drift_cond")" = "$declared_thinking" ] \
   && [ "$(jq -r '.declared_matches_observed' <<<"$drift_cond")" = "false" ]; then
  printf '  ok    silent thinking downgrade is recorded as off, not as the declared level\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL  a run that ran with thinking off recorded: %s\n' "$drift_cond"
  FAIL=$((FAIL + 1))
fi

# -- a retried step is a NEW attempt, not an amendment of the last one ---------
# Found by the build loop, which invokes the same step name once per attempt.
# run-step.sh counted starts/ends for the step across the whole run *after* the
# child ran, so the second invocation saw a matched pair from the first and
# concluded "the child closed its own attempt": no attempt-2 line was written and
# the previous attempt's verdict was reused as this one's. Retries after an audit
# FAIL had the same shape, so a failing retry could inherit a PASS.
before_ends="$(jq -rs '[.[] | select(.step == "doc" and .event == "end")] | length' run/steps.jsonl)"
out="$(run_step doc)"
out="$(run_step doc)"
after="$(jq -rs '[.[] | select(.step == "doc" and .event == "end")]' run/steps.jsonl)"
n_ends="$(jq 'length' <<<"$after")"
if [ "$n_ends" -eq $((before_ends + 2)) ]; then
  printf '  ok    a second invocation records a second attempt\n'; PASS=$((PASS + 1))
else
  printf '  FAIL  two invocations recorded %s end line(s), expected %s — a retry is being folded into the previous attempt\n' \
    "$n_ends" "$((before_ends + 2))"
  FAIL=$((FAIL + 1))
fi
if [ "$(jq -r '.[-1].attempt' <<<"$after")" -gt "$(jq -r '.[-2].attempt' <<<"$after")" ]; then
  printf '  ok    the retry is numbered as a later attempt\n'; PASS=$((PASS + 1))
else
  printf '  FAIL  the retry did not get a higher attempt number: %s\n' "$(jq -c '[.[-2].attempt, .[-1].attempt]' <<<"$after")"
  FAIL=$((FAIL + 1))
fi

# -- the skill must be the FACTORY's, not a same-named one from pi's global dir --
# Found on the first real run: ~/.pi/agent/skills belongs to another project and
# had its own `pipeline-spec`. pi loads both that directory and every explicit
# --skill path, so the developer model followed the wrong contract and wrote a
# different pipeline's artifacts. A collision is not an error anywhere in pi — it
# is a silent substitution, which is why the names are prefixed and why a
# collision now stops the run.
out="$(run_step spec)"
check "the factory's own skill is named"  "/skill:factory-spec" "$out"
mkdir -p "$WORK/fake-global/factory-spec"
: > "$WORK/fake-global/factory-spec/SKILL.md"
out="$(PI_SKILLS_DIR="$WORK/fake-global" run_step spec)"
check "a name collision stops the run"    "skill name collision" "$out"
check "and it names both directories"     "fake-global" "$out"

# -- a frontier provider must be refused (spec §08) ----------------------------
# On the developer role, because that is the one a reachable step resolves to.
# These read `audit-impl` until run-step stopped serving audits; test-judge.sh
# holds the same two refusals for the judge, on judge.sh, which is the path an
# audit actually takes.
jq '.roles.developer.provider = "anthropic" | .roles.developer.model = "claude-opus-5"' \
  "$PIPELINE_DIR/roles.json" > "$WORK/frontier-roles.json"
out="$(ROLES_FILE="$WORK/frontier-roles.json" run_step spec)"
check "frontier provider refused"       "is not in the allow-list" "$out"

# -- a model that is not installed must be refused, not silently substituted ---
jq '.roles.developer.model = "definitely-not-pulled:70b"' \
  "$PIPELINE_DIR/roles.json" > "$WORK/missing-roles.json"
out="$(ROLES_FILE="$WORK/missing-roles.json" run_step spec)"
check "absent model refused"            "is not present in ollama" "$out"

# -- the weights must be the ones the run started on ---------------------------
#
# new-run.sh records a digest per role; every step records the digest it observed.
# Nothing compared the two, so a tag re-pointed mid-run — `ollama pull` by this
# project or by anything else sharing the server — produced a run whose early
# steps ran on one set of weights and whose later steps ran on another, both
# recorded truthfully, with nothing anywhere saying they differ.
DIGEST_NOW="$(ollama list 2>/dev/null | awk -v m="$(jq -r '.roles.developer.model' "$PIPELINE_DIR/roles.json")" '$1 == m {d=$2} END {print d}')"
cp run/run.json "$WORK/run.json.bak"

# The agreeing case first, so the check is known to be capable of passing.
jq --arg d "${DIGEST_NOW:-unknown}" '.conditions = {developer: {digest: $d}}'   "$WORK/run.json.bak" > run/run.json
out="$(run_step spec)"
nope "the same digest is not a change"  "MODEL CHANGED" "$out"

jq '.conditions = {developer: {digest: "0000deadbeef"}}' "$WORK/run.json.bak" > run/run.json
out="$(run_step spec)"
check "a changed digest stops the run"  "MODEL CHANGED under this run" "$out"
check "it names the role"               "role developer" "$out"
check "and both digests"                "0000deadbeef" "$out"
check "and says why it cannot continue" "no longer one experiment" "$out"
check "and what to do about it"         "Start a fresh run" "$out"

# A run record with no digest for the role is not a mismatch. Digests are
# evidence — new-run.sh records them when ollama answers and omits them when it
# does not — and a missing one must not make every step refuse.
jq '.conditions = {developer: {model: "x"}}' "$WORK/run.json.bak" > run/run.json
out="$(run_step spec)"
nope "a run record with no digest passes" "MODEL CHANGED" "$out"
cp "$WORK/run.json.bak" run/run.json

# -- an unbound step must not silently pick a default --------------------------
jq 'del(.step_roles.doc)' "$PIPELINE_DIR/roles.json" > "$WORK/unbound-roles.json"
out="$(ROLES_FILE="$WORK/unbound-roles.json" run_step doc)"
check "unbound step refused"            "no role bound to step" "$out"

# -- the worker is contained, and a refusal is not a fallback ------------------
#
# The property worth testing is not that the container starts — that needs a
# container, and these run with a stub. It is what happens when it does not: a
# step that quietly ran pi on the host after the sandbox refused would still be
# recorded as contained by everything downstream, and that label is the whole
# value of the record.
printf 'schema_version: worker-manifest/1.0.0\nimage: "localhost/x@sha256:0"\n' > "$WORK/worker.lock.yaml"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/podman" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$WORK/bin/podman"

cat > "$WORK/refusing-sandbox.sh" <<'STUB'
#!/usr/bin/env bash
printf 'worker-sandbox: REFUSED — the image is not present
' >&2
exit 5
STUB
chmod +x "$WORK/refusing-sandbox.sh"
cp "$PIPELINE_DIR/run-step.sh" "$WORK/run-step-contained.sh"
# The sandbox and gateway are called by path from $PIPELINE_DIR, so a copy of
# the pipeline is the way to substitute them without touching the real ones.
cp -r "$PIPELINE_DIR" "$WORK/pipeline"
cp "$WORK/refusing-sandbox.sh" "$WORK/pipeline/worker-sandbox.sh"
cat > "$WORK/pipeline/model-gateway.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = start ] && { mkdir -p "$TMPDIR_GW"; echo "$TMPDIR_GW"; exit 0; }
exit 0
STUB
chmod +x "$WORK/pipeline/model-gateway.sh"

# And a stub preloader, because the real one loads the model.
#
# This is the only contained invocation in the suite, and until 2026-09-16 it ran
# the real ensure-loaded.sh: every pass of this file asked ollama to put a 27b on
# the GPU and then threw it away when the stub sandbox refused, three minutes
# later, while a measurement was using the same GPU. Stubbing it makes the call
# assertable instead of merely slow.
cat > "$WORK/pipeline/ensure-loaded.sh" <<'STUB'
#!/usr/bin/env bash
printf 'STUB-ENSURE-LOADED role=%s\n' "${1:-}" >&2
exit 0
STUB
chmod +x "$WORK/pipeline/ensure-loaded.sh"

out="$(PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" \
       PATH="$WORK/bin:$PATH" TMPDIR_GW="$WORK/gw" \
       FACTORY_WORKER_LOCK="$WORK/worker.lock.yaml" \
       bash "$WORK/pipeline/run-step.sh" run spec 2>&1)"
check "a refused sandbox stops the step"  "did NOT run on the host instead" "$out"
# The contained path preloads, and preloads the step's own role. A contained run
# is the only kind that does; every other invocation in this file asserts the
# absence of this line by never producing it.
check "a contained step preloads its role" "STUB-ENSURE-LOADED role=developer" "$out"
check "and the refusal itself is shown"   "worker-sandbox: REFUSED" "$out"
if grep -qF 'STUB-PI-ARGS' <<<"$out"; then
  printf '  FAIL  it must not fall back to running pi on the host\n'; FAIL=$((FAIL + 1))
else
  printf '  ok    it does not fall back to running pi on the host\n'; PASS=$((PASS + 1))
fi

# -- and running uncontained is said out loud ---------------------------------
out="$(PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" \
       FACTORY_CONTAIN_WORKER=0 FACTORY_WORKER_LOCK="$WORK/worker.lock.yaml" \
       bash "$PIPELINE_DIR/run-step.sh" run spec 2>&1)"
check "an uncontained developer step says so" "UNCONTAINED" "$out"
check "and it does then run"                  "STUB-PI-ARGS" "$out"

# -- every uncontained developer session says why ------------------------------
#
# bean-001 ran its worker on the host because a pipeline snapshot had left
# worker.lock.yaml behind. Nothing in the output said so; it was found by
# noticing a session file path in a log. The warning only fired when a manifest
# existed AND the user had opted out — every other route to uncontained was
# silent, which is the one thing a containment story cannot afford.
out="$(PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" \
       FACTORY_WORKER_LOCK="$WORK/does-not-exist.yaml" \
       bash "$PIPELINE_DIR/run-step.sh" run spec 2>&1)"
check "a missing manifest is announced"  "UNCONTAINED" "$out"
check "and it says which file it wanted" "does-not-exist.yaml" "$out"

out="$(PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" \
       FACTORY_CONTAIN_WORKER=0 FACTORY_WORKER_LOCK="$WORK/worker.lock.yaml" \
       bash "$PIPELINE_DIR/run-step.sh" run spec 2>&1)"
check "an explicit opt-out is announced too" "FACTORY_CONTAIN_WORKER=0" "$out"

# There was a third assertion here: that an audit step does not claim to be
# uncontained. It went with the audit branch — an audit can no longer reach
# run-step at all, so what it would have said about containment is not a
# question. The refusal at the top of this file is what covers that name now.

# -- a step's recorded elapsed time is the time it actually took ---------------
#
# run-step writes both boundaries after the child exits, because the
# reconciliation it does needs the child to have finished. That is right for the
# bookkeeping and was wrong for the clock: every model step recorded zero
# elapsed, including a real spec step that had taken sixteen minutes. The column
# meant to answer "what does a bean cost" was blank for the steps that cost
# anything.
rm -f run/steps.jsonl
cat > "$WORK/slow-pi" <<'STUB'
#!/usr/bin/env bash
sleep 2
exec "$STUB_REAL" "$@"
STUB
chmod +x "$WORK/slow-pi"
PI_BIN="$WORK/slow-pi" STUB_REAL="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions"   FACTORY_CONTAIN_WORKER=0 bash "$PIPELINE_DIR/run-step.sh" run spec >/dev/null 2>&1
elapsed="$(jq -rs '
  def t($x): ($x | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601);
  (t(.[-1].ts) - t(.[0].ts))' run/steps.jsonl 2>/dev/null || echo 0)"
if [ "${elapsed:-0}" -ge 2 ] 2>/dev/null; then
  printf '  ok    the step records the time it really took (%ss)\n' "$elapsed"; PASS=$((PASS + 1))
else
  printf '  FAIL  elapsed recorded as %ss for a step that slept 2s\n' "${elapsed:-?}"; FAIL=$((FAIL + 1))
fi

# -- a step that writes nothing says so ---------------------------------------
#
# A real doc step spent thirty-seven minutes, ended with the model saying "From
# now on, I'll create the documentation", and exited without writing anything.
# The run recorded "child exit 1", which reads like a crash and hides the useful
# fact.
cat > "$WORK/silent-pi" <<'STUB'
#!/usr/bin/env bash
sess="${PI_SESSIONS_DIR:-.}/stub-$(date +%s%N).jsonl"
mkdir -p "$(dirname "$sess")"
printf '{"type":"session","version":"stub","id":"stub","cwd":"%s"}\n' "$PWD" > "$sess"
printf 'From now on, I will create the documentation.\n'
exit 1
STUB
chmod +x "$WORK/silent-pi"
rm -f run/impl-detail.md
out="$(PI_BIN="$WORK/silent-pi" PI_SESSIONS_DIR="$WORK/sessions" FACTORY_CONTAIN_WORKER=0 \
       bash "$PIPELINE_DIR/run-step.sh" run doc 2>&1)"
check "the missing output is named"  "produced none of what it exists to produce" "$out"
check "and the file is named"        "impl-detail.md" "$out"
check "with what it usually means"   "described what" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
