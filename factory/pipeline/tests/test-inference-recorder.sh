#!/usr/bin/env bash
# test-inference-recorder.sh — the recorder must measure the line without
# changing what the line receives.
#
# It sits on the only route from the line to the GPU (Phase 4 task 13), so the
# claims that matter are the forwarding ones first: a response arrives byte for
# byte, a streamed one arrives AS it streams (a buffered stream is a silent model
# to pi's idle timeout), and an upstream that dies mid-answer is relayed as it
# died rather than taking the proxy down. Then the measurement: ollama's native
# metrics in nanoseconds, the OpenAI shape's `usage` counts with and without the
# usage chunk, TTFT, tags. Then the wiring: off by default, and off means the
# judge and the gateway are pointed exactly where they were before.
#
# Nothing here talks to :11434. A real bean may be on the GPU while this runs;
# fake-ollama.py answers in ollama's shapes on a port of its own.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERE="$PIPELINE_DIR/tests"
PY="${PIPELINE_PYTHON:-python3}"
WORK="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:300}"; FAIL=$((FAIL+1)); fi
}
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@" >/dev/null; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}
wait_file() { local _i; for _i in $(seq 1 50); do [ -s "$1" ] && return 0; sleep 0.1; done; return 1; }

"$PY" "$HERE/fake-ollama.py" --port-file "$WORK/up.port" --seen "$WORK/seen.jsonl" &
PIDS+=($!)
wait_file "$WORK/up.port" || { echo "fake upstream did not start"; exit 1; }
UP="$(cat "$WORK/up.port")"

start_recorder() { # start_recorder <name> [extra args...] -> port in $WORK/<name>.port
  local name="$1"; shift
  "$PY" "$PIPELINE_DIR/inference-recorder.py" serve --listen 127.0.0.1:0 --upstream "127.0.0.1:$UP" \
    --log "$WORK/$name.jsonl" --port-file "$WORK/$name.port" "$@" 2>"$WORK/$name.err" &
  PIDS+=($!)
  wait_file "$WORK/$name.port" || { echo "recorder $name did not start"; cat "$WORK/$name.err"; exit 1; }
}

FACTORY_BEAN=bean-env FACTORY_ROLE=developer FACTORY_STEP=spec \
  start_recorder main --requests-dir "$WORK/requests" --tags-file "$WORK/tags.json"
RP="$(cat "$WORK/main.port")"
D="http://127.0.0.1:$UP"; P="http://127.0.0.1:$RP"
nth() { sed -n "${1}p" "$WORK/main.jsonl"; }   # the n-th record
lines() { wc -l < "$WORK/main.jsonl" 2>/dev/null | tr -d ' '; }

echo "forwarding is byte-identical"
for case_ in 'stream|{"model":"m","messages":[{"role":"user","content":"hi"}]}' \
             'nostream|{"model":"m","stream":false,"messages":[]}' \
             'generate|{"model":"m","prompt":"p"}' \
             'v1sse|{"model":"m","stream":true,"stream_options":{"include_usage":true},"messages":[]}' \
             'v1json|{"model":"m","messages":[]}'; do
  name="${case_%%|*}"; body="${case_#*|}"
  path=/api/chat; [ "$name" = generate ] && path=/api/generate
  case "$name" in v1*) path=/v1/chat/completions ;; esac
  # --raw keeps the chunk framing, -i the status line and headers: the whole
  # response as it was on the wire.
  curl -sS --raw -i "$D$path" -d "$body" > "$WORK/direct.$name"
  curl -sS --raw -i "$P$path" -d "$body" > "$WORK/proxy.$name"
  want "$name: same bytes direct and through the recorder" "the responses differ" \
    cmp -s "$WORK/direct.$name" "$WORK/proxy.$name"
done
check "the streamed case really was chunked" "Transfer-Encoding: chunked" "$(cat "$WORK/proxy.stream")"
eq "five model calls, five records" 5 "$(lines)"

echo "metrics: native"
R1="$(nth 1)"
eq "path"                 "/api/chat" "$(jq -r .path <<<"$R1")"
eq "model"                "m"         "$(jq -r .model <<<"$R1")"
eq "stream (absent = ollama's default, true)" true "$(jq -r .stream <<<"$R1")"
# `* 1` so jq prints the number, not the literal: 2.0 and 2 are the same value.
eq "prompt_eval_count"    1000  "$(jq -r .prompt_eval_count <<<"$R1")"
eq "prompt_eval_duration_s (ns -> s)" 2 "$(jq -r '.prompt_eval_duration_s * 1' <<<"$R1")"
eq "eval_count"           50    "$(jq -r .eval_count <<<"$R1")"
eq "eval_duration_s"      0.5   "$(jq -r '.eval_duration_s * 1' <<<"$R1")"
eq "load_duration_s"      1.5   "$(jq -r '.load_duration_s * 1' <<<"$R1")"
eq "total_duration_s"     4     "$(jq -r '.total_duration_s * 1' <<<"$R1")"
eq "prefill_tok_s = 1000 / 2"   500 "$(jq -r '.prefill_tok_s * 1' <<<"$R1")"
eq "decode_tok_s = 50 / 0.5"    100 "$(jq -r '.decode_tok_s * 1' <<<"$R1")"
eq "status"               200   "$(jq -r .status <<<"$R1")"
eq "request_bytes"        "$(printf '%s' '{"model":"m","messages":[{"role":"user","content":"hi"}]}' | wc -c | tr -d ' ')" \
                          "$(jq -r .request_bytes <<<"$R1")"
want "streamed: ttft is a number" "ttft_s: $(jq -r .ttft_s <<<"$R1")" jq -e '.ttft_s | type == "number"' <<<"$R1"
R2="$(nth 2)"
eq "non-streamed: stream false" false "$(jq -r .stream <<<"$R2")"
eq "non-streamed: ttft null"    null  "$(jq -r .ttft_s <<<"$R2")"
eq "non-streamed: metrics read from the one object" 500 "$(jq -r '.prefill_tok_s * 1' <<<"$R2")"
eq "generate: metrics read"     1000  "$(jq -r .prompt_eval_count <<<"$(nth 3)")"

echo "metrics: OpenAI-compatible"
R4="$(nth 4)"
eq "SSE with usage: prompt tokens from usage"     321 "$(jq -r .prompt_eval_count <<<"$R4")"
eq "SSE with usage: completion tokens from usage" 12  "$(jq -r .eval_count <<<"$R4")"
eq "SSE: durations null, not estimated" "null null null" \
   "$(jq -r '"\(.prompt_eval_duration_s) \(.eval_duration_s) \(.prefill_tok_s)"' <<<"$R4")"
eq "SSE: metrics_source says usage" usage "$(jq -r .metrics_source <<<"$R4")"
want "SSE: ttft is a number" "ttft_s missing" jq -e '.ttft_s | type == "number"' <<<"$R4"
eq "/v1 non-streamed: stream false (the /v1 default)" false "$(jq -r .stream <<<"$(nth 5)")"
eq "/v1 non-streamed: usage read" 321 "$(jq -r .prompt_eval_count <<<"$(nth 5)")"
curl -sS "$P/v1/chat/completions" -d '{"model":"m","stream":true,"messages":[]}' >/dev/null
R6="$(nth 6)"
eq "SSE without a usage chunk: counts null, no crash" "null null" \
   "$(jq -r '"\(.prompt_eval_count) \(.eval_count)"' <<<"$R6")"
eq "SSE without usage: done_reason still read" stop "$(jq -r .done_reason <<<"$R6")"

echo "tags"
eq "env at start: bean, role, step" "bean-env developer spec" \
   "$(jq -r '"\(.tags.bean) \(.tags.role) \(.tags.step)"' <<<"$R1")"
printf '{"role":"judge","step":"audit-spec"}' > "$WORK/tags.json"
curl -sS "$P/api/chat" -d '{"model":"m","stream":false}' >/dev/null
eq "tags file over env, re-read per call" "bean-env judge audit-spec" \
   "$(jq -r '"\(.tags.bean) \(.tags.role) \(.tags.step)"' <<<"$(nth 7)")"
curl -sS "$P/api/chat" -H 'X-Factory-Role: reviewer' -H 'X-Factory-Bean: bean-hdr' \
  -H 'X-Factory-Some-Thing: x' -d '{"model":"m","stream":false}' >/dev/null
eq "headers over both" "bean-hdr reviewer audit-spec x" \
   "$(jq -r '"\(.tags.bean) \(.tags.role) \(.tags.step) \(.tags.some_thing)"' <<<"$(nth 8)")"
rm -f "$WORK/tags.json"

echo "requests saved for replay"
f="$WORK/requests/$(jq -r .request_file <<<"$R1")"
want "the body is saved byte for byte" "$f differs from what was sent" \
  cmp -s "$f" <(printf '%s' '{"model":"m","messages":[{"role":"user","content":"hi"}]}')
eq "named <seq>-<role>" "00001-developer.request.json" "$(basename "$f")"
eq "the sidecar has the path" "/api/chat" "$(jq -r .path "${f%.request.json}.meta.json")"

echo "not recorded: non-model paths"
n_before="$(lines)"
out="$(curl -sS "$P/api/ps")"
check "/api/ps is forwarded" '"fake:1b"' "$out"
curl -sS "$P/api/version" >/dev/null
eq "and not recorded" "$n_before" "$(lines)"

echo "streaming is relayed incrementally"
cat > "$WORK/client.py" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
body = b'{"model":"slow","messages":[]}'
s = socket.create_connection(("127.0.0.1", port))
t0 = time.monotonic()
s.sendall(b"POST /api/chat HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
          b"Content-Length: %d\r\n\r\n" % len(body) + body)
buf, first = b"", None
while True:
    d = s.recv(65536)
    if not d:
        break
    buf += d
    if first is None and b'"hello"' in buf:
        first = time.monotonic() - t0
    if buf.endswith(b"0\r\n\r\n"):
        break
print(f"{first:.3f} {time.monotonic() - t0:.3f}")
PY
read -r first total < <("$PY" "$WORK/client.py" "$RP")
want "the first token arrived before upstream finished (first ${first}s, total ${total}s)" \
  "the response was buffered" awk -v f="$first" -v t="$total" 'BEGIN{exit !(f < 1.0 && t >= 2.0)}'
eq "ttft measured at the first token chunk, not the first chunk (~0.3 s)" yes \
   "$(jq -r '.ttft_s | if . > 0.25 and . < 1.5 then "yes" else "no \(.)" end' <<<"$(tail -1 "$WORK/main.jsonl")")"

echo "a kept-alive connection carries a second request"
cat > "$WORK/keepalive.py" <<'PY'
import http.client, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]))
out = []
for body in ('{"model":"m","stream":false}', '{"model":"m"}'):
    c.request("POST", "/api/chat", body, {"Content-Type": "application/json"})
    r = c.getresponse(); out.append(f"{r.status}:{len(r.read())}")
print(" ".join(out))
PY
check "two answers on one connection" "200:" "$("$PY" "$WORK/keepalive.py" "$RP" 2>&1)"
eq "both answers whole" 2 "$("$PY" "$WORK/keepalive.py" "$RP" 2>&1 | grep -o '200:[1-9]' | wc -l | tr -d ' ')"

echo "Expect: 100-continue"
"$PY" -c 'import json; print(json.dumps({"model":"m","stream":False,"messages":[{"role":"user","content":"a"*2000000}]}))' > "$WORK/big.json"
# --expect100-timeout past --max-time: curl must be TOLD to continue, or it
# waits out the clock. Its default is to give up waiting after a second and
# send anyway, which would pass this whether or not the 100 was answered.
out="$(curl -sS -H 'Expect: 100-continue' --expect100-timeout 30 --max-time 5 "$P/api/chat" --data-binary @"$WORK/big.json")"
check "a large body behind Expect: 100-continue still gets its answer" '"done": true' "$out"

echo "a broken upstream does not break the recorder"
curl -sS --raw -i --max-time 5 "$D/api/chat" -d '{"model":"abort"}' > "$WORK/direct.abort" 2>/dev/null
curl -sS --raw -i --max-time 5 "$P/api/chat" -d '{"model":"abort"}' > "$WORK/proxy.abort" 2>/dev/null
want "aborted mid-stream: the client gets what upstream sent" "differs" \
  cmp -s "$WORK/direct.abort" "$WORK/proxy.abort"
check "and that was a partial answer" '"hello"' "$(cat "$WORK/proxy.abort")"
RA="$(tail -1 "$WORK/main.jsonl")"
check "recorded, with the error named" "before the response was complete" "$(jq -r .error <<<"$RA")"
curl -sS --raw -i --max-time 5 "$D/api/chat" -d '{"model":"garbage"}' > "$WORK/direct.garbage"
curl -sS --raw -i --max-time 5 "$P/api/chat" -d '{"model":"garbage"}' > "$WORK/proxy.garbage"
want "malformed body: relayed unchanged" "differs" cmp -s "$WORK/direct.garbage" "$WORK/proxy.garbage"
eq "malformed body: recorded with null metrics" "null 200" \
   "$(jq -r '"\(.prompt_eval_count) \(.status)"' <<<"$(tail -1 "$WORK/main.jsonl")")"
check "and the recorder still answers afterwards" '"fake:1b"' "$(curl -sS --max-time 5 "$P/api/ps")"

echo "an unreachable upstream"
"$PY" "$PIPELINE_DIR/inference-recorder.py" serve --listen 127.0.0.1:0 --upstream 127.0.0.1:1 \
  --log "$WORK/dead.jsonl" --port-file "$WORK/dead.port" 2>/dev/null &
PIDS+=($!); wait_file "$WORK/dead.port"
out="$(curl -sS -i --max-time 5 "http://127.0.0.1:$(cat "$WORK/dead.port")/api/chat" -d '{"model":"m"}')"
check "answers 502, naming the upstream" "502 Bad Gateway" "$out"
check "and records the call" "unreachable" "$(cat "$WORK/dead.jsonl")"

echo "a recording failure does not break forwarding"
"$PY" "$PIPELINE_DIR/inference-recorder.py" serve --listen 127.0.0.1:0 --upstream "127.0.0.1:$UP" \
  --log "$WORK/ro/calls.jsonl" --port-file "$WORK/ro.port" 2>"$WORK/ro.err" &
PIDS+=($!); wait_file "$WORK/ro.port"
chmod 500 "$WORK/ro"; rm -f "$WORK/ro/calls.jsonl" 2>/dev/null
out="$(curl -sS --max-time 5 "http://127.0.0.1:$(cat "$WORK/ro.port")/api/chat" -d '{"model":"m","stream":false}')"
chmod 700 "$WORK/ro"
check "the log is unwritable and the answer still arrives" '"done": true' "$out"
check "the failure went to stderr" "could not record" "$(cat "$WORK/ro.err")"

echo "parent pid: ends with the run that started it"
sleep 30 & PARENT=$!
"$PY" "$PIPELINE_DIR/inference-recorder.py" serve --listen 127.0.0.1:0 --upstream "127.0.0.1:$UP" \
  --log "$WORK/pp.jsonl" --port-file "$WORK/pp.port" --parent-pid "$PARENT" 2>/dev/null &
PP=$!; PIDS+=($PP); wait_file "$WORK/pp.port"
kill "$PARENT"; wait "$PARENT" 2>/dev/null
for _ in $(seq 1 40); do kill -0 "$PP" 2>/dev/null || break; sleep 0.1; done
want "the recorder exited when its parent did" "still running" bash -c "! kill -0 $PP 2>/dev/null"

# ------------------------------------------------------------------ wiring --
echo "wiring: off by default, and off changes nothing"
PIPELINE_DIR_SAVED="$PIPELINE_DIR"
(
  unset FACTORY_INFERENCE_RECORD FACTORY_INFERENCE_ADDR FACTORY_INFERENCE_TAGS OLLAMA_HOST
  # shellcheck source=../lib.sh
  source "$PIPELINE_DIR_SAVED/lib.sh"
  printf 'judge=%s\n' "$(judge_host)"
  printf 'gateway=%s\n' "$(gateway_upstream)"
  OLLAMA_HOST=http://elsewhere:1 printf 'judge_env=%s\n' "$(OLLAMA_HOST=http://elsewhere:1 judge_host)"
  mkdir -p "$WORK/run-off"
  inference_record_start "$WORK/run-off" bean-x
  inference_tag developer spec
  printf 'addr=%s tags=%s\n' "${FACTORY_INFERENCE_ADDR:-unset}" "${FACTORY_INFERENCE_TAGS:-unset}"
  printf 'dir=%s\n' "$([ -e "$WORK/run-off/inference" ] && echo made || echo none)"
) > "$WORK/off.txt" 2>&1
OFF="$(cat "$WORK/off.txt")"
check "judge HOST unset: the old default"           "judge=http://127.0.0.1:11434" "$OFF"
check "judge HOST: OLLAMA_HOST still honoured"      "judge_env=http://elsewhere:1" "$OFF"
check "gateway upstream unset: the old default"     "gateway=127.0.0.1:11434" "$OFF"
check "no recorder, no address, no tags"            "addr=unset tags=unset" "$OFF"
check "nothing written into the run dir"            "dir=none" "$OFF"
want "judge.sh asks judge_host"  "judge.sh does not use judge_host" grep -q 'HOST="$(judge_host)"' "$PIPELINE_DIR/judge.sh"
want "run-step.sh passes gateway_upstream" "run-step.sh does not use gateway_upstream" \
  grep -q 'model-gateway.sh" start --upstream "$(gateway_upstream)"' "$PIPELINE_DIR/run-step.sh"

want "orchestrate.sh starts the recorder from run_step" "no inference_record_start in orchestrate.sh" \
  grep -q 'inference_record_start "$RUN_DIR" "$BEAN_ID" "$\$"' "$PIPELINE_DIR/orchestrate.sh"
want "orchestrate.sh tags the judge's calls" "no inference_tag judge" \
  grep -q 'inference_tag judge "$step"' "$PIPELINE_DIR/orchestrate.sh"
want "run-step.sh tags the worker's calls" "no inference_tag in run-step.sh" \
  grep -q 'inference_tag "$ROLE" "$STEP"' "$PIPELINE_DIR/run-step.sh"

echo "wiring: on"
(
  export FACTORY_INFERENCE_RECORD=1 FACTORY_INFERENCE_UPSTREAM="127.0.0.1:$UP"
  unset FACTORY_INFERENCE_ADDR FACTORY_INFERENCE_TAGS
  source "$PIPELINE_DIR_SAVED/lib.sh"
  mkdir -p "$WORK/run-on"
  sleep 60 & owner=$!
  inference_record_start "$WORK/run-on" bean-042 "$owner" 2>/dev/null
  printf 'judge=%s\n' "$(judge_host)"
  printf 'gateway=%s\n' "$(gateway_upstream)"
  inference_tag judge audit-impl
  curl -sS "$(judge_host)/api/chat" -d '{"model":"m","stream":false}' >/dev/null
  inference_tag developer build-task T3
  curl -sS "http://$(gateway_upstream)/api/chat" -d '{"model":"m","stream":false}' >/dev/null
  printf 'role_env=%s\n' "${FACTORY_ROLE:-unset}"
  kill "$owner"
) > "$WORK/on.txt" 2>&1
ON="$(cat "$WORK/on.txt")"
check "judge HOST is the recorder"       "judge=http://127.0.0.1:" "$ON"
check "gateway upstream is the recorder" "gateway=127.0.0.1:" "$ON"
want "and neither is :11434" "still pointed at 11434" bash -c "! grep -q 11434 '$WORK/on.txt'"
check "FACTORY_ROLE did not leak into the caller (run-step reads it as an override)" "role_env=unset" "$ON"
CALLS="$WORK/run-on/inference/calls.jsonl"
eq "calls.jsonl in the run's inference/" 2 "$(wc -l < "$CALLS" 2>/dev/null | tr -d ' ')"
eq "judge call tagged" "bean-042 judge audit-impl" \
   "$(sed -n 1p "$CALLS" | jq -r '"\(.tags.bean) \(.tags.role) \(.tags.step)"')"
eq "worker call tagged, with its task" "bean-042 developer build-task T3" \
   "$(sed -n 2p "$CALLS" | jq -r '"\(.tags.bean) \(.tags.role) \(.tags.step) \(.tags.task)"')"
eq "requests saved for replay" 2 "$(ls "$WORK/run-on/inference/requests/"*.request.json 2>/dev/null | wc -l | tr -d ' ')"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
