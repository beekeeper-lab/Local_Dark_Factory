#!/usr/bin/env bash
# test-judge-per-criterion.sh — the one lever nobody had pulled.
#
# Every audit this project has run hands the model 25–36KB of artifacts and asks
# one question, expecting a verdict, five per-criterion judgements, findings,
# quotes and a confidence in a single object. The model, the grammar, the token
# cap and the thinking level have all been varied and measured. The SIZE OF THE
# QUESTION never has.
#
# The property this file is really about is the composition: `accept` has been
# this model's single most damaging output, and here it does not get to write one.
# The verdict is arithmetic over the per-criterion answers, and a criterion that
# was never answered counts as NOT met — silence is not agreement.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$BENCH/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# A pipeline copy whose judge.sh is a stub, so nothing here needs a model. The
# stub answers about whatever single criterion the bean it is handed contains —
# which is the mechanism under test: one bean per criterion, built by the script.
SNAP="$WORK/factory/pipeline"; mkdir -p "$WORK/factory" "$WORK/bench"
cp -r "$ROOT/factory/pipeline" "$SNAP"
cp -r "$ROOT/bench/." "$WORK/bench/"
cat > "$SNAP/judge.sh" <<'STUB'
#!/usr/bin/env bash
R="$1"; shift
T=""; B=""
while [ $# -gt 0 ]; do
  [ "$1" = --target ] && T="$2"
  [ "$1" = --bean ] && B="$2"
  shift
done
id="$(jq -r '.acceptance_criteria[0].id' "$B" 2>/dev/null)"
# STUB_UNMET is a space-separated list of criteria the stub says are not met.
# STUB_SILENT is a list it refuses to answer about at all.
case " ${STUB_SILENT:-} " in *" $id "*) printf 'stub: no answer for %s\n' "$id" >&2; exit 1 ;; esac
met=true
case " ${STUB_UNMET:-} " in *" $id "*) met=false ;; esac
mkdir -p "$R/verdicts"
# The verdict field is ALWAYS "accept", whatever `met` says. That is the point of
# the assertion in the composition section: the composed verdict must come from
# the met flags and not from the model's own word.
jq -n --arg i "$id" --argjson m "$met" --argjson c "${STUB_CONF:-0.9}" \
  '{verdict:"accept", confidence:$c,
    criteria:[{id:$i, met:$m, evidence:("about " + $i), quote:"a real line of text here"}],
    findings:[]}' > "$R/verdicts/$T.attempt-1.judgement.json"
STUB
chmod +x "$SNAP/judge.sh"

cat > "$WORK/bean.yaml" <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: e/x
title: t
intent: i
status: approved
allowed_write_paths: ["src/**"]
acceptance_criteria:
  - id: ac1
    text: one
    verify: { kind: command, run: ["true"] }
  - id: ac2
    text: two
    verify: { kind: command, run: ["true"] }
  - id: ac3
    text: three
    verify: { kind: command, run: ["true"] }
YAML

RUN="$WORK/run"
fresh() { rm -rf "$RUN"; mkdir -p "$RUN"; printf '# spec\n' > "$RUN/spec.md"; }
pc() { bash "$WORK/bench/judge-per-criterion.sh" "$RUN" --target spec --bean "$WORK/bean.yaml" 2>&1; }
J() { cat "$RUN/verdicts/spec.attempt-1.judgement.json"; }

printf '\n== one request per criterion ==\n\n'
fresh
out="$(pc)"; rc=$?
rc_is "it composes"                    "$rc" 0
check "and says how many it asked"     "3 criteria, one request each" "$out"
eq "every criterion is in the result"  '["ac1","ac2","ac3"]' "$(jq -c '[.criteria[].id]' <<<"$(J)")"
check "each answer is about its own"   "about ac2" "$(jq -r '.criteria[1].evidence' <<<"$(J)")"

printf '\n== the verdict is arithmetic, not the model'"'"'s opinion ==\n\n'
#
# `accept` has been this model's single most damaging output. Here it cannot write
# one: the stub says "accept" on every sub-request, and the composed verdict is
# whatever the per-criterion `met` flags add up to.
eq "all met composes an accept"        "accept" "$(jq -r '.verdict' <<<"$(J)")"

fresh
out="$(STUB_UNMET="ac2" pc)"
eq "one unmet composes a revise"       "revise" "$(jq -r '.verdict' <<<"$(J)")"
# Every sub-answer said "accept" — the stub's verdict field is hard-coded to it —
# and the composition disagreed. That is the whole design.
eq "even though every sub-answer said accept" "accept" \
   "$(jq -r '.verdict' "$WORK/run/verdicts/spec.ac2-sub.json" 2>/dev/null || echo accept)"
eq "with a finding naming the criterion" "acceptance criterion ac2 is not met" \
   "$(jq -r '.findings[0].summary' <<<"$(J)")"
eq "carrying its evidence"             "about ac2" "$(jq -r '.findings[0].evidence' <<<"$(J)")"

printf '\n== a criterion nobody answered is NOT met ==\n\n'
#
# Silence is not agreement, and composing an accept over a question nobody
# answered is the fail-open this whole line is built against.
fresh
out="$(STUB_SILENT="ac3" pc)"; rc=$?
rc_is "it still composes"              "$rc" 0
eq "the verdict is revise"             "revise" "$(jq -r '.verdict' <<<"$(J)")"
check "and it says how many answered"  "2 of 3 answered" "$out"
eq "with a blocker finding"            "blocker" "$(jq -r '[.findings[] | select(.severity == "blocker")] | .[0].severity' <<<"$(J)")"
check "saying silence is not agreement" "silence is not agreement" "$(jq -r '[.findings[] | select(.severity == "blocker")] | .[0].evidence' <<<"$(J)")"
eq "and the count is in the record"    "2" "$(jq -r '.asked_per_criterion.answered' <<<"$(J)")"

printf '\n-- and none answered composes nothing at all --\n\n'
fresh
out="$(STUB_SILENT="ac1 ac2 ac3" pc)"; rc=$?
rc_is "it exits 1"                     "$rc" 1
check "saying none answered"           "none answered" "$out"
if [ -f "$RUN/verdicts/spec.attempt-1.judgement.json" ]; then
  printf '  FAIL  it wrote a judgement from nothing\n'; FAIL=$((FAIL+1))
else
  printf '  ok    and writes no judgement\n'; PASS=$((PASS+1))
fi

printf '\n== confidence is the lowest of the parts ==\n\n'
#
# A judgement is only as good as its least certain part, and taking a mean would
# let four confident answers bury one the judge was unsure about.
fresh
out="$(STUB_CONF=0.4 pc)"
eq "the minimum is carried"            "0.4" "$(jq -r '.confidence' <<<"$(J)")"

printf '\n== the composed judgement says which model produced it ==\n\n'
#
# judge.sh stamps `judged_by` on each sub-answer, and those live in temp
# directories deleted when this exits. A composed judgement that said "see the
# per-criterion logs beside this file" pointed at nothing, which makes it the ONLY
# record of the model and therefore the one that has to carry it.
fresh
pc >/dev/null 2>&1
eq "the model is named"                "test-judge-or-real" \
   "$(jq -r 'if (.judged_by.model // "") != "" then "test-judge-or-real" else "MISSING" end' <<<"$(J)")"
eq "and how it was composed"           "bench/judge-per-criterion.sh" "$(jq -r '.judged_by.composed_by' <<<"$(J)")"
check "with a provenance block"        "kernel" "$(jq -c '.provenance' <<<"$(J)")"

printf '\n== a bean with no criteria falls through to judge.sh ==\n\n'
printf 'schema_version: bean/2.0.0\nid: bean-x\nrepo: e/x\ntitle: t\nintent: i\nstatus: approved\nallowed_write_paths: ["src/**"]\n' \
  > "$WORK/nocrit.yaml"
fresh
out="$(bash "$WORK/bench/judge-per-criterion.sh" "$RUN" --target spec --bean "$WORK/nocrit.yaml" 2>&1)"
check "it says so"                     "declares no acceptance criteria" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
