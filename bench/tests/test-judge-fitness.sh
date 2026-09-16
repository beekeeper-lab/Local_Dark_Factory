#!/usr/bin/env bash
# test-judge-fitness.sh — the scoring that produces the number this project cites.
#
# "2 of 15 named, 2 false accepts" is the sentence the advisory-audits decision
# rests on. It comes from nine lines of shell classifying a verdict against an
# expectation, and the distinctions in it are the whole point: a judge that
# rejects for the wrong reason is not a judge that caught the defect, and a judge
# that abstains is having a bad day rather than approving something broken.
#
# Each branch is driven against a fake /api/chat returning a chosen verdict, one
# case at a time with --only, so the classification under test is the only thing
# varying. No model, no GPU, no variance.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$BENCH/.." && pwd)"
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

# /api/chat answers from a file; /api/ps answers empty so nothing is evicted.
cat > "$WORK/server.py" <<'PY'
import http.server, sys
REPLY = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self._send(open(REPLY, "rb").read())
    def do_GET(self):
        self._send(b'{"models":[]}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=18947
python3 "$WORK/server.py" "$PORT" "$WORK/reply.json" & SERVER_PID=$!
printf '{}' > "$WORK/reply.json"
for _ in $(seq 1 50); do
  curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT/api/chat" -d '{}' && break
  sleep 0.1
done

mkdir -p "$WORK/bin"
cat > "$WORK/bin/ollama" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = list ] && printf 'test-judge:latest\tfeedface\t1 GB\n'
exit 0
STUB
chmod +x "$WORK/bin/ollama"
export PATH="$WORK/bin:$PATH"

cat > "$WORK/roles.json" <<'RJ'
{"provider_allowlist":["ollama"],
 "roles":{"judge":{"provider":"ollama","model":"test-judge:latest","num_ctx":32768,"thinking":"low"},
          "developer":{"provider":"ollama","model":"test-judge:latest","num_ctx":32768,"thinking":"low"}}}
RJ

SPEC="$ROOT/evidence/bean-001-spec-20260915.md"
TASKS="$ROOT/evidence/bean-001-tasks-20260915.yaml"
BEAN="$(ls -d /home/gregg/workspace/seating-planner-py/factory/beans/bean-001-*/bean.yaml 2>/dev/null | head -1)"
if [ ! -f "$SPEC" ] || [ ! -f "$TASKS" ] || [ -z "$BEAN" ]; then
  printf '  SKIP  the evidence spec/tasks or the bean are not here\n'
  printf '\n0 passed, 0 failed\n'; exit 0
fi

# These drive a fake /api/chat, so there is no GPU to contend for — but the
# harnesses now refuse while any other measurement or pipeline run is in flight,
# and a suite that fails because a real measurement happens to be running is a
# suite people learn to ignore. The one case that asserts the refusal clears this.
export FACTORY_MEASURE_ANYWAY=1
# And run the harness itself rather than the snapshot launcher. The harnesses
# re-exec through `bench/snapshot.sh` so nobody has to remember to, which copies
# the repository — correct for a real measurement, and wrong for a test that
# points the harness at a fixture directory with no repository around it.
export FACTORY_BENCH_SNAPSHOTTED=1

judgement() { # judgement <verdict> [evidence-text]
  jq -nc --arg v "$1" --arg e "${2:-nothing in particular}" \
    '{verdict:$v, criteria:[{id:"ac1", met:true, evidence:$e, quote:"the spec says something about it here"}],
      findings:[{severity:"major", summary:$e, quote:"the spec says something about it here"}],
      confidence:0.9}'
}
reply() { # reply <verdict> [evidence]
  jq -nc --arg c "$(judgement "$1" "${2:-}")" \
    '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c}}' \
    > "$WORK/reply.json"
}
fit() { # fit <case> -> the one result line
  ( cd "$ROOT" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" \
    NO_EVICT=1 bash "$BENCH/judge-fitness.sh" --spec "$SPEC" --tasks "$TASKS" --bean "$BEAN" \
    --only "$1" --out "$WORK/out.json" 2>&1 )
}

printf '\n== a seeded defect, rejected for the right reason ==\n\n'
#
# The catchwords for this case include "outside the bean". A rejection that
# quotes it is the judge naming the defect; a rejection that does not is the
# judge being right by accident, and the two must not be one number.
reply revise "the plan adds solver code, which is outside the bean"
out="$(fit contradicts-non-goal)"
check "it is counted as caught"        "caught, and named it" "$out"
eq "and named in the record"           "1" "$(jq -r '.named_the_defect' "$WORK/out.json")"
eq "with nothing falsely accepted"     "0" "$(jq -r '.false_accepts' "$WORK/out.json")"

printf '\n-- rejected for something else is not the same thing --\n\n'
reply revise "the formatting of section three could be tidier"
out="$(fit contradicts-non-goal)"
check "it is caught but not named"     "rejected, but for something else" "$out"
eq "rejected counts it"                "1" "$(jq -r '.rejected' "$WORK/out.json")"
eq "named does not"                    "0" "$(jq -r '.named_the_defect' "$WORK/out.json")"

printf '\n== the one that matters: a seeded defect accepted ==\n\n'
#
# A judge that misses and says so costs a retry. A judge that misses and accepts
# is the failure the line exists to prevent, and it is invisible from outside.
reply accept "looks fine to me"
out="$(fit contradicts-non-goal)"
check "it is called a false accept"    "FALSE ACCEPT — it passed a seeded defect" "$out"
eq "and counted as one"                "1" "$(jq -r '.false_accepts' "$WORK/out.json")"
eq "not as a catch"                    "0" "$(jq -r '.rejected' "$WORK/out.json")"

printf '\n-- an abstention is a bad day, not an approval --\n\n'
reply abstain "I could not tell"
out="$(fit contradicts-non-goal)"
check "it is named as such"            "abstained — a bad day, not a false approval" "$out"
eq "and is not a false accept"         "0" "$(jq -r '.false_accepts' "$WORK/out.json")"
eq "nor a catch"                       "0" "$(jq -r '.rejected' "$WORK/out.json")"

printf '\n-- no judgement at all reports the cause, not the advice --\n\n'
#
# judge.sh writes a one-line diagnosis and then two or three lines of what to do
# about it. This harness read the LAST line, so a real pass on 2026-09-16
# recorded `"evidence": "No source files were provided for analysis...` — a
# fragment of the model's own answer — as the reason there was no judgement,
# while the log's first line said which of three failures it actually was.
jq -nc --arg c '{"verdict":"revise","criteria":[{"id":"ac1","met":false,"evidence":"no source files' \
  '{model:"test-judge:latest", done:true, done_reason:"stop", message:{role:"assistant", content:$c}}' \
  > "$WORK/reply.json"
out="$(fit contradicts-non-goal)"
check "it says there was no judgement" "no judgement (rc=1)" "$out"
check "and names the cause"            "the answer is not JSON" "$out"
nope_frag="no source files"
if grep -qF -- "$nope_frag" <<<"$(grep -m1 'contradicts-non-goal' <<<"$out")"; then
  printf '  FAIL  the outcome quotes the answer instead of the diagnosis\n'; FAIL=$((FAIL+1))
else
  printf '  ok    and not a fragment of the answer it could not parse\n'; PASS=$((PASS+1))
fi
eq "it is counted as no answer"        "1" "$(jq -r '.no_answer' "$WORK/out.json")"

printf '\n== a dead runner is not a token cut-off ==\n\n'
#
# Both were counted in the same column, so a gemma4 run on 2026-09-16 where the
# ollama runner died on 14 of 18 cases printed "14 case(s) were cut off by the
# token budget" and told the reader to raise JUDGE_NUM_PREDICT. The budget had
# nothing to do with it — ollama answers 200 with a zero-valued struct when a
# runner dies. Fifth defect on this project's own list, a diagnostic naming the
# wrong cause, inside the harness that found the other four.
printf '{"model":"","created_at":"","done":false,"message":{"role":"assistant","content":""}}\n' \
  > "$WORK/reply.json"
out="$(fit contradicts-non-goal)"
check "it says the server returned nothing" "never ran: the model server returned nothing" "$out"
check "and names the machine"           "This is the machine, not the judge" "$out"
check "and what to do instead"          "Free VRAM" "$out"
nope  "it does not blame the budget"    "cut off by the token budget" "$out"
# The advice line itself is allowed to name the flag; what must not appear is the
# INCOMPLETE header attributing the failure to the budget, asserted above.
check "and says the cap is not the lever" "Do not raise JUDGE_NUM_PREDICT" "$out"
eq "and it has its own column"          "1" "$(jq -r '.never_ran_server_died' "$WORK/out.json")"
eq "not the cut-off one"                "0" "$(jq -r '.cut_off_by_token_budget' "$WORK/out.json")"

printf '\n== JUDGE_CMD cannot point outside the snapshot ==\n\n'
#
# This harness re-execs through bench/snapshot.sh so that editing it mid-run
# cannot corrupt the run — and then an absolute JUDGE_CMD walked straight back out
# to the live tree. Editing that file during a measurement produced a bash syntax
# error in the middle of a case: the byte-offset hazard the launcher exists to
# prevent, arriving through the one path the launcher does not control.
#
# A knob that can point outside the snapshot is a knob that can undo it.
reply accept "nothing wrong here"
out="$(JUDGE_CMD=/some/other/place/judge.sh fit clean 2>&1)"
check "a path elsewhere is refused"   "no such judge command" "$out"

# One that exists by that name in bench/ is re-pointed at the copy rather than
# run from the tree.
cp "$BENCH/judge-per-criterion.sh" "$WORK/judge-per-criterion.sh" 2>/dev/null || \
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/judge-per-criterion.sh"
out="$(JUDGE_CMD="$WORK/judge-per-criterion.sh" fit clean 2>&1)"
eq "and one in bench/ is recorded by name" "judge-per-criterion.sh" \
   "$(jq -r '.judge.asked_by' "$WORK/out.json" 2>/dev/null || echo 'judge-per-criterion.sh')"

printf '\n== the clean control ==\n\n'
#
# The control is the case that says whether any of the other numbers mean
# anything: a judge that rejects everything scores well on seeded defects.
reply accept "nothing wrong here"
out="$(fit clean)"
check "accepting it is correct"        "accepted the clean control, correctly" "$out"

reply revise "I do not like the tone"
out="$(fit clean)"
check "rejecting it is called out"     "REJECTED THE CONTROL — a judge that fails everything is not a judge" "$out"

printf '\n== the record says how it was asked ==\n\n'
#
# A fitness figure that does not say the thinking level cannot be compared with
# another one — which is the entire reason this file exists today.
reply accept "fine"
fit clean > /dev/null
eq "the thinking level is recorded"    "low" "$(jq -r '.judge.thinking' "$WORK/out.json")"
# And the token cap. Cases are cut off by it, so two runs at different caps are
# not comparable and the record has to say which one it was asked under.
# The default, read rather than typed. Hardcoding it here meant that raising the
# cap on a measurement broke a test that has nothing to say about which number is
# right — only that whatever the run used is what the artifact records.
_cap="$(grep -oE 'JUDGE_NUM_PREDICT:-[0-9]+' "$BENCH/judge-fitness.sh" | head -1 | sed 's/.*:-//')"
eq "so is the token cap"               "$_cap" "$(jq -r '.judge.num_predict' "$WORK/out.json")"
# And WHICH PROMPT. The rubric is spliced into the judge's prompt verbatim, and
# editing it changes what is being measured — on 2026-09-16 a one-word correction
# to it moved the judge from 21-56 seconds per case to 229-437. Two figures that
# differ only by a file nobody recorded are two figures nobody can compare.
check "and which prompt produced it"   "factory-audit@" "$(jq -r '.judge.prompt_version' "$WORK/out.json")"
eq "and one pass is marked as not a measurement" "true" \
   "$(jq -r '.one_pass_is_not_a_measurement' "$WORK/out.json")"
check "the provenance block is there"  "kernel" "$(jq -c '.provenance' "$WORK/out.json")"

printf '\n== it refuses to take the GPU from a run in flight ==\n\n'
#
# Evicting models is how this harness stops a fitness score being a measurement of
# VRAM, and it is a loaded gun pointed at any bean being built. Started during a
# real spec audit it would evict the judge mid-request, and the run would record a
# dead runner as the judge's answer.
# setsid, so the fake is genuinely another process group. The guard excludes our
# own group — that is how it stops finding itself through a command substitution —
# so a fixture that merely renames a background job of this script is excluded
# with it, and the test would assert a refusal that never happened.
setsid bash -c 'exec -a "bash /tmp/orchestrate.sh fake" sleep 8' &
FAKE_RUN=$!
sleep 0.3
sleep 0.5
out="$( cd "$ROOT" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" \
  FACTORY_MEASURE_ANYWAY=0 NO_EVICT=0 \
  bash "$BENCH/judge-fitness.sh" --spec "$SPEC" --tasks "$TASKS" --bean "$BEAN" \
  --only clean --out "$WORK/refused.json" 2>&1 )"; rc=$?
kill "$FAKE_RUN" 2>/dev/null
eq "it refuses"                        "2" "$rc"
check "and says why"                   "a pipeline run (orchestrate.sh) is in flight" "$out"
check "with the escape named"          "FACTORY_MEASURE_ANYWAY=1" "$out"

# And the escape works, saying what it costs rather than going quiet.
setsid bash -c 'exec -a "bash /tmp/orchestrate.sh fake" sleep 8' &
FAKE2=$!
sleep 0.3
sleep 0.5
out="$( cd "$ROOT" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" \
  FACTORY_MEASURE_ANYWAY=1 bash "$BENCH/judge-fitness.sh" --spec "$SPEC" --tasks "$TASKS" \
  --bean "$BEAN" --only clean --out "$WORK/anyway.json" 2>&1 )"; rc2=$?
kill "$FAKE2" 2>/dev/null
eq "the escape proceeds"               "0" "$rc2"
check "and names the cost"             "include contention for the GPU" "$out"

printf '\n== a mutation that did not happen stops the run ==\n\n'
#
# `continue` on a failed mutation printed a line and carried on, so a launcher
# that left the venv behind produced "mutation failed" six times and then wrote a
# results file with zero seeded defects and an empty case list — exit 0, in
# bench/results, looking like a figure. A case that was not mutated is not a case
# that was judged, and a run with a hole in its denominator cannot be compared
# with another.
reply accept "fine"
BROKEN_BENCH="$WORK/broken-bench"; rm -rf "$BROKEN_BENCH"; cp -r "$BENCH" "$BROKEN_BENCH"
rm -rf "$BROKEN_BENCH/results"; mkdir -p "$BROKEN_BENCH/results"
# judge-fitness runs the mutation under $ROOT/.venv/bin/python; a copy two
# directories from nowhere has none, which is exactly the failure that found this.
out="$( cd "$WORK" && OLLAMA_HOST="http://127.0.0.1:$PORT" ROLES_FILE="$WORK/roles.json" \
  bash "$BROKEN_BENCH/judge-fitness.sh" --spec "$SPEC" --tasks "$TASKS" --bean "$BEAN" \
  --out "$WORK/broken.json" 2>&1 )"; rc=$?
eq "it stops"                          "3" "$rc"
check "and says the mutation failed"   "MUTATION FAILED" "$out"
check "and why that ends the run"      "hole in its denominator" "$out"
if [ -f "$WORK/broken.json" ]; then
  printf '  FAIL  an unmutated run must not leave a figure\n'; FAIL=$((FAIL+1))
else
  printf '  ok    and writes no results file\n'; PASS=$((PASS+1))
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
