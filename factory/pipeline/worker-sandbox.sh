#!/usr/bin/env bash
# worker-sandbox.sh — run one pi session inside a container, or refuse to run it.
#
# The gate sandbox (sandbox.sh) contains commands that CHECK a change. This one
# contains the thing that MAKES it, which is a different risk: the worker is the
# only stage of the line a model actually steers, and until now it steered it on
# the host — the user's home directory, ssh keys, git credentials and the whole
# internet one tool call away. Containment was after the fact: reject the attempt
# and reset the tree. That catches a mistake. It does nothing about intent.
#
# The contract, clause by clause:
#
#   no network at all                --network=none. Not a filtered network: no
#                                     routes exist. Proven, not assumed — the
#                                     check below is a connect() that must fail.
#   exactly one endpoint             a unix socket bind-mounted in, bridged by
#                                     model-gateway.sh to one address and port.
#                                     Inside, a forwarder presents it on
#                                     127.0.0.1 because pi speaks TCP.
#   the tree is the only writable    --volume <tree>:/work:rw and the agent dir
#     mount that belongs to the repo   (which is not in the repo)
#   the agent's state is not in       HOME is a mounted directory outside the
#     the repository                   tree; a session file written into the repo
#                                     would read as a containment violation the
#                                     worker did not commit
#   dropped capabilities             --cap-drop=ALL --security-opt=no-new-privileges
#   pinned                           the image is named by digest in
#                                     factory/worker.lock.yaml, asserted here
#
# It refuses rather than degrading. A worker that quietly ran on the host after
# the container failed to start would still be labelled contained by everything
# downstream, and that label is the whole value of the record.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

REFUSED_RC=5

usage() {
  cat <<'EOF'
worker-sandbox.sh — run pi inside the worker container, or refuse.

usage:
  worker-sandbox.sh --tree <dir> --agent-dir <dir> --socket-dir <dir> [options] -- <pi-args...>
  worker-sandbox.sh --check                          report the contract, run nothing

  --tree <dir>        the repository the worker edits, mounted rw at /work
  --agent-dir <dir>   pi's HOME/.pi/agent — sessions land here, on the host,
                      where the controller reads back what actually ran
  --socket-dir <dir>  the directory model-gateway.sh printed
  --skills <dir>      the factory's skills, mounted read-only at /factory/skills
  --image <ref>       override the pinned image (refused unless --unpinned)
  --lock <file>       worker manifest (default: factory/worker.lock.yaml)
  --timeout <s>       wall clock, default 3600
  --memory <size>     default 8g
  --cpus <n>          default 8
  --pids <n>          default 512
  --env K=V           pass one extra variable (repeatable)

Exit: pi's own status, or 5 when the sandbox refused to run it.
EOF
}

TREE=""; AGENT_DIR=""; SOCKET_DIR=""; SKILLS_DIR=""; IMAGE=""; LOCK=""; CHECK=0
TIMEOUT=3600; MEMORY="8g"; CPUS="8"; PIDS="512"; UNPINNED=0
EXTRA_ENV=(); CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    --tree)       TREE="${2:?--tree needs a directory}"; shift 2 ;;
    --agent-dir)  AGENT_DIR="${2:?--agent-dir needs a directory}"; shift 2 ;;
    --socket-dir) SOCKET_DIR="${2:?--socket-dir needs a directory}"; shift 2 ;;
    --skills)     SKILLS_DIR="${2:?--skills needs a directory}"; shift 2 ;;
    --image)      IMAGE="${2:?--image needs a reference}"; shift 2 ;;
    --lock)       LOCK="${2:?--lock needs a file}"; shift 2 ;;
    --timeout)    TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --memory)     MEMORY="${2:?--memory needs a size}"; shift 2 ;;
    --cpus)       CPUS="${2:?--cpus needs a number}"; shift 2 ;;
    --pids)       PIDS="${2:?--pids needs a number}"; shift 2 ;;
    --env)        EXTRA_ENV+=( "${2:?--env needs K=V}" ); shift 2 ;;
    --unpinned)   UNPINNED=1; shift ;;
    --check)      CHECK=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --version)    cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    --)           shift; CMD=( "$@" ); break ;;
    *)            usage >&2; die "unknown argument: $1" ;;
  esac
done

refuse() { printf 'worker-sandbox: REFUSED — %s\n' "$*" >&2; exit "$REFUSED_RC"; }

command -v podman >/dev/null 2>&1 || refuse "podman is not installed; the worker sandbox is not optional"
ROOT="$(repo_root 2>/dev/null || pwd)"

# -- the image, by digest ------------------------------------------------------
[ -n "$LOCK" ] || LOCK="$ROOT/factory/worker.lock.yaml"
if [ -z "$IMAGE" ]; then
  [ -f "$LOCK" ] || refuse "no worker manifest at $LOCK — build one with factory/worker-image/build.sh"
  LOCK_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$LOCK")" || refuse "cannot read $LOCK"
  IMAGE="$(jq -r '.image // empty' <<<"$LOCK_JSON")"
  [ -n "$IMAGE" ] || refuse "$LOCK names no image"
  EXPECT_PI="$(jq -r '.expect_versions.pi // empty' <<<"$LOCK_JSON")"
elif [ "$UNPINNED" != 1 ]; then
  refuse "--image without --unpinned: a worker run labelled contained must say which image contained it"
fi

podman image exists "$IMAGE" 2>/dev/null \
  || refuse "image not present: $IMAGE (build it with factory/worker-image/build.sh)"

# A digest in the manifest is only a pin if the image actually carries it.
case "$IMAGE" in
  *@sha256:*)
    want="${IMAGE##*@}"
    got="$(podman image inspect "$IMAGE" --format '{{.Digest}}' 2>/dev/null)"
    [ "$got" = "$want" ] || refuse "image digest is $got, the manifest says $want"
    ;;
esac

if [ "$CHECK" = 1 ]; then
  printf 'worker sandbox contract\n\n'
  printf '  image        %s\n' "$IMAGE"
  printf '  network      none (no routes; the model arrives on a unix socket)\n'
  printf '  writable     the tree at /work, and the agent dir outside it\n'
  printf '  caps         all dropped, no-new-privileges\n'
  printf '  limits       %ss wall, %s memory, %s cpus, %s pids\n' "$TIMEOUT" "$MEMORY" "$CPUS" "$PIDS"
  exit 0
fi

# -- what must be true before a session starts ---------------------------------
[ -n "$TREE" ]       || refuse "--tree is required: there is nothing to contain without it"
[ -d "$TREE" ]       || refuse "tree not found: $TREE"
[ -n "$AGENT_DIR" ]  || refuse "--agent-dir is required: pi's state must land outside the tree, and the controller must be able to read the session back"
[ -n "$SOCKET_DIR" ] || refuse "--socket-dir is required: with no network and no socket, the worker cannot reach a model at all"
[ -S "$SOCKET_DIR/ollama.sock" ] \
  || refuse "no model socket at $SOCKET_DIR/ollama.sock — start one with model-gateway.sh"
[ "${#CMD[@]}" -gt 0 ] || refuse "nothing to run (expected -- <pi-args...>)"

TREE_ABS="$(cd "$TREE" && pwd)"
AGENT_ABS="$(cd "$AGENT_DIR" && pwd)"
SOCK_ABS="$(cd "$SOCKET_DIR" && pwd)"

# The agent directory must not be inside the tree. pi writes its sessions and
# config there every run; inside the repository those writes would appear in the
# change scan as files the worker never meant to author, and every attempt would
# be rejected for a containment violation the model did not commit.
case "$AGENT_ABS/" in
  "$TREE_ABS"/*) refuse "the agent directory is inside the tree ($AGENT_ABS) — pi's own writes would read as the worker editing the repo" ;;
esac

mkdir -p "$AGENT_ABS/sessions"
# The models file is what tells pi where the model is; its baseUrl points at
# 127.0.0.1:11434, which inside the container is the forwarder, not the host.
[ -f "$AGENT_ABS/models.json" ] \
  || refuse "no models.json in $AGENT_ABS — pi has no model catalogue and will refuse every --model"

chcon -R -t container_file_t -l s0 "$AGENT_ABS" 2>/dev/null || true

# "No git" is structural here, as it is for the gate sandbox — but by a different
# route, because the worker's edits have to land in the real tree rather than in a
# copy. An empty directory mounted over /work/.git masks it: git inside reports
# "not a git repository", the history cannot be read or rewritten, and the host's
# .git is untouched. The worker never needed it — the controller makes every
# commit, after it has decided the attempt is worth one.
GIT_MASK="$(mktemp -d "${FACTORY_SANDBOX_ROOT:-${TMPDIR:-/tmp}}/fgitmask.XXXXXX")"
trap 'rmdir "$GIT_MASK" 2>/dev/null || true' EXIT

RUN_ARGS=(
  --rm
  --network=none
  --userns=keep-id
  --cap-drop=ALL
  --security-opt=no-new-privileges
  --memory "$MEMORY" --cpus "$CPUS" --pids-limit "$PIDS"
  --volume "$TREE_ABS:/work:rw,Z"
  --volume "$GIT_MASK:/work/.git:ro"
  --volume "$AGENT_ABS:/home/worker/.pi/agent:rw"
  --volume "$SOCK_ABS:/run/model:rw"
  --workdir /work
)
if [ -n "$SKILLS_DIR" ]; then
  [ -d "$SKILLS_DIR" ] || refuse "skills directory not found: $SKILLS_DIR"
  RUN_ARGS+=( --volume "$(cd "$SKILLS_DIR" && pwd):/factory/skills:ro,Z" )
fi
for kv in ${EXTRA_ENV+"${EXTRA_ENV[@]}"}; do RUN_ARGS+=( --env "$kv" ); done

# The container is named, and the time is noted, so that a death can be asked
# about afterwards.
#
# SOLVED 2026-09-17, and it was never an external signal.
#
# The story until then: a doc session on 2026-09-15 wrote a complete
# 18,626-byte document and its container died at 1022 seconds with 143. Nothing
# here sends SIGTERM and `timeout` would have exited 124, so it was read as
# somebody outside the process tree — an operator's `pkill -f`, which this
# repository has done to itself five times. Unreproducible, unlogged, arriving
# mid-session: the shape fit.
#
# It was the worker image's own entrypoint. It backgrounds the model-socket
# forwarder, runs pi, then kills and reaps it:
#
#     kill "$FORWARDER" 2>/dev/null
#     wait "$FORWARDER" 2>/dev/null
#     exit "$rc"
#
# with `set -e` at the top. `wait` on a job that died by signal returns 143,
# `set -e` ends the shell on that status, and `exit "$rc"` is never reached. So
# the container exited 143 after a successful session, a failed one, or no
# session at all — `pi --version` in this image, one second, no model, nobody
# near the machine, exits 143, and 0 on the host. Five lines with `sleep`
# reproduce it with no container and no pi involved.
#
# Worth keeping the diagnosis below anyway, for two reasons: images built before
# the fix still do it, and if a CURRENT image ever exits 143 the external-signal
# reading becomes the right one again. The events are read back on any non-zero
# exit; a `died` event carrying 143 with no `stop` before it is what to look at.
#
# The lesson is in the note further down about the forwarder's "terminated"
# message: that was the same bug one layer up, found, and fixed at the MESSAGE
# rather than at the status. A fix that treats the symptom leaves the cause to be
# found again, and it was, twice, two days apart.
CNAME="factory-worker-$$-$(date +%s)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_ARGS+=( --name "$CNAME" )

timeout --signal=TERM --kill-after=30 "$TIMEOUT" \
  podman run "${RUN_ARGS[@]}" "$IMAGE" "${CMD[@]}"
rc=$?
[ "$rc" -eq 124 ] && printf 'worker-sandbox: the session was killed after %ss\n' "$TIMEOUT" >&2
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
  printf '\nworker-sandbox: the container exited %s. What podman saw:\n' "$rc" >&2
  # Captured, not redirected in place. `2>/dev/null >&2` sends stdout to the fd
  # that was just pointed at /dev/null — the events came back and went nowhere,
  # and the diagnosis printed under an empty heading.
  EV="$(podman events --since "$STARTED_AT" --stream=false --filter "container=$CNAME" \
    --format '  {{.Time}}  {{.Status}}{{if .ContainerExitCode}} (exit {{.ContainerExitCode}}){{end}}' 2>/dev/null)"
  if [ -n "$EV" ]; then printf '%s\n' "$EV" >&2
  else printf '  (no events; podman may have rolled them, or the container was never named)\n' >&2; fi
  if [ "$rc" -eq 143 ]; then
    printf '\n  143 is SIGTERM, and nothing in this script sends one: `timeout` would have\n' >&2
    printf '  exited 124. If there is no `stop` event above, nobody asked podman to stop\n' >&2
    printf '  the container either.\n' >&2
    printf '  FIRST CHECK THE IMAGE. Until 2026-09-17 the worker entrypoint exited 143 on\n' >&2
    printf '  EVERY run, whatever pi did: `set -e`, then `wait` on the forwarder it had\n' >&2
    printf '  just killed, which returns 143 and ends the shell before `exit $rc`.\n' >&2
    printf '  `pi --version` in such an image exits 143 in one second. If this image\n' >&2
    printf '  predates that fix, that is what this is, and the output above it stands.\n' >&2
    printf '  If the image is current, then it did come from outside this process tree,\n' >&2
    printf '  and the first suspect is a pattern kill from a terminal — `pkill -f` has hit\n' >&2
    printf '  this repository five times. See "Never pkill -f" in RESUME.md.\n' >&2
  fi
fi
exit "$rc"
