#!/usr/bin/env bash
# ensure-loaded.sh — load a role's model at the context that role declares.
#
# `roles.json` says `num_ctx: 65536` for the developer, and the note beside it
# explains that this is pi's window rather than the server's: pi has no context
# flag, so ollama serves whatever `OLLAMA_CONTEXT_LENGTH` or the last request
# asked for, and a real run duly recorded `declared=65536 observed=262144`. The
# run record has been honest about that drift since 2026-09-14 and unable to do
# anything about it.
#
# It can be done about. The ollama API takes `options.num_ctx` per request, and
# the loaded instance keeps the context it was loaded with — `judge.sh` has been
# relying on that since it was written, which is why `/api/ps` reports the judge
# at exactly the 32768 it asks for. So: load the model deliberately, at the
# declared size, with a keep-alive, before the step that needs it. The step's own
# request then reuses the loaded instance.
#
# The global alternative is `OLLAMA_CONTEXT_LENGTH` on the systemd unit, which is
# one number for every role and every other project on this machine. That was
# deliberately not done, and this is why it did not have to be.
#
# Phase 4 (task 3) made this the inference manager's contract from §09:
#
#   ensure_loaded(role)   serial regime: unload every other role's model first,
#                         then load this one, retrying a failed load twice
#   healthcheck(role)     the model is in /api/tags with the digest the run
#                         declared, and a one-token probe answers
#   load_seconds          per load, appended to --record, for swap_overhead_pct
#
# Exit: 0 loaded at the declared context · 1 loaded at a different one (said, not
#       hidden) · 2 could not load at all, after the retries · 3 loaded but failed
#       its health check (wrong digest, or no answer to the probe)
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
ensure-loaded.sh — load a role's model at the context roles.json declares.

usage: ensure-loaded.sh <role> [--keep-alive <duration>] [--check-only]
                        [--healthcheck] [--expect-digest <sha>] [--record <file>]
                        [--retries <n>] [--coresident]

  --keep-alive     how long ollama should hold it (default 60m)
  --check-only     report what is loaded; load nothing
  --healthcheck    after loading: digest in /api/tags, and a one-token probe
  --expect-digest  the digest (or its 12-character prefix) the run declared
  --record         append one JSON line per call: load_seconds, what was evicted
  --retries        failed loads retried this many times (default 2)
  --coresident     do not evict other roles' models (the serial regime does)

Exit: 0 at the declared context · 1 loaded at another · 2 could not load ·
      3 unhealthy.
EOF
}

ROLE=""; KEEP="60m"; CHECK_ONLY=0; HEALTH=0; EXPECT=""; RECORD=""; RETRIES=2
# Serial unless told otherwise: Phase 0 measured that the developer and the judge
# cannot co-reside on Forge.
EVICT=1; [ "${FACTORY_REGIME:-serial}" = coresident ] && EVICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-alive) KEEP="${2:?}"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --healthcheck) HEALTH=1; shift ;;
    --expect-digest) EXPECT="${2:-}"; shift 2 ;;
    --record) RECORD="${2:?}"; shift 2 ;;
    --retries) RETRIES="${2:?}"; shift 2 ;;
    --coresident) EVICT=0; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*) usage >&2; die "unknown flag: $1" ;;
    *) [ -z "$ROLE" ] || die "one role at a time"; ROLE="$1"; shift ;;
  esac
done
[ -n "$ROLE" ] || { usage >&2; exit 2; }
require_cmd jq; require_cmd curl

HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
ROLES_FILE="${ROLES_FILE:-$PIPELINE_DIR/roles.json}"
MODEL="$(jq -r --arg r "$ROLE" '.roles[$r].model // empty' "$ROLES_FILE")"
[ -n "$MODEL" ] || die "roles.json has no model for role '$ROLE'"
WANT_CTX="$(jq -r --arg r "$ROLE" '.roles[$r].num_ctx // empty' "$ROLES_FILE")"

loaded_ctx() { # the context of the loaded instance, or empty
  curl -s --max-time 10 "$HOST/api/ps" 2>/dev/null \
    | jq -r --arg m "$MODEL" '[.models[]? | select(.name == $m) | .context_length] | first // empty'
}

NOW="$(loaded_ctx)"
if [ "$CHECK_ONLY" = 1 ]; then
  if [ -z "$NOW" ]; then
    printf 'LOADED  %-28s not loaded\n' "$MODEL"; exit 2
  fi
  if [ -n "$WANT_CTX" ] && [ "$NOW" != "$WANT_CTX" ]; then
    printf 'LOADED  %-28s at %s, roles.json declares %s\n' "$MODEL" "$NOW" "$WANT_CTX"; exit 1
  fi
  printf 'LOADED  %-28s at %s\n' "$MODEL" "$NOW"; exit 0
fi

T0="$(date +%s.%N)"; EVICTED=""; LOAD_TRIES=0; OUTCOME=""

record() { # record <outcome> — one line per call, whatever happened
  [ -n "$RECORD" ] || return 0
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg role "$ROLE" --arg model "$MODEL" \
    --arg out "$1" --arg ev "$EVICTED" --argjson tries "$LOAD_TRIES" \
    --argjson secs "$(awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')" \
    --arg ctx "${NOW:-}" \
    '{ts:$ts, role:$role, model:$model, outcome:$out, load_seconds:$secs, load_attempts:$tries,
      evicted:($ev | split(" ") | map(select(. != ""))), context:$ctx}' >> "$RECORD" 2>/dev/null || true
}

healthcheck() { # 0 healthy · 3 not
  local tags dig probe
  tags="$(curl -s --max-time 15 "$HOST/api/tags" 2>/dev/null)"
  dig="$(jq -r --arg m "$MODEL" '[.models[]? | select(.name == $m) | .digest] | first // empty' <<<"$tags")"
  if [ -z "$dig" ]; then
    printf 'UNHEALTHY  %s: not in /api/tags\n' "$MODEL" >&2; return 3
  fi
  if [ -n "$EXPECT" ] && [ "${dig#sha256:}" != "${EXPECT#sha256:}" ] && [[ "${dig#sha256:}" != "${EXPECT#sha256:}"* ]]; then
    printf 'UNHEALTHY  %s: digest %s, the run declared %s — never proceed on the wrong model\n' \
      "$MODEL" "${dig:0:12}" "${EXPECT:0:12}" >&2; return 3
  fi
  probe="$(jq -nc --arg m "$MODEL" --argjson c "${WANT_CTX:-null}" \
    '{model:$m, prompt:"Reply with the single word OK.", stream:false, keep_alive:"'"$KEEP"'",
      options:({num_predict:1} + (if $c == null then {} else {num_ctx:$c} end))}')"
  if ! curl -s --max-time 300 "$HOST/api/generate" -d "$probe" 2>/dev/null | jq -e '.done == true' >/dev/null 2>&1; then
    printf 'UNHEALTHY  %s: no answer to a one-token probe\n' "$MODEL" >&2; return 3
  fi
  printf 'HEALTHY  %-28s digest %s, probe answered\n' "$MODEL" "${dig:0:12}"
  return 0
}

# Serial regime: every OTHER role's model out first. Ollama would evict on its
# own when memory runs short, but then the load time includes an eviction nobody
# measured, and a half-evicted pair is the state in which both requests stall.
if [ "$EVICT" = 1 ]; then
  for other in $(jq -r --arg m "$MODEL" '[.roles[].model] | unique | .[] | select(. != $m)' "$ROLES_FILE"); do
    if curl -s --max-time 10 "$HOST/api/ps" | jq -e --arg o "$other" '[.models[]? | select(.name == $o)] | length > 0' >/dev/null 2>&1; then
      curl -s --max-time 60 "$HOST/api/generate" -d "$(jq -nc --arg o "$other" '{model:$o, keep_alive:0}')" >/dev/null 2>&1 || true
      for _ in $(seq 1 120); do
        curl -s --max-time 10 "$HOST/api/ps" | jq -e --arg o "$other" '[.models[]? | select(.name == $o)] | length == 0' >/dev/null 2>&1 && break
        sleep 1
      done
      EVICTED="$EVICTED $other"
      printf 'EVICTED  %s (serial regime: one role resident at a time)\n' "$other"
    fi
  done
fi

if [ -n "$WANT_CTX" ] && [ "$NOW" = "$WANT_CTX" ]; then
  printf 'LOADED  %-28s already at %s\n' "$MODEL" "$NOW"
  if [ "$HEALTH" = 1 ]; then healthcheck || { record unhealthy; exit 3; }; fi
  record already_loaded
  exit 0
fi

# An empty message list is the documented way to ask ollama to load a model and
# nothing else. num_predict 0 so that a server which decides to answer anyway
# costs nothing.
BODY="$(jq -nc --arg m "$MODEL" --arg k "$KEEP" --argjson c "${WANT_CTX:-null}" \
  '{model:$m, messages:[], stream:false, keep_alive:$k}
   + (if $c == null then {} else {options:{num_ctx:$c, num_predict:0}} end)')"
# A load that fails is retried, twice by default (§09: retry <= 2, then block the
# bean). The caller decides what blocking means; this says it could not.
while :; do
  LOAD_TRIES=$((LOAD_TRIES + 1))
  why=""
  if RESP="$(curl -sS --max-time 600 "$HOST/api/chat" -d "$BODY" 2>&1)"; then
    NOW="$(loaded_ctx)"
    [ -n "$NOW" ] && break
    why="the server reports it as not loaded after the request: $(jq -rc '.error // .' <<<"$RESP" 2>/dev/null | head -c 120)"
  else
    NOW=""; why="${RESP:0:160}"
  fi
  printf 'LOAD FAILED  %s (attempt %s of %s): %s\n' "$MODEL" "$LOAD_TRIES" "$((RETRIES + 1))" "$why" >&2
  if [ "$LOAD_TRIES" -gt "$RETRIES" ]; then record load_failed; exit 2; fi
  sleep $((LOAD_TRIES * 5))
done
if [ -n "$WANT_CTX" ] && [ "$NOW" != "$WANT_CTX" ]; then
  # Reported, never hidden. A run that believes it holds a role at 65536 when the
  # server holds it at 262144 is a run whose conditions block is fiction, and the
  # whole point of this script is to stop that being unfixable rather than to
  # pretend it is fixed.
  printf 'LOADED  %-28s at %s after asking for %s — the server did not honour it\n' \
    "$MODEL" "$NOW" "$WANT_CTX" >&2
  if [ "$HEALTH" = 1 ]; then healthcheck || { record unhealthy; exit 3; }; fi
  record wrong_context
  exit 1
fi
printf 'LOADED  %-28s at %s, held for %s\n' "$MODEL" "$NOW" "$KEEP"
if [ "$HEALTH" = 1 ]; then healthcheck || { record unhealthy; exit 3; }; fi
record loaded
