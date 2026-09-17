#!/usr/bin/env bash
# test-ensure-loaded.sh — holding a role at the context it declares.
#
# `roles.json` has said `num_ctx: 65536` for the developer since 2026-09-15 and
# the run record has been reporting `observed=262144` beside it ever since —
# honest, and unable to do anything about it. The API takes `options.num_ctx`
# per request and the loaded instance keeps it, which is why /api/ps reports the
# judge at exactly the number judge.sh asks for.
#
# What must not happen is the fix quietly failing: a run that believes it holds a
# role at 65536 while the server holds it at 262144 has a conditions block that
# is fiction, which is worse than the honest drift it replaced.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# /api/ps answers from a file the test rewrites; /api/chat records the body it was
# given, so the assertions can be about what was actually asked for.
cat > "$WORK/server.py" <<'PY'
import http.server, sys
PS, SEEN = sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self._send(open(PS, "rb").read())
    def do_POST(self):
        open(SEEN, "wb").write(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        # A load request changes what /api/ps reports, which is what the real
        # server does. Racing that with a background `sleep` in the test made the
        # check read the old state and call a successful load a failure.
        import os
        after = PS + ".after"
        if os.path.exists(after):
            open(PS, "wb").write(open(after, "rb").read())
            os.unlink(after)
        self._send(b'{"model":"m","done":true,"message":{"role":"assistant","content":""}}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=18953
python3 "$WORK/server.py" "$PORT" "$WORK/ps.json" "$WORK/seen.json" & SERVER_PID=$!
printf '{"models":[]}' > "$WORK/ps.json"
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/api/ps" && break
  sleep 0.1
done

cat > "$WORK/roles.json" <<'RJ'
{"provider_allowlist":["ollama"],
 "roles":{"developer":{"provider":"ollama","model":"dev:1b","num_ctx":65536,"thinking":"low"},
          "nocxt":{"provider":"ollama","model":"other:1b"}}}
RJ
ps_says() { # ps_says <context or empty>
  if [ -z "$1" ]; then printf '{"models":[]}' > "$WORK/ps.json"
  else jq -nc --argjson c "$1" '{models:[{name:"dev:1b", context_length:$c}]}' > "$WORK/ps.json"; fi
}
el() { OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" \
       bash "$PIPELINE_DIR/ensure-loaded.sh" "$@" 2>&1; }

printf '\n== it loads at the declared context ==\n\n'
ps_says 65536
out="$(el developer)"; rc=$?
rc_is "it succeeds"                   "$rc" 0
check "and says what is held"         "already at 65536" "$out"

printf '\n-- and asks for exactly that when it has to load --\n\n'
ps_says ""
: > "$WORK/seen.json"
# What /api/ps will say once the load request arrives — applied by the server when
# it receives one, rather than raced against with a sleep.
jq -nc '{models:[{name:"dev:1b", context_length:65536}]}' > "$WORK/ps.json.after"
out="$(el developer)"; rc=$?
rc_is "it succeeds"                   "$rc" 0
check "the request names the model"   '"model":"dev:1b"' "$(cat "$WORK/seen.json")"
check "and the declared context"      '"num_ctx":65536' "$(cat "$WORK/seen.json")"
check "with an empty message list"    '"messages":[]' "$(cat "$WORK/seen.json")"
check "and a keep-alive"              '"keep_alive"' "$(cat "$WORK/seen.json")"
check "it says how long it is held"   "held for 60m" "$out"

printf '\n== a server that does not honour it is reported, not papered over ==\n\n'
#
# The failure this must not have: a run believing it holds a role at 65536 while
# the server holds it at 262144. That conditions block would be fiction, which is
# worse than the honest drift it replaced.
ps_says 262144
out="$(el developer)"; rc=$?
rc_is "it does not claim success"     "$rc" 1
check "it names both numbers"         "at 262144 after asking for 65536" "$out"
check "and says who did not honour it" "the server did not honour it" "$out"

printf '\n== a model that will not load at all ==\n\n'
ps_says ""
out="$(el developer)"; rc=$?
rc_is "it fails"                      "$rc" 2
check "and says the server reports it unloaded" "not loaded after the request" "$out"

printf '\n== --check-only loads nothing ==\n\n'
ps_says 65536
: > "$WORK/seen.json"
out="$(el developer --check-only)"; rc=$?
rc_is "it reports"                    "$rc" 0
check "what is loaded"                "at 65536" "$out"
if [ -s "$WORK/seen.json" ]; then
  printf '  FAIL  --check-only made a request\n'; FAIL=$((FAIL+1))
else
  printf '  ok    and made no request\n'; PASS=$((PASS+1))
fi

ps_says ""
out="$(el developer --check-only)"; rc=$?
rc_is "an unloaded model is exit 2"   "$rc" 2
check "and says so"                   "not loaded" "$out"

printf '\n== a role with no declared context ==\n\n'
#
# Nothing to assert, so nothing is asserted: it loads the model and says what the
# server chose, rather than inventing a number to compare against.
printf '{"models":[{"name":"other:1b","context_length":131072}]}' > "$WORK/ps.json"
out="$(el nocxt --check-only)"; rc=$?
rc_is "it does not fail"              "$rc" 0

printf '\n== refusals ==\n\n'
out="$(el no-such-role --check-only)"; rc=$?
rc_is "an unknown role refuses"       "$rc" 1
check "and says why"                  "no model for role" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
