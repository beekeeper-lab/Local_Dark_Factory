#!/usr/bin/env bash
# judge-qualify.sh — score a judge against real audits whose right answer is known.
#
# bench/judge-fitness.sh plants synthetic defects in one bean-001 spec. That
# measures something, but not the thing the line needs to know before it trusts a
# local judge: whether it catches the defects this line actually ships. On
# 2026-09-28 an independent review of five merged beans found a real defect in
# every one (bench/qualify/cases/*/case.json says what and where), all of which
# had passed tests, gate, CI and an advisory audit. Those are the cases here, each
# frozen with the bean as it was at the run, plus repaired twins that differ from
# a defect case only in the defect.
#
# Each case runs the real judge.sh and then the real audit-check.sh, from a
# worktree of the target repository at the commit the audit saw, so a quote from
# the code resolves exactly as it would have. Scored per case:
#
#   answered    the judge wrote a judgement
#   stamped     audit-check turned it into a verdict (quotes on disk, shape valid)
#   verdict     revise/block on a defect case is a catch; accept on a twin is right
#   named       a finding mentions one of the case's anchors — a keyword test over
#               text the judge wrote, so an UPPER bound, as judge-fitness says of
#               its own; "named and stamped" is the strict figure
#   false alarm on a twin, a finding naming the defect its twin carries
#
# A pair (defect case, twin) is DISCRIMINATED when the defect is named and stamped
# and the twin raises no false alarm. That is the question this suite exists for:
# can the judge tell the broken version from the repaired one.
#
# usage: judge-qualify.sh --repo <target-repo> [--only <case>] [--passes <n>]
#                         [--thinking <level>] [--roles <roles.json>] [--out <file>]
#   --roles   a roles.json whose .roles.judge names the model to qualify
set -uo pipefail
if [ "${FACTORY_BENCH_SNAPSHOTTED:-0}" != 1 ] && [ "${FACTORY_NO_SNAPSHOT:-0}" != 1 ]; then
  exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/snapshot.sh" \
    "$(basename "${BASH_SOURCE[0]}")" "$@"
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PIPE="$ROOT/factory/pipeline"
# shellcheck source=inflight.sh
source "$HERE/inflight.sh"
# shellcheck source=provenance.sh
source "$HERE/provenance.sh"
JUDGE_CMD="${JUDGE_CMD:-$PIPE/judge.sh}"
AUDIT_CHECK="${AUDIT_CHECK:-$PIPE/audit-check.sh}"
CASES_DIR="${QUALIFY_CASES:-$HERE/qualify/cases}"

REPO=""; ONLY=""; PASSES=1; THINKING=""; ROLES=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --only) ONLY="${2:?}"; shift 2 ;;
    --passes) PASSES="${2:?}"; shift 2 ;;
    --thinking) THINKING="${2:?}"; shift 2 ;;
    --roles) ROLES="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -d "$REPO/.git" ] || { echo "--repo must be the target repository (a git checkout)" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
case "$PASSES" in ''|*[!0-9]*|0) echo "--passes wants a positive number" >&2; exit 2 ;; esac
if [ -n "$ROLES" ]; then
  [ -f "$ROLES" ] || { echo "no such roles file: $ROLES" >&2; exit 2; }
  export ROLES_FILE="$(cd "$(dirname "$ROLES")" && pwd)/$(basename "$ROLES")"
fi
ROLES_IN_USE="${ROLES_FILE:-$PIPE/roles.json}"
[ -n "$OUT" ] || OUT="$ROOT/bench/results/judge-qualify-$(date -u +%Y%m%dT%H%M%SZ).json"

mapfile -t CASES < <(for c in "$CASES_DIR"/*/case.json; do
  [ -f "$c" ] || continue
  id="$(jq -r .id "$c")"; [ -z "$ONLY" ] || [ "$ONLY" = "$id" ] && printf '%s\n' "$c"
done)
[ "${#CASES[@]}" -gt 0 ] || { echo "no cases${ONLY:+ matching $ONLY} under $CASES_DIR" >&2; exit 2; }
for c in "${CASES[@]}"; do
  jq -e '.answer_key.why != "" and (.anchors|length) > 0 or .expect == "accept"' "$c" >/dev/null \
    || { echo "case $(jq -r .id "$c") has no answer key; refusing to score against nothing" >&2; exit 2; }
done

# A judge on a busy card is a measurement of the card. Stub judges (the tests)
# take nothing from the GPU and say so.
[ "${QUALIFY_NO_GPU:-0}" = 1 ] || refuse_if_inflight evicts

WORK="$(mktemp -d)"
cleanup() {
  for wt in "$WORK"/wt-*; do [ -d "$wt" ] && git -C "$REPO" worktree remove --force "$wt" >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap cleanup EXIT

printf '\njudge qualification — %s\n  judge: %s (%s thinking)\n  cases: %s × %s pass(es)\n\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(jq -r '.roles.judge.model // "?"' "$ROLES_IN_USE")" \
  "${THINKING:-$(jq -r '.roles.judge.thinking // "?"' "$ROLES_IN_USE")}" "${#CASES[@]}" "$PASSES"
printf '%-40s %-6s %-8s %-7s %-7s %s\n' CASE EXPECT VERDICT STAMPED NAMED OUTCOME

ROWS='[]'
for pass in $(seq 1 "$PASSES"); do
  for c in "${CASES[@]}"; do
    CD="$(dirname "$c")"
    id="$(jq -r .id "$c")"; target="$(jq -r .target "$c")"; expect="$(jq -r .expect "$c")"
    cand="$(jq -r .source.candidate_sha "$c")"
    WT="$WORK/wt-$id-$pass"
    git -C "$REPO" cat-file -e "$cand^{commit}" 2>/dev/null \
      || { printf '%-40s candidate %s is not in %s — fetch it first\n' "$id" "${cand:0:12}" "$REPO"; continue; }
    git -C "$REPO" worktree add -q --detach "$WT" "$cand" 2>/dev/null \
      || { printf '%-40s could not make a worktree at %s\n' "$id" "${cand:0:12}"; continue; }
    RD="$WORK/run-$id-$pass"; mkdir -p "$RD/verdicts"
    cp -r "$CD/inputs/." "$RD/"
    base="$(jq -r '.base // empty' "$RD/gate.json" 2>/dev/null)"; [ -n "$base" ] || base="$(jq -r .source.bean_at "$c")"
    jq --arg b "$base" '. + {base:$b}' "$RD/run.json" > "$RD/run.json.tmp" && mv "$RD/run.json.tmp" "$RD/run.json"
    BEAN="$RD/bean/bean.yaml"

    t0="$(date +%s)"; jrc=0
    ( cd "$WT" && STUB_CASE_JSON="$c" PIPE_DIR="$PIPE" bash "$JUDGE_CMD" "$RD" --target "$target" --bean "$BEAN" ${THINKING:+--thinking "$THINKING"} ) \
      > "$WORK/judge-$id-$pass.log" 2>&1 || jrc=$?
    arc=0
    ( cd "$WT" && bash "$AUDIT_CHECK" "$RD" --target "$target" --bean "$BEAN" ) \
      > "$WORK/check-$id-$pass.log" 2>&1 || arc=$?
    secs=$(( $(date +%s) - t0 ))

    J="$RD/verdicts/$target.attempt-1.judgement.json"
    V="$RD/verdicts/$target.attempt-1.json"
    verdict="-"; answered=false; stamped=false; named=false; body=""
    if [ -f "$J" ]; then
      answered=true
      verdict="$(jq -r '.verdict // "?"' "$J")"
      # On a twin only a blocker or major finding, or a criterion called unmet,
      # counts as reporting the defect: a minor note that mentions the repaired
      # line while describing it correctly is not a false alarm.
      sev='.'; [ "$expect" = accept ] && sev='select(.severity == "blocker" or .severity == "major")'
      body="$(jq -r "[(.findings[]? | $sev | .summary, .evidence, .where), (.criteria[]? | select(.met == false) | .evidence)] | map(select(. != null)) | join(\" \")" "$J" | tr '[:upper:]' '[:lower:]')"
    fi
    [ -f "$V" ] && stamped=true
    if [ -n "$body" ]; then
      while IFS= read -r a; do
        [ -n "$a" ] && grep -qF -- "$(tr '[:upper:]' '[:lower:]' <<<"$a")" <<<"$body" && { named=true; break; }
      done < <(jq -r '.anchors[]' "$c")
    fi
    why="$(grep -E '^AUDIT [a-z]+: ' "$WORK/check-$id-$pass.log" 2>/dev/null | tail -1 | sed 's/^AUDIT [a-z]*: //' | head -c 80)"

    if [ "$answered" = false ]; then
      outcome="no judgement: $(grep -m1 '^JUDGE  [a-z-]*: ' "$WORK/judge-$id-$pass.log" 2>/dev/null | sed 's/^JUDGE  //' | head -c 60)"
    elif [ "$expect" = reject ]; then
      case "$verdict" in
        revise|block) if [ "$named" = true ] && [ "$stamped" = true ]; then outcome="CAUGHT — named and stamped"
                      elif [ "$named" = true ]; then outcome="named, not stamped ($why)"
                      else outcome="rejected for something else"; fi ;;
        accept) outcome="FALSE ACCEPT" ;;
        abstain) outcome="abstained" ;;
        *) outcome="no usable verdict" ;;
      esac
    else
      if [ "$named" = true ]; then outcome="FALSE ALARM — reported the repaired defect"
      elif [ "$verdict" = accept ]; then outcome="accepted, correctly"
      else outcome="$verdict, on other grounds"; fi
    fi
    printf '%-40s %-6s %-8s %-7s %-7s %s  (%ss)\n' "$id" "$expect" "$verdict" "$stamped" "$named" "$outcome" "$secs"

    KEEP="$(dirname "$OUT")/judge-qualify-logs/$(basename "$OUT" .json)/$id.$pass"
    mkdir -p "$KEEP"; cp -f "$WORK/judge-$id-$pass.log" "$WORK/check-$id-$pass.log" "$KEEP/" 2>/dev/null
    cp -f "$RD"/verdicts/* "$KEEP/" 2>/dev/null || true
    ROWS="$(jq -c --arg id "$id" --argjson p "$pass" --arg t "$target" --arg e "$expect" --arg v "$verdict" \
      --argjson ans "$answered" --argjson st "$stamped" --argjson nm "$named" --arg o "$outcome" --arg why "$why" \
      --argjson s "$secs" --argjson jrc "$jrc" --argjson arc "$arc" \
      --arg twin "$(jq -r '.twin_of // ""' "$c")" --argjson contested "$(jq '.contested // false' "$c")" \
      --arg diff "$(jq -r '.difficulty // ""' "$c")" \
      '. + [{case:$id, pass:$p, target:$t, expect:$e, verdict:$v, answered:$ans, stamped:$st, named:$nm,
             outcome:$o, refused_because:$why, seconds:$s, judge_rc:$jrc, check_rc:$arc,
             twin_of:(if $twin=="" then null else $twin end), contested:$contested, difficulty:$diff}]' <<<"$ROWS")"
    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
  done
done

SUMMARY="$(jq -c '
  def rate(a; b): if b > 0 then ((a * 100 / b) | floor) else null end;
  (map(select(.expect=="reject" and (.contested|not)))) as $d
  | (map(select(.expect=="accept"))) as $t
  | (map(select(.expect=="reject" and .contested))) as $c
  | {rows: length,
     answered: (map(select(.answered)) | length),
     stamped: (map(select(.stamped)) | length),
     defects: ($d|length),
     defects_rejected: ($d | map(select(.verdict=="revise" or .verdict=="block")) | length),
     defects_named_and_stamped: ($d | map(select(.named and .stamped)) | length),
     false_accepts: ($d | map(select(.verdict=="accept")) | length),
     twins: ($t|length),
     twins_accepted: ($t | map(select(.verdict=="accept" and (.named|not))) | length),
     false_alarms: ($t | map(select(.named)) | length),
     contested: ($c|length),
     contested_named: ($c | map(select(.named)) | length),
     pairs_discriminated: ([ $t[] as $tw | $d[] | select(.case == $tw.twin_of and .pass == $tw.pass
                               and .named and .stamped and ($tw.named|not)) ] | length),
     pairs: ($t|length)}
  | . + {strict_catch_rate: rate(.defects_named_and_stamped; .defects),
         false_accept_rate: rate(.false_accepts; .defects),
         stamp_rate: rate(.stamped; .rows)}' <<<"$ROWS")"

mkdir -p "$(dirname "$OUT")"
jq -n --argjson rows "$ROWS" --argjson s "$SUMMARY" \
  --argjson prov "$(provenance_block "$(jq -r '.roles.judge.model // empty' "$ROLES_IN_USE")" 2>/dev/null || echo null)" \
  --arg judge_cmd "$(basename "$JUDGE_CMD")" --arg roles "$ROLES_IN_USE" --arg thinking "$THINKING" \
  --arg cases_sha "$(cat "$CASES_DIR"/*/case.json | sha256sum | cut -d' ' -f1)" \
  '{schema:"judge-qualify/1.0.0", judge_cmd:$judge_cmd, roles_file:$roles,
    thinking_override:(if $thinking=="" then null else $thinking end),
    cases_sha256:$cases_sha, summary:$s, results:$rows, provenance:$prov,
    note:"named is a keyword match over the judge-written text: an upper bound. named-and-stamped is the strict figure."}' > "$OUT"

jq -r '.summary |
  "\n\(.rows) audit run(s): \(.answered) answered, \(.stamped) stamped (\(.stamp_rate // "-")%)",
  "defects: \(.defects_named_and_stamped) of \(.defects) caught, named and stamped (\(.strict_catch_rate // "-")%); \(.defects_rejected) rejected; \(.false_accepts) FALSE ACCEPT(s)",
  "twins:   \(.twins_accepted) of \(.twins) accepted cleanly; \(.false_alarms) false alarm(s)",
  "pairs:   \(.pairs_discriminated) of \(.pairs) told apart",
  "contested: \(.contested_named) of \(.contested) named (scored separately)"' "$OUT"
printf '\nresults: %s\n' "$OUT"
[ "$PASSES" -gt 1 ] || printf 'One pass is not a measurement of this judge, which gives different verdicts for identical input; use --passes 3 or more to compare.\n'
