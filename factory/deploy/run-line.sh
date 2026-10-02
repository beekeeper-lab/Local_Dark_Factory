#!/usr/bin/env bash
# run-line.sh — what darkfactory@.service runs: the line, unattended, until drained.
#
# 1. The environment is rebuilt from an allowlist before anything else runs.
#    §08: no frontier provider exists in the runtime, and the factory user's
#    environment carries no API key but GitHub's. An allowlist rather than a
#    denylist, because a denylist has to know every name a key can have.
# 2. Then, forever: reconcile (the state log made to agree with GitHub and the
#    tree), `factory go`, and when nothing is ready, wait for a merge.
# 3. It stops on `factory drain` / `stop-now`, and on the pivot trigger's
#    same-class rule: three beans in a row halting means the cause is probably
#    the line or the machine, not the beans, so it stops and says so rather than
#    walking the rest of the queue into the same wall.
# One compound command, parsed whole before it runs: this loop runs for days and
# its file is updated by git pull underneath it (see bin/factory).
{
set -uo pipefail

if [ -z "${_DF_SCRUBBED:-}" ]; then
  keep=(PATH HOME USER LOGNAME LANG LC_ALL TZ TERM XDG_RUNTIME_DIR CONTAINERS_STORAGE_CONF
        OLLAMA_HOST GH_TOKEN PIPELINE_CONFIG)
  args=(_DF_SCRUBBED=1)
  for v in "${keep[@]}"; do [ -n "${!v+x}" ] && args+=("$v=${!v}"); done
  # The line's own switches (FACTORY_ADVISORY_AUDITS, FACTORY_STATE_STRICT, ...)
  # are configuration, not credentials.
  while IFS='=' read -r name _; do
    case "$name" in FACTORY_*) args+=("$name=${!name}") ;; esac
  done < <(env)
  exec env -i "${args[@]}" bash "$0" "$@"
fi
for name in $(env | cut -d= -f1); do
  case "$name" in
    *API_KEY*|*SECRET*|ANTHROPIC_*|OPENAI_*|GEMINI_*|GOOGLE_API*|AWS_*)
      printf 'run-line: %s survived the scrub; refusing to run the line with it\n' "$name" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY="${FACTORY_BIN:-$HERE/../bin/factory}"
IDLE="${FACTORY_IDLE_SECONDS:-600}"
MAX_HALTS="${FACTORY_MAX_CONSECUTIVE_HALTS:-3}"
say() { printf '%s run-line: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
notify() { command -v notify-push >/dev/null 2>&1 && notify-push "factory: $*" >/dev/null 2>&1 || true; }
control() { "$FACTORY" state --control 2>/dev/null || true; }

halts=0
say "started on $(pwd)"
while :; do
  v="$(control)"
  if [ "$v" = drain ] || [ "$v" = stop-now ]; then say "factory $v: stopping"; exit 0; fi
  "$FACTORY" reconcile --apply || say "reconcile exited $?; continuing on the log as it stands"
  out="$("$FACTORY" go 2>&1)"; rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    halts=$((halts + 1))
    say "a bean halted (exit $rc), $halts in a row"
    notify "a bean halted on $(basename "$(pwd)") (exit $rc); $halts in a row"
    if [ "$halts" -ge "$MAX_HALTS" ]; then
      say "$halts beans in a row halted: the cause is likely the line or the machine. Stopping."
      notify "$halts beans halted in a row on $(basename "$(pwd)"); the line has stopped"
      exit 3
    fi
    continue   # the halted bean is blocked now, so the next go moves past it
  fi
  halts=0
  v="$(control)"
  if [ "$v" = drain ] || [ "$v" = stop-now ]; then say "factory $v: stopping"; exit 0; fi
  if grep -q '^0 bean(s) run\.$\|ready: nothing' <<<"$out"; then
    say "nothing ready; waiting ${IDLE}s for a merge"
    sleep "$IDLE"
  fi
done
exit $?
}
