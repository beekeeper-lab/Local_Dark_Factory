#!/usr/bin/env bash
# test-inference-replay.sh — one variable changed, and only that one; and the
# summary's arithmetic.
#
# A replay exists to compare two server configurations on the same work, so the
# claim it must not get wrong is "the same work": `--set num_batch=1024` changes
# options.num_batch and nothing else in the body. A replay that also dropped a
# message, or re-ordered the options it was not asked about, would measure its
# own edit. And a replay that runs beside a live bean measures the contention,
# so the GPU guard is held here too — with a fake gate, because the real one may
# be held by a real bean while this runs.
#
# The report's percentiles are checked against a dataset small enough to do by
# hand. Nothing here talks to :11434.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REPLAY="$ROOT/bench/inference-replay.sh"
REPORT="$ROOT/bench/inference-report.py"
PY="${PIPELINE_PYTHON:-python3}"
WORK="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
# Run from the tree, not a snapshot: the snapshot is about protecting a long
# measurement from edits, and this is neither.
export FACTORY_NO_SNAPSHOT=1

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:400}"; FAIL=$((FAIL+1)); fi }
eq()    { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi }
rc_is() { if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi }

# ---------------------------------------------------------------- report --
echo "report: percentiles and shares on a known dataset"
# Ten judge calls with prefill rates 10..100 tok/s, so p50 = 55 and p90 = 91
# by linear interpolation between ranks; ttft 1..10 s, p50 5.5, p90 9.1. Each
# call: wall 10 s = prefill 6 + decode 3 + load 0.5 + 0.5 other.
for i in 1 2 3 4 5 6 7 8 9 10; do
  jq -nc --argjson i "$i" '{path:"/api/chat", model:"j", tags:{role:"judge"}, stream:true,
    wall_s:10, ttft_s:$i, prefill_tok_s:($i*10), decode_tok_s:($i+100),
    prompt_eval_count:($i*1000), eval_count:($i*10),
    prompt_eval_duration_s:6, eval_duration_s:3, load_duration_s:0.5}'
done > "$WORK/known.jsonl"
# Two developer calls through /v1: counts, no durations — they must not drag the
# shares or the rates, and must still count.
for i in 1 2; do
  jq -nc '{path:"/v1/chat/completions", tags:{role:"developer"}, stream:true, wall_s:4,
    ttft_s:null, prompt_eval_count:300, eval_count:20, prefill_tok_s:null, decode_tok_s:null,
    prompt_eval_duration_s:null, eval_duration_s:null, load_duration_s:null}'
done >> "$WORK/known.jsonl"
printf '{"kind":"provenance","harness":"x"}\nnot json\n' >> "$WORK/known.jsonl"
J="$("$PY" "$REPORT" --json "$WORK/known.jsonl" 2>/dev/null)"
row() { jq -c --arg r "$1" '.rows[] | select(.role == $r)' <<<"$J"; }
eq "provenance and junk lines skipped: 12 calls" 12 "$(jq -r .calls <<<"$J")"
eq "judge n"               10   "$(row judge | jq -r .n)"
eq "ttft p50 of 1..10"     5.5  "$(row judge | jq -r '.ttft.p50')"
eq "ttft p90 of 1..10"     9.1  "$(row judge | jq -r '.ttft.p90 * 1000 | round / 1000')"
eq "prefill p50/p90"       "55 91" "$(row judge | jq -r '"\(.prefill_tok_s.p50 * 1) \(.prefill_tok_s.p90 * 1000 | round / 1000)"')"
eq "ISL p50/p90"           "5500 9100" "$(row judge | jq -r '"\(.isl.p50 * 1) \(.isl.p90 | round)"')"
eq "OSL p50"               55   "$(row judge | jq -r '.osl.p50 * 1')"
eq "wall share: prefill 60%, decode 30%, load 5%, other 5%" "0.6 0.3 0.05 0.05" \
   "$(row judge | jq -r '.wall_share | [.prefill, .decode, .load, .other] | map(. * 1000 | round / 1000) | join(" ")')"
eq "developer: counts kept, rates and shares null" "2 300 null null" \
   "$(row developer | jq -r '"\(.n) \(.isl.p50 * 1) \(.prefill_tok_s.p50) \(.wall_share.prefill)"')"
T="$("$PY" "$REPORT" "$WORK/known.jsonl" 2>/dev/null)"
check "text table has the judge row" "judge" "$T"
check "text table shows the shares" "60" "$T"
jq -nc '{path:"/api/chat", tags:{role:"judge"}, wall_s:1, ttft_s:7}' > "$WORK/one.jsonl"
eq "one value: p50 = p90 = the value" "7 7" \
   "$("$PY" "$REPORT" --json "$WORK/one.jsonl" | jq -r '.rows[0].ttft | "\(.p50) \(.p90)"')"

# ---------------------------------------------------------------- replay --
"$PY" "$ROOT/factory/pipeline/tests/fake-ollama.py" --port-file "$WORK/up.port" --seen "$WORK/seen.jsonl" &
PIDS+=($!)
for _ in $(seq 1 50); do [ -s "$WORK/up.port" ] && break; sleep 0.1; done
SERVER="http://127.0.0.1:$(cat "$WORK/up.port")"

# Recorded requests in the shape the recorder saves them, plus the two things a
# replay must not send: a judge verdicts/ sidecar, and a /v1 call under --set.
REQ="$WORK/requests"; mkdir -p "$REQ"
printf '%s' '{"model":"j","stream":false,"messages":[{"role":"user","content":"judge this"}],"options":{"num_ctx":32768,"temperature":0}}' \
  > "$REQ/00001-judge.request.json"
printf '{"path":"/api/chat","tags":{"role":"judge","bean":"bean-1"}}\n' > "$REQ/00001-judge.meta.json"
printf '%s' '{"model":"d","messages":[{"role":"user","content":"write it"}]}' > "$REQ/00002-developer.request.json"
printf '%s' '{"model":"d","stream":true,"messages":[]}' > "$REQ/00003-developer.request.json"
printf '{"path":"/v1/chat/completions","tags":{"role":"developer"}}\n' > "$REQ/00003-developer.meta.json"
printf '%s' '{"schema":"judge-request/1.0.0","artifact_bytes":100,"model":"j","num_ctx":32768}' > "$WORK/spec.request.json"

GATE="$WORK/state"; mkdir -p "$GATE"; NOGATE="$WORK/nostate"; mkdir -p "$NOGATE"
# FACTORY_MEASURE_ANYWAY: a real bean may be in flight on this box while the
# suite runs, and inflight.sh would rightly refuse; the fake gate below is what
# these cases test.
export FACTORY_MEASURE_ANYWAY=1

echo "replay: --set changes options and nothing else"
out="$(bash "$REPLAY" "$REQ" "$WORK/spec.request.json" --label batch1024 --set num_batch=1024 \
        --passes 2 --server "$SERVER" --state-dir "$NOGATE" --out-dir "$WORK/out" 2>&1)"; rc=$?
rc_is "replayed" "$rc" 0
check "the judge sidecar is skipped and named" "spec.request.json — not a request body" "$out"
check "the /v1 call is skipped under --set" "takes no ollama options" "$out"
SENT1="$(jq -r 'select(.body | contains("judge this")) | .body' "$WORK/seen.jsonl" | head -1)"
eq "options.num_batch set, the other options kept" '{"num_ctx":32768,"temperature":0,"num_batch":1024}' \
   "$(jq -c .options <<<"$SENT1")"
eq "everything outside options is unchanged" \
   "$(jq -cS 'del(.options)' "$REQ/00001-judge.request.json")" "$(jq -cS 'del(.options)' <<<"$SENT1")"
SENT2="$(jq -r 'select(.body | contains("write it")) | .body' "$WORK/seen.jsonl" | head -1)"
eq "a request with no options gets just the one" '{"num_batch":1024}' "$(jq -c .options <<<"$SENT2")"
eq "and its messages are intact" "$(jq -c .messages "$REQ/00002-developer.request.json")" "$(jq -c .messages <<<"$SENT2")"
eq "N passes: 2 requests x 2 passes reached the server" 4 "$(wc -l < "$WORK/seen.jsonl" | tr -d ' ')"
OUT="$(ls "$WORK"/out/inference-replay-batch1024-*.jsonl 2>/dev/null | head -1)"
check "results named inference-replay-<label>-<ts>.jsonl" "inference-replay-batch1024-" "$OUT"
eq "a provenance line, then four calls" "provenance 4" \
   "$(jq -rs '"\(.[0].kind) \([.[] | select(.path)] | length)"' "$OUT")"
eq "provenance records the change and the server version" '{"num_batch":1024} 0.0.0-fake' \
   "$(head -1 "$OUT" | jq -rc '"\(.set) \(.server_version)"')"
eq "every call tagged with the label" batch1024 "$(jq -rs '[.[] | select(.path) | .tags.label] | unique | join(",")' "$OUT")"
eq "roles from the sidecar and the file name" "developer,judge" \
   "$(jq -rs '[.[] | select(.path) | .tags.role] | unique | join(",")' "$OUT")"
eq "passes tagged 1 and 2" "1,2" "$(jq -rs '[.[] | select(.path) | .tags.pass] | unique | join(",")' "$OUT")"
eq "metrics come out as a live run's do" 500 "$(jq -rs '[.[] | select(.path)][0].prefill_tok_s * 1' "$OUT")"
check "the summary is printed" "batch1024" "$out"

echo "replay: no --set sends the body unchanged"
: > "$WORK/seen.jsonl"
bash "$REPLAY" "$REQ/00001-judge.request.json" --label base --server "$SERVER" \
  --state-dir "$NOGATE" --out-dir "$WORK/out" >/dev/null 2>&1
eq "byte for byte" "$(cat "$REQ/00001-judge.request.json")" "$(jq -r .body "$WORK/seen.jsonl")"

echo "replay: refuses while the line holds the GPU"
sleep 60 & HOLDER=$!; PIDS+=($HOLDER)
jq -n --arg o "$(hostname):$HOLDER" '{holder:{owner:$o, role:"developer", bean:"bean-025"}, waiters:[], resident:"developer"}' \
  > "$GATE/inference.json"
: > "$WORK/seen.jsonl"
out="$(bash "$REPLAY" "$REQ" --label x --server "$SERVER" --state-dir "$GATE" --out-dir "$WORK/out2" 2>&1)"; rc=$?
rc_is "refused" "$rc" 2
check "naming the holder" "bean-025" "$out"
eq "and nothing was sent" 0 "$(wc -l < "$WORK/seen.jsonl" | tr -d ' ')"
out="$(bash "$REPLAY" "$REQ/00002-developer.request.json" --label x --server "$SERVER" --state-dir "$GATE" \
        --out-dir "$WORK/out2" --force 2>&1)"; rc=$?
rc_is "--force replays anyway" "$rc" 0
eq "and the provenance says it was contended" true \
   "$(head -1 "$(ls "$WORK"/out2/inference-replay-x-*.jsonl | head -1)" | jq -r .contended)"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
out="$(bash "$REPLAY" "$REQ/00002-developer.request.json" --label y --server "$SERVER" --state-dir "$GATE" \
        --out-dir "$WORK/out2" 2>&1)"; rc=$?
rc_is "a holder whose process is gone does not block" "$rc" 0

echo "report: timings ollama under-reported or the /v1 route never sent"
COR="$WORK/corrections.jsonl"
cat > "$COR" <<'J'
{"path":"/api/chat","tags":{"role":"judge"},"wall_s":50.0,"prompt_eval_count":13762,"prompt_eval_duration_s":0.035,"eval_count":588,"eval_duration_s":19.3,"load_duration_s":0.2,"total_duration_s":49.5,"prefill_tok_s":393200.0,"decode_tok_s":30.5}
{"path":"/v1/chat/completions","tags":{"role":"developer"},"stream":true,"wall_s":30.0,"ttft_s":10.0,"prompt_eval_count":5000,"eval_count":400,"prompt_eval_duration_s":null,"eval_duration_s":null}
J
J="$("$PY" "$REPORT" "$COR" --json)"
pre="$(jq -r '.rows[] | select(.role=="judge") | .prefill_tok_s.p50' <<<"$J" 2>/dev/null)"
check "an implausible judge prefill is taken from the residual (13762 / 30.0 s)" "458.7" "$pre"
dec="$(jq -r '.rows[] | select(.role=="developer") | .decode_tok_s.p50' <<<"$J" 2>/dev/null)"
check "a /v1 call's decode is estimated from wall - TTFT (400 / 20 s)" "20" "$dec"
share="$(jq -r '.rows[] | select(.role=="developer") | .wall_share.decode' <<<"$J" 2>/dev/null)"
check "and its wall share is counted, not left out" "0.66" "$share"

echo "replay: refusals before anything is sent"
out="$(bash "$REPLAY" "$REQ" --server "$SERVER" --state-dir "$NOGATE" 2>&1)"; rc=$?
rc_is "no --label" "$rc" 2
out="$(bash "$REPLAY" "$REQ" --label x --set nonsense --server "$SERVER" --state-dir "$NOGATE" 2>&1)"; rc=$?
rc_is "--set without =" "$rc" 2
out="$(bash "$REPLAY" "$WORK/spec.request.json" --label x --server "$SERVER" --state-dir "$NOGATE" --out-dir "$WORK/out3" 2>&1)"; rc=$?
rc_is "nothing replayable" "$rc" 2

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
