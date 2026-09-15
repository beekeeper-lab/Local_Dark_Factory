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
  spec            factory-spec         <bean-id> <run_dir>
  implement       factory-implement    <run_dir>
  build-task      factory-build-task   <run_dir> <task-id> <attempt-dir>
                  (one task of the build loop; build-loop.sh passes the extras)
  doc             factory-doc          <run_dir>
  audit-<target>  factory-audit        <target> <run_dir>
  pr              factory-pr           <run_dir>

The `factory-` prefix keeps these from colliding with the identically-named
skills in the global ~/.pi/agent/skills directory, which belongs to another
project. A collision is not an error anywhere — it is a silent substitution.
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

# Skill names are prefixed `factory-` and that prefix is load-bearing. pi
# discovers skills from ~/.pi/agent/skills as well as from every explicit
# --skill path, and that global directory belongs to another project which also
# has a `pipeline-spec`. On the first real run of this line, the developer model
# followed THAT skill: it wrote the artifacts of a different pipeline's contract
# and the controller refused them. Two skills with one name is a coin toss, and
# the run record would have said nothing about which one won.
case "$STEP" in
  spec)      SKILL="factory-spec";      SKILL_ARGS="$BEAN_ID $RUN_DIR" ; TARGET="" ;;
  implement) SKILL="factory-implement"; SKILL_ARGS="$RUN_DIR"         ; TARGET="" ;;
  build-task) SKILL="factory-build-task"; SKILL_ARGS="$RUN_DIR"      ; TARGET="" ;;
  doc)       SKILL="factory-doc";       SKILL_ARGS="$RUN_DIR"         ; TARGET="" ;;
  pr)        SKILL="factory-pr";        SKILL_ARGS="$RUN_DIR"         ; TARGET="" ;;
  audit-*)   SKILL="factory-audit"; TARGET="${STEP#audit-}"
             case "$TARGET" in
               spec|impl|doc|package) ;;
               *) die "unknown audit target '$STEP' (expected audit-spec|audit-impl|audit-doc|audit-package)" ;;
             esac
             SKILL_ARGS="$TARGET $RUN_DIR" ;;
  *) die "unknown step '$STEP' (expected spec|implement|build-task|doc|pr|audit-<target>)" ;;
esac

ROOT="$(repo_root)"

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

# Close the harness surface. Without these, pi discovers everything in
# ~/.pi/agent — on this box, 24 extensions (github-mcp.ts, trello.ts, obsidian.ts,
# team-lead.ts, two posttooluse-edit-write hooks, ...) and a directory of prompt
# templates — and prepends any AGENTS.md/CLAUDE.md it finds in the target repo,
# into every developer session, and records none of it. That is the skill
# collision (pi loads both, the winner is not recorded) one directory over. The
# worker gets the four built-in tools by name and nothing that was not put here.
#
# --no-context-files is deliberate, not incidental: factory-spec tells the model
# to READ the repo's CLAUDE.md/AGENTS.md if present, which is a recorded act;
# silent injection is not. Skill discovery stays on (the collision check below
# covers the one directory it reaches) until --no-skills + --skill is proven to
# still load the explicit path — that needs a live smoke step, not a stub.
HARNESS_FLAGS=( --no-extensions --no-prompt-templates --no-context-files
                --tools read,write,edit,bash )
PI_ARGS+=( "${HARNESS_FLAGS[@]}" )

# Load this repo's skills explicitly. The global ~/.pi/agent/skills directory is
# owned by another project (its sync-skills.sh treats its own copy as canonical),
# so editing the installed copies would silently break it on its next run.
FACTORY_SKILLS="${FACTORY_SKILLS:-$PIPELINE_DIR/../skills}"
[ -d "$FACTORY_SKILLS" ] && PI_ARGS+=( --skill "$FACTORY_SKILLS" )

# The prefix is the defence; this is the alarm. If a skill of the same name ever
# appears in pi's global directory, the run must not quietly pick one.
GLOBAL_SKILLS="${PI_SKILLS_DIR:-$HOME/.pi/agent/skills}"
if [ -d "$GLOBAL_SKILLS/$SKILL" ]; then
  die "skill name collision: '$SKILL' exists both in $FACTORY_SKILLS and in $GLOBAL_SKILLS.
pi loads both and the winner is not recorded anywhere. Rename one of them before running."
fi

printf 'STEP   %s   role=%s model=%s ctx=%s thinking=%s\n' \
  "$STEP" "$ROLE" "$ROLE_MODEL" "${ROLE_CTX:--}" "${ROLE_THINKING:--}" >&2

# -- locate the child's session file -------------------------------------------------
SESS_DIR="$(pi_sessions_dir)"
T0="$(date +%s)"
SNAP="$(mktemp)"; NEW="$(mktemp)"
trap 'rm -f "$SNAP" "$NEW"' EXIT
find "$SESS_DIR" -type f -name '*.jsonl' 2>/dev/null | sort > "$SNAP" || true

# -- what steps.jsonl looked like BEFORE this invocation -------------------------------
# The reconciliation below asks "what did THIS child record?". Counting totals
# after the fact cannot answer that: on the second invocation of the same step —
# a retry after an audit FAIL, or any attempt of the build loop — the totals
# already show a matched start/end pair from the previous attempt, which reads
# exactly like "the child closed its own attempt". The result was that a retry
# recorded no new attempt and silently inherited the previous attempt's verdict.
STEPS="$RUN_DIR/steps.jsonl"
[ -f "$STEPS" ] || : > "$STEPS"
STARTS_BEFORE="$(jq -rs --arg s "$STEP" '[.[] | select(.step == $s and .event == "start")] | length' "$STEPS")"
ENDS_BEFORE="$(jq -rs --arg s "$STEP" '[.[] | select(.step == $s and .event == "end")] | length' "$STEPS")"

# -- launch the child (output streams straight through) ------------------------------
#
# Contained, when the repository has a worker manifest. The worker is the one
# stage a model steers, and on the host it steered it with the user's home
# directory, keys and the whole internet within reach; worker-sandbox.sh puts it
# in a pinned image with no routes at all and one unix socket to the model.
#
# Two translations are needed and neither is optional. The tree is at /work
# inside, so every host path in the prompt has to be rewritten or the worker is
# told to open files that are not there. And pi's sessions land in the mounted
# agent directory, so PI_SESSIONS_DIR has to point at it — otherwise the
# reconciliation below looks in $HOME, finds nothing new, and records a step
# whose observed conditions are blank.
#
# FACTORY_CONTAIN_WORKER=0 runs on the host. It exists because the tests stub pi
# and cannot run a container, not as an operational escape hatch: when a manifest
# is present and this is unset, containment is the default and its absence is
# printed rather than assumed.
# Deciding NOT to contain is a decision, and it gets said out loud.
#
# The first version only announced an uncontained run when a manifest existed and
# the user had explicitly opted out. Every other route to CONTAIN=0 — no
# manifest found, podman missing — was silent, and bean-001 duly ran its worker
# on the host because a snapshot had left worker.lock.yaml behind. Nothing in the
# output said so. It was found by noticing a session file path.
#
# A pipeline that can quietly stop containing the one thing a model steers is not
# a contained pipeline, whatever its manifest says.
CONTAIN="${FACTORY_CONTAIN_WORKER:-auto}"
# The worker manifest belongs to the FACTORY, not to the repository being built.
# gates.lock.yaml is per-repo because a project's toolchain is the project's; the
# worker image is the agent harness, identical for every bean in every repo, and
# a copy per target would be four copies to drift apart. A target repo may still
# override it — some project might need a worker with something extra in it —
# and that override is found first precisely because it is the unusual case.
WORKER_LOCK="${FACTORY_WORKER_LOCK:-}"
if [ -z "$WORKER_LOCK" ]; then
  for cand in "$ROOT/factory/worker.lock.yaml" "$PIPELINE_DIR/../worker.lock.yaml"; do
    [ -f "$cand" ] && { WORKER_LOCK="$cand"; break; }
  done
  [ -n "$WORKER_LOCK" ] || WORKER_LOCK="$PIPELINE_DIR/../worker.lock.yaml"
fi
CONTAIN_WHY=""
if [ "$CONTAIN" = auto ]; then
  if [ "$ROLE" != developer ]; then
    CONTAIN=0; CONTAIN_WHY="role '$ROLE' is not the developer; only authoring sessions are contained"
  elif [ ! -f "$WORKER_LOCK" ]; then
    CONTAIN=0; CONTAIN_WHY="no worker manifest at $WORKER_LOCK"
  elif ! command -v podman >/dev/null 2>&1; then
    CONTAIN=0; CONTAIN_WHY="podman is not installed"
  else
    CONTAIN=1
  fi
elif [ "$CONTAIN" = 0 ]; then
  CONTAIN_WHY="FACTORY_CONTAIN_WORKER=0"
fi
if [ "$CONTAIN" = 0 ] && [ "$ROLE" = developer ]; then
  printf 'STEP   %s   UNCONTAINED — this session runs pi on the host: %s\n' "$STEP" "$CONTAIN_WHY" >&2
fi

# Every model session gets /dev/null on stdin, contained or not.
#
# The build loop already did this for build-task, because a worker reading stdin
# ate the loop's task list. The same hazard exists at every other step, and it
# surfaced the moment the line was driven end to end by a stub that behaves like
# pi: the spec step hung forever on a read waiting for a terminal that was never
# going to send anything.
#
# Nothing in an authoring session should be reading stdin. Making that true here,
# once, beats remembering it at each call site — build-loop.sh keeps its own
# redirect as belt and braces, since it has a work list to lose.
set +e
if [ "$CONTAIN" = 1 ]; then
  GW_DIR="${FACTORY_MODEL_SOCKET_DIR:-}"
  GW_STARTED=0
  if [ -z "$GW_DIR" ]; then
    GW_DIR="$("$PIPELINE_DIR/model-gateway.sh" start)" || die "could not open a model gateway; refusing to run the worker uncontained"
    GW_STARTED=1
  fi
  AGENT_DIR="$(mktemp -d "${FACTORY_SANDBOX_ROOT:-${TMPDIR:-/tmp}}/fagent.XXXXXX")"
  mkdir -p "$AGENT_DIR/sessions"
  cp "$HOME/.pi/agent/models.json" "$AGENT_DIR/models.json" 2>/dev/null \
    || die "no ~/.pi/agent/models.json to give the contained worker; it would refuse every --model"

  # Make the declared context the real one.
  #
  # pi has no num_ctx flag, so on the host the number in roles.json is a wish:
  # ollama serves whatever OLLAMA_CONTEXT_LENGTH or pi's own catalogue asks for,
  # and the first contained run duly recorded declared=32768 observed=262144. The
  # drift is reported honestly, which is right, but a contained run can do better
  # than report it — the controller writes this catalogue, so it can set the
  # number rather than hope for it. On the host this is not possible without
  # editing the user's own ~/.pi/agent/models.json, which belongs to them.
  if [ -n "$ROLE_CTX" ]; then
    jq --arg m "$ROLE_MODEL" --argjson c "$ROLE_CTX" \
      '(.providers[].models[]? | select(.id == $m) | .contextWindow) = $c' \
      "$AGENT_DIR/models.json" > "$AGENT_DIR/models.json.tmp" \
      && mv "$AGENT_DIR/models.json.tmp" "$AGENT_DIR/models.json"
  fi
  SESS_DIR="$AGENT_DIR/sessions"
  : > "$SNAP"

  # Host paths -> container paths. The longest prefix first, so a run directory
  # inside the tree is rewritten once rather than twice.
  CPROMPT="${PROMPT//$ROOT/\/work}"
  CARGS=()
  for a in "${PI_ARGS[@]}"; do CARGS+=( "${a//$ROOT/\/work}" ); done
  CARGS=( "${CARGS[@]/#$FACTORY_SKILLS/\/factory\/skills}" )

  # --lock, because run-step is the thing that knows where the manifest is: it
  # looks in the target repo and then in the factory. worker-sandbox.sh on its
  # own only knows the repo it was called from, which for every target except
  # this one is the wrong place — and it refuses rather than guessing, so the
  # first real run halted on the manifest it had just been told about.
  "$PIPELINE_DIR/worker-sandbox.sh" \
    --tree "$ROOT" --agent-dir "$AGENT_DIR" --socket-dir "$GW_DIR" \
    --skills "$FACTORY_SKILLS" --lock "$WORKER_LOCK" \
    -- "${CARGS[@]}" -p "$CPROMPT" </dev/null
  RC=$?
  [ "$GW_STARTED" = 1 ] && "$PIPELINE_DIR/model-gateway.sh" stop --dir "$GW_DIR" >/dev/null 2>&1
  [ "$RC" -eq 5 ] && die "the worker sandbox refused; the step did NOT run on the host instead"
else
  "$BIN" "${PI_ARGS[@]}" -p "$PROMPT" </dev/null
  RC=$?
fi
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
# Prefer a session whose header names this working directory. A contained worker
# records /work, because that is where the tree is mounted; on the host it records
# the repository path. Both are this run.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  cwd="$(jq -r 'select(.type == "session") | .cwd' "$f" 2>/dev/null | head -n 1 || true)"
  if [ "$cwd" = "$ROOT" ] || { [ "$CONTAIN" = 1 ] && [ "$cwd" = "/work" ]; }; then SESSION_FILE="$f"; break; fi
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
COMPACTIONS=0
if [ -n "$SESSION_FILE" ] && [ -f "$SESSION_FILE" ]; then
  OBS_THINKING="$(jq -rs '[.[] | select(.type == "thinking_level_change") | .thinkingLevel] | last // empty' "$SESSION_FILE" 2>/dev/null || true)"
  OBS_MODEL="$(jq -rs '[.[] | select(.type == "model_change") | .model] | last // empty' "$SESSION_FILE" 2>/dev/null || true)"
  # Did the session run out of context and compact?
  #
  # This is a quality signal, not a performance one. A worker that compacted has
  # lost the earlier part of its own reasoning mid-task — exactly the failure the
  # task loop exists to prevent, and invisible in the output, which still looks
  # like a confident finished answer. Found by noticing a spec step taking fifty
  # minutes instead of twenty and asking why.
  COMPACTIONS="$(jq -rs '[.[] | select(.type == "compaction")] | length' "$SESSION_FILE" 2>/dev/null || echo 0)"
fi
# These are two different numbers and calling both "num_ctx" was a mistake.
#
# roles.json's num_ctx is PI's window: what the agent believes it may fill before
# it must compact. The contained worker gets it honoured, because the controller
# writes the models.json pi reads. That is what stopped a spec session compacting
# twice.
#
# /api/ps reports OLLAMA's: how much context the loaded model actually has, which
# comes from OLLAMA_CONTEXT_LENGTH or the model's default and is a property of
# the running server, not of this run. pi does not set it — it speaks the
# openai-completions API, which has no field for it.
#
# So the two differing is normal and is not drift in the sense the other
# conditions use. Reporting it as drift alongside "the model was not the one we
# asked for" trains everyone to ignore the word. Recorded as both, named
# separately.
OBS_CTX="$(curl -s --max-time 5 "${OLLAMA_HOST:-http://127.0.0.1:11434}/api/ps" 2>/dev/null \
  | jq -r --arg m "$ROLE_MODEL" '[.models[]? | select(.name == $m) | .context_length] | last // empty' 2>/dev/null || true)"

if [ "${COMPACTIONS:-0}" -gt 0 ]; then
  printf 'WARN   %s   the session COMPACTED %s time(s) — it ran out of context and lost\n' "$STEP" "$COMPACTIONS" >&2
  printf '       part of its own reasoning. Raise num_ctx for role %s, or make the task smaller.\n' "$ROLE" >&2
fi

drift=""
[ -n "$OBS_THINKING" ] && [ -n "$ROLE_THINKING" ] && [ "$OBS_THINKING" != "$ROLE_THINKING" ] \
  && drift="$drift thinking(declared=$ROLE_THINKING observed=$OBS_THINKING)"
# Deliberately NOT part of drift; see above. The server's context is reported in
# the conditions and shown when it is smaller than what pi was told it may use,
# which is the only combination that can hurt: pi filling a window the server
# will truncate.
if [ -n "$OBS_CTX" ] && [ -n "$ROLE_CTX" ] && [ "$OBS_CTX" -lt "$ROLE_CTX" ] 2>/dev/null; then
  printf 'WARN   %s   pi may use %s tokens but the loaded model only has %s — the server will\n' \
    "$STEP" "$ROLE_CTX" "$OBS_CTX" >&2
  printf '       truncate before pi thinks it needs to. Lower num_ctx for role %s, or raise\n' "$ROLE" >&2
  printf '       OLLAMA_CONTEXT_LENGTH (system-wide, so it is the operator'"'"'s call).\n' >&2
fi
false && [ -n "$OBS_CTX" ] && [ -n "$ROLE_CTX" ] && [ "$OBS_CTX" != "$ROLE_CTX" ] \
  && drift="$drift num_ctx(declared=$ROLE_CTX observed=$OBS_CTX)"
[ -n "$OBS_MODEL" ] && [ "$OBS_MODEL" != "$ROLE_MODEL" ] \
  && drift="$drift model(declared=$ROLE_MODEL observed=$OBS_MODEL)"
[ -n "$drift" ] && printf 'WARN   %s   conditions drift:%s — the run record carries the observed values\n' \
  "$STEP" "$drift" >&2

# -- bookkeeping in steps.jsonl --------------------------------------------------------
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
# What this child recorded, as opposed to what the run has recorded so far.
CHILD_STARTS=$((STARTS - STARTS_BEFORE))
CHILD_ENDS=$((ENDS - ENDS_BEFORE))

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
    # spec.attempt-1.judgement.json matches this glob too, and its attempt number
    # parses as "1.judgement". pr.sh and package-check.sh already skip these; this
    # loop and orchestrate's did not, and printed "integer expected" to stderr
    # mid-step where it read like noise from something else.
    case "$f" in *.judgement.json) continue ;; esac
    nfile="${f##*attempt-}"; nfile="${nfile%.json}"
    case "$nfile" in ''|*[!0-9]*) continue ;; esac
    if [ "$nfile" -gt "$BEST_N" ]; then BEST_N="$nfile"; VFILE="$f"; fi
  done
  if [ -n "$VFILE" ]; then
    # accept -> PASS; revise/block -> FAIL. The fork wrote PASS/FAIL directly;
    # the factory's verdict schema uses the spec's three words (§10).
    raw="$(jq -r '.verdict // "FAIL"' "$VFILE" 2>/dev/null || echo FAIL)"
    case "$raw" in
      accept|PASS) END_VERDICT="PASS" ;;
      *)           END_VERDICT="FAIL" ;;
    esac
  else
    END_VERDICT="FAIL"
  fi
elif [ "$CHILD_ENDS" -gt 0 ]; then
  # Honour a verdict THIS child stamped; otherwise stamp from rc. A verdict from
  # an earlier attempt is not this attempt's result.
  EXISTING="$(jq -rs --arg s "$STEP" '[.[] | select(.step == $s and .event == "end")] | last.verdict' "$STEPS")"
  if [ -z "$EXISTING" ] || [ "$EXISTING" = "null" ]; then
    if [ "$RC" -eq 0 ]; then END_VERDICT="PASS"; else END_VERDICT="FAIL"; fi
  else
    END_VERDICT="$EXISTING"
  fi
else
  if [ "$RC" -eq 0 ]; then END_VERDICT="PASS"; else END_VERDICT="FAIL"; fi
fi

if [ "$CHILD_ENDS" -gt 0 ] && [ "$CHILD_STARTS" -eq "$CHILD_ENDS" ]; then
  : # this child opened and closed its own attempt: the amend below stamps it
else
  if [ "$CHILD_STARTS" -eq 0 ]; then
    "$PIPELINE_DIR/step.sh" "$RUN_DIR" "$STEP" start
  fi
  "$PIPELINE_DIR/step.sh" "$RUN_DIR" "$STEP" end "$END_VERDICT"
fi

# Patch the newest end line: session_file + end verdict (slurped JSONL in,
# JSONL stream out).
SF_ARG=""
[ -n "$SESSION_FILE" ] && SF_ARG="$SESSION_FILE"
# The harness surface is a run condition like thinking and num_ctx: two runs
# with different flag sets are not comparable, so the set goes in the record.
HARNESS_JSON="$(printf '%s\n' "${HARNESS_FLAGS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
jq -sc \
  --arg s "$STEP" \
  --arg sf "$SF_ARG" \
  --arg v "$END_VERDICT" \
  --argjson cond "$(jq -cn \
      --arg role "$ROLE" --arg model "$ROLE_MODEL" --arg digest "$MODEL_DIGEST" \
      --arg thinking "$ROLE_THINKING" --argjson ctx "${ROLE_CTX:-null}" \
      --arg obs_thinking "$OBS_THINKING" --argjson obs_ctx "${OBS_CTX:-null}" \
      --arg obs_model "$OBS_MODEL" --argjson harness "$HARNESS_JSON" \
      --argjson compactions "${COMPACTIONS:-0}" \
      'def s($v): if $v == "" then null else $v end;
       {role:$role, model:$model, digest:$digest,
        num_ctx:($obs_ctx // null), thinking:s($obs_thinking),
        pi_window:$ctx,
        context_note:"num_ctx is the context of the loaded model on the server; pi_window is what the agent was told it may fill. pi does not set the server side.",
        harness:{flags:$harness, tools:["read","write","edit","bash"]},
        compactions:$compactions,
        ran_within_context:($compactions == 0),
        declared:{num_ctx:$ctx, thinking:s($thinking), model:$model},
        observed_from:{thinking:"pi session", num_ctx:"ollama /api/ps", model:s($obs_model)},
        declared_matches_observed:
          ((($obs_thinking == "") or ($thinking == "") or ($obs_thinking == $thinking))
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
