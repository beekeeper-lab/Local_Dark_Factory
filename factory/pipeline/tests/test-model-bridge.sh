#!/usr/bin/env bash
# test-model-bridge.sh — the worker's one way out.
#
# The container has no routes at all: `--network=none`, and a single unix socket
# bridged to ollama by this program. Everything the containment claim rests on is
# the claim that this forwards to exactly one place and cannot be talked into a
# second. It is 86 lines for that reason, and it had no tests.
#
# What is testable without a container: that it forwards faithfully in both
# directions, that a request larger than one buffer arrives whole, that a client
# finishing its request still gets to read the response (half-close, not
# destroy), that it survives an upstream that is not there, and that its
# destination is fixed at start and not read from anything a caller sends.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PIPELINE_PYTHON:-python3}"
WORK="$(mktemp -d)"
BRIDGE_PID=""; UP_PID=""; UP2_PID=""
cleanup() {
  for p in "$BRIDGE_PID" "$UP_PID" "$UP2_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# An upstream that answers like ollama does: reads a request, writes a response,
# and records what it was asked so the test can prove the bytes arrived whole.
cat > "$WORK/upstream.py" <<'PY'
import http.server, json, sys
SEEN = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        open(SEEN, "wb").write(body)
        out = json.dumps({"ok": True, "received": len(body), "path": self.path}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
UP_PORT=18821
"$PY" "$WORK/upstream.py" "$UP_PORT" "$WORK/seen.bin" & UP_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null -X POST "http://127.0.0.1:$UP_PORT/api/chat" -d '{}' && break
  sleep 0.1
done

SOCK="$WORK/model.sock"
"$PY" "$PIPELINE_DIR/model-bridge.py" "$SOCK" 127.0.0.1 "$UP_PORT" > "$WORK/bridge.log" 2>&1 & BRIDGE_PID=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done

# --------------------------------------------------------------------------
printf '\n== it forwards, and says where ==\n\n'
want "the socket exists"               "the bridge should have bound its socket" test -S "$SOCK"
check "and it announces its one destination" "$SOCK -> 127.0.0.1:$UP_PORT" "$(cat "$WORK/bridge.log")"
# 0666 deliberately: the container runs as the invoking user under --userns=keep-id,
# so 0600 would do today, and a socket that stops working when that changes would
# fail in a way that looks like the model.
eq "the socket is world-accessible on purpose" "666" "$(stat -c %a "$SOCK")"

out="$(curl -s --unix-socket "$SOCK" -X POST "http://localhost/api/chat" -d '{"model":"x"}')"
check "a request reaches upstream"     '"ok": true' "$out"
check "and the response comes back"    '"received": 13' "$out"
eq "the body arrived byte for byte"    '{"model":"x"}' "$(cat "$WORK/seen.bin")"
check "including the path"             '"path": "/api/chat"' "$out"

# --------------------------------------------------------------------------
printf '\n== a request larger than one buffer arrives whole ==\n\n'
#
# The pump reads 65536 at a time. A judge prompt with six artifacts in it is
# several hundred kilobytes, so "it worked on a small one" proves nothing about
# the case that actually runs.
"$PY" - "$WORK/big.json" <<'PY'
import json, sys
json.dump({"model": "x", "messages": [{"role": "user", "content": "y" * 400000}]},
          open(sys.argv[1], "w"))
PY
BIG_LEN="$(wc -c < "$WORK/big.json")"
out="$(curl -s --unix-socket "$SOCK" -X POST "http://localhost/api/chat" --data-binary @"$WORK/big.json")"
check "the big request is answered"    '"ok": true' "$out"
eq "with every byte of it"             "$BIG_LEN" "$(jq -r '.received' <<<"$out")"
eq "and the bytes are the same bytes"  "$(sha256sum < "$WORK/big.json" | cut -d' ' -f1)" \
   "$(sha256sum < "$WORK/seen.bin" | cut -d' ' -f1)"

# --------------------------------------------------------------------------
printf '\n== a client that finishes its request still gets to read ==\n\n'
#
# Half-close rather than destroy. Closing both directions when one side finishes
# turns a completed call into a truncated one, which a caller reads as the model
# having said something strange.
out="$("$PY" - "$SOCK" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
body = b'{"model":"x"}'
s.sendall(b"POST /api/chat HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n%s"
          % (len(body), body))
s.shutdown(socket.SHUT_WR)          # "I am done sending" — the case that matters
data = b""
while True:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
print(data.decode("utf-8", "replace"))
PY
)"
check "the response survives a half-close" '"ok": true' "$out"
check "and it is a complete HTTP response" "HTTP/1.0 200" "$out"

# --------------------------------------------------------------------------
printf '\n== it still serves after each of those ==\n\n'
#
# A forwarder that handles one connection and then wedges would look identical to
# a working one for the length of a single step.
for i in 1 2 3; do
  out="$(curl -s --unix-socket "$SOCK" -X POST "http://localhost/api/chat" -d "{\"n\":$i}")"
  check "connection $i is served"      '"ok": true' "$out"
done
want "the bridge is still running"     "it must not exit after a connection" kill -0 "$BRIDGE_PID"

# --------------------------------------------------------------------------
printf '\n== an upstream that is not there ==\n\n'
#
# The worker sees a closed connection either way. Saying why on the host is the
# difference between "the model is down" and "the model said something strange"
# when the log is read afterwards.
SOCK2="$WORK/dead.sock"
"$PY" "$PIPELINE_DIR/model-bridge.py" "$SOCK2" 127.0.0.1 1 > "$WORK/dead.log" 2>&1 & UP2_PID=$!
for _ in $(seq 1 50); do [ -S "$SOCK2" ] && break; sleep 0.1; done
curl -s --max-time 5 --unix-socket "$SOCK2" -X POST "http://localhost/api/chat" -d '{}' >/dev/null 2>&1
for _ in $(seq 1 30); do grep -q 'cannot reach' "$WORK/dead.log" 2>/dev/null && break; sleep 0.1; done
check "it says it could not reach upstream" "cannot reach 127.0.0.1:1" "$(cat "$WORK/dead.log")"
want "and it stays up for the next attempt" "one unreachable call must not end the bridge" \
     kill -0 "$UP2_PID"

# --------------------------------------------------------------------------
printf '\n== the destination is fixed at start ==\n\n'
#
# This is the containment claim. There is no routing, no header parsing and no
# configuration read at runtime, so a request naming another host is forwarded to
# the one address the bridge was started with — as a request, exactly as sent.
printf 'x' > "$WORK/seen.bin"
out="$(curl -s --unix-socket "$SOCK" -X POST "http://evil.example.com/api/chat" -d '{"to":"elsewhere"}')"
check "a request for another host still answers" '"ok": true' "$out"
eq "from the one upstream it was given"  '{"to":"elsewhere"}' "$(cat "$WORK/seen.bin")"
# And nothing in the program reads an address from anywhere but argv.
src="$(cat "$PIPELINE_DIR/model-bridge.py")"
for forbidden in "os.environ" "open(" "json.load" "subprocess" "import requests"; do
  if grep -qF -- "$forbidden" <<<"$src"; then
    printf '  FAIL  the bridge must not reach for %s\n' "$forbidden"; FAIL=$((FAIL+1))
  else
    printf '  ok    it does not use %s\n' "$forbidden"; PASS=$((PASS+1))
  fi
done

# --------------------------------------------------------------------------
printf '\n== refusals ==\n\n'
out="$("$PY" "$PIPELINE_DIR/model-bridge.py" 2>&1)"; rc=$?
rc_is "no arguments refuses"           "$rc" 2
check "with the usage line"            "usage: model-bridge.py" "$out"
# A unix address is 108 bytes in the kernel struct; a path that does not fit is
# silently truncated by some libcs, which binds a socket nobody can find.
LONG="$WORK/$(printf 'x%.0s' $(seq 1 120)).sock"
out="$("$PY" "$PIPELINE_DIR/model-bridge.py" "$LONG" 127.0.0.1 "$UP_PORT" 2>&1)"; rc=$?
rc_is "an over-long socket path refuses" "$rc" 2
check "and says why"                   "will not fit in a unix address" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
