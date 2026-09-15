#!/bin/sh
# Start the one route out, then become pi.
#
# The forwarder has to be running before pi makes its first request and has to
# die with the container. Backgrounding it and exec'ing pi does both: pi becomes
# PID 1, and when it exits the container tears down whatever else is in there.
set -e
node /usr/local/lib/model-socket.js &
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
exec pi "$@"
