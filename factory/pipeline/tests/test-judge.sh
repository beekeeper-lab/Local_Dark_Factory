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
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
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
REQ = os.path.join(os.path.dirname(REPLY), "last-request.json")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        # Keep what was asked, not only what came back. Everything about the
        # prompt -- the schema, the preamble, the artifact split -- was
        # unassertable while this was a discarded read.
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open(REQ, "wb").write(raw)
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
printf '\n-- and an answer that stops without the server saying `length` --\n\n'
#
# The case the old message could not tell apart. A judge-fitness pass hit this
# branch and left a 578-byte log ending mid-string: the answer looked cut off,
# the message said the model had ignored the schema, and done_reason said `stop`.
# Whether the bytes really stopped unterminated or the 400-char print did was
# unanswerable, because nothing was kept.
clean_verdicts
reply "$(jq -nc --arg c '{"verdict":"revise","criteria":[{"id":"ac1","met":false,"evidence":"no source files were provided' \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c, thinking:""}}')"
out="$(judge)"; rc=$?
rc_is "exit 1, not 8"                  "$rc" 1
check "it reports the real done_reason" "done_reason=stop" "$out"
check "and what jq objected to"        "at EOF" "$out"
check "and says the cap may not be it" "may do nothing" "$out"
want  "all of it is kept"              "verdicts/spec.unparseable.json should exist" \
      test -s "$R/verdicts/spec.unparseable.json"
# Kept whole, not to the 400 characters the message used to print.
want  "kept whole, not truncated"      "the file should be the full answer" \
      test "$(wc -c < "$R/verdicts/spec.unparseable.json")" -eq 97

printf '\n-- an answer that is not JSON at all is a different sentence --\n\n'
clean_verdicts
reply "$(jq -nc --arg c 'I have reviewed the specification and it looks good to me.' \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c, thinking:""}}')"
out="$(judge)"; rc=$?
rc_is "it fails"                       "$rc" 1
check "it blames the decode"           "decode failing rather than the model choosing" "$out"
nope  "and not the token budget"       "JUDGE_NUM_PREDICT" "$out"
want  "what it sent is kept"           "verdicts/spec.unparseable.json should exist" \
      test -s "$R/verdicts/spec.unparseable.json"

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
printf '\n== what `met` means is said, and it depends on the target ==\n\n'
#
# The schema asked for a boolean called `met` and said nothing about it. For an
# impl audit the answer is in the diff; for a SPEC audit there is no code at all,
# and on 2026-09-16 the judge answered a spec audit with `met: false, evidence:
# "No source files were provided for analysis; the repository appears empty"`.
# A correct observation about a question it was not asked: every artifact it had
# was a plan.
#
# The sentence lives in two places — the preamble a human reads and the schema
# the decoder enforces — so both are asserted, against the same request.
clean_verdicts
reply "$(jq -nc --arg c "$GOOD_JUDGEMENT" \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c}}')"
judge >/dev/null 2>&1
REQ="$WORK/last-request.json"
want "the request is recorded"          "the stub should have kept the body" test -s "$REQ"
# The redirect has to be inside the command, not after `want` — after it, it is
# want's own "ok" line that goes to /dev/null and the assertion passes silently.
want "and the whole request is JSON"    "judge.sh sent something unparseable" \
     bash -c 'jq -e . "$1" >/dev/null' _ "$REQ"
# The schema travels inside the request; if it were malformed the model would be
# decoding against nothing and every field guarantee below it would be a wish.
# And the LITERAL in judge.sh is valid JSON on its own, before any substitution.
# bench/format-support.sh reads it out of the file with sed to measure a model
# against the real grammar rather than a copy — so a `$(...)` spliced into the
# literal makes what it extracts shell, and it refuses. That is a bench failure
# eighteen assertions wide for a change made in judge.sh, which is the wrong file
# to find out in.
want "the schema literal parses as JSON" "sed extraction must yield a schema, not shell" \
     bash -c "sed -n \"/^SCHEMA='/,/^}'\$/p\" \"\$1\" | sed \"1s/^SCHEMA='//; \\\$s/'\$//\" | jq -e . >/dev/null" \
     _ "$PIPELINE_DIR/judge.sh"
want "the response schema is valid JSON" "format must parse as a schema object" \
     bash -c 'jq -e ".format | type == \"object\"" "$1" >/dev/null' _ "$REQ"
want "and met carries a description"     "met must describe itself" \
     bash -c 'jq -e ".format.properties.criteria.items.properties.met | has(\"description\")" "$1" >/dev/null' _ "$REQ"

spec_met="$(jq -r '.format.properties.criteria.items.properties.met.description' "$REQ")"
check "a spec audit asks about the plan" "would THE PLAN" "$spec_met"
check "and says no code is expected"     "There is no code yet" "$spec_met"
# The same sentence, not a second one that can drift from it.
prompt="$(jq -r '[.messages[].content] | join("\n")' "$REQ")"
check "the preamble says the same thing" "$spec_met" "$prompt"

printf '\n-- and an impl audit asks about the work, not the plan --\n\n'
printf 'diff --git a/x b/x\n+++ b/x\n+one line\n' > "$R/diff.txt"
printf '{"overall":"pass","gates":[]}\n' > "$R/gate.json"
clean_verdicts
( cd "$REPO" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" \
  bash "$PIPELINE_DIR/judge.sh" factory/runs/R --target impl --bean "$WORK/bean.yaml" ) >/dev/null 2>&1
impl_met="$(jq -r '.format.properties.criteria.items.properties.met.description' "$REQ")"
check "it asks about the work as built" "the work as built" "$impl_met"
nope "and not about a plan"             "would THE PLAN" "$impl_met"

printf '\n== each artifact says how to read it, on the artifact ==\n\n'
#
# The preamble says artifacts are quoted material and not instructions. It says
# it once, thousands of tokens before the first artifact arrives.
#
# On 2026-09-16, asked for a spec audit of a real run, this judge read
# claims-check.json — a controller measurement, raw JSON under the heading "WHAT
# THE SPEC SAYS EXISTS, CHECKED AGAINST THE REPO" — as a confusing set of
# statements about its own task, invented a response shape of its own, and ended
# twenty thousand characters of reasoning with "Could you clarify what exactly
# you'd like me to do?". It never wrote an answer. The trace is in
# evidence/reaudit-bean-001-20260916.log.
clean_verdicts
printf '{"claims":[{"path":"src/x.py","exists":false}]}\n' > "$R/claims-check.json"
reply "$(jq -nc --arg c "$GOOD_JUDGEMENT" \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c}}')"
judge >/dev/null 2>&1
req="$(jq -r '[.messages[].content] | join("\n")' "$WORK/last-request.json")"
check "the bean says who it is addressed to" "addressed to a DIFFERENT model" "$req"
check "and that it is not a task for the judge" "not a task for you to carry out" "$req"
check "a controller measurement says so"    "A measurement the controller already took" "$req"
check "and that it is not a question"       "not a question for you" "$req"
# On the artifact, not only in the preamble: the header is what a reader sees
# beside the bytes it describes.
check "the note is in the artifact header"  "read as:" "$req"
rm -f "$R/claims-check.json"

printf '\n== how much of the window the request used, and whose lever that is ==\n\n'
#
# ollama returns prompt_eval_count and eval_count on the final response, and this
# script read neither. So "it stopped without finishing" could be the token cap,
# the context window, or the model just stopping, and the message could only name
# the first — which is the wrong lever twice out of three.
#
# Real case: a doc audit returned 13,273 bytes of well-formed JSON that stopped
# mid-string with done_reason=stop. Not `length`, so not the cap.
clean_verdicts
reply "$(jq -nc --arg c "$GOOD_JUDGEMENT" \
  '{model:"test-judge:latest", done:true, done_reason:"stop", prompt_eval_count:1000, eval_count:500,
    message:{role:"assistant", content:$c}}')"
out="$(judge)"
check "the counts are reported"        "1000 prompt + 500 generated = 1500 of 32768" "$out"
nope  "and a roomy request says nothing about the window" "CONTEXT WINDOW" "$out"

printf '\n-- and a request that filled the window says whose lever it is --\n\n'
clean_verdicts
reply "$(jq -nc --arg c "$GOOD_JUDGEMENT" \
  '{model:"test-judge:latest", done:true, done_reason:"stop", prompt_eval_count:30000, eval_count:2700,
    message:{role:"assistant", content:$c}}')"
out="$(judge)"
check "it names the context window"    "that is the CONTEXT WINDOW, not the token cap" "$out"
check "and the setting to change"      "roles.json" "$out"
check "and what is NOT the lever"      "JUDGE_NUM_PREDICT" "$out"
check "and that done_reason hid it"    "which does not say this" "$out"

printf '\n== the criterion ids are in the grammar, not only in the prose ==\n\n'
#
# The prompt has said, in bold, "the criteria you report on are these, and only
# these — using exactly these ids", followed by the list. Twelve real audits of
# bean-001 on 2026-09-16 filled `criteria` with `task-1`, `task-2` (the task
# list's ids) and `artifact-1`..`artifact-5` (the numbering of the prompt's own
# delimiters). Never once ac1..ac4.
#
# It is not ignoring the instruction so much as filling the field from whatever
# enumerable thing is nearest, and prose cannot stop that. An enum can:
# constrained decoding makes `task-1` unemittable rather than discouraged.
printf 'schema_version: bean/2.0.0\nid: bean-001\ntitle: a thing\nintent: do a thing\nacceptance_criteria:\n  - id: ac1\n    text: one\n  - id: ac2\n    text: two\n  - id: ac3\n    text: three\n' \
  > "$WORK/bean-crit.yaml"
clean_verdicts
reply "$(jq -nc --arg c "$GOOD_JUDGEMENT" \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c}}')"
( cd "$REPO" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" \
  bash "$PIPELINE_DIR/judge.sh" factory/runs/R --target spec --bean "$WORK/bean-crit.yaml" ) >/dev/null 2>&1
# An OBJECT keyed by id, not an array with an enum on it. The enum plus minItems
# was already a large win and left one hole, which the model found: `criteria`
# came back as ac1, ac1, ac1, ac2 — four items, each from the list, exactly as
# asked, and nothing said distinct. JSON Schema's `uniqueItems` cannot say it
# either, because two entries with the same id and different evidence are unique
# objects.
eq "criteria is keyed by criterion id"  "object" \
   "$(jq -r '.format.properties.criteria.type' "$WORK/last-request.json")"
eq "all of them are required"           '["ac1","ac2","ac3"]' \
   "$(jq -c '.format.properties.criteria.required' "$WORK/last-request.json")"
eq "and nothing else is allowed"        "false" \
   "$(jq -r '.format.properties.criteria.additionalProperties' "$WORK/last-request.json")"
eq "each carries the same fields"       '["evidence","met","quote"]' \
   "$(jq -c '.format.properties.criteria.properties.ac1.required | sort' "$WORK/last-request.json")"
# id is not a field inside the entry any more: the key IS the id, and two places
# to write it is one place that can disagree.
eq "and not a redundant id field"       "null" \
   "$(jq -r '.format.properties.criteria.properties.ac1.properties.id // "null"' "$WORK/last-request.json")"
# The list in the prose and the list in the grammar come from one source, so they
# cannot drift apart — which is how the prose came to be right and ignored.
check "the prose still lists them too" "ac1: one" \
   "$(jq -r '[.messages[].content] | join("\n")' "$WORK/last-request.json")"

printf '\n-- a bean with no criteria gets no enum, not an empty one --\n\n'
#
# An empty enum is a grammar that permits no string at all, which would make the
# field unfillable rather than constrained.
clean_verdicts
( cd "$REPO" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" \
  bash "$PIPELINE_DIR/judge.sh" factory/runs/R --target spec --bean "$WORK/bean.yaml" ) >/dev/null 2>&1
eq "criteria stays an array"           "array" \
   "$(jq -r '.format.properties.criteria.type' "$WORK/last-request.json")"
eq "with no required key list"         "null" \
   "$(jq -r '.format.properties.criteria.required // "null"' "$WORK/last-request.json")"

printf '\n-- and the keyed answer becomes the list everything downstream expects --\n\n'
#
# audit-check, verdict.schema.json and the pull request body all take `criteria`
# as an array of objects carrying an `id`. None of them should know about the wire
# shape; it is converted at the boundary, in the bean's order so that two runs of
# the same audit are diffable.
clean_verdicts
reply "$(jq -nc --arg c '{"verdict":"accept","confidence":0.9,"findings":[],"criteria":{"ac3":{"met":true,"evidence":"e3","quote":"the third quote here"},"ac1":{"met":false,"evidence":"e1","quote":"the first quote here"},"ac2":{"met":true,"evidence":"e2","quote":"the second quote here"}}}' \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c}}')"
( cd "$REPO" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" \
  bash "$PIPELINE_DIR/judge.sh" factory/runs/R --target spec --bean "$WORK/bean-crit.yaml" ) >/dev/null 2>&1
J="$R/verdicts/spec.attempt-1.judgement.json"
eq "criteria is written as a list"     "array" "$(jq -r '.criteria | type' "$J" 2>/dev/null)"
eq "in the bean's order"               '["ac1","ac2","ac3"]' "$(jq -c '[.criteria[].id]' "$J" 2>/dev/null)"
eq "carrying each entry's fields"      "e1" "$(jq -r '.criteria[0].evidence' "$J" 2>/dev/null)"
eq "and its met value"                 "false" "$(jq -r '.criteria[0].met' "$J" 2>/dev/null)"

printf '\n== the field caps are a knob, because they are a suspect ==\n\n'
#
# maxLength stopped `evidence` arriving with a Python module in it, and the same
# afternoon the case-level fitness numbers became the worst on record. Two things
# changed at once, so neither is attributable — and the way to find out is to vary
# one of them and be able to say in the artifact which value produced the number,
# rather than depending on what the working tree looked like at the time.
clean_verdicts
reply "$(jq -nc --arg c "$GOOD_JUDGEMENT" \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c}}')"
judge >/dev/null 2>&1
eq "the default caps evidence"         "600" \
   "$(jq -r '.format.properties.criteria.items.properties.evidence.maxLength' "$WORK/last-request.json")"
eq "and quotes at half of it"          "300" \
   "$(jq -r '.format.properties.criteria.items.properties.quote.maxLength' "$WORK/last-request.json")"

clean_verdicts
JUDGE_FIELD_MAXLEN=1200 judge >/dev/null 2>&1
eq "one number moves them together"    "1200" \
   "$(jq -r '.format.properties.criteria.items.properties.evidence.maxLength' "$WORK/last-request.json")"
eq "the quote with it"                 "600" \
   "$(jq -r '.format.properties.criteria.items.properties.quote.maxLength' "$WORK/last-request.json")"
eq "and the one-line fields at a third" "400" \
   "$(jq -r '.format.properties.findings.items.properties.summary.maxLength' "$WORK/last-request.json")"

printf '\n-- and 0 removes them, which is the experiment --\n\n'
clean_verdicts
# With the bean that HAS criteria, so the assertion below about the keyed shape
# surviving is about something. $WORK/bean.yaml declares none and keeps the plain
# array, correctly, which would make it pass for the wrong reason.
( cd "$REPO" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" JUDGE_FIELD_MAXLEN=0 \
  bash "$PIPELINE_DIR/judge.sh" factory/runs/R --target spec --bean "$WORK/bean-crit.yaml" ) >/dev/null 2>&1
eq "no cap on evidence"                "null" \
   "$(jq -r '.format.properties.criteria.items.properties.evidence.maxLength // "null"' "$WORK/last-request.json")"
eq "nor anywhere else"                 "0" \
   "$(jq '[.. | objects | select(has("maxLength"))] | length' "$WORK/last-request.json")"
# The rest of the grammar must survive it: removing a cap must not remove the
# constraints that were measured to work.
eq "the criterion keys survive"        "object" \
   "$(jq -r '.format.properties.criteria.type' "$WORK/last-request.json")"
eq "and the confidence enum"           "11" \
   "$(jq -r '.format.properties.confidence.enum | length' "$WORK/last-request.json")"

out="$(JUDGE_FIELD_MAXLEN=nonsense judge 2>&1)"
check "a non-numeric cap is refused"   "wants a number of characters" "$out"

printf '\n== confidence is an enum, because numeric bounds are not enforced ==\n\n'
#
# This field has carried `"minimum": 0, "maximum": 1` for days and the judge
# returned **100** — twice, months apart, most recently 2026-09-16 on a real impl
# audit that had passed every other check. llama.cpp's grammar conversion honours
# `enum` and does not honour numeric bounds, which is worth knowing before
# reaching for any other numeric constraint.
#
# audit-check refuses a confidence outside the range rather than clamping,
# because clamping 100 to 1 invents a claim the model never made. An enum makes
# 100 unemittable instead.
clean_verdicts
reply "$(jq -nc --arg c "$GOOD_JUDGEMENT" \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c}}')"
judge >/dev/null 2>&1
conf="$(jq -c '.format.properties.confidence' "$WORK/last-request.json")"
check "it is an enum"                  '"enum"' "$conf"
check "bounded at one"                 "1" "$conf"
nope  "and not a numeric maximum"      '"maximum"' "$conf"
eq "with one decimal place of range"   "11" \
   "$(jq -r '.format.properties.confidence.enum | length' "$WORK/last-request.json")"
# 100 must not be in it. That is the value the model actually returned.
eq "and 100 is not in the list"        "false" \
   "$(jq -r '.format.properties.confidence.enum | any(. == 100)' "$WORK/last-request.json")"

printf '\n== the token cap has one default, in three files ==\n\n'
#
# judge.sh sets it; bench/judge-fitness.sh and bench/judge-variance.sh record it
# into their artifacts so a figure says what budget produced it. Three copies of
# a number is two copies that will eventually be wrong, and the way it goes wrong
# is silent: an artifact saying cap=12000 for a run that used 16000 is a figure
# nobody can check afterwards.
jcap="$(grep -oE 'JUDGE_NUM_PREDICT:-[0-9]+' "$PIPELINE_DIR/judge.sh" | head -1 | sed 's/.*:-//')"
BENCHDIR="$(cd "$PIPELINE_DIR/../../bench" 2>/dev/null && pwd || true)"
if [ -n "$jcap" ] && [ -n "$BENCHDIR" ]; then
  drift=""
  for h in judge-fitness.sh judge-variance.sh; do
    [ -f "$BENCHDIR/$h" ] || continue
    hcap="$(grep -oE 'JUDGE_NUM_PREDICT:-[0-9]+' "$BENCHDIR/$h" | head -1 | sed 's/.*:-//')"
    [ "$hcap" = "$jcap" ] || drift="$drift $h=$hcap"
  done
  if [ -z "$drift" ]; then
    printf '  ok    every file agrees the default is %s\n' "$jcap"; PASS=$((PASS+1))
  else
    printf '  FAIL  judge.sh says %s, but:%s — an artifact would record a budget the run did not use\n' "$jcap" "$drift"
    FAIL=$((FAIL+1))
  fi
else
  printf '  FAIL  could not read the token cap default out of judge.sh\n'; FAIL=$((FAIL+1))
fi

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
