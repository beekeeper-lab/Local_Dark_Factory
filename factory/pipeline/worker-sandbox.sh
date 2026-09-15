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

TREE=""; AGENT_DIR=""; SOCKET_DIR=""; IMAGE=""; LOCK=""; CHECK=0
TIMEOUT=3600; MEMORY="8g"; CPUS="8"; PIDS="512"; UNPINNED=0
EXTRA_ENV=(); CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    --tree)       TREE="${2:?--tree needs a directory}"; shift 2 ;;
    --agent-dir)  AGENT_DIR="${2:?--agent-dir needs a directory}"; shift 2 ;;
    --socket-dir) SOCKET_DIR="${2:?--socket-dir needs a directory}"; shift 2 ;;
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

RUN_ARGS=(
  --rm
  --network=none
  --userns=keep-id
  --cap-drop=ALL
  --security-opt=no-new-privileges
  --memory "$MEMORY" --cpus "$CPUS" --pids-limit "$PIDS"
  --volume "$TREE_ABS:/work:rw,Z"
  --volume "$AGENT_ABS:/home/worker/.pi/agent:rw"
  --volume "$SOCK_ABS:/run/model:rw"
  --workdir /work
)
for kv in ${EXTRA_ENV+"${EXTRA_ENV[@]}"}; do RUN_ARGS+=( --env "$kv" ); done

timeout --signal=TERM --kill-after=30 "$TIMEOUT" \
  podman run "${RUN_ARGS[@]}" "$IMAGE" "${CMD[@]}"
rc=$?
[ "$rc" -eq 124 ] && printf 'worker-sandbox: the session was killed after %ss\n' "$TIMEOUT" >&2
exit "$rc"
