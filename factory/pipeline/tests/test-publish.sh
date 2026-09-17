#!/usr/bin/env bash
# test-publish.sh — publishing the gate image must not break the box that did it.
#
# `podman push` does not create a local tag. So the moment gates.lock.yaml is
# re-pinned from `localhost/factory-gate-python` to
# `ghcr.io/<org>/factory-gate-python`, every sandbox on the publishing machine
# refuses with "image not present" — measured on 2026-09-17 as 43 assertions
# failing across five suites on the box that had just pushed the image
# successfully, with the image sitting right there under its old name.
#
# podman is stubbed: the point is the sequence and the message, not the runtime.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PIPELINE_DIR/../.." && pwd)"
PUB="$ROOT/factory/gate-image/publish.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:250}"; FAIL=$((FAIL+1)); fi }

[ -f "$PUB" ] || { printf '  SKIP  no publish.sh\n\n0 passed, 0 failed\n'; exit 0; }

printf '\n== it tags the local image under the published name ==\n\n'
#
# Asserted from the source: driving the real script needs a registry, and the
# thing that must not regress is that the tag step exists at all and is tied to
# the reason.
SRC="$(cat "$PUB")"
check "the tag step is there"        "podman tag" "$SRC"
check "and it targets the pushed name" 'podman tag "$PIN_REF" "$DEST"' "$SRC"
check "with what happens without it"  "image not present" "$SRC"
check "and the count that measured it" "43 assertions" "$SRC"
check "and it warns rather than failing the push" "warning: pushed, but could not tag" "$SRC"
check "telling the operator the command" 'podman tag %s %s' "$SRC"

printf '\n== the tag comes after a successful push, not before ==\n\n'
#
# A local rename that happens whether or not the push worked would leave the box
# pinned to an image no registry has.
_push_line="$(grep -n 'podman push' <<<"$SRC" | head -1 | cut -d: -f1)"
_tag_line="$(grep -n 'podman tag "\$PIN_REF"' <<<"$SRC" | head -1 | cut -d: -f1)"
if [ -n "$_push_line" ] && [ -n "$_tag_line" ] && [ "$_tag_line" -gt "$_push_line" ]; then
  printf '  ok    tag (line %s) follows push (line %s)\n' "$_tag_line" "$_push_line"; PASS=$((PASS+1))
else
  printf '  FAIL  the local tag does not follow the push: push=%s tag=%s\n' "${_push_line:-none}" "${_tag_line:-none}"; FAIL=$((FAIL+1))
fi

printf '\n== the manifest and the local store agree right now ==\n\n'
#
# The live check, and the one that would have caught this at the time: whatever
# gates.lock.yaml pins must exist locally, or every gate on this box is refused.
GATES="$ROOT/factory/scaffold/factory/gates.lock.yaml"
if [ -f "$GATES" ] && command -v podman >/dev/null 2>&1; then
  PINNED="$(sed -n 's/^image:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$GATES" | head -1)"
  REF="${PINNED%%@*}"
  if [ -z "$REF" ]; then
    printf '  FAIL  no image pinned in %s\n' "$GATES"; FAIL=$((FAIL+1))
  elif podman image exists "$REF" 2>/dev/null; then
    printf '  ok    the pinned image is in the local store (%s)\n' "$REF"; PASS=$((PASS+1))
  else
    printf '  FAIL  gates.lock.yaml pins %s and the local store has no such image — every gate on this box will refuse\n' "$REF"
    FAIL=$((FAIL+1))
  fi
else
  printf '  SKIP  no manifest or no podman\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
