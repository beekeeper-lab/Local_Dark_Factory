#!/usr/bin/env bash
# build.sh — build the worker image and print the line to paste into worker.lock.yaml.
#
# Same discipline as the gate image, for a related but distinct reason. The gate
# is pinned because "the tests passed" is a claim about a toolchain. The worker
# is pinned because "the 27B could not finish this task" is a claim about an
# agent build: pi's tool set, its prompt scaffolding and its context handling all
# move between releases, and a blocked-bean record under a harness that no longer
# exists is an anecdote, not a measurement.
#
# So this refuses to print a digest for an image whose contents disagree with
# versions.env, and asserts the two properties the sandbox depends on: that the
# forwarder is present, and that there is no way out except through it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-localhost/factory-worker-pi}"
TAG="${TAG:-$(date -u +%Y%m%d)}"

# shellcheck source=versions.env
source "$HERE/versions.env"

echo "building $IMAGE_NAME:$TAG"
podman build \
  --build-arg "PI_VERSION=$PI_VERSION" \
  -t "$IMAGE_NAME:$TAG" \
  -f "$HERE/Containerfile" "$HERE"

echo "verifying what is inside the image"
fail=0
ok()  { printf '  ok    %-22s %s\n' "$1" "$2"; }
bad() { printf '  FAIL  %-22s %s\n' "$1" "$2"; fail=1; }

got="$(podman run --rm --network=none --entrypoint pi "$IMAGE_NAME:$TAG" --version 2>&1 | tr -d '\r' | head -1)"
[ "$got" = "$PI_VERSION" ] && ok "pi" "$got" || bad "pi" "image has ${got:-<none>}, versions.env says $PI_VERSION"

podman run --rm --network=none --entrypoint sh "$IMAGE_NAME:$TAG" -c 'test -f /usr/local/lib/model-socket.js' \
  && ok "forwarder present" "/usr/local/lib/model-socket.js" \
  || bad "forwarder present" "missing — the container would have no way to reach a model"

# The forwarder must refuse when no socket is mounted. A worker that starts
# without one would fail on its first request instead, which reads in the log
# like the model being down.
if podman run --rm --network=none "$IMAGE_NAME:$TAG" --version >/dev/null 2>&1; then
  bad "refuses with no socket" "it started anyway"
else
  ok "refuses with no socket" "the entrypoint stops rather than listening on nothing"
fi

# And with no routes, there is nothing else to reach. This is the clause the
# whole design rests on, so it is measured rather than asserted in a comment.
if podman run --rm --network=none --entrypoint node "$IMAGE_NAME:$TAG" \
     -e 'require("net").createConnection(443,"1.1.1.1").on("connect",()=>process.exit(1)).on("error",()=>process.exit(0))' 2>/dev/null; then
  ok "no network" "an outbound connect fails, as it must"
else
  bad "no network" "something outside the container was reachable"
fi

[ "$fail" -eq 0 ] || { echo "refusing to print a digest for an image that does not hold its contract" >&2; exit 1; }

DIGEST="$(podman inspect "$IMAGE_NAME:$TAG" --format '{{.Digest}}')"
echo
echo "image line for factory/worker.lock.yaml:"
echo "  image: \"$IMAGE_NAME:$TAG@$DIGEST\""
