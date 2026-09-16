#!/usr/bin/env bash
# test-format-support.sh — the classifier that decides which judge this line may use.
#
# This harness answers one question — can this (model, thinking) pair return the
# judgement object at all — and the answer moves configuration. On 2026-09-16 it
# said gpt-oss:120b holds the schema only at `low`, and roles.json had been saying
# `medium` for two days.
#
# Its whole substance is six branches over a response. A branch that mislabels is
# a decision made on a wrong word, so each is exercised against a fake /api/chat
# that returns exactly the shape being classified. No model, no GPU, no variance.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$(cd "$HERE/.." && pwd)"
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
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

cat > "$WORK/server.py" <<'PY'
import http.server, sys
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
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=18931
python3 "$WORK/server.py" "$PORT" "$WORK/reply.json" & SERVER_PID=$!
printf '{}' > "$WORK/reply.json"
for _ in $(seq 1 50); do
  curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/api/chat" -d '{}' && break
  sleep 0.1
done

# These drive a fake /api/chat, so there is no GPU to contend for — but the
# harnesses now refuse while any other measurement or pipeline run is in flight,
# and a suite that fails because a real measurement happens to be running is a
# suite people learn to ignore. The one case that asserts the refusal clears this.
export FACTORY_MEASURE_ANYWAY=1

reply() { printf '%s' "$1" > "$WORK/reply.json"; }
# One model, one level, so each case is one classification.
fs() {
  OLLAMA_HOST="http://127.0.0.1:$PORT" \
    bash "$BENCH/format-support.sh" --out "$WORK/out.json" test-model:1b 2>&1 \
    | grep -E '^test-model'| head -1
}
msg() { # msg <content> [done_reason]
  jq -nc --arg c "$1" --arg r "${2:-stop}" \
    '{model:"test-model:1b", done_reason:$r, message:{role:"assistant", content:$c}}'
}

GOOD='{"verdict":"revise","criteria":[],"findings":[],"confidence":0.9}'

printf '\n== a real judgement holds ==\n\n'
reply "$(msg "$GOOD")"
out="$(fs)"
check "it holds"                      "yes" "$out"
check "and shows what came back"      '"verdict":"revise"' "$out"
eq "the record agrees"                "true" "$(jq -r '.results[0].holds' "$WORK/out.json")"

printf '\n== the failures, each told apart ==\n\n'
#
# These four look identical in a log that only records "no", and each points
# somewhere different: the budget, the model, the grammar, the contract.
reply "$(msg "" length)"
check "budget spent on thinking"      "spent the whole budget thinking and wrote nothing" "$(fs)"

reply "$(msg "" stop)"
check "empty for another reason"      "empty content (done_reason=stop)" "$(fs)"
nope "and not blamed on the budget"   "spent the whole budget" "$(fs)"

reply "$(msg '```json
{"verdict":"accept"}
```')"
check "a markdown fence is named"     "the grammar did not bind" "$(fs)"

reply "$(msg 'I think the plan is fine.')"
check "prose is not JSON"             "not JSON: I think the plan is fine" "$(fs)"

printf '\n-- JSON that is not the contract --\n\n'
#
# The case that matters most: valid JSON, confidently wrong shape. A classifier
# that called this "holds" would put a model into the judge seat on the strength
# of it having returned a brace.
reply "$(msg '{"strengths":["clear"],"weaknesses":[]}')"
out="$(fs)"
check "it does not hold"              "no" "$out"
check "and the keys are shown"        "JSON, but not the contract" "$out"

reply "$(msg '{"verdict":"looks good","criteria":[],"findings":[],"confidence":1}')"
check "a verdict outside the enum"    "is outside the enum" "$(fs)"

printf '\n== the record says how the question was asked ==\n\n'
#
# Without artifacts this asks a short question, and the short question has a
# different and more flattering answer — that is how the line came to run its
# judge at a thinking level which, under real artifacts, returns nothing.
reply "$(msg "$GOOD")"
out="$(OLLAMA_HOST="http://127.0.0.1:$PORT" bash "$BENCH/format-support.sh" \
  --out "$WORK/short.json" test-model:1b 2>&1)"
check "it warns in the output"        "NO ARTIFACTS" "$out"
eq "and marks the artifact"           "true"  "$(jq -r '.short_question_only' "$WORK/short.json")"
eq "with artifacts absent"            "false" "$(jq -r '.asked_with_artifacts' "$WORK/short.json")"

RD="$WORK/run"; mkdir -p "$RD"
printf '# Spec\n\nSomething real and long enough to matter.\n' > "$RD/spec.md"
printf 'schema_version: tasks/1.0.0\ntasks: []\n' > "$RD/tasks.yaml"
out="$(OLLAMA_HOST="http://127.0.0.1:$PORT" bash "$BENCH/format-support.sh" \
  --artifacts "$RD" --out "$WORK/long.json" test-model:1b 2>&1)"
check "with artifacts it says so"     "payload: 2 artifact(s)" "$out"
nope "and does not warn"              "NO ARTIFACTS" "$out"
eq "the artifact records it"          "true" "$(jq -r '.asked_with_artifacts' "$WORK/long.json")"
eq "and it is not the short question" "false" "$(jq -r '.short_question_only' "$WORK/long.json")"

printf '\n== an unknown flag is not a model name ==\n\n'
out="$(OLLAMA_HOST="http://127.0.0.1:$PORT" bash "$BENCH/format-support.sh" --nonsense 2>&1)"; rc=$?
eq "it refuses"                       "2" "$rc"
check "and says which flag"           "unknown flag: --nonsense" "$out"
nope "no results file is written"     "format-support-" "$(ls "$BENCH/results" 2>/dev/null | grep "$(date -u +%Y%m%dT%H%M)" || true)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
