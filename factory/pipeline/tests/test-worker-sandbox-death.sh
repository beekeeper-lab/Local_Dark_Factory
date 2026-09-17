#!/usr/bin/env bash
# test-worker-sandbox-death.sh — what the sandbox says when the container dies.
#
# A doc session on 2026-09-15 wrote a complete 18,626-byte document and its
# container died at 1022 seconds with 143, and it was read for two days as a
# SIGTERM from outside. It was the worker image's own entrypoint: `set -e`, then
# `wait` on the forwarder it had just killed, which returns 143 and ends the
# shell before `exit "$rc"`. Every contained run exited 143 — including
# `pi --version`, in one second, with no model and nobody near the machine.
#
# So the diagnosis this script prints has to send a reader to the image FIRST,
# and only then to the external-signal reading, which is right again for a
# current image. These assertions are about that ordering — a diagnosis that
# names the rare cause before the certain one is a diagnosis that costs a day.
#
# podman is stubbed. The point is the message and the naming, not the runtime.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:300}"; FAIL=$((FAIL+1)); fi }
nope()  { if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
          else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi }
rc_is() { if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi }

mkdir -p "$WORK/bin" "$WORK/tree" "$WORK/agent" "$WORK/sock"
# A real socket: worker-sandbox tests it with `[ -S ]`, and an empty file is not
# one. It refuses before running anything otherwise, and every assertion below
# would then be about the refusal.
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$WORK/sock/ollama.sock"
export PATH="$WORK/bin:$PATH"

# A podman that reports the image present, exits with whatever PODMAN_RC says on
# `run`, and answers `events` from a file.
cat > "$WORK/bin/podman" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  image)  [ "${2:-}" = exists ] && exit 0 ;;
  inspect) printf '%s\n' "${FAKE_DIGEST:-sha256:deadbeef}"; exit 0 ;;
  events) cat "${FAKE_EVENTS:-/dev/null}"; exit 0 ;;
  run)
    # Remember the name it was given, so the test can assert the container is
    # identifiable at all — an unnamed container cannot be asked about later.
    while [ $# -gt 0 ]; do [ "$1" = --name ] && { printf '%s\n' "$2" > "$FAKE_NAMEFILE"; }; shift; done
    exit "${PODMAN_RC:-0}" ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/podman"
# Everything the sandbox refuses without, so the assertions below are about the
# death and not about a precondition. Each of these refusals is itself a feature
# and is asserted elsewhere.
printf '{"models":[]}\n' > "$WORK/agent/models.json"
export FAKE_NAMEFILE="$WORK/name"

ws() {
  bash "$PIPELINE_DIR/worker-sandbox.sh" --tree "$WORK/tree" --agent-dir "$WORK/agent" \
    --socket-dir "$WORK/sock" --image localhost/fake:1 --unpinned -- --version 2>&1
}

printf '\n== a container that dies is named, so it can be asked about ==\n\n'
printf '  2026-09-17 01:00:00  died (exit 143)\n' > "$WORK/events"
# Exported, not prefixed: `ws` is a function that runs bash as a child, and a
# prefix assignment on a function call does not reach it. The stub podman then
# reads no events file and the assertion is about the fixture.
export PODMAN_RC=143 FAKE_EVENTS="$WORK/events"
out="$(ws)"; rc=$?
rc_is "the exit code is passed through" "$rc" 143
if [ -s "$WORK/name" ]; then
  printf '  ok    the container was given a name (%s)\n' "$(cat "$WORK/name")"; PASS=$((PASS+1))
else
  printf '  FAIL  the container was not named — nothing can be asked about it afterwards\n'; FAIL=$((FAIL+1))
fi
check "and podman's own account is printed" "died (exit 143)" "$out"

printf '\n== 143 gets a diagnosis, not a number ==\n\n'
check "it says what 143 is"             "143 is SIGTERM" "$out"
check "and that this script did not send it" "nothing in this script sends one" "$out"
check "and rules out the timeout"       "exited 124" "$out"
check "it sends you to the image first"  "FIRST CHECK THE IMAGE" "$out"
check "naming the mechanism"            "wait" "$out"
check "and the one-second reproduction" "pi --version" "$out"
check "and it says the output stands"   "the output above it stands" "$out"
check "the external reading is kept"    "pattern kill from a terminal" "$out"
check "but only for a current image"    "If the image is current" "$out"
check "with where that is written down" "RESUME.md" "$out"

printf '\n== a clean exit says nothing at all ==\n\n'
export PODMAN_RC=0
out="$(ws)"; rc=$?
rc_is "it exits 0"                      "$rc" 0
nope  "and there is no diagnosis"       "143 is SIGTERM" "$out"
nope  "and no event dump"               "What podman saw" "$out"

printf '\n== any other failure gets the events, without the SIGTERM story ==\n\n'
printf '  2026-09-17 01:00:00  died (exit 1)\n' > "$WORK/events"
export PODMAN_RC=1
out="$(ws)"; rc=$?
rc_is "the code is passed through"      "$rc" 1
check "the events are still shown"      "What podman saw" "$out"
nope  "but 143's explanation is not"    "pattern kill from a terminal" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
