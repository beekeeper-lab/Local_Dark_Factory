#!/usr/bin/env bash
# inference-replay.sh — send recorded model requests again, one variable changed.
#
# Phase 4 task 13. Every inference change on the parking lot — num_batch for
# prefill throughput, num_ctx, prompt order for prefix caching — is a claim that
# a server configuration makes the SAME work faster. "The same work" is the hard
# part: a live run never asks the same question twice, and comparing one bean's
# audits with another's measures the beans. A recorded request is the same work,
# exactly, as many times as it is sent.
#
# So this takes request bodies a recorded run saved (<run>/inference/requests/,
# written by factory/pipeline/inference-recorder.py), sends each one N times
# through a recorder of its own, and the records come out in the shape a live
# run's do — inference-report.py reads both. `--set key=value` changes one
# ollama option in every request, and only that; the label names the
# configuration so two replays can be laid side by side:
#
#   bench/inference-replay.sh <run>/inference/requests --label base --passes 3
#   bench/inference-replay.sh <run>/inference/requests --label batch1024 --set num_batch=1024 --passes 3
#   bench/inference-report.py bench/results/inference-replay-{base,batch1024}-*.jsonl
#
# One variable at a time is the discipline, and the script enforces the half of
# it a script can: --set touches `options` and nothing else, and a request that
# has no `options` to change — the OpenAI-shaped /v1 calls pi makes, where
# ollama does not read one — is skipped and counted rather than replayed
# unchanged under a label that says it was changed.
#
# What it will not replay: a judge run's verdicts/<target>.request.json. Despite
# the name, that file is a sidecar recording what was SENT — bytes, model,
# num_ctx — not the body (judge.sh's comment above the jq that writes it). It has
# no messages, so it is skipped and named. A judge call is replayable from a run
# recorded with FACTORY_INFERENCE_RECORD=1, which saves the body itself.
#
# It refuses to run while the line holds the GPU: two models on one card means
# both records stop meaning what they say (inflight.sh has the history). --force
# runs anyway and the results file says it did.
set -uo pipefail
if [ "${FACTORY_BENCH_SNAPSHOTTED:-0}" != 1 ] && [ "${FACTORY_NO_SNAPSHOT:-0}" != 1 ]; then
  exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/snapshot.sh" \
    "$(basename "${BASH_SOURCE[0]}")" "$@"
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PIPE="$ROOT/factory/pipeline"
# shellcheck source=inflight.sh
source "$HERE/inflight.sh"

usage() {
  cat <<'EOF'
inference-replay.sh — replay recorded model requests against a server.

usage: inference-replay.sh <dir|file.request.json>... --label <name>
                           [--passes <n>] [--set key=value]... [--server <url>]
                           [--state-dir <dir>]... [--out-dir <dir>] [--force]

  <dir>        every *.request.json in it, in name order (a run's inference/requests/)
  --label      the configuration's name; it goes in the results file name and
               on every record as tags.label
  --passes     how many times each request is sent (default 1)
  --set k=v    set options.k in every request (value read as JSON when it
               parses, else as a string); repeatable, though one at a time is
               the point
  --server     the model server (default http://127.0.0.1:11434)
  --state-dir  a line state directory to check for a GPU holder (repeatable;
               default: $FACTORY_STATE_DIR and this repo's factory/runs/.state)
  --out-dir    where the results go (default bench/results)
  --force      replay even while the line holds the GPU

Writes <out-dir>/inference-replay-<label>-<ts>.jsonl: a provenance line, then
one recorder line per call. Summarise with bench/inference-report.py.
Exit: 0 replayed · 1 a request failed · 2 refused or misconfigured.
EOF
}

INPUTS=(); LABEL=""; PASSES=1; SETS=(); SERVER="http://127.0.0.1:11434"; STATE_DIRS=()
OUT_DIR="$ROOT/bench/results"; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --label)     LABEL="${2:?--label needs a name}"; shift 2 ;;
    --passes)    PASSES="${2:?}"; shift 2 ;;
    --set)       SETS+=("${2:?--set needs key=value}"); shift 2 ;;
    --server)    SERVER="${2:?}"; shift 2 ;;
    --state-dir) STATE_DIRS+=("${2:?}"); shift 2 ;;
    --out-dir)   OUT_DIR="${2:?}"; shift 2 ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          usage >&2; printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
    *)           INPUTS+=("$1"); shift ;;
  esac
done
[ -n "$LABEL" ] || { usage >&2; printf '\n--label is required: a replay nobody can name is one nobody can compare.\n' >&2; exit 2; }
case "$LABEL" in *[!A-Za-z0-9_.-]*) printf 'label must be [A-Za-z0-9_.-]: %s\n' "$LABEL" >&2; exit 2 ;; esac
case "$PASSES" in ''|*[!0-9]*|0) printf -- '--passes must be a positive whole number\n' >&2; exit 2 ;; esac
[ "${#INPUTS[@]}" -gt 0 ] || { usage >&2; exit 2; }
command -v jq >/dev/null && command -v curl >/dev/null || { printf 'needs jq and curl\n' >&2; exit 2; }

# The overrides as one JSON object, built before anything is sent, so a typo is
# a refusal and not N passes of a measurement of the typo.
OVR='{}'
for kv in ${SETS[@]+"${SETS[@]}"}; do
  k="${kv%%=*}"; v="${kv#*=}"
  [ "$k" != "$kv" ] && [ -n "$k" ] || { printf -- '--set wants key=value, got %s\n' "$kv" >&2; exit 2; }
  OVR="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): ($v | try fromjson catch $v)}' <<<"$OVR")"
done

# ------------------------------------------------------------- GPU guard --
# The inference gate (infergate.py) names the process holding the GPU in
# <state>/inference.json; a holder whose process is alive is the line mid-step.
# Between steps the gate is free while a bean is still in flight, so the
# orchestrate.sh check in inflight.sh is the second half of the same question.
[ -n "${FACTORY_STATE_DIR:-}" ] && STATE_DIRS+=("$FACTORY_STATE_DIR")
[ "${#STATE_DIRS[@]}" -gt 0 ] || STATE_DIRS+=("$ROOT/factory/runs/.state")
HOLDER=""
for sd in "${STATE_DIRS[@]}"; do
  f="$sd/inference.json"; [ -f "$f" ] || continue
  owner="$(jq -r '.holder.owner // empty' "$f" 2>/dev/null)"
  [ -n "$owner" ] || continue
  h="${owner%:*}"; p="${owner##*:}"
  if [ "$h" != "$(hostname)" ] || kill -0 "$p" 2>/dev/null; then
    HOLDER="$(jq -r '"\(.holder.bean // "?") (\(.holder.role // "?"), \(.holder.owner))"' "$f") in $f"; break
  fi
done
CONTENDED=0
if [ -n "$HOLDER" ]; then
  if [ "$FORCE" = 1 ]; then
    printf 'NOTE — the line holds the GPU (%s) and --force is replaying anyway.\n' "$HOLDER" >&2
    CONTENDED=1
  else
    printf 'REFUSED — the line holds the GPU: %s.\n' "$HOLDER" >&2
    printf 'A replay beside a live step measures the contention, not the configuration.\n' >&2
    printf 'Wait for it, or pass --force and accept that.\n' >&2
    exit 2
  fi
fi
[ -n "$(_inflight_others '[o]rchestrate\.sh')" ] && CONTENDED=1
if [ "$FORCE" = 1 ]; then FACTORY_MEASURE_ANYWAY=1 refuse_if_inflight
else refuse_if_inflight; fi

# ---------------------------------------------------------------- inputs --
FILES=()
for in_ in "${INPUTS[@]}"; do
  if [ -d "$in_" ]; then
    while IFS= read -r f; do FILES+=("$f"); done < <(find "$in_" -maxdepth 1 -name '*.request.json' | sort)
  elif [ -f "$in_" ]; then FILES+=("$in_")
  else printf 'no such file or directory: %s\n' "$in_" >&2; exit 2; fi
done

WORK="$(mktemp -d)"; REC_PID=""
cleanup() { [ -n "$REC_PID" ] && kill "$REC_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# Each request: path, role, body. The path comes from the recorder's sidecar,
# else from the body's shape (messages: chat; prompt: generate).
PLAN=(); SKIPPED=0
for f in "${FILES[@]}"; do
  meta="${f%.request.json}.meta.json"
  if ! jq -e 'type == "object" and (has("messages") or has("prompt"))' "$f" >/dev/null 2>&1; then
    printf 'SKIP   %s — not a request body (a judge verdicts/*.request.json records what was sent, not the body)\n' "$f" >&2
    SKIPPED=$((SKIPPED + 1)); continue
  fi
  path="$(jq -r '.path // empty' "$meta" 2>/dev/null)"
  [ -n "$path" ] || path="$(jq -r 'if has("messages") then "/api/chat" else "/api/generate" end' "$f")"
  role="$(jq -r '.tags.role // empty' "$meta" 2>/dev/null)"
  if [ -z "$role" ]; then
    role="$(basename "$f" .request.json)"; role="${role#*-}"
    [ "$role" != "$(basename "$f" .request.json)" ] || role=unknown
  fi
  if [ "$OVR" != '{}' ]; then
    case "$path" in
      /api/*) ;;
      *) printf 'SKIP   %s — %s takes no ollama options, so --set would change nothing\n' "$f" "$path" >&2
         SKIPPED=$((SKIPPED + 1)); continue ;;
    esac
  fi
  n="${#PLAN[@]}"
  jq -c --argjson o "$OVR" 'if $o == {} then . else .options = ((.options // {}) + $o) end' "$f" > "$WORK/$n.json" \
    || { printf 'could not prepare %s\n' "$f" >&2; exit 2; }
  PLAN+=("$path|$role|$(basename "$f")|$WORK/$n.json")
done
[ "${#PLAN[@]}" -gt 0 ] || { printf 'nothing to replay (%s skipped)\n' "$SKIPPED" >&2; exit 2; }

# -------------------------------------------------------------- recorder --
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/inference-replay-$LABEL-$TS.jsonl"
UP="${SERVER#http://}"; UP="${UP#https://}"; UP="${UP%%/*}"
# Provenance first, from the server under test rather than the `ollama` CLI:
# the CLI asks whatever OLLAMA_HOST points at, which need not be --server.
VER="$(curl -s --max-time 5 "$SERVER/api/version" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)"
jq -nc --arg host "$(hostname)" --arg kernel "$(uname -r)" --arg ts "$TS" --arg server "$SERVER" \
  --arg v "$VER" --arg label "$LABEL" --argjson o "$OVR" --argjson p "$PASSES" \
  --argjson n "${#PLAN[@]}" --argjson s "$SKIPPED" --argjson c "$CONTENDED" \
  --arg sha "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)" \
  '{kind:"provenance", harness:"inference-replay", host:$host, kernel:$kernel, ts:$ts,
    server:$server, server_version:(if $v == "" then null else $v end), label:$label,
    set:$o, passes:$p, requests:$n, skipped:$s, contended:($c == 1), git:$sha}' > "$OUT"

"$(command -v python3)" "$PIPE/inference-recorder.py" serve --listen 127.0.0.1:0 --upstream "$UP" \
  --log "$OUT" --port-file "$WORK/port" --parent-pid $$ 2>"$WORK/recorder.log" &
REC_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
PORT="$(cat "$WORK/port" 2>/dev/null)"
[ -n "$PORT" ] || { cat "$WORK/recorder.log" >&2; printf 'the recorder did not start\n' >&2; exit 2; }

SETTAG="$(jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$OVR")"
FAILED=0
for pass in $(seq 1 "$PASSES"); do
  for item in "${PLAN[@]}"; do
    IFS='|' read -r path role src body <<<"$item"
    # `Expect:` empty: curl would otherwise ask permission before a large body.
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3600 -H 'Expect:' \
      -H 'Content-Type: application/json' -H "X-Factory-Role: $role" -H "X-Factory-Label: $LABEL" \
      -H "X-Factory-Pass: $pass" -H "X-Factory-Source: $src" ${SETTAG:+-H "X-Factory-Set: $SETTAG"} \
      --data-binary "@$body" "http://127.0.0.1:$PORT$path" 2>"$WORK/curl.err")" || code="000"
    printf 'REPLAY pass %s/%s  %-28s %-10s -> %s\n' "$pass" "$PASSES" "$src" "$role" "$code" >&2
    case "$code" in 2*) ;; *) FAILED=$((FAILED + 1)); sed 's/^/       /' "$WORK/curl.err" >&2 ;; esac
  done
done
kill "$REC_PID" 2>/dev/null; wait "$REC_PID" 2>/dev/null; REC_PID=""

printf '\n%s\n\n' "$OUT"
"$(command -v python3)" "$HERE/inference-report.py" "$OUT" || true
[ "$FAILED" -eq 0 ] || { printf '\n%s request(s) failed\n' "$FAILED" >&2; exit 1; }
exit 0
