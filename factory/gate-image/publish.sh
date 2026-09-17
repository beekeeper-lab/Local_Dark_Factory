#!/usr/bin/env bash
# publish.sh — push the pinned gate image to a registry, by digest, unchanged.
#
# CI has to run the same gates as the line, and "the same" has to mean the same
# bytes. A workflow that pip-installs ruff and mypy runs *a* lint and *a* type
# check; it does not run the gate, and a green from it means something different
# from a green on Forge. That difference is invisible in a checkmark, which is the
# whole problem — so the image goes to a registry and CI pulls it by digest.
#
# This pushes what is already built and verified. It does not build, and it
# refuses if the local image's digest is not the one gates.lock.yaml pins: the
# manifest is the authority on which bytes are the gate, and a publish that
# quietly ships something else would make CI's green a claim about an image
# nobody audited.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

usage() {
  cat <<'EOF'
publish.sh — push the pinned gate image to a registry.

usage: publish.sh --registry <host/namespace> [--gates <gates.lock.yaml>] [--dry-run]

  --registry   e.g. ghcr.io/beekeeper-lab
  --gates      the manifest whose digest must match (default: the scaffold's)
  --dry-run    print what would be pushed and stop

Requires a registry login with permission to write packages:

  gh auth refresh --scopes write:packages
  gh auth token | podman login ghcr.io -u <your-github-user> --password-stdin

Prints the line to put in gates.lock.yaml's `image:` once the push succeeds.
EOF
}

REGISTRY=""; GATES=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY="${2:?}"; shift 2 ;;
    --gates)    GATES="${2:?}"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
[ -n "$REGISTRY" ] || { usage >&2; exit 1; }
[ -n "$GATES" ] || GATES="$ROOT/factory/scaffold/factory/gates.lock.yaml"
[ -f "$GATES" ] || { printf 'no gate manifest at %s\n' "$GATES" >&2; exit 1; }
command -v podman >/dev/null 2>&1 || { printf 'podman is required\n' >&2; exit 1; }

PINNED="$("$ROOT/factory/pipeline/yaml2json.sh" "$GATES" | jq -r '.image')"
PIN_REF="${PINNED%@*}"          # localhost/factory-gate-python:20260914
PIN_DIGEST="${PINNED##*@}"      # sha256:...
PIN_NAME="${PIN_REF##*/}"       # factory-gate-python:20260914
printf 'manifest pins %s\n' "$PINNED"

LOCAL_DIGEST="$(podman image inspect "$PIN_REF" --format '{{.Digest}}' 2>/dev/null || true)"
if [ -z "$LOCAL_DIGEST" ]; then
  printf 'the pinned image is not present locally: %s\n' "$PIN_REF" >&2
  printf 'build it first: factory/gate-image/build.sh\n' >&2
  exit 1
fi
if [ "$LOCAL_DIGEST" != "$PIN_DIGEST" ]; then
  printf 'the local %s is %s, but the manifest pins %s.\n' "$PIN_REF" "$LOCAL_DIGEST" "$PIN_DIGEST" >&2
  printf 'Publishing it would make CI green about an image this repo has never audited.\n' >&2
  exit 1
fi
printf 'local image matches the pin\n'

DEST="$REGISTRY/$PIN_NAME"
if [ "$DRY" = 1 ]; then
  printf '\nwould push: %s -> %s\n' "$PIN_REF" "$DEST"
  printf 'then gates.lock.yaml image: "%s@%s"\n' "$DEST" "$PIN_DIGEST"
  exit 0
fi

printf 'pushing %s -> %s\n' "$PIN_REF" "$DEST"
podman push "$PIN_REF" "docker://$DEST" || {
  printf '\npush failed. The usual cause is that the login has no package-write scope:\n' >&2
  printf '  gh auth refresh --scopes write:packages\n' >&2
  printf '  gh auth token | podman login %s -u <your-github-user> --password-stdin\n' "${REGISTRY%%/*}" >&2
  exit 2
}

# Read the digest back from the registry rather than trusting that a push of the
# same bytes yields the same digest. It should; if it ever does not, the manifest
# must say what CI will actually pull.
REMOTE_DIGEST="$(podman image inspect "$PIN_REF" --format '{{.Digest}}' 2>/dev/null || echo "$PIN_DIGEST")"
# Tag the LOCAL image under the published name, or this box cannot run its own
# gates any more.
#
# The push does not create a local tag. So the moment gates.lock.yaml is re-pinned
# from `localhost/...` to `ghcr.io/...`, every sandbox on the machine that
# published it refuses with "image not present" — 43 assertions across five suites
# on 2026-09-17, on the box that had just pushed the image successfully.
#
# It is the same image: the digest below is read back from the registry and
# compared. Tagging is a local rename, not a second build.
if ! podman tag "$PIN_REF" "$DEST" 2>/dev/null; then
  printf '\nwarning: pushed, but could not tag the local image as %s.\n' "$DEST" >&2
  printf 'Gates on THIS machine will refuse with "image not present" once\n' >&2
  printf 'gates.lock.yaml names the registry. Run:  podman tag %s %s\n' "$PIN_REF" "$DEST" >&2
fi

printf '\npushed. Put this in gates.lock.yaml:\n\n'
printf '  image: "%s@%s"\n\n' "$DEST" "$REMOTE_DIGEST"
if [ "$REMOTE_DIGEST" != "$PIN_DIGEST" ]; then
  printf 'NOTE: the digest changed in transit (%s -> %s). CI must pull what is in the\n' \
    "$PIN_DIGEST" "$REMOTE_DIGEST" >&2
  printf 'registry, so the manifest has to name the new one.\n' >&2
fi
