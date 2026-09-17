#!/bin/sh
# Start the one route out, then become pi.
#
# The forwarder has to be running before pi makes its first request and has to
# die with the container. Backgrounding it and exec'ing pi does both: pi becomes
# PID 1, and when it exits the container tears down whatever else is in there.
set -e
# `disown`-equivalent: the forwarder is a background job, and when pi exits the
# shell reports its death as "terminated" on the way out. That line appears in
# the run log immediately before the step's failure and reads like something
# external killed the container — it cost a real diagnosis session, including
# checking podman's event log for a signal that was never sent. The container had
# exited 1 of its own accord.
node /usr/local/lib/model-socket.js 2>/dev/null &
FORWARDER=$!
# Wait for the listener rather than racing it. pi's first request happens within
# milliseconds of startup, and a connection refused there looks to the model like
# a configuration error rather than a startup order problem.
i=0
while [ "$i" -lt 50 ]; do
  if node -e 'require("net").createConnection(Number(process.env.MODEL_PORT||11434),"127.0.0.1").on("connect",function(){process.exit(0)}).on("error",function(){process.exit(1)})' 2>/dev/null; then
    break
  fi
  i=$((i+1))
  sleep 0.1
done
[ "$i" -lt 50 ] || { echo "model-socket never came up" >&2; exit 1; }
# Not exec: pi has to return so the forwarder can be reaped quietly rather than
# killed noisily when PID 1 vanishes.
# `if`, not a bare call: `set -e` aborts the script the moment a bare `pi "$@"`
# returns non-zero, so on every failed session the two lines below — the ones
# that reap the forwarder — were skipped entirely. Inside a container that is
# survivable, because the forwarder dies with it. It still means the code that
# closes the one route out of the sandbox only ran when nothing had gone wrong,
# which is the wrong way round.
if pi "$@"; then rc=0; else rc=$?; fi
# `|| true` on both, and it is the whole bug that was open for two days.
#
# `set -e` is on. `kill` sends TERM to the forwarder and `wait` then reports the
# status of a job that died by signal: 143. Under `set -e` a non-zero status from
# `wait` ends the shell THERE, with 143, and `exit "$rc"` below was never
# reached. So every contained worker exited 143 — after a successful session, a
# failed one, or none at all: `pi --version`, one second, no model, nobody near
# the machine, exits 143 in this container and 0 on the host.
#
# It was read as an external SIGTERM for two days. RESUME named "a pattern kill
# from a terminal" as the first suspect and the note above this line describes
# the same shape of misdiagnosis, one layer down: that one fixed the MESSAGE the
# shell prints about the dying forwarder, and left the status it exits with.
# Reproduces in five lines with `sleep`, no container and no pi involved.
kill "$FORWARDER" 2>/dev/null || true
wait "$FORWARDER" 2>/dev/null || true
exit "$rc"
