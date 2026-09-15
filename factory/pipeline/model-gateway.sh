#!/usr/bin/env bash
# model-gateway.sh — the worker's one way out, and the reason its container can
# run with no network at all.
#
# §08 wants the sandbox to have no network. The worker needs exactly one endpoint.
# Those look contradictory and are not: the container gets `--network=none`, which
# removes every route rather than filtering them, and the model arrives through a
# single unix socket bind-mounted into it. There is no interface to widen, no
# allow-list to edit, and no DNS. The only thing reachable is whatever this script
# was pointed at when it started.
#
# Why it runs under `runcon`. SELinux checks a unix socket connection against the
# *peer process's* context, not the socket file's label. A container (container_t)
# connecting to a socket held by an ordinary user process (unconfined_t) is
# denied, and relabelling the file does not help — measured, twice. Running the
# forwarder itself as container_t is what makes the connection legal, and it has
# the pleasant side effect of confining the forwarder too.
#
# The forwarder moves bytes and has no second destination. A worker that talks to
# it reaches the model the controller chose, or nothing.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

REFUSED_RC=5

usage() {
  cat <<'EOF'
model-gateway.sh — bridge one model endpoint into a network-less container.

usage:
  model-gateway.sh start [--upstream <host:port>] [--dir <dir>]
  model-gateway.sh stop  [--dir <dir>]
  model-gateway.sh check [--dir <dir>]

  --upstream <host:port>  where the model actually is (default: 127.0.0.1:11434)
  --dir <dir>             where the socket lives (default: a fresh dir under
                          $FACTORY_SANDBOX_ROOT, printed by `start`)

`start` prints the socket directory on stdout. Mount it into the worker
container; nothing else needs to pass between them.

Exit: 0 running · 5 refused (it will not start a gateway it cannot make safe).
EOF
}

CMD="${1:-}"; shift 2>/dev/null || true
case "$CMD" in
  -h|--help|"") usage; exit 0 ;;
  --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
esac

UPSTREAM="127.0.0.1:11434"
DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upstream) UPSTREAM="${2:?--upstream needs host:port}"; shift 2 ;;
    --dir)      DIR="${2:?--dir needs a path}"; shift 2 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

UP_HOST="${UPSTREAM%:*}"; UP_PORT="${UPSTREAM##*:}"
case "$UP_PORT" in ''|*[!0-9]*) die "upstream port is not a number: $UPSTREAM" ;; esac

refuse() { printf 'GATEWAY REFUSED  %s\n' "$1" >&2; exit "$REFUSED_RC"; }

# The socket path goes into a sockaddr_un, which is 108 bytes on Linux. A long
# run directory silently overflows it, and the error ("AF_UNIX path too long")
# arrives from a forwarder that never started rather than from here.
default_dir() {
  local base="${FACTORY_SANDBOX_ROOT:-${TMPDIR:-/tmp}}"
  mktemp -d "$base/fgw.XXXXXX"
}

case "$CMD" in
  start)
    require_cmd podman
    command -v runcon >/dev/null 2>&1 || refuse "runcon is not installed; without it the forwarder cannot run in a context a container may connect to"
    [ -n "$DIR" ] || DIR="$(default_dir)" || refuse "could not create a socket directory"
    SOCK="$DIR/ollama.sock"
    [ "${#SOCK}" -lt 100 ] || refuse "socket path is ${#SOCK} bytes, which will not fit in a unix address: $SOCK"

    # Is the upstream actually there? A gateway that starts against nothing hands
    # the worker a connection that is refused at first token, which reads like a
    # model failure rather than a setup one.
    (exec 3<>"/dev/tcp/$UP_HOST/$UP_PORT") 2>/dev/null \
      || refuse "nothing is listening on $UPSTREAM — start the model server first"

    cp "$PIPELINE_DIR/model-bridge.py" "$DIR/model-bridge.py" \
      || refuse "could not stage the forwarder into $DIR"
    # container_t cannot read the repository (user_home_t), so the forwarder runs
    # from the socket directory and that directory carries the container label.
    chcon -R -t container_file_t -l s0 "$DIR" 2>/dev/null \
      || refuse "could not label $DIR for container access (is SELinux present?)"

    runcon -t container_t python3 "$DIR/model-bridge.py" "$SOCK" "$UP_HOST" "$UP_PORT" \
      > "$DIR/gateway.log" 2>&1 &
    echo "$!" > "$DIR/gateway.pid"

    for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
    [ -S "$SOCK" ] || { cat "$DIR/gateway.log" >&2; refuse "the forwarder did not come up"; }
    chcon -t container_file_t -l s0 "$SOCK" 2>/dev/null || true

    printf 'GATEWAY  %s -> %s  (pid %s)\n' "$SOCK" "$UPSTREAM" "$(cat "$DIR/gateway.pid")" >&2
    printf '%s\n' "$DIR"
    ;;

  stop)
    [ -n "$DIR" ] || die "stop needs --dir (the directory start printed)"
    if [ -f "$DIR/gateway.pid" ]; then
      pid="$(cat "$DIR/gateway.pid")"
      # By pid, never by pattern. `pkill -f model-bridge` matches any shell whose
      # command line mentions it, including the one running this script — which
      # has killed a session here before.
      kill "$pid" 2>/dev/null || true
      rm -f "$DIR/gateway.pid"
    fi
    rm -f "$DIR/ollama.sock"
    ;;

  check)
    [ -n "$DIR" ] || die "check needs --dir"
    [ -S "$DIR/ollama.sock" ] || { printf 'no socket at %s/ollama.sock\n' "$DIR" >&2; exit 1; }
    pid="$(cat "$DIR/gateway.pid" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
      || { printf 'socket exists but the forwarder is gone (pid %s)\n' "${pid:-unknown}" >&2; exit 1; }
    printf 'gateway up: %s (pid %s)\n' "$DIR/ollama.sock" "$pid"
    ;;

  *) usage >&2; die "unknown command: $CMD" ;;
esac
