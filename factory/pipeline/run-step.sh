#!/usr/bin/env bash
# run-step.sh — run one pipeline step as a fresh child pi process.
#
# The orchestrator never does a step's work itself. This script launches the
# step's skill in a child pi process, waits for it, identifies the session file
# the child created, records it as `session_file` on the step's newest `end`
# line in steps.jsonl, and (for audit steps) enforces the child's verdict as
# the exit code.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="run-step.sh <run_dir> <step-name> [-- <extra args for the skill>]"

case "${1:-}" in
  --version)
    cat "$PIPELINE_DIR/VERSION"
    exit 0
    ;;
  -h|--help)
    cat <<'EOF'
run-step.sh — run one pipeline step as a fresh child pi process.

usage: run-step.sh <run_dir> <step-name> [-- <extra args for the skill>]

Step → child skill mapping (args the child receives):
  spec            pipeline-spec        <bean-id> <run_dir>
  implement       pipeline-implement   <run_dir>
  doc             pipeline-doc         <run_dir>
  audit-<target>  pipeline-audit       <target> <run_dir>
  pr              pipeline-pr          <run_dir>
    (<target> ∈ spec impl doc package)

Extra args after `--` are appended to the skill invocation — used for retries,
e.g. passing the path of the FAIL verdict whose findings to address.

The child's session file (a .jsonl newly created under the Pi sessions
directory while the child runs) is recorded as `session_file` on the step's
newest `end` line in <run_dir>/steps.jsonl. If the child never started the
step, a start/end pair is appended so the attempt is counted.

Verdict and exit code:
  audit steps  the newest <run_dir>/verdicts/<target>.attempt-N.json is read;
               exit 0 on "PASS", non-zero otherwise.
  other steps  exit 0 when the verdict recorded on the attempt is PASS. The
               recorded verdict is stamped by the child if it stamped one,
               otherwise it is derived from the child's raw exit status. The
               raw `pi -p` exit code is not a reliable success signal on its
               own (a child can stamp PASS and still exit non-zero) — the
               verdict written to steps.jsonl wins (BEAN-127).

Environment:
  PI_BIN           pi binary to launch (default: pi). Override for tests.
  PI_SESSIONS_DIR  Pi sessions directory (default: $HOME/.pi/agent/sessions).
EOF
    exit 0
    ;;
esac
require_args "$#" 2 "$USAGE"
require_cmd jq

RUN_DIR="$1"
STEP="$2"
shift 2
EXTRA=()
if [ "${1:-}" = "--" ]; then
  shift
  EXTRA=( "$@" )
fi

[ -d "$RUN_DIR" ] || die "run directory not found: $RUN_DIR"
[ -f "$RUN_DIR/run.json" ] || die "run.json not found in $RUN_DIR"
BEAN_ID="$(jq -r '.bean // empty' "$RUN_DIR/run.json")"
[ -n "$BEAN_ID" ] || die "run.json has no bean id"

case "$STEP" in
  spec)      SKILL="pipeline-spec";      SKILL_ARGS="$BEAN_ID $RUN_DIR" ; TARGET="" ;;
  implement) SKILL="pipeline-implement"; SKILL_ARGS="$RUN_DIR"         ; TARGET="" ;;
  doc)       SKILL="pipeline-doc";       SKILL_ARGS="$RUN_DIR"         ; TARGET="" ;;
  pr)        SKILL="pipeline-pr";        SKILL_ARGS="$RUN_DIR"         ; TARGET="" ;;
  audit-*)   SKILL="pipeline-audit"; TARGET="${STEP#audit-}"
             case "$TARGET" in
               spec|impl|doc|package) ;;
               *) die "unknown audit target '$STEP' (expected audit-spec|audit-impl|audit-doc|audit-package)" ;;
             esac
             SKILL_ARGS="$TARGET $RUN_DIR" ;;
  *) die "unknown step '$STEP' (expected spec|implement|doc|pr|audit-<target>)" ;;
esac

PROMPT="/skill:$SKILL $SKILL_ARGS"
[ "${#EXTRA[@]}" -gt 0 ] && PROMPT="$PROMPT ${EXTRA[*]}"

BIN="${PI_BIN:-pi}"
command -v "$BIN" >/dev/null 2>&1 || die "pi binary not found: $BIN (set PI_BIN?)"

# -- role -> model routing ------------------------------------------------------------
# The whole point of the fork: authoring steps and auditing steps must not run on
# the same weights (spec §01). ROLES_FILE binds each step to a role and each role
# to a model; FACTORY_ROLE overrides for a single step (used to run a smoke judge).
ROLES_FILE="${ROLES_FILE:-$PIPELINE_DIR/roles.json}"
[ -f "$ROLES_FILE" ] || die "roles file not found: $ROLES_FILE"

ROLE="${FACTORY_ROLE:-$(jq -r --arg s "$STEP" '.step_roles[$s] // empty' "$ROLES_FILE")}"
[ -n "$ROLE" ] || die "no role bound to step '$STEP' in $ROLES_FILE"

ROLE_CFG="$(jq -c --arg r "$ROLE" '.roles[$r] // empty' "$ROLES_FILE")"
[ -n "$ROLE_CFG" ] || die "role '$ROLE' is not defined in $ROLES_FILE"

ROLE_PROVIDER="$(jq -r '.provider' <<<"$ROLE_CFG")"
ROLE_MODEL="$(jq -r '.model' <<<"$ROLE_CFG")"
ROLE_CTX="$(jq -r '.num_ctx // empty' <<<"$ROLE_CFG")"
ROLE_THINKING="$(jq -r '.thinking // empty' <<<"$ROLE_CFG")"

# Provider allow-list (spec §08). Refuse rather than warn: a frontier provider
# reaching the runtime is the one failure this design must make impossible.
jq -e --arg p "$ROLE_PROVIDER" '.provider_allowlist | index($p)' "$ROLES_FILE" >/dev/null \
  || die "provider '$ROLE_PROVIDER' is not in the allow-list in $ROLES_FILE (runtime is local-only)"

# Assert the weights exist before spending a step on them; a silently-substituted
# model is the "wrong model loaded" fault the plan wants blocked, not tolerated.
MODEL_DIGEST="$(ollama list 2>/dev/null | awk -v m="$ROLE_MODEL" '$1 == m {d=$2} END {print d}')"
[ -n "$MODEL_DIGEST" ] || die "model '$ROLE_MODEL' for role '$ROLE' is not present in ollama"

PI_ARGS=( --model "$ROLE_PROVIDER/$ROLE_MODEL" )
[ -n "$ROLE_THINKING" ] && PI_ARGS+=( --thinking "$ROLE_THINKING" )

# Load this repo's skills explicitly. The global ~/.pi/agent/skills directory is
# owned by another project (its sync-skills.sh treats its own copy as canonical),
# so editing the installed copies would silently break it on its next run.
FACTORY_SKILLS="${FACTORY_SKILLS:-$PIPELINE_DIR/../skills}"
[ -d "$FACTORY_SKILLS" ] && PI_ARGS+=( --skill "$FACTORY_SKILLS" )

printf 'STEP   %s   role=%s model=%s ctx=%s thinking=%s\n' \
  "$STEP" "$ROLE" "$ROLE_MODEL" "${ROLE_CTX:--}" "${ROLE_THINKING:--}" >&2

# -- locate the child's session file -------------------------------------------------
SESS_DIR="$(pi_sessions_dir)"
T0="$(date +%s)"
SNAP="$(mktemp)"; NEW="$(mktemp)"
trap 'rm -f "$SNAP" "$NEW"' EXIT
find "$SESS_DIR" -type f -name '*.jsonl' 2>/dev/null | sort > "$SNAP" || true

# -- launch the child (output streams straight through) ------------------------------
set +e
"$BIN" "${PI_ARGS[@]}" -p "$PROMPT"
RC=$?
set -e

find "$SESS_DIR" -type f -name '*.jsonl' 2>/dev/null | sort > "$NEW" || true

SESSION_FILE=""
CANDS="$(comm -13 "$SNAP" "$NEW" 2>/dev/null || true)"
if [ -z "$CANDS" ]; then
  # fallback: anything (in the new listing) modified since the child started
  for f in $(cat "$NEW"); do
    [ "$(stat -c %Y "$f" 2>/dev/null || echo 0)" -ge "$T0" ] && printf '%s\n' "$f"
  done
fi
CANDS="$(printf '%s\n' "$CANDS" | sed '/^[[:space:]]*$/d' || true)"
# Prefer a session whose header names this working directory.
ROOT="$(repo_root)"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  cwd="$(jq -r 'select(.type == "session") | .cwd' "$f" 2>/dev/null | head -n 1 || true)"
  if [ "$cwd" = "$ROOT" ]; then SESSION_FILE="$f"; break; fi
done <<< "$CANDS"
if [ -z "$SESSION_FILE" ]; then
  SESSION_FILE="$(printf '%s\n' "$CANDS" | sed -n '1p')"
fi

# -- observe the conditions, do not declare them ---------------------------------------
# roles.json says what this step *asked for*. What it got is a separate question,
# and the answer has been wrong before: pi silently ran the judge with reasoning
# off while roles.json said "high", and run-step stamped "high" into the record
# anyway. num_ctx is the same shape of lie — pi has no flag for it (`pi --help`),
# so ollama serves whatever OLLAMA_CONTEXT_LENGTH or the last request set, which
# need not be the number in roles.json. A false provenance figure is worse than a
# missing one: it survives into the telemetry later decisions are made from.
# So: read both back from the horse's mouth, record the observed value, keep the
# declared value beside it, and say plainly when they differ.
OBS_THINKING=""
OBS_MODEL=""
if [ -n "$SESSION_FILE" ] && [ -f "$SESSION_FILE" ]; then
  OBS_THINKING="$(jq -rs '[.[] | select(.type == "thinking_level_change") | .thinkingLevel] | last // empty' "$SESSION_FILE" 2>/dev/null || true)"
  OBS_MODEL="$(jq -rs '[.[] | select(.type == "model_change") | .model] | last // empty' "$SESSION_FILE" 2>/dev/null || true)"
fi
OBS_CTX="$(curl -s --max-time 5 "${OLLAMA_HOST:-http://127.0.0.1:11434}/api/ps" 2>/dev/null \
  | jq -r --arg m "$ROLE_MODEL" '[.models[]? | select(.name == $m) | .context_length] | last // empty' 2>/dev/null || true)"

drift=""
[ -n "$OBS_THINKING" ] && [ -n "$ROLE_THINKING" ] && [ "$OBS_THINKING" != "$ROLE_THINKING" ] \
  && drift="$drift thinking(declared=$ROLE_THINKING observed=$OBS_THINKING)"
[ -n "$OBS_CTX" ] && [ -n "$ROLE_CTX" ] && [ "$OBS_CTX" != "$ROLE_CTX" ] \
  && drift="$drift num_ctx(declared=$ROLE_CTX observed=$OBS_CTX)"
[ -n "$OBS_MODEL" ] && [ "$OBS_MODEL" != "$ROLE_MODEL" ] \
  && drift="$drift model(declared=$ROLE_MODEL observed=$OBS_MODEL)"
[ -n "$drift" ] && printf 'WARN   %s   conditions drift:%s — the run record carries the observed values\n' \
  "$STEP" "$drift" >&2

# -- bookkeeping in steps.jsonl --------------------------------------------------------
STEPS="$RUN_DIR/steps.jsonl"
[ -f "$STEPS" ] || : > "$STEPS"

is_audit=0
[ -n "$TARGET" ] && is_audit=1

# -- reconcile the attempt the child may or may not have recorded ---------------------
# The child's skill opens (and sometimes closes) its own attempt via step.sh, or
# records nothing at all (test children, crashes). Reconcile against steps.jsonl:
#   child closed its attempt  (starts == ends > 0)  -> amend its last end line with
#     this attempt's verdict + session file; NEVER append a second end for it —
#     that is exactly the unpaired-end shape that broke BEAN-125's telemetry.
#   otherwise (an open start, or nothing)           -> close the open attempt with
#     a proper verdict, opening it first if the child never did.
# step.sh enforces the invariant (no end without a matching open start), so an
# un-paired line can never reach steps.jsonl from here.
ENDS="$(jq -rs --arg s "$STEP" '[.[] | select(.step == $s and .event == "end")] | length' "$STEPS")"
STARTS="$(jq -rs --arg s "$STEP" '[.[] | select(.step == $s and .event == "start")] | length' "$STEPS")"

# End verdict for *this* attempt.
END_VERDICT=""
if [ "$is_audit" = 1 ]; then
  # The child writes one verdict per attempt (verdicts/<target>.attempt-N.json),
  # so the highest numbered file is THIS attempt's. Keying off it is what keeps
  # an older attempt's PASS from masking the verdict we just wanted — and a
  # freshly-passing retry from being stamped by the previous attempt's FAIL.
  VFILE=""
  BEST_N=0
  for f in "$RUN_DIR/verdicts/$TARGET".attempt-*.json; do
    [ -e "$f" ] || continue
    nfile="${f##*attempt-}"; nfile="${nfile%.json}"
    if [ "$nfile" -gt "$BEST_N" ]; then BEST_N="$nfile"; VFILE="$f"; fi
  done
  if [ -n "$VFILE" ]; then
    END_VERDICT="$(jq -r '.verdict // "FAIL"' "$VFILE" 2>/dev/null || echo FAIL)"
  else
    END_VERDICT="FAIL"
  fi
elif [ "$ENDS" -gt 0 ]; then
  # Honour a verdict the child already stamped; otherwise stamp from rc.
  EXISTING="$(jq -rs --arg s "$STEP" '[.[] | select(.step == $s and .event == "end")] | last.verdict' "$STEPS")"
  if [ -z "$EXISTING" ] || [ "$EXISTING" = "null" ]; then
    if [ "$RC" -eq 0 ]; then END_VERDICT="PASS"; else END_VERDICT="FAIL"; fi
  else
    END_VERDICT="$EXISTING"
  fi
else
  if [ "$RC" -eq 0 ]; then END_VERDICT="PASS"; else END_VERDICT="FAIL"; fi
fi

if [ "$STARTS" -eq "$ENDS" ] && [ "$ENDS" -gt 0 ]; then
  : # child already closed this attempt: the amend below stamps its end line
else
  if [ "$STARTS" -eq 0 ]; then
    "$PIPELINE_DIR/step.sh" "$RUN_DIR" "$STEP" start
  fi
  "$PIPELINE_DIR/step.sh" "$RUN_DIR" "$STEP" end "$END_VERDICT"
fi

# Patch the newest end line: session_file + end verdict (slurped JSONL in,
# JSONL stream out).
SF_ARG=""
[ -n "$SESSION_FILE" ] && SF_ARG="$SESSION_FILE"
jq -sc \
  --arg s "$STEP" \
  --arg sf "$SF_ARG" \
  --arg v "$END_VERDICT" \
  --argjson cond "$(jq -cn \
      --arg role "$ROLE" --arg model "$ROLE_MODEL" --arg digest "$MODEL_DIGEST" \
      --arg thinking "$ROLE_THINKING" --argjson ctx "${ROLE_CTX:-null}" \
      --arg obs_thinking "$OBS_THINKING" --argjson obs_ctx "${OBS_CTX:-null}" \
      --arg obs_model "$OBS_MODEL" \
      'def s($v): if $v == "" then null else $v end;
       {role:$role, model:$model, digest:$digest,
        num_ctx:($obs_ctx // null), thinking:s($obs_thinking),
        declared:{num_ctx:$ctx, thinking:s($thinking), model:$model},
        observed_from:{thinking:"pi session", num_ctx:"ollama /api/ps", model:s($obs_model)},
        declared_matches_observed:
          ((($obs_ctx == null) or ($ctx == null) or ($obs_ctx == $ctx))
           and (($obs_thinking == "") or ($thinking == "") or ($obs_thinking == $thinking))
           and (($obs_model == "") or ($obs_model == $model)))}')" \
  '
  . as $arr
  | ([ to_entries[] | select(.value.step == $s and .value.event == "end") | .key ]) as $idx
  | if ($idx | length) == 0 then $arr
    else
      $arr | .[ ($idx | last) ] |=
          ( .session_file = (if $sf == "" then null else $sf end)
          | .verdict = (if $v == "" then .verdict else $v end)
          | .conditions = $cond )
    end
  | .[]
  ' "$STEPS" > "$STEPS.tmp"
mv "$STEPS.tmp" "$STEPS"

# -- exit code ------------------------------------------------------------------------
if [ "$is_audit" = 1 ]; then
  if [ "$END_VERDICT" = "PASS" ]; then
    printf 'STEP   %s   PASS   session=%s\n' "$STEP" "${SESSION_FILE:--}"
    exit 0
  fi
  printf 'STEP   %s   FAIL   verdict-file=%s session=%s\n' "$STEP" "${VFILE:--}" "${SESSION_FILE:--}" >&2
  exit 1
fi

# BEAN-127: the exit code must follow the verdict that was written to
# steps.jsonl, exactly like the audit path above. A child that stamped PASS
# and exited non-zero is still a PASS — the raw `pi -p` exit status is
# fallback evidence (used to derive the verdict when the child stamped
# nothing), never an override of a verdict it did stamp. A step recorded
# FAIL exits non-zero regardless of RC (a child could stamp FAIL and exit 0);
# a child that stamped nothing and exited non-zero yielded FAIL above and
# still halts the run — the spec-timeout path is preserved.
if [ "$END_VERDICT" = "PASS" ]; then
  if [ "$RC" -ne 0 ]; then
    printf 'STEP   %s   PASS   child exited %s but recorded PASS — the stamped verdict wins\n' "$STEP" "$RC"
  else
    printf 'STEP   %s   PASS   session=%s\n' "$STEP" "${SESSION_FILE:--}"
  fi
  exit 0
fi
printf 'STEP   %s   FAIL   child exit %s session=%s\n' "$STEP" "$RC" "${SESSION_FILE:--}" >&2
exit 1
