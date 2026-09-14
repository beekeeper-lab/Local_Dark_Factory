#!/usr/bin/env bash
# phase0.sh — Phase-0 measurement harness (spec §02).
#
# Answers the Phase-0 exit criteria with provenance:
#   - residency + GPU/CPU split per model, per context size, alone and together
#   - prompt-processing vs generation speed, measured separately
#   - model swap time in both directions
#   - the co-resident vs serial regime decision
#
# Context is swept via the per-request `options.num_ctx` rather than by editing
# and restarting the systemd unit: same measurement, no sudo, no service bounce
# that would disturb anything else using Ollama.
#
# Every figure is written with model digest, quant, Ollama version, kernel
# GTT limit and context length beside it — a figure without provenance is a
# rumour, and Phase 0 exists to replace rumours with numbers.
set -euo pipefail

HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
DEV="${DEV_MODEL:-qwen3.8:27b-mtp-q8_0}"
JUDGE="${JUDGE_MODEL:-gpt-oss:120b}"
CONTEXTS="${CONTEXTS:-16384 32768 49152}"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/phase0-$STAMP.json"

usage() {
  cat <<'EOF'
phase0.sh — measure model residency, speed and swap cost on Forge.

usage: phase0.sh [--quick] [--models "<dev> <judge>"] [--contexts "16384 32768"]

  --quick        one context size (32768) and a short prompt; ~5 min smoke test
  --models       override the two models under test
  --contexts     override the context sweep
  --out <path>   results file (default: bench/results/phase0-<stamp>.json)

Environment: OLLAMA_HOST, DEV_MODEL, JUDGE_MODEL, CONTEXTS, OUT_DIR

Writes a single JSON document: provenance, per-(model,context) speed rows,
residency snapshots, swap timings, and a regime recommendation.
EOF
}

QUICK=0
PROV_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --provenance-only) PROV_ONLY=1; shift ;;
    --quick) QUICK=1; CONTEXTS="32768"; shift ;;
    --models) DEV="${2%% *}"; JUDGE="${2##* }"; shift 2 ;;
    --contexts) CONTEXTS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for c in curl jq ollama; do
  command -v "$c" >/dev/null 2>&1 || { printf 'phase0: required command not found: %s\n' "$c" >&2; exit 1; }
done
mkdir -p "$(dirname "$OUT")"

log() { printf '[phase0] %s\n' "$*" >&2; }

# ---------------------------------------------------------------- provenance --
# GTT is the cap on system RAM the GPU may pin (ttm.pages_limit x page size).
# On this APU there is no dedicated VRAM, so GTT *is* the GPU's ceiling.
gtt_bytes() {
  local pages page_size
  pages="$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo 0)"
  page_size="$(getconf PAGESIZE)"
  echo $((pages * page_size))
}

model_meta() {
  # model_meta <model> -> {digest, quant, params, arch, native_context}
  local m="$1" show digest
  show="$(ollama show "$m" 2>/dev/null || true)"
  digest="$(ollama list 2>/dev/null | awk -v m="$m" '$1 == m {d=$2} END {print d}')"
  jq -cn \
    --arg model "$m" \
    --arg digest "${digest:-unknown}" \
    --arg quant "$(sed -n 's/^[[:space:]]*quantization[[:space:]]*//p' <<<"$show" | head -1 | tr -d ' ')" \
    --arg params "$(sed -n 's/^[[:space:]]*parameters[[:space:]]*//p' <<<"$show" | head -1 | tr -d ' ')" \
    --arg arch "$(sed -n 's/^[[:space:]]*architecture[[:space:]]*//p' <<<"$show" | head -1 | tr -d ' ')" \
    --arg native_ctx "$(sed -n 's/^[[:space:]]*context length[[:space:]]*//p' <<<"$show" | head -1 | tr -d ' ')" \
    '{model:$model, digest:$digest, quant:$quant, parameters:$params,
      architecture:$arch, native_context:($native_ctx|tonumber? // null)}'
}

provenance() {
  jq -cn \
    --arg host "$(hostname)" \
    --arg kernel "$(uname -r)" \
    --arg ollama "$(ollama --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson gtt_bytes "$(gtt_bytes)" \
    --argjson ram_total_gb "$(free -g | awk '/^Mem:/{print $2}')" \
    --argjson dev "$(model_meta "$DEV")" \
    --argjson judge "$(model_meta "$JUDGE")" \
    '{host:$host, kernel:$kernel, ollama_version:$ollama, measured_at:$ts,
      gtt_bytes:$gtt_bytes, gtt_gb:(($gtt_bytes/1073741824)|floor),
      ram_total_gb:$ram_total_gb, developer:$dev, judge:$judge}'
}

# ------------------------------------------------------------------ residency --
# `ollama ps` is the only honest source for where the weights actually landed.
residency() {
  ollama ps 2>/dev/null | awk 'NR>1 && NF {
      name=$1; size=$3" "$4; proc=$5" "$6;
      printf "%s\t%s\t%s\n", name, size, proc
    }' | jq -Rs 'split("\n") | map(select(length>0)) | map(split("\t")) |
        map({model:.[0], size:.[1], processor:.[2]})'
}

# ---------------------------------------------------------------------- speed --
# Ollama reports prompt_eval_* and eval_* separately, which is exactly the split
# the spec asks for: a developer session is prompt-heavy, a judge review is both.
PROMPT_SMALL="Reply with the single word: ready."

build_prompt() {
  # build_prompt <approx_tokens> — synthetic filler so prompt processing is
  # actually exercised. ~4 chars/token is close enough for a rate measurement.
  local target_tokens="$1" chars i line out=""
  chars=$((target_tokens * 4))
  line="The quick brown fox jumps over the lazy dog while the auditor records every claim with evidence. "
  while [ ${#out} -lt "$chars" ]; do out="$out$line"; done
  printf 'Read the following text, then reply with exactly the word: ready.\n\n%s\n' "${out:0:$chars}"
}

measure() {
  # measure <model> <num_ctx> <prompt> -> speed row JSON
  local model="$1" ctx="$2" prompt="$3" body resp t0 t1
  body="$(jq -cn --arg m "$model" --arg p "$prompt" --argjson c "$ctx" \
    '{model:$m, prompt:$p, stream:false, options:{num_ctx:$c, temperature:0, num_predict:64}}')"
  t0="$(date +%s.%N)"
  resp="$(curl -sS --max-time 1800 "$HOST/api/generate" -d "$body" 2>/dev/null || echo '{}')"
  t1="$(date +%s.%N)"
  jq -cn \
    --arg model "$model" --argjson ctx "$ctx" \
    --argjson wall "$(echo "$t1 - $t0" | bc)" \
    --argjson r "${resp:-{\}}" '
    ($r.prompt_eval_count // 0)     as $pc |
    ($r.prompt_eval_duration // 0)  as $pd |
    ($r.eval_count // 0)            as $ec |
    ($r.eval_duration // 0)         as $ed |
    {model:$model, num_ctx:$ctx, wall_seconds:($wall|.*100|round/100),
     prompt_tokens:$pc, prompt_seconds:(($pd/1e9)|.*100|round/100),
     prompt_tokens_per_second: (if $pd > 0 then (($pc/($pd/1e9))|.*10|round/10) else null end),
     gen_tokens:$ec, gen_seconds:(($ed/1e9)|.*100|round/100),
     gen_tokens_per_second: (if $ed > 0 then (($ec/($ed/1e9))|.*10|round/10) else null end),
     load_seconds: ((($r.load_duration // 0)/1e9)|.*100|round/100),
     ok: (($r.done // false) == true)}'
}

# ----------------------------------------------------------------------- swap --
swap_time() {
  # swap_time <from> <to> — stop `from`, time `to` becoming answer-ready.
  local from="$1" to="$2" t0 t1
  ollama stop "$from" >/dev/null 2>&1 || true
  sleep 1
  t0="$(date +%s.%N)"
  curl -sS --max-time 900 "$HOST/api/generate" \
    -d "$(jq -cn --arg m "$to" --arg p "$PROMPT_SMALL" \
          '{model:$m, prompt:$p, stream:false, options:{num_predict:1, temperature:0}}')" \
    >/dev/null 2>&1 || true
  t1="$(date +%s.%N)"
  jq -cn --arg from "$from" --arg to "$to" \
    --argjson seconds "$(echo "scale=2; $t1 - $t0" | bc)" \
    '{from:$from, to:$to, seconds:$seconds}'
}

# ----------------------------------------------------------------------- main --
log "writing results to $OUT"
PROV="$(provenance)"
log "GTT ceiling: $(jq -r .gtt_gb <<<"$PROV") GB · RAM: $(jq -r .ram_total_gb <<<"$PROV") GB"

# --provenance-only: validate the metadata path and current residency without
# loading, stopping or evicting anything. Safe to run while other work is using
# Ollama — the full harness is not, because it calls `ollama stop`.
if [ "$PROV_ONLY" = 1 ]; then
  jq -n --argjson provenance "$PROV" --argjson residency "$(residency)" \
    '{schema:"phase0-provenance/1.0.0", provenance:$provenance, residency_now:$residency}'
  exit 0
fi

BIG_PROMPT_TOKENS=$([ "$QUICK" = 1 ] && echo 512 || echo 4000)
BIG_PROMPT="$(build_prompt "$BIG_PROMPT_TOKENS")"

SPEED_ROWS="[]"
RESIDENCY_ROWS="[]"

for ctx in $CONTEXTS; do
  for m in "$DEV" "$JUDGE"; do
    log "measuring $m @ num_ctx=$ctx (prompt ~${BIG_PROMPT_TOKENS} tok, alone)"
    ollama stop "$DEV" >/dev/null 2>&1 || true
    ollama stop "$JUDGE" >/dev/null 2>&1 || true
    sleep 2
    row="$(measure "$m" "$ctx" "$BIG_PROMPT")"
    SPEED_ROWS="$(jq -c --argjson r "$row" '. + [$r + {scenario:"alone"}]' <<<"$SPEED_ROWS")"
    RESIDENCY_ROWS="$(jq -c --argjson ctx "$ctx" --arg sc "alone:$m" --argjson p "$(residency)" \
      '. + [{num_ctx:$ctx, scenario:$sc, loaded:$p}]' <<<"$RESIDENCY_ROWS")"
    printf '%s\n' "$row" >&2
  done

  # Co-residency probe: load both, then read where they actually landed.
  log "co-residency probe @ num_ctx=$ctx"
  measure "$DEV" "$ctx" "$PROMPT_SMALL"   >/dev/null
  measure "$JUDGE" "$ctx" "$PROMPT_SMALL" >/dev/null
  BOTH="$(residency)"
  RESIDENCY_ROWS="$(jq -c --argjson ctx "$ctx" --argjson p "$BOTH" \
    '. + [{num_ctx:$ctx, scenario:"both", loaded:$p}]' <<<"$RESIDENCY_ROWS")"
  log "  both loaded: $(jq -r 'map(.model) | join(", ")' <<<"$BOTH")"

  # With both resident, re-measure the developer: if co-residency is real the
  # numbers hold; if something was evicted the load_seconds give it away.
  row="$(measure "$DEV" "$ctx" "$BIG_PROMPT")"
  SPEED_ROWS="$(jq -c --argjson r "$row" '. + [$r + {scenario:"coresident"}]' <<<"$SPEED_ROWS")"
done

log "measuring swap time in both directions"
SWAPS="$(jq -cn --argjson a "$(swap_time "$JUDGE" "$DEV")" \
                --argjson b "$(swap_time "$DEV" "$JUDGE")" '[$a, $b]')"
jq -r '.[] | "  \(.from) -> \(.to): \(.seconds)s"' <<<"$SWAPS" >&2

# Regime decision: co-resident only if both models appear loaded together at
# some swept context. The controller reads this; it is not a judgement call.
REGIME="$(jq -r '[.[] | select(.scenario == "both") | select((.loaded | length) >= 2) | .num_ctx]
  | if length > 0 then "coresident@\(max)" else "serial" end' <<<"$RESIDENCY_ROWS")"

jq -n \
  --argjson provenance "$PROV" \
  --argjson speed "$SPEED_ROWS" \
  --argjson residency "$RESIDENCY_ROWS" \
  --argjson swaps "$SWAPS" \
  --arg regime "$REGIME" \
  '{schema: "phase0-measurement/1.0.0",
    provenance: $provenance,
    speed: $speed,
    residency: $residency,
    swaps: $swaps,
    regime_decision: $regime,
    model_load_timeout_suggestion_s: (($swaps | map(.seconds) | max // 60) * 2 | ceil)}' > "$OUT"

log "done: $OUT"
printf '\n== Phase 0 summary ==\n'
jq -r '
  "host: \(.provenance.host)  kernel: \(.provenance.kernel)  ollama: \(.provenance.ollama_version)",
  "GTT: \(.provenance.gtt_gb) GB of \(.provenance.ram_total_gb) GB RAM",
  "developer: \(.provenance.developer.model) [\(.provenance.developer.quant)] \(.provenance.developer.digest)",
  "judge:     \(.provenance.judge.model) [\(.provenance.judge.quant)] \(.provenance.judge.digest)",
  "",
  "| model | ctx | scenario | prompt tok/s | gen tok/s | load s |",
  "|---|---|---|---|---|---|",
  (.speed[] | "| \(.model) | \(.num_ctx) | \(.scenario) | \(.prompt_tokens_per_second // "-") | \(.gen_tokens_per_second // "-") | \(.load_seconds) |"),
  "",
  "swaps: \(.swaps | map("\(.from)->\(.to) \(.seconds)s") | join("  ·  "))",
  "REGIME DECISION: \(.regime_decision)",
  "model_load_timeout suggestion: \(.model_load_timeout_suggestion_s)s"
' "$OUT"
