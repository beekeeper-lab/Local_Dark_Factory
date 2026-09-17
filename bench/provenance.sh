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

# freeze_inputs <dir> <path>... — copy the inputs a measurement reads, once.
#
# The provenance block says which machine and which model. This says which SPEC,
# which task list, which bean — and it exists because on 2026-09-16 a six-case
# judge-fitness run took two hours, re-read the bean at the start of every case,
# and the bean was annotated in another repository at 19:55 and reverted at 20:12
# while the run was on its third case. Two of six cases measured a different bean
# from the other four. Nothing in the artifact said so, and the only way anyone
# found out was noticing the file mtimes afterwards.
#
# Every bench harness re-execs through bench/snapshot.sh so that editing the
# SCRIPT mid-run cannot corrupt the run. The inputs point outside that snapshot,
# and an input is more of a measurement than the script is.
#
# Copies each path into <dir> keeping its basename — a directory whole, so a bean
# directory keeps the name that `run.json` records it by. The caller re-points its
# variables at "<dir>/<basename>"; nothing here can do that for it, because the
# point is that every later read goes to the copy.
#
# Prints {name: sha256[0:12]} for the artifact. Arguments may be `name=path`, and
# should be: the key is what a later reader compares two runs by, so it has to be
# the ROLE — spec, tasks, bean — and not a filename that changes when somebody
# renames a fixture. A bare path keys on its basename.
freeze_inputs() { # freeze_inputs <dir> [name=]<path>...
  local dir="$1"; shift
  mkdir -p "$dir" || return 1
  local json='{}' arg p base key sha
  for arg in "$@"; do
    case "$arg" in
      [a-z_]*=*) key="${arg%%=*}"; p="${arg#*=}" ;;
      *)         key=""; p="$arg" ;;
    esac
    [ -n "$p" ] && [ -e "$p" ] || continue
    base="$(basename "$p")"
    [ -n "$key" ] || key="$base"
    if [ -d "$p" ]; then
      cp -a "$p" "$dir/" || return 1
      # Every file under it, in a stable order: a directory whose contents changed
      # is a different input even when its name did not.
      sha="$(find "$p" -type f -exec sha256sum {} + 2>/dev/null | awk '{print $1}' | sort | sha256sum | cut -c1-12)"
    else
      cp "$p" "$dir/$base" || return 1
      sha="$(sha256sum "$p" | cut -c1-12)"
    fi
    json="$(jq -c --arg n "$key" --arg v "$sha" '. + {($n): $v}' <<<"$json")" || return 1
  done
  printf '%s' "$json"
}
