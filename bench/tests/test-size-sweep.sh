#!/usr/bin/env bash
# test-size-sweep.sh — the sweep's independent variable has to actually vary.
#
# The sweep pads the artifacts to a series of sizes and asks whether the judge
# still catches a defect. Everything it says rests on the padding being the size
# the table claims. On 2026-09-17 it was not: `--pad-from` pointed at a bean SET
# (flat, `<dir>/bean-001.yaml`) where the glob expected a scaffolded repo
# (`<dir>/<id>/bean.yaml`), so it matched nothing, padded with 161 bytes, and
# printed a full table with rows labelled 10000 and 20000.
#
# Nothing was wrong with the output except that it was not a measurement. That is
# the fail-open shape this project keeps finding, and both halves are asserted
# here: the layout it could not read, and the refusal it did not make.
#
# No model is involved. Every assertion below is reached before the first judge
# call, which is also why they are worth having — the parts of this script that
# need a GPU cannot be tested cheaply, and these parts are where it went wrong.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SWEEP="$ROOT/bench/size-sweep.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:200}"; FAIL=$((FAIL+1)); fi }
rc_is() { if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi }
nope()  { if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
          else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi }

SPEC="$ROOT/evidence/bean-001-spec-20260915.md"
TASKS="$ROOT/evidence/bean-001-tasks-20260915.yaml"
CORPUS="$ROOT/benchmark/seating-planner/bean-sets/v1/beans"
BEAN="$ROOT/bench/fixtures/bean-001-annotated.yaml"
if [ ! -f "$SPEC" ] || [ ! -d "$CORPUS" ] || [ ! -f "$BEAN" ]; then
  printf '  SKIP  no corpus or fixtures\n\n0 passed, 0 failed\n'; exit 0
fi

sweep() { FACTORY_NO_SNAPSHOT=1 timeout 60 bash "$SWEEP" --spec "$SPEC" --tasks "$TASKS" --bean "$BEAN" "$@" 2>&1; }

printf '\n== it refuses a sweep it cannot pad to ==\n\n'
# bench/fixtures holds two copies of one bean, which is 161 bytes of padding
# after the bean under test is excluded. Asking for 20,000 from it is asking for
# a measurement that cannot be made.
out="$(sweep --pad-from "$ROOT/bench/fixtures" --sizes '0 20000' --repeat 1 --out "$WORK/a.json")"; rc=$?
rc_is "it exits 2"                    "$rc" 2
check "and says how short it is"      "161 bytes of padding available, 20000 needed" "$out"
check "and names the directory"       "bench/fixtures" "$out"
check "and says what a pad source looks like" "<dir>/<id>/bean.yaml or <dir>/<id>.yaml" "$out"
check "and why it will not proceed"   "would report a sweep that" "$out"
if [ -f "$WORK/a.json" ]; then
  printf '  FAIL  it wrote a results file for a sweep it refused to run\n'; FAIL=$((FAIL+1))
else
  printf '  ok    and writes no results file\n'; PASS=$((PASS+1))
fi

printf '\n== a flat bean set is a pad source, not an empty one ==\n\n'
# The layout that matched nothing. 20 beans, so the padding is tens of kilobytes.
out="$(sweep --pad-from "$CORPUS" --sizes '0' --repeat 1 --out "$WORK/b.json" | head -3)"
have="$(grep -oE 'padding available: [0-9]+' <<<"$out" | grep -oE '[0-9]+')"
if [ -n "$have" ] && [ "$have" -gt 20000 ]; then
  printf '  ok    a flat bean set yields %s bytes\n' "$have"; PASS=$((PASS+1))
else
  printf '  FAIL  a flat bean set yielded %s bytes — the glob is only matching one layout again\n' "${have:-0}"; FAIL=$((FAIL+1))
fi

printf '\n== and the scaffolded layout still is ==\n\n'
# The layout it always read: one directory per bean. Built here rather than
# depending on a target repo being checked out.
SCAF="$WORK/scaffolded"; mkdir -p "$SCAF"
i=0
for b in "$CORPUS"/bean-*.yaml; do
  i=$((i+1)); [ "$i" -gt 6 ] && break
  d="$SCAF/$(basename "$b" .yaml)-slug"; mkdir -p "$d"; cp "$b" "$d/bean.yaml"
done
out="$(sweep --pad-from "$SCAF" --sizes '0' --repeat 1 --out "$WORK/c.json" | head -3)"
have="$(grep -oE 'padding available: [0-9]+' <<<"$out" | grep -oE '[0-9]+')"
if [ -n "$have" ] && [ "$have" -gt 5000 ]; then
  printf '  ok    a scaffolded directory yields %s bytes\n' "$have"; PASS=$((PASS+1))
else
  printf '  FAIL  a scaffolded directory yielded %s bytes\n' "${have:-0}"; FAIL=$((FAIL+1))
fi

printf '\n== it says when it could only measure the verdict ==\n\n'
#
# The case is chosen because the judge has caught and NAMED it before, so that a
# fall-off in naming is legible across sizes. Every run since 2026-09-16 has
# named it in zero rows — so the sweep measured the verdict only, and a reader
# comparing verdict columns should know the stronger question was unavailable
# rather than answered negatively.
check "the script says so when nothing was named" "NAMED in none of the" "$(cat "$SWEEP")"
check "and why that is about the judge, not size"  "nothing left to fall from" "$(cat "$SWEEP")"
check "and it is conditional on the count"         'N_NAMED" -eq 0' "$(cat "$SWEEP")"

printf '\n== it warns when the padding contains what the defect introduced ==\n\n'
#
# The confound found on 2026-09-17 after a result had already been acted on: the
# seeded `contradicts-non-goal` plans a CP-SAT stub at
# src/seating_planner/solver/cpsat.py, and the padding is the other beans — of
# which seventeen of twenty mention the solver and bean-006 OWNS
# src/seating_planner/solver/**. A judge accepting under that padding may have
# been told the write is legitimate rather than distracted by volume.
#
# The harness can see this itself, because it knows what it seeded.
out="$(sweep --pad-from "$CORPUS" --sizes '0' --repeat 1 --out "$WORK/d.json" 2>&1 | head -20)"
check "the real corpus is flagged"    "the padding contains words the seeded defect introduced" "$out"
check "naming the term that matters"  "CP-SAT" "$out"
check "and what the two readings are" "telling the judge the defect is legitimate" "$out"
check "with where the control lives"  "pad-neutral" "$out"

printf '\n-- and the control pad source is not flagged --\n\n'
NEUTRAL="$ROOT/bench/fixtures/pad-neutral"
if [ -d "$NEUTRAL" ]; then
  out="$(sweep --pad-from "$NEUTRAL" --sizes '0' --repeat 1 --out "$WORK/e.json" 2>&1 | head -20)"
  nope "the control raises no warning" "the padding contains words the seeded defect introduced" "$out"
else
  printf '  FAIL  bench/fixtures/pad-neutral is missing — the control for the size finding\n'; FAIL=$((FAIL+1))
fi

printf '\n== the artifact says which padding was used ==\n\n'
#
# It did not, and that is the provenance gap in exactly the variable that turned
# out to matter: two sweeps padded from different sources were indistinguishable
# in their records. The same lesson as every other one today — record what
# varied — arriving at the thing that varied without anyone noticing.
#
# Checked against the script rather than by running a sweep: the run needs a GPU
# and this is a property of what it writes.
SRC="$(cat "$SWEEP")"
check "the source directory is recorded" 'pad_from' "$SRC"
check "and a hash of the padding itself" 'pad_sha' "$SRC"
check "and how much there was"           'pad_bytes' "$SRC"
check "and the confound check's result"  'words_the_seeded_defect_introduced' "$SRC"
check "with why it is in the record"     "cannot be compared with one that used the other" "$SRC"

printf '\n== --keep, because a table cannot be re-examined ==\n\n'
#
# Five rows of the control on 2026-09-17 read NAMED=yes, which would mean the
# judge identified the forbidden work and accepted it anyway — the sharpest
# reading available. It could not be checked: NAMED is a keyword match that can
# fire on a FABRICATED finding, and the run directories had already been deleted.
K="$WORK/kept"
out="$(sweep --pad-from "$CORPUS" --sizes '0' --repeat 1 --keep "$K" --out "$WORK/f.json" 2>&1 | head -6)"
check "it says where it is keeping them" "keeping run directories" "$out"
if [ -n "$(ls -A "$K" 2>/dev/null)" ]; then
  printf '  ok    and the directory survives the run\n'; PASS=$((PASS+1))
else
  printf '  FAIL  --keep was given and nothing was kept\n'; FAIL=$((FAIL+1))
fi
check "the flag is documented"          "NAMED in particular" "$(cat "$SWEEP")"
check "with the day it was needed"      "2026-09-17" "$(cat "$SWEEP")"

printf '\n== the script says what shape of prompt it actually measures ==\n\n'
#
# The padding goes INSIDE spec.md, so the experiment is "a document under audit
# that is mostly other material" — not "a prompt with more separate artifacts",
# which is what a real audit is. That distinction was missing for several hours
# while a warning was written on the broader reading.
SRC="$(cat "$SWEEP")"
check "it says the padding goes inside the document" "INSIDE spec.md" "$SRC"
# Single-line substrings: these are prose comments and the phrases wrap.
check "and what that is not"          "prompt with more separate artifacts" "$SRC"
check "and names the experiment that would settle it" "one hour of GPU" "$SRC"

printf '\n== --pad-into bean puts the bytes in a different artifact ==\n\n'
#
# WHERE the bytes go is a different question from how many, and only one answer
# was ever measured. `spec` appends inside the document under audit; `bean`
# appends to a copy of the bean, which reaches the judge under its own header
# while spec.md stays exactly as written. That is the arm that says whether
# displacement crosses an artifact boundary — which is what a real audit is made
# of.
K2="$WORK/kept2"
sweep --pad-from "$CORPUS" --sizes '20000' --repeat 1 --pad-into bean --keep "$K2" --out "$WORK/g.json" >/dev/null 2>&1 &
_sp=$!
# The judge call needs a GPU and this assertion does not: what matters is the
# tree it built, which exists before the model is asked anything.
sleep 20
B="$(find "$K2" -name bean.yaml 2>/dev/null | head -1)"
if [ -n "$B" ] && [ -s "$B" ]; then
  printf '  ok    a padded copy of the bean is written (%s bytes)\n' "$(wc -c < "$B")"; PASS=$((PASS+1))
else
  printf '  FAIL  --pad-into bean wrote no bean copy\n'; FAIL=$((FAIL+1))
fi
# Two concatenated YAML documents is not YAML, and yaml2json is what reads this
# to build the criterion id list — so the padding goes in as a block scalar.
if [ -n "$B" ]; then
  ids="$("$ROOT/factory/pipeline/yaml2json.sh" "$B" 2>/dev/null | jq -r '[.acceptance_criteria[]?.id] | join(",")')"
  if [ "$ids" = "ac1,ac2,ac3,ac4" ]; then
    printf '  ok    and it still parses, with its criterion ids intact\n'; PASS=$((PASS+1))
  else
    printf '  FAIL  the padded bean does not parse as the same bean: got "%s"\n' "$ids"; FAIL=$((FAIL+1))
  fi
  SP="$(find "$K2" -name spec.md 2>/dev/null | head -1)"
  if [ -n "$SP" ] && [ "$(wc -c < "$SP")" -lt 20000 ]; then
    printf '  ok    and the document under audit is left alone\n'; PASS=$((PASS+1))
  else
    printf '  FAIL  spec.md was padded too — the arm measures nothing new\n'; FAIL=$((FAIL+1))
  fi
fi
kill "$_sp" 2>/dev/null; wait "$_sp" 2>/dev/null || true

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
