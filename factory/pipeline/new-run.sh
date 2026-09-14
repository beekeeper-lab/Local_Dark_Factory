#!/usr/bin/env bash
# new-run.sh — create a pipeline run directory (run.json) for a bean.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="new-run.sh <BEAN-ID>"
case "${1:-}" in
  --version)
    cat "$PIPELINE_DIR/VERSION"
    exit 0
    ;;
  -h|--help)
    echo "new-run.sh — create ai/runs/<BEAN-ID>-<UTC stamp>/ with run.json for a pipeline run."
    echo "$USAGE"
    exit 0
    ;;
esac
require_args "$#" 1 "$USAGE"
require_cmd jq

BEAN_ID="$1"
[[ "$BEAN_ID" =~ ^BEAN-[0-9]+$ ]] || die "BEAN-ID must look like BEAN-NNN (got: $BEAN_ID)"

require_config
root="$(repo_root)"
runs_root="$(jq -r '.runs_root' "$CONFIG_PATH")"
[[ "$runs_root" =~ ^[A-Za-z0-9._/-]+$ ]] || die "suspicious runs_root in config: $runs_root"

branch="$(git -C "$root" branch --show-current 2>/dev/null || true)"
[ -n "$branch" ] || die "could not determine current branch in $root"

# Resolve the newest Pi session JSONL whose session entry has cwd == this repo.
# Optional: a run driven outside a Pi session (tests, cron) records null and the
# orchestrator row of the telemetry report is empty.
sess_base="$(pi_sessions_dir)"
sess_file=""
if [ -d "$sess_base" ]; then
  for d in "$sess_base"/*/; do
    newest="$(ls -t "$d"*.jsonl 2>/dev/null | head -n 1 || true)"
    [ -n "$newest" ] || continue
    cwd="$(jq -r 'select(.type == "session") | .cwd' "$newest" 2>/dev/null | head -n 1 || true)"
    if [ "$cwd" = "$root" ]; then
      sess_file="$newest"
      break
    fi
  done
else
  printf 'warning: Pi sessions directory not found: %s\n' "$sess_base" >&2
fi
if [ -z "$sess_file" ]; then
  printf 'warning: no Pi session JSONL found for cwd %s under %s; recording a null orchestrator session\n' "$root" "$sess_base" >&2
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
rundir="$(resolve_repo_path "$runs_root")/$BEAN_ID-$stamp"
mkdir -p "$rundir"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_id="$(basename "$rundir")"

jq -n \
  --arg run_id "$run_id" \
  --arg bean "$BEAN_ID" \
  --arg branch "$branch" \
  --arg started_at "$started_at" \
  --arg sess "$sess_file" \
  '{
    run_id: $run_id,
    bean: $bean,
    branch: $branch,
    started_at: $started_at,
    status: "running",
    pi_session_file: (if $sess == "" then null else $sess end)
  }' > "$rundir/run.json"

printf '%s\n' "$rundir"
