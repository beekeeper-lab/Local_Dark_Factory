#!/usr/bin/env bash
# build.sh — build the gate image and print the line to paste into gates.lock.yaml.
#
# The manifest pins the image by digest, so this script exists to make that pin
# reproducible rather than remembered: it builds with the versions recorded in
# versions.env, reads the digest back out of the built image, and asserts that
# what is inside matches what the manifest will claim is inside. A gate image
# whose contents drift from its expect_versions is worse than an unpinned one —
# the manifest would be asserting something false.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-localhost/factory-gate-python}"
TAG="${TAG:-$(date -u +%Y%m%d)}"

# shellcheck source=versions.env
source "$HERE/versions.env"

echo "building $IMAGE_NAME:$TAG"
podman build \
  --build-arg "RUFF_VERSION=$RUFF_VERSION" \
  --build-arg "MYPY_VERSION=$MYPY_VERSION" \
  --build-arg "PYTEST_VERSION=$PYTEST_VERSION" \
  --build-arg "PYTEST_COV_VERSION=$PYTEST_COV_VERSION" \
  --build-arg "ORTOOLS_VERSION=$ORTOOLS_VERSION" \
  -t "$IMAGE_NAME:$TAG" \
  -f "$HERE/Containerfile" "$HERE"

# Assert the image contains what the manifest will say it contains.
echo "verifying the toolchain inside the image"
fail=0
check() { # check <label> <expected> <command...>
  local label="$1" expected="$2"; shift 2
  local got
  got="$(podman run --rm --network=none "$IMAGE_NAME:$TAG" "$@" 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
  if [ "$got" = "$expected" ]; then
    printf '  ok    %-12s %s\n' "$label" "$got"
  else
    printf '  FAIL  %-12s image has %s, versions.env says %s\n' "$label" "${got:-<none>}" "$expected"
    fail=1
  fi
}
check ruff       "$RUFF_VERSION"       ruff --version
check mypy       "$MYPY_VERSION"       mypy --version
check pytest     "$PYTEST_VERSION"     pytest --version
check ortools    "$ORTOOLS_VERSION"    python -c 'import ortools; print(ortools.__version__)'
[ "$fail" -eq 0 ] || { echo "refusing to print a digest for an image whose contents do not match versions.env" >&2; exit 1; }

DIGEST="$(podman inspect "$IMAGE_NAME:$TAG" --format '{{.Digest}}')"
echo
echo "image line for factory/gates.lock.yaml:"
echo "  image: \"$IMAGE_NAME:$TAG@$DIGEST\""
