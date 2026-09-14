#!/usr/bin/env bash
# test-sandbox.sh — every clause of the §08 sandbox contract, asserted.
#
# A sandbox is the one component where "it looked fine" is worthless. Each test
# here tries to do the thing the contract forbids and requires the attempt to
# fail — not the command to be absent, not the flag to be present in the podman
# arguments, but the escape itself to not work.
#
# Needs podman and the gate image (factory/gate-image/build.sh).
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATES="$PIPELINE_DIR/../scaffold/factory/gates.lock.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nocheck() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — the sandbox allowed: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}

if ! command -v podman >/dev/null 2>&1; then
  echo "podman not installed — the sandbox cannot be tested, and must not be assumed" >&2
  exit 1
fi

TREE="$WORK/tree"
mkdir -p "$TREE"
echo "print('inside')" > "$TREE/a.py"

sb() { bash "$PIPELINE_DIR/sandbox.sh" --tree "$TREE" --gates "$GATES" "$@" 2>&1; }

printf '\n== it runs, and the tree is writable ==\n\n'
out="$(sb -- python a.py)"
check "the command runs"              "inside" "$out"
out="$(sb -- sh -c 'echo written-by-the-sandbox > out.txt && cat out.txt')"
check "the tree is writable"          "written-by-the-sandbox" "$out"
want  "and the write reaches the host" "the file did not appear outside the container" \
  test -f "$TREE/out.txt"

printf '\n== everything outside the tree is read-only ==\n\n'
out="$(sb -- sh -c 'touch /escaped 2>&1')"
check "cannot write to /"             "Read-only file system" "$out"
out="$(sb -- sh -c 'touch /usr/bin/escaped 2>&1')"
check "cannot write to /usr/bin"      "Read-only file system" "$out"
out="$(sb -- sh -c 'echo x > /etc/passwd 2>&1')"
check "cannot write to /etc/passwd"   "Read-only" "$out"

printf '\n== the host filesystem is not there at all ==\n\n'
out="$(sb -- sh -c 'ls /home 2>&1; echo "---"; ls "'"$WORK"'" 2>&1')"
nocheck "the host home is not mounted"      "gregg" "$out"
nocheck "the work directory is not visible" "tree" "${out#*---}"
# Ask whether the socket EXISTS, not whether the word appears: `ls` prints the
# path it could not find, so grepping its error output for "docker.sock" finds
# the string in the very message proving the socket is absent.
out="$(sb -- sh -c 'for s in /var/run/docker.sock /run/docker.sock /run/user/1000/podman/podman.sock; do [ -S "$s" ] && echo "FOUND $s"; done; echo scanned')"
check   "the check ran"               "scanned" "$out"
nocheck "no container socket of any kind" "FOUND" "$out"
out="$(sb -- sh -c 'echo "SSH_AUTH_SOCK=[${SSH_AUTH_SOCK:-unset}]"')"
check "no SSH agent forwarded"        "SSH_AUTH_SOCK=[unset]" "$out"

printf '\n== no network by default ==\n\n'
out="$(sb -- python -c 'import socket
try:
    socket.create_connection(("1.1.1.1", 53), 2); print("REACHED THE INTERNET")
except OSError as e: print("blocked:", e)')"
check "the internet is unreachable"   "blocked:" "$out"
nocheck "and definitely not reached"  "REACHED THE INTERNET" "$out"
out="$(sb -- python -c 'import socket
try:
    socket.create_connection(("127.0.0.1", 11434), 2); print("REACHED OLLAMA")
except OSError as e: print("blocked:", e)')"
nocheck "the model endpoint is unreachable too" "REACHED OLLAMA" "$out"

printf '\n== no credentials, and a scrubbed environment ==\n\n'
export GITHUB_TOKEN="ghp_pretend_this_is_real"
export AWS_SECRET_ACCESS_KEY="pretend"
export MY_OWN_SECRET="pretend"
out="$(sb -- sh -c 'env')"
nocheck "the host GITHUB_TOKEN does not leak"  "ghp_pretend_this_is_real" "$out"
nocheck "no AWS secret leaks"                  "AWS_SECRET_ACCESS_KEY" "$out"
nocheck "no unrelated host variable leaks"     "MY_OWN_SECRET" "$out"
check   "only the named variables are present" "HOME=/tmp" "$out"
unset GITHUB_TOKEN AWS_SECRET_ACCESS_KEY MY_OWN_SECRET

out="$(sb --env "GITHUB_TOKEN=x" -- true)"
check "passing a token is refused"     "looks like a credential" "$out"
out="$(sb --env "OPENAI_API_KEY=x" -- true)"
check "so is an API key"               "looks like a credential" "$out"
out="$(sb --env "BEAN_ID=bean-001" -- sh -c 'echo "got [$BEAN_ID]"')"
check "an innocuous variable is allowed" "got [bean-001]" "$out"

printf '\n== no privileges to escalate ==\n\n'
out="$(sb -- sh -c 'grep CapEff /proc/self/status')"
check "every capability is dropped"    "CapEff:	0000000000000000" "$out"
out="$(sb -- sh -c 'grep NoNewPrivs /proc/self/status')"
check "no-new-privileges is set"       "NoNewPrivs:	1" "$out"
uid="$(sb -- id -u | head -1 | tr -dc '0-9')"
want "not running as root"             "the container ran as uid 0" test "${uid:-0}" -ne 0

printf '\n== git is absent structurally, not by instruction ==\n\n'
out="$(sb -- sh -c 'command -v git || echo "no git binary"')"
check "the image has no git"           "no git binary" "$out"
mkdir -p "$WORK/withgit/.git"
out="$(bash "$PIPELINE_DIR/sandbox.sh" --tree "$WORK/withgit" --gates "$GATES" -- true 2>&1)"
check "a tree with .git is refused"    "still has a .git" "$out"
bash "$PIPELINE_DIR/sandbox.sh" --tree "$WORK/withgit" --gates "$GATES" -- true >/dev/null 2>&1
want "and refusal has its own exit code" "expected 5" test "$?" -eq 5

printf '\n== the image must be pinned, and must be the pinned one ==\n\n'
out="$(bash "$PIPELINE_DIR/sandbox.sh" --tree "$TREE" --image "localhost/factory-gate-python:20260914" -- true 2>&1)"
check "an unpinned image is refused"   "is not pinned by digest" "$out"
out="$(bash "$PIPELINE_DIR/sandbox.sh" --tree "$TREE" \
  --image "localhost/factory-gate-python:20260914@sha256:$(printf '0%.0s' {1..64})" -- true 2>&1)"
check "a wrong digest is refused"      "the gate image was replaced under the manifest" "$out"

printf '\n== the limits are real ==\n\n'
out="$(sb --timeout 3 -- sleep 30)"
check "the wall clock kills a hang"    "exceeded the 3s wall clock" "$out"

out="$(sb --memory 64m -- python -c 'x = bytearray(512 * 1024 * 1024); print("ALLOCATED")' 2>&1)"
nocheck "a memory limit is enforced"   "ALLOCATED" "$out"

out="$(sb --max-output 2000 -- python -c 'print("x" * 100000)')"
check "output is truncated"            "[sandbox: output truncated at 2000 bytes" "$out"
want  "and the truncation is bounded"  "the output cap did not hold" \
  test "${#out}" -lt 4000

printf '\n== --check reports the contract without running anything ==\n\n'
out="$(bash "$PIPELINE_DIR/sandbox.sh" --check --tree "$TREE" --gates "$GATES" 2>&1)"
check "it names the pinned image"      "@sha256:" "$out"
check "it asserts git is absent"       "git in image    absent (asserted)" "$out"
check "it names the limits"            "capabilities    all dropped" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
