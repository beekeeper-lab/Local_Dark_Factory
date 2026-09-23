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
  build-task      factory-build-task   <run_dir> <task-id> <attempt-dir>
                  (one task of the build loop; build-loop.sh passes the extras)
  doc             factory-doc          <run_dir>
  pr              factory-pr           <run_dir>

Audits are NOT here. `orchestrate.sh` runs them itself — judge.sh over HTTP,
then audit-check.sh — and run-step refuses an `audit-*` step name rather than
offering a second way to do it. judge.sh's header has the measurement: as a pi
session this model reaches for a `repo_browser` tool namespace that does not
exist, gets nothing, and answers anyway.

The `factory-` prefix keeps these from colliding with the identically-named
skills in the global ~/.pi/agent/skills directory, which belongs to another
project. A collision is not an error anywhere — it is a silent substitution.
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
  spec)      SKILL="factory-spec";      SKILL_ARGS="$BEAN_ID $RUN_DIR" ;;
  build-task) SKILL="factory-build-task"; SKILL_ARGS="$RUN_DIR"      ;;
  doc)       SKILL="factory-doc";       SKILL_ARGS="$RUN_DIR"         ;;
  pr)        SKILL="factory-pr";        SKILL_ARGS="$RUN_DIR"         ;;
  # Audits do not run here, and asking for one is refused rather than served.
  #
  # This branch used to build a `factory-audit` pi session. Nothing in the live
  # line reached it — orchestrate.sh handles `audit-*` itself, judge.sh then
  # audit-check.sh — so it was a second way to run an audit, and it was the way
  # that was MEASURED NOT TO WORK: as a pi session this model reaches for a
  # `repo_browser` tool namespace that does not exist, gets nothing, and answers
  # anyway, producing a fluent audit of a document it never read.
  #
  # Dead code that produces a plausible wrong answer is worse than no code. It
  # is gone; the step name is now an error that says where audits live.
  audit-*)
    die "audits do not run through run-step.sh: orchestrate.sh runs judge.sh over HTTP and then audit-check.sh. As a pi session this model answers about files it never read - see judge.sh's header for the measurement."
    ;;
  *) die "unknown step '$STEP' (expected spec|build-task|doc|pr)" ;;
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

# And it is the same weights the run started with.
#
# new-run.sh records a digest per role in the run record, and every step records
# the digest it observed. Nothing compared the two, so a tag re-pointed
# mid-run — `ollama pull` on either model, by this project or by anything else
# sharing the server — would produce a run whose early steps ran on one set of
# weights and whose later steps ran on another, with both truthfully recorded and
# nothing saying they differ. The run record would be internally consistent and
# describe something that never happened as a single experiment.
#
# This is the healthcheck half of the plan's "wrong model loaded → blocked" item.
# The other half — refusing a model that is absent — is two lines above.
#
# Halt, not warn: the comparison arm of every measurement this project makes is
# another run, and a run that changed models partway through cannot be compared
# with anything, including itself.
if [ -n "${RUN_DIR:-}" ] && [ -f "$RUN_DIR/run.json" ]; then
  DECLARED_DIGEST="$(jq -r --arg r "$ROLE" '.conditions[$r].digest // empty' "$RUN_DIR/run.json" 2>/dev/null || true)"
  if [ -n "$DECLARED_DIGEST" ] && [ "$DECLARED_DIGEST" != "$MODEL_DIGEST" ]; then
    printf 'STEP   %s   MODEL CHANGED under this run.\n' "$STEP" >&2
    printf '       role %s: the run started on %s and ollama now serves %s for %s.\n' \
      "$ROLE" "$DECLARED_DIGEST" "$MODEL_DIGEST" "$ROLE_MODEL" >&2
    printf '       Earlier steps of this run used the other weights. Both are recorded\n' >&2
    printf '       truthfully and the run as a whole is no longer one experiment, so it\n' >&2
    printf '       stops here rather than finishing something that cannot be compared.\n' >&2
    printf '       Start a fresh run, or re-pull %s to restore %s.\n' "$ROLE_MODEL" "$DECLARED_DIGEST" >&2
    exit 1
  fi
fi

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
# silent injection is not.
#
# --no-skills is here as of 2026-09-17, and it took a live probe rather than a
# stub to earn it: with `--no-skills --skill <dir>`, an explicit skill still
# loads and still invokes by name. Measured with gpt-oss:20b on a skill whose
# whole content was "answer with exactly one word: PINEAPPLE-7", invoked as
# `/skill:probe-skill`, which answered PINEAPPLE-7. Discovery off, explicit path
# on.
#
# So the worker now reaches NOTHING it was not handed. The collision check below
# stays anyway — it costs a directory listing, and a guard removed because
# another guard covers it is a guard removed on the assumption that the other one
# never changes.
HARNESS_FLAGS=( --no-extensions --no-prompt-templates --no-context-files
                --no-skills
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
STEP_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
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
# What this step exists to produce, and what those files looked like before it
# ran. Both halves matter, and the second was missing: a doc attempt that wrote
# nothing was reported as "its output IS present", because a previous attempt's
# file was still on disk. The diagnostic was true about the directory and false
# about the attempt, which is worse than saying nothing — it sent the next
# reader looking for a crash after the work rather than for work that never
# happened.
EXPECTED=""
case "$STEP" in
  spec)       EXPECTED="$RUN_DIR/spec.md $RUN_DIR/tasks.yaml" ;;
  doc)        EXPECTED="$RUN_DIR/impl-detail.md" ;;
  build-task) EXPECTED="" ;;   # its output is the diff, checked by containment
esac
BEFORE_SUMS=()
for f in $EXPECTED; do
  if [ -s "$f" ]; then
    BEFORE_SUMS+=( "$(sha256sum "$f" | cut -d' ' -f1)" )
  else
    BEFORE_SUMS+=( "-" )
  fi
done

# Load the model at the context this role declares, before pi asks for it.
#
# pi has no context flag, so ollama serves whatever it was last asked for — and a
# real run recorded `declared=65536 observed=262144`. The run record has been
# honest about that since 2026-09-14 and unable to do anything about it. The API
# does take `options.num_ctx` per request and the loaded instance keeps it, which
# is why /api/ps reports the judge at exactly the number judge.sh asks for; so the
# controller loads the model deliberately and pi reuses what is loaded.
#
# Advisory here, not fatal. If the server will not honour the context, the honest
# outcome is the drift this already reports rather than a halted run — the step
# can still do its work at another context, and `conditions.declared_matches_observed`
# is where a reader finds out. FACTORY_ENSURE_LOADED=0 turns it off.
# Only for a contained step, which is the only kind that is a real run, and only
# once the gateway is open — see the call site below.
#
# The first version preloaded unconditionally and the test suite went from two
# minutes to over ten: every stubbed step asked ollama to load a 64GB model, on a
# box where the GPU was busy with a measurement. Tests set
# FACTORY_CONTAIN_WORKER=0 and the line refuses to run uncontained without an
# explicit opt-out, so containment is the honest signal for "a model is actually
# about to be asked something" — and preloading 64GB for a shell stub is wrong
# whether or not a test is watching.
ensure_role_loaded() {
  [ "${FACTORY_ENSURE_LOADED:-1}" = 1 ] || return 0
  [ -x "$PIPELINE_DIR/ensure-loaded.sh" ] || return 0
  local el_rc=0
  ROLES_FILE="$ROLES_FILE" "$PIPELINE_DIR/ensure-loaded.sh" "$ROLE" >&2 || el_rc=$?
  [ "$el_rc" -ge 2 ] && printf 'WARN   %s   could not preload %s; the step runs at whatever context the server has\n' \
    "$STEP" "$ROLE_MODEL" >&2
  return 0
}

if [ "$CONTAIN" = 1 ]; then
  GW_DIR="${FACTORY_MODEL_SOCKET_DIR:-}"
  GW_STARTED=0
  if [ -z "$GW_DIR" ]; then
    GW_DIR="$("$PIPELINE_DIR/model-gateway.sh" start)" || die "could not open a model gateway; refusing to run the worker uncontained"
    GW_STARTED=1
  fi
  # Load after the gateway, not before it. Loading first meant a run whose
  # gateway would not open had already spent the minutes it takes to put 64GB on
  # the GPU, for a step that then died. Nothing between here and the worker needs
  # the model; the gateway is the cheap thing and it goes first.
  ensure_role_loaded
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
  # Turn off pi's HTTP idle timeout, which is five minutes and is wrong here.
  #
  # pi configures undici with `headersTimeout` and `bodyTimeout` set from
  # DEFAULT_HTTP_IDLE_TIMEOUT_MS = 300000, so a gap of five minutes between body
  # chunks aborts the request. Against a frontier endpoint that gap means a dead
  # connection. Against a 27B Q8 on this box it means the model is thinking, and
  # pi's own settings text says so: "Disable for local models that pause longer
  # than five minutes."
  #
  # Measured on bean-004, 2026-09-22. Four consecutive spec turns died, each one
  # after the model had finished reasoning and announced it was about to write
  # tasks.yaml. pi recorded stopReason=error, errorMessage="terminated", usage
  # all zeros. Ollama recorded HTTP 200, truncated = 0, 36.5k-39.5k tokens
  # against a 65536 window, and then `srv stop: cancel task` AFTER the handler
  # had returned — the signature of a client that hung up, not a server that
  # failed. Three of the four ran 5m07s, 5m11s and 5m16s.
  #
  # Written here rather than in ~/.pi/agent/settings.json for the same reason
  # the context window is written above: that file belongs to the user, and this
  # one is the controller's to write. The contained worker gets no settings.json
  # at all today, so it takes the default either way.
  #
  # Disabling is bounded, and that is what makes it safe rather than hopeful:
  # worker-sandbox.sh holds a 3600s wall clock over the whole session, so a
  # request that genuinely hangs still dies — with the step failing on a wall
  # clock the controller set, instead of on a transport default nobody chose.
  jq -n '{httpIdleTimeoutMs: 0}' > "$AGENT_DIR/settings.json" \
    || die "could not write the contained worker's settings.json"

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
  # The worker's wall clock, which until now nothing could set.
  #
  # worker-sandbox.sh defaults to 3600s and this call passed no --timeout, so an
  # hour was the limit for every step of every bean, chosen by a default rather
  # than by anyone. bean-004's task-2 hit it six times in eleven attempts --
  # 3630s each, no compaction involved at 131072 -- while the three attempts that
  # DID finish were each within one lint finding of done. An hour is not a
  # property of the work; it was a property of this line having no way to say
  # otherwise.
  #
  # Config first so it is a per-repository fact recorded in the repository, the
  # same shape as verify_timeout_s; the environment for a one-off; 3600 when
  # neither says anything, so nothing changes for a repo that does not care.
  WORKER_TIMEOUT_S="${FACTORY_WORKER_TIMEOUT:-}"
  if [ -z "$WORKER_TIMEOUT_S" ] && [ -n "${PIPELINE_CONFIG:-}" ] && [ -f "$PIPELINE_CONFIG" ]; then
    WORKER_TIMEOUT_S="$(jq -r '.worker_timeout_s // empty' "$PIPELINE_CONFIG" 2>/dev/null || true)"
  fi
  [ -n "$WORKER_TIMEOUT_S" ] || WORKER_TIMEOUT_S=3600
  case "$WORKER_TIMEOUT_S" in
    ''|*[!0-9]*) die "worker_timeout_s must be a whole number of seconds, got '$WORKER_TIMEOUT_S'" ;;
  esac

  "$PIPELINE_DIR/worker-sandbox.sh" \
    --tree "$ROOT" --agent-dir "$AGENT_DIR" --socket-dir "$GW_DIR" \
    --skills "$FACTORY_SKILLS" --lock "$WORKER_LOCK" --timeout "$WORKER_TIMEOUT_S" \
    -- "${CARGS[@]}" -p "$CPROMPT" </dev/null
  RC=$?
  [ "$GW_STARTED" = 1 ] && "$PIPELINE_DIR/model-gateway.sh" stop --dir "$GW_DIR" >/dev/null 2>&1
  [ "$RC" -eq 5 ] && die "the worker sandbox refused; the step did NOT run on the host instead"
else
  "$BIN" "${PI_ARGS[@]}" -p "$PROMPT" </dev/null
  RC=$?
fi
set -e

# Did THIS attempt write what the step exists to produce? Computed here, before
# any verdict is derived, because the answer changes what the exit code means.
MISSING=""; STALE=""; FRESH=""
_i=0
for _f in $EXPECTED; do
  _before="${BEFORE_SUMS[$_i]:--}"
  _i=$((_i + 1))
  if [ ! -s "$_f" ]; then
    MISSING="$MISSING $(basename "$_f")"
  elif [ "$(sha256sum "$_f" | cut -d' ' -f1)" = "$_before" ]; then
    STALE="$STALE $(basename "$_f")"
  else
    FRESH="$FRESH $(basename "$_f")"
  fi
done
# Nothing missing, and at least one output written during THIS attempt.
#
# It used to require every output to be fresh, and that is wrong on a retry. The
# guard exists for a session that narrates an intention and stops — a doc step
# once spent thirty-seven minutes saying "From now on, I'll create the
# documentation" and wrote nothing. What proves that did not happen is one
# output written now, not all of them.
#
# bean-002 halted on this. The spec-check found one finding, in spec.md's
# "Current behaviour"; the worker fixed exactly that, said in its report that
# tasks.yaml had no findings against it and was therefore unchanged — which was
# true and correct — and the run failed the attempt for not rewriting a file that
# did not need rewriting. A rule that punishes a minimal, targeted edit teaches
# the opposite of what this line wants.
#
# STALE is still computed and still printed. An attempt that leaves something
# untouched is worth seeing; it is just not, by itself, an attempt that did
# nothing.
OUTPUT_FRESH=0
[ -n "$EXPECTED" ] && [ -z "$MISSING" ] && [ -n "$FRESH" ] && OUTPUT_FRESH=1

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
# (There was a `false && ...` line here that added num_ctx to drift and could
# never run. Dead code guarded by a literal false reads as live code to everyone
# who greps for the variable, and the decision it encoded — that the server
# context is not drift — is now written down above and tested. Deleted rather
# than left switched off.)
[ -n "$OBS_MODEL" ] && [ "$OBS_MODEL" != "$ROLE_MODEL" ] \
  && drift="$drift model(declared=$ROLE_MODEL observed=$OBS_MODEL)"
[ -n "$drift" ] && printf 'WARN   %s   conditions drift:%s — the run record carries the observed values\n' \
  "$STEP" "$drift" >&2

# -- bookkeeping in steps.jsonl --------------------------------------------------------
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

# verdict_from_rc — the exit code, unless the step produced its output anyway.
#
# The exit status of a `pi -p` session is fallback evidence, which this file
# already says a few lines down about a verdict the child stamped. It is the same
# for a step whose output is a file: a doc session wrote a complete 18KB document,
# printed its report, and then returned 143 — seventeen minutes of model time
# thrown away over a signal that arrived after the work was finished.
#
# This is safe because it is not the last word. Everything a step produces is
# checked by the controller immediately afterwards — doc-check reads the document,
# spec-check reads the spec — so a half-written file fails on its contents rather
# than being accepted on its timestamp. What changes is only which check gets to
# make that decision: the one that reads the file, rather than an exit code.
verdict_from_rc() {
  if [ "$RC" -eq 0 ]; then
    END_VERDICT="PASS"
  elif [ "$OUTPUT_FRESH" = 1 ]; then
    END_VERDICT="PASS"
    printf 'NOTE   %s   exited %s AFTER writing%s. The output is what this step is for,\n' \
      "$STEP" "$RC" "$FRESH" >&2
    printf '       and the checks that read it run next; the exit code is not the last word.\n' >&2
  else
    END_VERDICT="FAIL"
  fi
}

# End verdict for *this* attempt.
END_VERDICT=""
# An `audit-*` step used to be read out of verdicts/<target>.attempt-N.json here.
# That branch went with the audit routing above: audits are judge.sh's, and
# orchestrate.sh stamps their verdicts itself. Nothing reachable from here has a
# verdict file, so reading one would have been reading someone else's.
if [ "$CHILD_ENDS" -gt 0 ]; then
  # Honour a verdict THIS child stamped; otherwise stamp from rc. A verdict from
  # an earlier attempt is not this attempt's result.
  EXISTING="$(jq -rs --arg s "$STEP" '[.[] | select(.step == $s and .event == "end")] | last.verdict' "$STEPS")"
  if [ -z "$EXISTING" ] || [ "$EXISTING" = "null" ]; then
    verdict_from_rc
  else
    END_VERDICT="$EXISTING"
  fi
else
  verdict_from_rc
fi

if [ "$CHILD_ENDS" -gt 0 ] && [ "$CHILD_STARTS" -eq "$CHILD_ENDS" ]; then
  : # this child opened and closed its own attempt: the amend below stamps it
else
  if [ "$CHILD_STARTS" -eq 0 ]; then
    # Written now, stamped with when the child actually started. Without this
    # every model step recorded zero elapsed, because both boundaries are written
    # here after the work is done.
    STEP_TS="$STEP_STARTED_AT" "$PIPELINE_DIR/step.sh" "$RUN_DIR" "$STEP" start
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
  --argjson dur "$(( $(date +%s) - T0 ))" \
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
        # num_ctx was in this comparison and is out again, with a measurement
        # behind the decision this time.
        #
        # It was added because the field is named declared_matches_observed and
        # num_ctx is both declared and observed, so excluding it looked like the
        # summary lying about itself. The consequence: the flag read false on
        # every step of every run, and factory status printed (conditions
        # drifted) beside every line. A flag that is false always is not a
        # summary, it is noise, and it trains a reader to stop looking.
        #
        # What the journal says, measured on bean-002 on 2026-09-17:
        #
        #   17:24:02  load_model: initializing, n_slots = 1, n_ctx_slot = 65536
        #   17:24:10  load_model: initializing, n_slots = 1, n_ctx_slot = 262144
        #
        # The controller preloads the role at its declared context; EIGHT SECONDS
        # LATER the workers own first request reloads the model at the servers
        # default, and every request in the session runs there. This was the open
        # question in RESUME - whether pi keeps the loaded context or forces a
        # reload - and the answer is the reload. pi speaks the
        # openai-completions API, which has no field for the server side context,
        # so nothing the controller does inside a session can hold it.
        #
        # So the two numbers differing is the NORMAL case and not drift. It is
        # still worth recording, which is what server_ctx_honoured is for: same
        # fact, its own name, no longer dragging the other two down with it.
        # Fixing it for real means OLLAMA_CONTEXT_LENGTH on the server, which is
        # one number for every role and every other project on the machine.
        #
        # (No apostrophes in this comment. The whole jq program is one
        # single-quoted shell string and one apostrophe ends it. Sixth time.)
        declared_matches_observed:
          ((($obs_thinking == "") or ($thinking == "") or ($obs_thinking == $thinking))
           and (($obs_model == "") or ($obs_model == $model))),
        server_ctx_honoured:
          (if ($obs_ctx == null) or ($ctx == null) then null else ($obs_ctx == $ctx) end)}')" \
  '
  . as $arr
  | ([ to_entries[] | select(.value.step == $s and .value.event == "end") | .key ]) as $idx
  | if ($idx | length) == 0 then $arr
    else
      $arr | .[ ($idx | last) ] |=
          ( .session_file = (if $sf == "" then null else $sf end)
          | .verdict = (if $v == "" then .verdict else $v end)
          # One clock reading, not the difference between two records.
          #
          # Elapsed time has been derived by subtracting the ts on the start line
          # from the ts on the end line, which is right when both were written
          # when they say and wrong in a way nothing notices when they were not.
          # (No apostrophes: this whole jq program is one single-quoted shell
          # string, and one apostrophe ends it. Fourth time in this repository.)
          # On the first
          # complete run every build-task attempt read 0s — the pair written six
          # milliseconds apart after work that took 947, 89 and 95 seconds — while
          # the `build` step wrapping them read 1136s. A per-attempt duration of
          # zero is the number every later question about cost reads from.
          #
          # This is measured in the process that ran the step, from before the
          # child to after it, and does not depend on the start line being right.
          #
          # The 0s readings themselves have since been explained, and it was not
          # the contained path misbehaving as the commit that added this guessed:
          # the run used a pipeline snapshot taken at 19:20, and STEP_STARTED_AT
          # landed at 20:37. The steps that read zero ran at 20:06. A run copies
          # the pipeline at launch and finishes on the code it started with, which
          # is the point of snapshotting and also means a record can be evidence
          # about a version of the line that no longer exists.
          #
          # Kept anyway. Two independent numbers that must agree is a better
          # record than one derived from two timestamps, and the next reason a
          # boundary is wrong will not be this one.
          | .duration_s = $dur
          | .conditions = $cond )
    end
  | .[]
  ' "$STEPS" > "$STEPS.tmp"
mv "$STEPS.tmp" "$STEPS"

# -- exit code ------------------------------------------------------------------------
# BEAN-127: the exit code must follow the verdict that was written to
# steps.jsonl. A child that stamped PASS
# and exited non-zero is still a PASS — the raw `pi -p` exit status is
# fallback evidence (used to derive the verdict when the child stamped
# nothing), never an override of a verdict it did stamp. A step recorded
# FAIL exits non-zero regardless of RC (a child could stamp FAIL and exit 0);
# a child that stamped nothing and exited non-zero yielded FAIL above and
# still halts the run — the spec-timeout path is preserved.
if [ "$END_VERDICT" = "PASS" ]; then
  if [ "$RC" -ne 0 ] && [ "$OUTPUT_FRESH" = 1 ]; then
    printf 'STEP   %s   PASS   child exited %s after writing%s — the output stands\n' \
      "$STEP" "$RC" "$FRESH"
  elif [ "$RC" -ne 0 ]; then
    printf 'STEP   %s   PASS   child exited %s but recorded PASS — the stamped verdict wins\n' "$STEP" "$RC"
  else
    printf 'STEP   %s   PASS   session=%s\n' "$STEP" "${SESSION_FILE:--}"
  fi
  exit 0
fi
# Say what the step was for and whether it did it.
#
# "child exit 1" is true and useless. A real doc step spent thirty-seven minutes
# and fifteen turns, ended with the model saying "From now on, I'll create the
# documentation", and exited — having written nothing. The run recorded `child
# exit 1`, which reads like a crash, and the actually useful fact (the file it
# exists to produce is not there) was only discoverable by going to look.
#
# A model that narrates an intention and stops is a specific failure with a
# specific fix, and it is invisible unless the expected output is named.
# MISSING, STALE and FRESH were settled before the verdict was derived; a step
# that reaches here produced nothing new, or it would have passed.
printf 'STEP   %s   FAIL   child exit %s session=%s\n' "$STEP" "$RC" "${SESSION_FILE:--}" >&2
if [ -n "$MISSING" ] || [ -n "$STALE" ]; then
  if [ -n "$MISSING" ]; then
    printf '       It produced none of what it exists to produce:%s\n' "$MISSING" >&2
  fi
  if [ -n "$STALE" ]; then
    # The trap this closes: the file is there, so the step looks like it worked
    # and broke afterwards. It is byte-for-byte what an earlier attempt left.
    #
    # Reaching here means NOTHING was fresh — an attempt that rewrote one of its
    # outputs and left another alone is a pass, because leaving a file that had
    # no findings against it alone is the right answer on a retry.
    printf '       Unchanged since before this attempt started:%s\n' "$STALE" >&2
    printf '       Those files are a previous attempt'"'"'s, and nothing else was written.\n' >&2
  fi
  printf '       A session that ends without writing its output has usually described what\n' >&2
  printf '       it was about to do rather than doing it. The transcript is in the session\n' >&2
  printf '       file above; its last message is the place to look.\n' >&2
elif [ -n "$FRESH" ]; then
  printf '       It did write what it exists to produce (%s) during this attempt,\n' "${FRESH# }" >&2
  printf '       so this is a failure after the work rather than instead of it.\n' >&2
fi
exit 1
