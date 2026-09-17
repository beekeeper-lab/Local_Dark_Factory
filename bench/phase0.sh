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
OUT_EXPLICIT=0

usage() {
  cat <<'EOF'
phase0.sh — measure model residency, speed and swap cost on Forge.

usage: phase0.sh [--quick] [--models "<dev> <judge>"] [--contexts "16384 32768"]

  --quick        one context size (32768) and a short prompt; ~5 min smoke test
  --provenance-only     print and write provenance + current residency; loads nothing
  --coresidency-probe   measure which model pairs actually co-reside and at what
                        GTT footprint; requires OLLAMA_MAX_LOADED_MODELS>=2 and
                        refuses (exit 3) with the commands to set it otherwise
  --models       override the two models under test
  --contexts     override the context sweep
  --out <path>   results file (default: bench/results/phase0-<stamp>.json)

Environment: OLLAMA_HOST, DEV_MODEL, JUDGE_MODEL, CONTEXTS, OUT_DIR

Writes a single JSON document: provenance, per-(model,context) speed rows,
residency snapshots, swap timings, and a regime recommendation.
EOF
}

QUICK=0
PROBE_ONLY=0
PROV_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --provenance-only) PROV_ONLY=1; shift ;;
    --coresidency-probe) PROBE_ONLY=1; shift ;;
    --quick) QUICK=1; CONTEXTS="32768"; shift ;;
    --models) DEV="${2%% *}"; JUDGE="${2##* }"; shift 2 ;;
    --contexts) CONTEXTS="$2"; shift 2 ;;
    --out) OUT="$2"; OUT_EXPLICIT=1; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# A provenance record is not a measurement sweep; giving it its own name keeps a
# cheap --provenance-only run from shadowing the sweep anything reads for figures.
[ "$PROV_ONLY" = 1 ] && [ "$OUT_EXPLICIT" = 0 ] && OUT="$OUT_DIR/phase0-provenance-$STAMP.json"

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

# GTT actually pinned right now, as opposed to the ceiling. The co-residency
# question is decided by this number, not by the sum of the model file sizes.
gtt_used_bytes() {
  cat /sys/class/drm/card*/device/mem_info_gtt_used 2>/dev/null | sort -rn | head -1 || echo 0
}

# The scheduler settings are part of the conditions, not background scenery:
# MAX_LOADED_MODELS=1 makes co-residency impossible by configuration, so a
# regime "measurement" taken under it is a reading of the unit file.
unit_env() {
  systemctl show ollama.service -p Environment 2>/dev/null \
    | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1
}

provenance() {
  jq -cn \
    --arg mlm "$(unit_env OLLAMA_MAX_LOADED_MODELS)" \
    --arg npar "$(unit_env OLLAMA_NUM_PARALLEL)" \
    --arg keep "$(unit_env OLLAMA_KEEP_ALIVE)" \
    --arg ctxlen "$(unit_env OLLAMA_CONTEXT_LENGTH)" \
    --argjson gtt_used "$(gtt_used_bytes)" \
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
      gtt_used_gib: (($gtt_used/1073741824)*10|round/10),
      ram_total_gb:$ram_total_gb, developer:$dev, judge:$judge,
      scheduler: {max_loaded_models: (if $mlm == "" then null else ($mlm|tonumber? // $mlm) end),
                  num_parallel:      (if $npar == "" then null else ($npar|tonumber? // $npar) end),
                  keep_alive:        (if $keep == "" then null else $keep end),
                  context_length:    (if $ctxlen == "" then null else ($ctxlen|tonumber? // $ctxlen) end)}}'
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
PROV="$(provenance)"
log "GTT ceiling: $(jq -r .gtt_gb <<<"$PROV") GB · RAM: $(jq -r .ram_total_gb <<<"$PROV") GB"

# --provenance-only: validate the metadata path and current residency without
# loading, stopping or evicting anything. Safe to run while other work is using
# Ollama — the full harness is not, because it calls `ollama stop`.
if [ "$PROV_ONLY" = 1 ]; then
  # Write the file this run announced. Printing to stdout while logging
  # "writing results to <path>" left the operator believing a provenance record
  # existed when none did — a small lie of exactly the kind Phase 0 exists to
  # stop telling.
  jq -n --argjson provenance "$PROV" --argjson residency "$(residency)" \
    '{schema:"phase0-provenance/1.0.0", provenance:$provenance, residency_now:$residency}' \
    | tee "$OUT"
  log "done: $OUT"
  exit 0
fi

# --------------------------------------------------------- co-residency probe --
# The 81.4-88.4 GiB effective-budget bracket was originally taken by hand and
# written straight into JSON, which left the most consequential Phase-0 finding
# unreproducible: no script emitted it, and the drop-in it needed had been
# removed. This mode regenerates that artifact under the same schema.
#
# It deliberately does not edit the unit itself — a measurement harness that
# rewrites system configuration is a harness you cannot run casually. It refuses
# instead, and prints the two commands.
if [ "$PROBE_ONLY" = 1 ]; then
  MLM="$(jq -r '.scheduler.max_loaded_models // "unset"' <<<"$PROV")"
  if [ "$MLM" != "2" ] && [ "$MLM" != "3" ] && [ "$MLM" != "4" ]; then
    log "refusing: OLLAMA_MAX_LOADED_MODELS is '$MLM'; co-residency cannot be attempted below 2."
    log "enable it:  printf '[Service]\\nEnvironment=OLLAMA_MAX_LOADED_MODELS=2\\n' | sudo tee /etc/systemd/system/ollama.service.d/zz-phase0-coresidency-test.conf && sudo systemctl daemon-reload && sudo systemctl restart ollama"
    log "undo it:    sudo rm /etc/systemd/system/ollama.service.d/zz-phase0-coresidency-test.conf && sudo systemctl daemon-reload && sudo systemctl restart ollama"
    exit 3
  fi

  PROBE_OUT="${PROBE_OUT:-$OUT_DIR/coresidency-probe-$(date -u +%Y%m%d).json}"
  # pair-a | pair-b | num_ctx | why this pair is in the list
  PAIRS="${PAIRS:-$JUDGE|gpt-oss:20b|8192|control: the judge co-resides with something small, so a refusal is not a per-model quirk
$DEV|qwen3-coder-next:latest|8192|control: highest confirmed-good footprint before the judge is introduced
$JUDGE|qwen3.8:27b|16384|the Q4 developer arm
$JUDGE|qwen3.8:27b|49152|the Q4 arm at the largest swept context
$JUDGE|$DEV|16384|the Q8 pair the regime decision turns on}"

  TRIALS="[]"
  while IFS='|' read -r a b ctx why; do
    [ -n "${a:-}" ] || continue
    missing=""
    for m in "$a" "$b"; do
      ollama list 2>/dev/null | awk -v m="$m" '$1 == m {found=1} END {exit !found}' || missing="$missing $m"
    done
    if [ -n "$missing" ]; then
      log "skip $a + $b @ $ctx — not installed:$missing"
      TRIALS="$(jq -c --arg a "$a" --arg b "$b" --argjson ctx "$ctx" --arg why "$why" --arg miss "$missing" \
        '. + [{pair:[$a,$b], num_ctx:$ctx, coresident:null, skipped:("not installed:" + $miss), note:$why}]' <<<"$TRIALS")"
      continue
    fi
    log "probe: $a + $b @ num_ctx=$ctx"
    ollama stop "$a" >/dev/null 2>&1 || true
    ollama stop "$b" >/dev/null 2>&1 || true
    sleep 2
    measure "$a" "$ctx" "$PROMPT_SMALL" >/dev/null
    measure "$b" "$ctx" "$PROMPT_SMALL" >/dev/null
    LOADED="$(residency)"
    used_gib="$(jq -n --argjson u "$(gtt_used_bytes)" '($u/1073741824*10|round)/10')"
    co="$(jq --arg a "$a" --arg b "$b" 'map(.model) | (index($a) != null) and (index($b) != null)' <<<"$LOADED")"
    log "  coresident=$co  gtt_used=${used_gib} GiB  loaded: $(jq -r 'map(.model)|join(", ")' <<<"$LOADED")"
    TRIALS="$(jq -c --arg a "$a" --arg b "$b" --argjson ctx "$ctx" --arg why "$why" \
      --argjson co "$co" --argjson used "$used_gib" --argjson loaded "$LOADED" \
      '. + [{pair:[$a,$b], num_ctx:$ctx, gtt_used_gib:$used, coresident:$co, loaded:$loaded, note:$why}]' <<<"$TRIALS")"
  done <<< "$PAIRS"

  jq -n --argjson provenance "$PROV" --argjson trials "$TRIALS" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: "phase0-coresidency-probe/1.0.0",
      measured_at: $ts,
      purpose: "Bracket the footprint at which ollama stops granting a second runner, so the regime decision rests on a measured budget rather than on the sum of the model file sizes.",
      provenance: $provenance,
      trials: $trials,
      effective_budget_gib: {
        highest_coresident: ([$trials[] | select(.coresident == true) | .gtt_used_gib // empty] | max // null),
        lowest_refused:     ([$trials[] | select(.coresident == false) | .gtt_used_gib // empty] | min // null)}}' \
    | tee "$PROBE_OUT"
  log "done: $PROBE_OUT"
  exit 0
fi

log "writing results to $OUT"

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
#
# But a derived field is only evidence if it could have come out the other way.
# Under OLLAMA_MAX_LOADED_MODELS=1 ollama will never hold two runners, so this
# derivation can only ever emit "serial" — a reading of the unit file wearing a
# measurement's clothes. Say "unknown" instead, and say why.
MLM="$(jq -r '.scheduler.max_loaded_models // "unset"' <<<"$PROV")"
REGIME="$(jq -r '[.[] | select(.scenario == "both") | select((.loaded | length) >= 2) | .num_ctx]
  | if length > 0 then "coresident@\(max)" else "serial" end' <<<"$RESIDENCY_ROWS")"
REGIME_NOTE="derived from observed co-residency across the swept contexts"
if [ "$MLM" = "1" ] && [ "$REGIME" = "serial" ]; then
  REGIME="unknown"
  REGIME_NOTE="co-residency was not attemptable: OLLAMA_MAX_LOADED_MODELS=1 forbids a second runner, so serial is enforced by configuration and cannot be measured here. Re-run with --coresidency-probe under a MAX_LOADED_MODELS>=2 drop-in to measure it."
fi
log "regime: $REGIME ($REGIME_NOTE)"

jq -n \
  --argjson provenance "$PROV" \
  --argjson speed "$SPEED_ROWS" \
  --argjson residency "$RESIDENCY_ROWS" \
  --argjson swaps "$SWAPS" \
  --arg regime "$REGIME" \
  --arg regime_note "$REGIME_NOTE" \
  --arg mlm "$MLM" \
  '{schema: "phase0-measurement/1.0.0",
    provenance: $provenance,
    speed: $speed,
    residency: $residency,
    swaps: $swaps,
    regime_decision: $regime,
    regime_evidence: {max_loaded_models: $mlm,
                      coresidency_attemptable: ($mlm != "1"),
                      note: $regime_note},
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
