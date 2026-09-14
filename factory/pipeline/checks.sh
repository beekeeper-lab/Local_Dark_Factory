#!/usr/bin/env bash
# checks.sh — run the gate commands from config.json in order, stopping at first failure.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="checks.sh <run_dir>"
case "${1:-}" in
  --version)
    cat "$PIPELINE_DIR/VERSION"
    exit 0
    ;;
  -h|--help)
    echo "checks.sh — run the configured quality gates and write <run_dir>/checks.json."
    echo "$USAGE"
    echo ""
    echo "Gates are read from the pipeline config (config.json or \$PIPELINE_CONFIG),"
    echo "in order, and execution stops at the first failing gate. Later gates are"
    echo "recorded as 'skipped'. Exits non-zero if any gate failed."
    exit 0
    ;;
esac
require_args "$#" 1 "$USAGE"
require_cmd jq

RUN_DIR="$1"
[ -d "$RUN_DIR" ] || die "run directory not found: $RUN_DIR"

require_config
jq -e '.gates | type == "array" and length > 0' "$CONFIG_PATH" >/dev/null \
  || die "config must define a non-empty 'gates' array: $CONFIG_PATH"

root="$(repo_root)"
overall="pass"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

gates_json="[]"
append_gate() {
  gates_json="$(jq --argjson g "$1" '. + [$g]' <<<"$gates_json")"
}

while IFS= read -r gate; do
  name="$(jq -r '.name' <<<"$gate")"
  cmd="$(jq -r '.command' <<<"$gate")"
  wd="$(jq -r '.working_dir // "."' <<<"$gate")"
  wdir="$(resolve_repo_path "$wd")"

  out_file="$(mktemp)"
  start_ms="$(date +%s%3N)"
  if ( cd "$wdir" && bash -c "$cmd" ) >"$out_file" 2>&1; then
    rc=0
    status="pass"
  else
    rc=$?
    status="fail"
  fi
  end_ms="$(date +%s%3N)"
  duration_s="$(awk -v a="$start_ms" -v b="$end_ms" 'BEGIN { printf "%.3f", (b - a) / 1000 }')"

  gate_json="$(jq -cn \
    --arg name "$name" \
    --arg cmd "$cmd" \
    --arg wd "$wd" \
    --arg status "$status" \
    --argjson rc "$rc" \
    --argjson dur "$duration_s" \
    '{ name: $name, command: $cmd, working_dir: $wd, status: $status, exit_code: $rc, duration_s: $dur }')"
  if [ "$status" = "fail" ]; then
    tail_json="$(jq -Rcn '[inputs]' <(tail -n 20 "$out_file"))"
    gate_json="$(jq -c --argjson tail "$tail_json" '. + {output_tail: $tail}' <<<"$gate_json")"
    overall="fail"
    printf 'GATE  %-20s FAIL (exit %s)\n' "$name" "$rc"
    echo "----- last 20 lines -----"
    tail -n 20 "$out_file"
  else
    printf 'GATE  %-20s pass (%ss)\n' "$name" "$duration_s"
  fi
  append_gate "$gate_json"
  rm -f "$out_file"

  if [ "$status" = "fail" ]; then break; fi
done < <(jq -c '.gates[]' "$CONFIG_PATH")

# Record any gates that were never reached.
if [ "$overall" = "fail" ]; then
  while IFS= read -r gate; do
    name="$(jq -r '.name' <<<"$gate")"
    [ "$name" = "." ] && continue
    if ! jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$gates_json" >/dev/null; then
      append_gate "$(jq -cn --arg n "$name" '{name: $n, status: "skipped", exit_code: null, duration_s: null}')"
      printf 'GATE  %-20s skipped (a previous gate failed)\n' "$name"
    fi
  done < <(jq -c '.gates[]' "$CONFIG_PATH")
fi

finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg started_at "$started_at" \
  --arg finished_at "$finished_at" \
  --arg overall "$overall" \
  --argjson gates "$gates_json" \
  '{ started_at: $started_at, finished_at: $finished_at, overall: $overall, gates: $gates }' \
  > "$RUN_DIR/checks.json"

if [ "$overall" = "fail" ]; then
  echo "checks: FAILED (see $RUN_DIR/checks.json)" >&2
  exit 1
fi
echo "checks: all gates passed (see $RUN_DIR/checks.json)"
