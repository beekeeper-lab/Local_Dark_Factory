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

# ------------------------------------------------------------------------------
# The inference manager (Phase 4, task 3): eviction in the serial regime, the
# health check, retries, and the load record. A server with state this time:
# what is loaded, the digests /api/tags reports, how many loads to fail, and
# whether a probe answers.
cat > "$WORK/server2.py" <<'PY'
import http.server, json, sys
ST = sys.argv[2]
def st(): return json.load(open(ST))
def save(s): json.dump(s, open(ST, "w"))
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        s = st()
        if self.path.startswith("/api/tags"):
            self._send({"models": [{"name": m, "digest": d} for m, d in s["digests"].items()]})
        else:
            self._send({"models": [{"name": m, "context_length": c} for m, c in s["loaded"].items()]})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        s = st(); s.setdefault("log", []).append({"path": self.path, "model": body.get("model"),
                                                  "keep_alive": body.get("keep_alive")})
        m = body.get("model")
        if self.path == "/api/generate" and body.get("keep_alive") == 0:
            s["loaded"].pop(m, None); save(s); return self._send({"done": True})
        if self.path == "/api/chat":
            if s.get("fail_loads", 0) > 0:
                s["fail_loads"] -= 1; save(s); return self._send({"error": "load failed"})
            s["loaded"][m] = (body.get("options") or {}).get("num_ctx", 2048); save(s)
            return self._send({"done": True})
        save(s)  # the probe
        return self._send({"done": s.get("probe_ok", True), "response": "OK"})
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT2=18954
python3 "$WORK/server2.py" "$PORT2" "$WORK/st.json" & SERVER2_PID=$!
trap 'kill "$SERVER2_PID" 2>/dev/null; cleanup' EXIT
cat > "$WORK/roles2.json" <<'RJ'
{"provider_allowlist":["ollama"],
 "roles":{"developer":{"provider":"ollama","model":"dev:1b","num_ctx":65536},
          "judge":{"provider":"ollama","model":"judge:1b","num_ctx":32768}}}
RJ
server_is() { # server_is <json>
  jq -c '. + {log: []}' <<<"$1" > "$WORK/st.json"
}
el2() { OLLAMA_HOST="http://127.0.0.1:$PORT2" ROLES_FILE="$WORK/roles2.json" \
        bash "$PIPELINE_DIR/ensure-loaded.sh" "$@" 2>&1; }
for _ in $(seq 1 50); do server_is '{"loaded":{},"digests":{}}'; curl -s -o /dev/null "http://127.0.0.1:$PORT2/api/ps" && break; sleep 0.1; done

printf '\n== serial regime: the other role goes first ==\n\n'
server_is '{"loaded":{"dev:1b":65536},"digests":{"dev:1b":"sha256:aaaa1111bbbb","judge:1b":"sha256:cccc2222dddd"}}'
out="$(el2 judge --record "$WORK/loads.jsonl")"; rc=$?
rc_is "the judge loads"                 "$rc" 0
check "after the developer is evicted"  "EVICTED  dev:1b" "$out"
check "and only the judge is resident"  '["judge:1b"]' "$(jq -c '.loaded | keys' "$WORK/st.json")"
check "the eviction preceded the load"  '"keep_alive":0' "$(jq -c '.log[0]' "$WORK/st.json")"
check "the load is recorded"            '"outcome":"loaded"' "$(tail -1 "$WORK/loads.jsonl")"
check "with what it evicted"            '"evicted":["dev:1b"]' "$(tail -1 "$WORK/loads.jsonl")"
check "and how long it took"            '"load_seconds":' "$(tail -1 "$WORK/loads.jsonl")"
server_is '{"loaded":{"dev:1b":65536},"digests":{}}'
out="$(el2 judge --coresident)"
check "co-resident evicts nothing"      '["dev:1b","judge:1b"]' "$(jq -c '.loaded | keys' "$WORK/st.json")"

printf '\n== a failed load is retried, then reported ==\n\n'
server_is '{"loaded":{},"digests":{},"fail_loads":1}'
out="$(el2 judge --retries 2 --record "$WORK/loads.jsonl")"; rc=$?
rc_is "one failure, then it loads"      "$rc" 0
check "and the attempts are counted"    '"load_attempts":2' "$(tail -1 "$WORK/loads.jsonl")"
server_is '{"loaded":{},"digests":{},"fail_loads":9}'
out="$(el2 judge --retries 1 --record "$WORK/loads.jsonl")"; rc=$?
rc_is "past the retries it gives up"    "$rc" 2
check "and says which attempt"          "attempt 2 of 2" "$out"
check "the failure is recorded"         '"outcome":"load_failed"' "$(tail -1 "$WORK/loads.jsonl")"

printf '\n== the health check ==\n\n'
server_is '{"loaded":{"judge:1b":32768},"digests":{"judge:1b":"sha256:cccc2222dddd"}}'
out="$(el2 judge --healthcheck --expect-digest cccc2222dddd)"; rc=$?
rc_is "the right digest and an answer"  "$rc" 0
check "is healthy"                      "HEALTHY  judge:1b" "$out"
out="$(el2 judge --healthcheck --expect-digest 999999999999)"; rc=$?
rc_is "a different digest is unhealthy" "$rc" 3
check "and it says never proceed"       "never proceed on the wrong model" "$out"
server_is '{"loaded":{"judge:1b":32768},"digests":{"judge:1b":"sha256:cccc2222dddd"},"probe_ok":false}'
out="$(el2 judge --healthcheck)"; rc=$?
rc_is "no answer to the probe is unhealthy" "$rc" 3
check "and says so"                     "no answer to a one-token probe" "$out"
server_is '{"loaded":{"judge:1b":32768},"digests":{}}'
out="$(el2 judge --healthcheck)"; rc=$?
rc_is "a model missing from tags is unhealthy" "$rc" 3

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
