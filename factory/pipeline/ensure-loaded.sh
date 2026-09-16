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
# Exit: 0 loaded at the declared context · 1 loaded at a different one (said, not
#       hidden) · 2 could not load at all
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
ensure-loaded.sh — load a role's model at the context roles.json declares.

usage: ensure-loaded.sh <role> [--keep-alive <duration>] [--check-only]

  --keep-alive  how long ollama should hold it (default 60m)
  --check-only  report what is loaded; load nothing

Exit: 0 at the declared context · 1 loaded at another · 2 could not load.
EOF
}

ROLE=""; KEEP="60m"; CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-alive) KEEP="${2:?}"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
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

if [ -n "$WANT_CTX" ] && [ "$NOW" = "$WANT_CTX" ]; then
  printf 'LOADED  %-28s already at %s\n' "$MODEL" "$NOW"
  exit 0
fi

# An empty message list is the documented way to ask ollama to load a model and
# nothing else. num_predict 0 so that a server which decides to answer anyway
# costs nothing.
BODY="$(jq -nc --arg m "$MODEL" --arg k "$KEEP" --argjson c "${WANT_CTX:-null}" \
  '{model:$m, messages:[], stream:false, keep_alive:$k}
   + (if $c == null then {} else {options:{num_ctx:$c, num_predict:0}} end)')"
RESP="$(curl -sS --max-time 600 "$HOST/api/chat" -d "$BODY" 2>&1)" || {
  printf 'LOAD FAILED  %s: %s\n' "$MODEL" "${RESP:0:160}" >&2; exit 2; }

NOW="$(loaded_ctx)"
if [ -z "$NOW" ]; then
  printf 'LOAD FAILED  %s: the server reports it as not loaded after the request\n' "$MODEL" >&2
  printf '             %s\n' "$(jq -rc '.error // .' <<<"$RESP" 2>/dev/null | head -c 160)" >&2
  exit 2
fi
if [ -n "$WANT_CTX" ] && [ "$NOW" != "$WANT_CTX" ]; then
  # Reported, never hidden. A run that believes it holds a role at 65536 when the
  # server holds it at 262144 is a run whose conditions block is fiction, and the
  # whole point of this script is to stop that being unfixable rather than to
  # pretend it is fixed.
  printf 'LOADED  %-28s at %s after asking for %s — the server did not honour it\n' \
    "$MODEL" "$NOW" "$WANT_CTX" >&2
  exit 1
fi
printf 'LOADED  %-28s at %s, held for %s\n' "$MODEL" "$NOW" "$KEEP"
