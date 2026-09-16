#!/usr/bin/env bash
# harmony-conformance.sh — Phase-0 exit criterion `harmony_conformance` (spec §02).
#
# gpt-oss speaks the Harmony format: its output is split into analysis /
# commentary / final channels. The judge role depends on three properties of
# that format surviving the trip through Ollama, and none of them are safe to
# assume:
#
#   1. the final channel arrives as clean content, with no <|channel|> control
#      tokens leaking into it — a leaked token becomes a verdict the schema
#      validator rejects, at the end of a step that already cost minutes;
#   2. the analysis channel arrives *separately*, so reasoning never contaminates
#      the verdict body;
#   3. constrained decoding still holds when both are in play, because every
#      verdict is a schema-shaped JSON object, not prose.
#
# A failure here is not cosmetic. §01 puts the judge on a different model family
# precisely so its blind spots differ from the developer's; if the judge cannot
# emit a parseable verdict, that independence buys nothing.
set -euo pipefail

HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
JUDGE="${JUDGE_MODEL:-gpt-oss:120b}"
CTX="${NUM_CTX:-32768}"

OUT_DIR="${OUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results}"
OUT="${OUT:-$OUT_DIR/harmony-$(date -u +%Y%m%dT%H%M%SZ).json}"

# Every case is recorded, not just counted. This suite proves a property of a
# specific set of weights, so "12 passed" printed to a terminal and then lost is
# not evidence a later reader can use: the digest and the date are the point.
pass=0; fail=0
CASES="[]"
record() {
  CASES="$(jq -c --arg n "$1" --arg r "$2" '. + [{case:$n, result:$r}]' <<<"$CASES")"
}
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); record "$1" pass; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); record "$1" fail; }

# Harmony control tokens that must never reach the caller's content field.
LEAK_RE='<\|channel\|>|<\|start\|>|<\|end\|>|<\|message\|>|<\|constrain\|>|^analysis|^commentary'

printf '\n== Harmony conformance: %s @ num_ctx=%s ==\n\n' "$JUDGE" "$CTX"

# -- 1. OpenAI endpoint: channel separation -----------------------------------
RESP="$(curl -s "$HOST/v1/chat/completions" -H 'Content-Type: application/json' -d "$(jq -n \
  --arg m "$JUDGE" '{model:$m, messages:[{role:"user",content:"Reply with exactly the word: OK"}], max_tokens:400}')")"
CONTENT="$(jq -r '.choices[0].message.content // ""' <<<"$RESP")"
REASON="$(jq -r '.choices[0].message.reasoning // .choices[0].message.reasoning_content // ""' <<<"$RESP")"

[ -n "$CONTENT" ] && ok "final channel returns non-empty content" || bad "final channel empty"
grep -qE "$LEAK_RE" <<<"$CONTENT" && bad "Harmony control tokens leaked into content: $CONTENT" \
  || ok "no Harmony control tokens in content"
[ -n "$REASON" ] && ok "analysis channel exposed separately (reasoning field)" \
  || bad "reasoning field absent — analysis channel not separated"
grep -qE "$LEAK_RE" <<<"$REASON" && bad "control tokens leaked into reasoning" \
  || ok "no control tokens in reasoning"
[ "$(tr -d '[:space:]' <<<"$CONTENT")" = "OK" ] && ok "content is exactly the requested token" \
  || bad "content not clean: '$CONTENT'"

# -- 2. 'developer' role accepted ---------------------------------------------
DEV_RESP="$(curl -s "$HOST/v1/chat/completions" -H 'Content-Type: application/json' -d "$(jq -n \
  --arg m "$JUDGE" '{model:$m, messages:[{role:"developer",content:"You answer with one word."},{role:"user",content:"Say READY"}], max_tokens:400}')")"
# Non-empty, not merely present. jq treats "" as TRUE — only null and false are
# falsy — so a server that accepted the role and returned nothing would have been
# recorded as accepting it, and this predicate is one of the six that closed
# Phase 0. The same trap was found in phase0-audit's provenance check the same
# morning; it is worth grepping for `jq -e '.field'` whenever a check reads a
# string it did not itself write.
if [ -n "$(jq -r '.choices[0].message.content // ""' <<<"$DEV_RESP")" ]; then
  ok "'developer' role accepted on the OpenAI endpoint"
else
  bad "'developer' role rejected or answered with nothing: $(jq -rc '.error // .' <<<"$DEV_RESP")"
fi

# -- 3. Native endpoint: thinking separated from content ----------------------
NAT="$(curl -s "$HOST/api/chat" -d "$(jq -n --arg m "$JUDGE" --argjson c "$CTX" \
  '{model:$m, stream:false, think:"high", options:{num_ctx:$c},
    messages:[{role:"user",content:"Name the capital of France in one word."}]}')")"
NC="$(jq -r '.message.content // ""' <<<"$NAT")"
NT="$(jq -r '.message.thinking // ""' <<<"$NAT")"
[ -n "$NT" ] && ok "native endpoint separates thinking at think=high" || bad "no thinking field at think=high"
grep -qE "$LEAK_RE" <<<"$NC" && bad "control tokens leaked into native content" \
  || ok "no control tokens in native content"

# -- 4. Constrained decoding under Harmony ------------------------------------
# The real shape a verdict takes: an enum the controller branches on, an array,
# and a number. If constrained decoding and Harmony interfere, this is where it
# shows.
SCHEMA='{"type":"object","properties":{"verdict":{"type":"string","enum":["approve","revise","block"]},"criteria":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"met":{"type":"boolean"}},"required":["id","met"]}},"confidence":{"type":"number"}},"required":["verdict","criteria","confidence"]}'
JR="$(curl -s "$HOST/api/chat" -d "$(jq -n --arg m "$JUDGE" --argjson c "$CTX" --argjson f "$SCHEMA" \
  '{model:$m, stream:false, think:"high", options:{num_ctx:$c}, format:$f,
    messages:[{role:"user",content:"Bean bean-001 adds a Table dataclass: src/models.py plus tests/test_models.py with three assertions. All gates passed. Emit your verdict."}]}')")"
JC="$(jq -r '.message.content // ""' <<<"$JR")"
if jq -e . >/dev/null 2>&1 <<<"$JC"; then
  ok "constrained output parses as JSON"
  V="$(jq -r '.verdict' <<<"$JC")"
  case "$V" in approve|revise|block) ok "verdict is a schema-legal enum value ($V)" ;;
    *) bad "verdict outside enum: $V" ;; esac
  jq -e 'has("criteria") and has("confidence") and (.criteria|type=="array")' >/dev/null 2>&1 <<<"$JC" \
    && ok "required verdict fields present and typed" || bad "verdict missing required fields: $JC"
  grep -qE "$LEAK_RE" <<<"$JC" && bad "control tokens inside constrained JSON" \
    || ok "no control tokens in constrained JSON"
else
  bad "constrained output is not JSON: $JC"
fi

printf '\n%d passed, %d failed\n\n' "$pass" "$fail"

mkdir -p "$(dirname "$OUT")"
jq -n \
  --arg model "$JUDGE" \
  --arg digest "$(ollama list 2>/dev/null | awk -v m="$JUDGE" '$1 == m {print $2; exit}')" \
  --arg quant "$(ollama show "$JUDGE" 2>/dev/null | sed -n 's/^[[:space:]]*quantization[[:space:]]*//p' | head -1 | tr -d ' ')" \
  --arg ollama "$(ollama --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)" \
  --arg kernel "$(uname -r)" \
  --arg host "$(hostname)" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson ctx "$CTX" \
  --argjson passed "$pass" --argjson failed "$fail" \
  --argjson cases "$CASES" \
  '{schema: "phase0-harmony-conformance/1.0.0",
    provenance: {host:$host, kernel:$kernel, ollama_version:$ollama, measured_at:$ts,
                 judge: {model:$model, digest:$digest, quant:$quant}, num_ctx:$ctx},
    passed:$passed, failed:$failed, result:(if $failed == 0 then "pass" else "fail" end),
    cases:$cases}' > "$OUT"
printf '[harmony] wrote %s\n' "$OUT" >&2

[ "$fail" -eq 0 ]
