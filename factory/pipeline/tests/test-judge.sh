#!/usr/bin/env bash
# test-judge.sh — what the judge path does with every shape of answer it gets.
#
# judge.sh is the only place in the line that talks to a model over HTTP rather
# than through pi, and its whole second half is a decision tree about responses:
# empty content, empty content at the token cap, tool calls instead of an answer,
# JSON that stops mid-object, JSON that is not a judgement, a runner that died
# mid-request. Every branch was written in response to something that actually
# happened on this box, and none of them had a test — they were verified by
# waiting for the failure to recur.
#
# A fake /api/chat makes them all reachable in milliseconds. What is being tested
# is not the model; it is whether the controller says the true thing about what
# came back, because the diagnostic is the whole value of a failed audit.
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
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# ---------------------------------------------------------------- fixtures --
REPO="$WORK/repo"; git init -q -b main "$REPO"; cd "$REPO"
git config user.email t@e.com; git config user.name T
R="$REPO/factory/runs/R"; mkdir -p "$R/verdicts"
printf '{"schema_version":"run/1.0.0","run_id":"R","bean_id":"bean-001"}\n' > "$R/run.json"
printf '# Spec\n\n## Proposed change\n\nSomething is proposed here at length.\n' > "$R/spec.md"
printf 'schema_version: tasks/1.0.0\ntasks:\n  - id: task-1\n    title: do it\n' > "$R/tasks.yaml"
printf 'schema_version: bean/2.0.0\nid: bean-001\ntitle: a thing\nintent: do a thing\n' > "$WORK/bean.yaml"
git add -A 2>/dev/null; git commit -q -m init 2>/dev/null

# `ollama list` is consulted for the digest before any request is made, so the
# stub has to exist even for tests that never reach the HTTP call.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ollama" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = list ] && printf 'test-judge:latest\tabc123def456\t1 GB\n'
exit 0
STUB
chmod +x "$WORK/bin/ollama"
export PATH="$WORK/bin:$PATH"

cat > "$WORK/roles.json" <<'JSON'
{
  "provider_allowlist": ["ollama"],
  "roles": {
    "judge": {"provider": "ollama", "model": "test-judge:latest", "num_ctx": 32768, "thinking": "medium"},
    "developer": {"provider": "ollama", "model": "test-judge:latest", "num_ctx": 32768, "thinking": "medium"}
  }
}
JSON

# A one-file /api/chat that replies with whatever is in $WORK/reply.json. The
# response is the variable under test, so it is a file the test rewrites rather
# than a server the test restarts.
cat > "$WORK/server.py" <<'PY'
import http.server, os, sys
REPLY = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = open(REPLY, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=18771
python3 "$WORK/server.py" "$PORT" "$WORK/reply.json" &
SERVER_PID=$!
printf '{}' > "$WORK/reply.json"
for _ in $(seq 1 50); do
  curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/api/chat" -d '{}' && break
  sleep 0.1
done

reply() { printf '%s' "$1" > "$WORK/reply.json"; }
judge() {
  ( cd "$REPO" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" \
    bash "$PIPELINE_DIR/judge.sh" factory/runs/R --target spec --bean "$WORK/bean.yaml" "$@" 2>&1 )
}
clean_verdicts() { rm -rf "$R/verdicts"; mkdir -p "$R/verdicts"; }

GOOD_JUDGEMENT='{"verdict":"accept","criteria":[{"id":"ac1","met":true,"evidence":"line 4 of the spec"}],"findings":[],"confidence":0.9}'

# --------------------------------------------------------------------------
printf '\n== a judgement the model actually wrote ==\n\n'
clean_verdicts
reply "$(jq -nc --arg c "$GOOD_JUDGEMENT" \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c, thinking:"brief"}}')"
out="$(judge)"; rc=$?
rc_is "it succeeds"                    "$rc" 0
want  "and writes the judgement"       "spec.attempt-1.judgement.json should exist" \
      test -f "$R/verdicts/spec.attempt-1.judgement.json"
check "the controller stamps the model" "test-judge:latest" \
      "$(cat "$R/verdicts/spec.attempt-1.judgement.json")"
check "and the digest it read from ollama" "abc123def456" \
      "$(cat "$R/verdicts/spec.attempt-1.judgement.json")"
check "the verdict survives intact"    '"verdict": "accept"' \
      "$(jq . "$R/verdicts/spec.attempt-1.judgement.json")"

printf '\n-- and a second call numbers itself rather than overwriting the first --\n\n'
out="$(judge)"; rc=$?
rc_is "it succeeds again"              "$rc" 0
want  "attempt 1 is still there"       "a judgement must never be overwritten" \
      test -f "$R/verdicts/spec.attempt-1.judgement.json"
want  "and attempt 2 is beside it"     "spec.attempt-2.judgement.json should exist" \
      test -f "$R/verdicts/spec.attempt-2.judgement.json"

# --------------------------------------------------------------------------
printf '\n== it reasoned and then said nothing ==\n\n'
#
# The live failure, twice in one evening: content empty, done_reason "stop",
# and a thinking field full of fluent prose about a different task. The old
# message printed the first 300 bytes of the raw response — which is 300 bytes of
# that thinking — so the error a person read was a confident paragraph about
# something else.
clean_verdicts
reply "$(jq -nc --arg t "We need to determine whether the code passes the tests. Let us open the repository." \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:"", thinking:$t}}')"
out="$(judge)"; rc=$?
rc_is "it fails"                       "$rc" 1
check "it says the turn ended"         "ended its turn" "$out"
check "and that this is not the cap"   "not the token cap" "$out"
check "and whose failure it is"        "the judge failing at the task" "$out"
check "and where the reasoning went"   "spec.thinking.txt" "$out"
want  "which is actually written"      "verdicts/spec.thinking.txt should exist" \
      test -s "$R/verdicts/spec.thinking.txt"
check "with the reasoning in it"       "open the repository" "$(cat "$R/verdicts/spec.thinking.txt")"
want  "and no judgement is invented"   "no judgement file may be written for a non-answer" \
      test ! -f "$R/verdicts/spec.attempt-1.judgement.json"

printf '\n-- an empty response with no reasoning either is a different failure --\n\n'
clean_verdicts
reply '{"model":"test-judge:latest","done":true,"done_reason":"stop","message":{"role":"assistant","content":"","thinking":""}}'
out="$(judge)"; rc=$?
rc_is "it fails"                       "$rc" 1
check "and says it is the server"      "server or model-loading problem" "$out"
nope  "not the judge"                  "the judge failing at the task" "$out"

# --------------------------------------------------------------------------
printf '\n== it ran out of room, which is ours to fix and not the judge'"'"'s ==\n\n'
#
# Exit 8, deliberately distinct from 1: the fitness harness must never score a
# budget we set too low as a judge that could not answer.
clean_verdicts
reply "$(jq -nc --arg t "thinking that went on and on" \
  '{model:"test-judge:latest", done:true, done_reason:"length", message:{role:"assistant", content:"", thinking:$t}}')"
out="$(judge)"; rc=$?
rc_is "exit 8, not 1"                  "$rc" 8
check "it names the budget"            "token budget thinking" "$out"
check "and what to raise"              "JUDGE_NUM_PREDICT" "$out"
want  "the reasoning is kept"          "verdicts/spec.thinking.txt should exist" \
      test -s "$R/verdicts/spec.thinking.txt"

printf '\n-- and JSON cut off mid-object is the same cause, not bad formatting --\n\n'
clean_verdicts
reply "$(jq -nc --arg c '{"verdict":"revise","criteria":[{"id":"ac1","met":false,"evidence":"the ruff check is present but not' \
  '{model:"test-judge:latest", done:true, done_reason:"length", message:{role:"assistant", content:$c, thinking:""}}')"
out="$(judge)"; rc=$?
rc_is "exit 8 again"                   "$rc" 8
check "it says cut off, not malformed" "cut off mid-answer" "$out"
nope  "and does not blame the schema"  "not JSON despite constrained decoding" "$out"
want  "what it managed is kept"        "verdicts/spec.truncated.json should exist" \
      test -s "$R/verdicts/spec.truncated.json"

# --------------------------------------------------------------------------
printf '\n== it tried to call tools that do not exist ==\n\n'
clean_verdicts
reply '{"model":"test-judge:latest","done":true,"done_reason":"stop","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"repo_browser.open_file"}},{"function":{"name":"repo_browser.search"}}]}}'
out="$(judge)"; rc=$?
rc_is "it fails"                       "$rc" 1
check "it counts them"                 "2 call(s)" "$out"
check "and names them"                 "repo_browser.open_file" "$out"
check "and says there are no tools"    "no tools on this path" "$out"

# --------------------------------------------------------------------------
printf '\n== it answered in JSON, but not with a judgement ==\n\n'
#
# Constrained decoding is a request, not a guarantee. A generic review shape —
# strengths, weaknesses, recommendations — is refused rather than coerced, and
# what the model sent is kept so the cause can be found.
clean_verdicts
reply "$(jq -nc --arg c '{"strengths":["clear"],"weaknesses":["vague"],"recommendations":["be less vague"]}' \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c}}')"
out="$(judge)"; rc=$?
rc_is "it fails"                       "$rc" 1
check "it names every missing field"   "missing: verdict criteria findings confidence" "$out"
check "and what it got instead"        "strengths" "$out"
want  "what it sent is kept"           "the rejected answer should be on disk" \
      test -s "$R/verdicts/spec.attempt-1.judgement.json.rejected"
want  "but not as a judgement"         "a rejected answer must not become the judgement" \
      test ! -f "$R/verdicts/spec.attempt-1.judgement.json"

printf '\n-- a partial judgement is still not a judgement --\n\n'
clean_verdicts
reply "$(jq -nc --arg c '{"verdict":"accept","findings":[]}' \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c}}')"
out="$(judge)"; rc=$?
rc_is "it fails"                       "$rc" 1
check "and names only what is absent"  "missing: criteria confidence" "$out"

# --------------------------------------------------------------------------
printf '\n== the runner died mid-request ==\n\n'
#
# Ollama answers 200 with a zero-valued struct when its runner dies. Four of six
# cases in a row scored as "the judge had no answer" before this was recognised.
# Nothing was asked and nothing ran.
clean_verdicts
reply '{"model":"","created_at":"","done":false,"message":{"role":"assistant","content":""}}'
out="$(judge)"; rc=$?
check "it is called out as the machine" "This is the machine, not the judge" "$out"
check "with what to do about it"        "ollama stop" "$out"
want  "and no judgement is written"     "a dead runner must not produce a judgement" \
      test ! -f "$R/verdicts/spec.attempt-1.judgement.json"

# --------------------------------------------------------------------------
printf '\n== the runtime allow-list holds on this path too ==\n\n'
#
# judge.sh is the second place a model is chosen, and a hole here would be a hole
# in the whole "no frontier model at runtime" guarantee.
clean_verdicts
jq '.roles.judge.provider = "anthropic"' "$WORK/roles.json" > "$WORK/roles-bad.json"
out="$( cd "$REPO" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles-bad.json" \
  bash "$PIPELINE_DIR/judge.sh" factory/runs/R --target spec --bean "$WORK/bean.yaml" 2>&1 )"; rc=$?
rc_is "a non-local provider refuses"   "$rc" 1
check "and says why"                   "not in the allow-list" "$out"
want  "before any request is made"     "nothing should have been written" \
      test ! -f "$R/verdicts/spec.attempt-1.judgement.json"

printf '\n-- and a model ollama does not have is refused, not substituted --\n\n'
cat > "$WORK/bin/ollama" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = list ] && printf 'some-other-model:latest\tfff000\t1 GB\n'
exit 0
STUB
out="$(judge)"; rc=$?
rc_is "it refuses"                     "$rc" 1
check "and names the model"            "test-judge:latest" "$out"
check "and says it is not present"     "is not present in ollama" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
