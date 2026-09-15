#!/usr/bin/env bash
# provenance.sh — the block every figure in bench/results carries.
#
# A figure without provenance is a rumour. `bench/phase0.sh` has always written
# one; the harnesses added since — judge fitness, judge variance, the size sweep,
# format support, controller fitness — did not, and the Phase-0 exit predicate
# `figures_have_provenance` duly went red on eleven files at once. Two lists of
# what a figure must carry is one list that disagrees with itself, so there is
# one function now and every harness calls it.
#
# The floor is kernel, ollama version and a timestamp: enough to know whether two
# numbers were measured on the same machine running the same server. Model
# digests are added when the caller names models, because a re-pointed tag is the
# quietest way for two figures to stop being comparable.
#
# sourced: `source "$(dirname "$0")/provenance.sh"` then `provenance_block [model...]`

provenance_block() { # provenance_block [model ...]
  local models_json='{}' m dig
  for m in "$@"; do
    [ -n "$m" ] || continue
    dig="$(ollama list 2>/dev/null | awk -v n="$m" '$1==n{print $2; exit}')"
    models_json="$(jq -c --arg m "$m" --arg d "${dig:-}" \
      '. + {($m): (if $d == "" then null else $d end)}' <<<"$models_json")"
  done
  jq -cn \
    --arg host "$(hostname)" \
    --arg kernel "$(uname -r)" \
    --arg ollama "$(ollama --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg pipeline "$(cat "$(cd "$(dirname "${BASH_SOURCE[0]}")/../factory/pipeline" && pwd)/VERSION" 2>/dev/null || echo unknown)" \
    --argjson models "$models_json" \
    '{host:$host, kernel:$kernel, ollama_version:$ollama, measured_at:$ts,
      pipeline_version:$pipeline}
     + (if ($models | length) == 0 then {} else {models:$models} end)'
}
