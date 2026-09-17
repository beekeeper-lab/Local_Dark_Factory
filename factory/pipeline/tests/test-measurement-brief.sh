#!/usr/bin/env bash
# test-measurement-brief.sh — the controller's own measurements, in fewer bytes.
#
# Size is the only lever measured this week that moved the judge's false-accept
# rate: three passes at 20,422 and 30,422 bytes rejected a seeded defect 3 of 3,
# and at 40,422 it accepted 2 of 3. A real spec audit sits at 25,428, of which
# 4,805 are two controller measurements sent as raw JSON. As prose they are 720.
#
# So these assertions are about a summary staying TRUE while getting short. The
# failure they exist to prevent is a brief that quietly drops the thing the judge
# was supposed to notice — which would be invisible, because the prompt would
# still look complete.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MB="$PIPELINE_DIR/measurement-brief.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:250}"; FAIL=$((FAIL+1)); fi }
nope()  { if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
          else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi }
rc_is() { if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi }

printf '\n== the fact a verify-precheck exists to carry ==\n\n'
# A task where EVERY verify already passed is the defect. One already-passing
# verify among several is often legitimate, and the brief has to keep that
# distinction or it turns a real finding into a scary number.
cat > "$WORK/vp.json" <<'J'
{"schema":"verify-precheck/1.0.0","tasks":[
 {"task":"task-1","verifies":[{"passes_before_the_work":true},{"passes_before_the_work":false},{"passes_before_the_work":false}]},
 {"task":"task-2","verifies":[{"passes_before_the_work":true},{"passes_before_the_work":true}]}]}
J
out="$(bash "$MB" "$WORK/vp.json")"; rc=$?
rc_is "it renders"                      "$rc" 0
check "a partial count is just a count" "task-1: 1 of 3 verifies already passed" "$out"
check "and the whole-task case is called out" "task-2: 2 of 2 verifies already passed" "$out"
check "in words, not just a number"     "EVERY check already passed" "$out"
nope  "and task-1 is not accused"       "task-1: 1 of 3 verifies already passed   <-" "$out"
check "the legitimate case is explained" "often legitimate" "$out"

printf '\n== the fact a claims-check exists to carry ==\n\n'
cat > "$WORK/cc.json" <<'J'
{"schema":"claims-check/1.0.0",
 "current_behaviour":{"section":"Current behaviour","checked":true,
   "missing_paths":["src/ghost.py"],"said_absent_but_present":["pyproject.toml"]},
 "proposed":{"section":"Proposed change","checked":true,
   "missing_paths":[],"said_absent_but_present":[]}}
J
out="$(bash "$MB" "$WORK/cc.json")"; rc=$?
rc_is "it renders"                      "$rc" 0
check "a path the spec invented is named" "src/ghost.py" "$out"
check "with what that means"            "says these exist and they do NOT" "$out"
check "and the other direction too"     "says these are absent and they ARE present" "$out"
check "a clean section says so"         "every path it names is as the spec describes" "$out"
# No section may vanish. The first version selected on `has("checked")`, so a
# section without that key disappeared from the brief entirely — the precise
# failure this renderer must not have, because the prompt would still look
# complete and nobody would know a section had been dropped.
cat > "$WORK/cc2.json" <<'J'
{"schema":"claims-check/1.0.0",
 "half":{"section":"Recorded no result","missing_paths":[]},
 "whole":{"section":"Checked","checked":true,"missing_paths":["x.py"]}}
J
out2="$(bash "$MB" "$WORK/cc2.json")"
check "a section with no result still appears" "Recorded no result" "$out2"
check "and says that is what it is"      "NO RESULT RECORDED" "$out2"
check "alongside the one that has one"   "\"Checked\": checked" "$out2"
n="$(grep -c 'section "' <<<"$out2")"
if [ "$n" = "2" ]; then printf '  ok    both sections are rendered, none dropped\n'; PASS=$((PASS+1))
else printf '  FAIL  %s of 2 sections rendered — one was silently dropped\n' "$n"; FAIL=$((FAIL+1)); fi

printf '\n== the gate record, which is the biggest JSON in an impl audit ==\n\n'
# 6,510 bytes of a 30,514-byte prompt, almost all of it per-gate logs, digests,
# timings and containment records the judge is told not to re-derive.
cat > "$WORK/g.json" <<'J'
{"schema":"gate-run/1.0.0","overall":"fail","tier":{"final_tier":2,"terms":{"policy":2}},
 "base":"e9a5b33e9482f0b23d5678e96622f2c5a92a2a83",
 "gates":[{"id":"lint","status":"pass"},{"id":"unit","status":"fail"}],
 "acceptance_criteria":[{"id":"ac1","passed":"pass"},{"id":"ac2","passed":"fail"}],
 "test_integrity":{"fails_on_revert":{"result":"no"}}}
J
out="$(bash "$MB" "$WORK/g.json")"; rc=$?
rc_is "it renders"                      "$rc" 0
check "the overall result is first"     "overall: fail" "$out"
check "each gate by name"               "gate unit: fail" "$out"
check "each criterion"                  "ac2: fail" "$out"
check "and what the controller decided about the tests" "tests pin the change: no" "$out"
# `tier` is an object with the number inside it and `base` is a bare sha.
# Reading either with `// "?"` printed the whole tier object into the brief —
# forty lines of policy terms where a number was meant, in the one place whose
# entire purpose is fewer bytes.
check "the tier is the number, not the object" "tier 2, against base e9a5b33e9482" "$out"
nope  "and no policy terms leaked in"   "binding_term" "$out"

printf '\n== it refuses what it does not understand ==\n\n'
printf '{"schema":"something-else/9.9","data":[1,2,3]}\n' > "$WORK/x.json"
out="$(bash "$MB" "$WORK/x.json" 2>&1)"; rc=$?
rc_is "an unknown schema is refused"    "$rc" 2
check "and it says which"               "something-else/9.9" "$out"
check "and why refusing is right"       "worse than the JSON it replaced" "$out"
printf 'not json\n' > "$WORK/y.json"
out="$(bash "$MB" "$WORK/y.json" 2>&1)"; rc=$?
rc_is "so is a file that is not JSON"   "$rc" 2

printf '\n== --out writes it, and says what it saved ==\n\n'
out="$(bash "$MB" "$WORK/vp.json" --out "$WORK/vp.txt")"; rc=$?
rc_is "it writes"                       "$rc" 0
check "and reports both sizes"          "bytes ->" "$out"
if [ -s "$WORK/vp.txt" ]; then
  printf '  ok    the brief is on disk\n'; PASS=$((PASS+1))
else
  printf '  FAIL  nothing was written\n'; FAIL=$((FAIL+1))
fi
# Not asserted smaller HERE: this fixture is a 250-byte JSON and the brief carries
# a few hundred bytes of fixed prose explaining what the measurement means. It
# pays for itself on a real task list — asserted below, 4,805 into 720 — and on a
# trivial one it does not. judge.sh sends whichever is smaller, which is asserted
# in test-judge.sh, because the whole justification for this is the byte count.
# A refusal must not leave a half-written file behind for the judge to be sent.
bash "$MB" "$WORK/x.json" --out "$WORK/x.txt" >/dev/null 2>&1
if [ -e "$WORK/x.txt" ]; then
  printf '  FAIL  a refused render still wrote a file\n'; FAIL=$((FAIL+1))
else
  printf '  ok    and a refusal writes nothing\n'; PASS=$((PASS+1))
fi

printf '\n== the real measurements from a real run ==\n\n'
R=/home/gregg/workspace/seating-planner-py/factory/runs/bean-001-20260915T192025Z
if [ -f "$R/verify-precheck.json" ] && [ -f "$R/claims-check.json" ]; then
  b=0; a=0
  for f in verify-precheck claims-check; do
    bash "$MB" "$R/$f.json" --out "$WORK/$f.txt" >/dev/null 2>&1 || continue
    b=$((b + $(wc -c < "$R/$f.json"))); a=$((a + $(wc -c < "$WORK/$f.txt")))
  done
  if [ "$a" -gt 0 ] && [ "$a" -lt "$((b / 3))" ]; then
    printf '  ok    %s bytes of measurement become %s\n' "$b" "$a"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s bytes became %s — expected less than a third\n' "$b" "$a"; FAIL=$((FAIL+1))
  fi
  # And the thing that must survive: the one real discrepancy in that run.
  check "the real discrepancy survives the summary" "factory/pipeline-config.json" \
    "$(cat "$WORK/claims-check.txt" 2>/dev/null)"
else
  printf '  SKIP  no real run to read\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
