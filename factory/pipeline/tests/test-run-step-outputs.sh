#!/usr/bin/env bash
# test-run-step-outputs.sh — what "this attempt did nothing" means, exactly.
#
# run-step derives a verdict partly from whether the step wrote what it exists to
# produce. The guard is for a session that narrates an intention and stops: a doc
# step once spent thirty-seven minutes ending with "From now on, I'll create the
# documentation", wrote nothing, and was recorded as `child exit 1` — which reads
# like a crash and sent the next reader looking in the wrong place.
#
# The rule used to be "every expected output must be fresh", and that is wrong on
# a retry. bean-002 halted on it on 2026-09-17: spec-check raised one finding
# against spec.md, the worker fixed exactly that, said plainly that tasks.yaml
# had no findings and was therefore unchanged — true, and the right thing to do —
# and the attempt was failed for not rewriting a file that did not need it. A
# rule that punishes a minimal targeted edit teaches the opposite of what this
# line wants.
#
# So: nothing missing, and at least one output written now.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "${3:0:300}"; FAIL=$((FAIL+1)); fi }
nope()  { if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
          else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi }
rc_is() { if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
          else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi }

cd "$WORK"
git init -q .
git commit -q --allow-empty -m init
mkdir -p run/verdicts sessions
echo '{"run_id":"T","bean":"BEAN-001","branch":"bean/BEAN-001-test"}' > run/run.json

# The stub writes whichever outputs the test names, with whatever content, and
# exits with whatever status — the three variables this suite is about. It also
# writes a session file, because run-step reads the observed conditions out of
# one and a stub without it would fail for an unrelated reason.
cat > stub-pi <<'STUB'
#!/usr/bin/env bash
for f in ${STUB_WRITE:-}; do printf '%s\n' "${STUB_CONTENT:-written $(date +%s%N)}" > "$f"; done
sess="${PI_SESSIONS_DIR:-.}/stub-$(date +%s%N).jsonl"
mkdir -p "$(dirname "$sess")"
printf '{"type":"session","version":"stub","id":"stub","cwd":"%s"}\n' "$PWD" > "$sess"
exit "${STUB_RC:-0}"
STUB
chmod +x stub-pi

run_step() { # run_step <what to write> <stub exit code>
  STUB_WRITE="$1" STUB_RC="$2" \
  PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" FACTORY_CONTAIN_WORKER=0 \
    bash "$PIPELINE_DIR/run-step.sh" run spec 2>&1
}
reset() { rm -f "$WORK/run/spec.md" "$WORK/run/tasks.yaml" "$WORK/run/steps.jsonl"; }

printf '\n== an attempt that exited badly and wrote nothing is a failure ==\n\n'
#
# Non-zero throughout this suite where the outputs are the question. A child that
# exits 0 is a PASS whatever it wrote, on purpose: the controller check that
# reads the file runs next and fails on the contents, which is a better place to
# decide than an exit code. What the freshness rule settles is what a NON-ZERO
# exit means — work that happened and then broke, or work that never happened.
reset
out="$(run_step "" 143)"; rc=$?
rc_is "it fails"                         "$rc" 1
check "naming what is not there"         "It produced none of what it exists to produce" "$out"
check "and where to look"                "its last message is the place to look" "$out"

printf '\n== a first attempt that wrote only one of two is still short ==\n\n'
#
# Not the retry case: the other file does not exist at all, so the step has not
# produced what the next check reads.
reset
out="$(run_step "$WORK/run/spec.md" 143)"; rc=$?
rc_is "it fails"                         "$rc" 1
check "naming the missing one"           "tasks.yaml" "$out"

printf '\n== a retry that changed only the file with findings passes ==\n\n'
#
# The bean-002 halt, in three lines. Both outputs exist from the first attempt;
# this attempt rewrites the one that had a finding and leaves the other exactly
# as it was, which is correct.
reset
STUB_WRITE="$WORK/run/spec.md $WORK/run/tasks.yaml" STUB_CONTENT="first attempt" \
  PI_BIN="$WORK/stub-pi" PI_SESSIONS_DIR="$WORK/sessions" FACTORY_CONTAIN_WORKER=0 \
  bash "$PIPELINE_DIR/run-step.sh" run spec >/dev/null 2>&1
before="$(sha256sum "$WORK/run/tasks.yaml" | cut -d' ' -f1)"
out="$(STUB_CONTENT="second attempt" run_step "$WORK/run/spec.md" 0)"; rc=$?
rc_is "the attempt passes"               "$rc" 0
after="$(sha256sum "$WORK/run/tasks.yaml" | cut -d' ' -f1)"
if [ "$before" = "$after" ]; then printf '  ok    and tasks.yaml really was left alone\n'; PASS=$((PASS+1))
else printf '  FAIL  the fixture rewrote tasks.yaml, so this tested nothing\n'; FAIL=$((FAIL+1)); fi
nope  "it is not called a stale attempt" "Unchanged since before this attempt started" "$out"

printf '\n-- and the same, with a non-zero exit from the worker --\n\n'
#
# Which is the shape bean-002 actually had: the worker exited 143 because the
# container entrypoint always did, and the targeted edit was real.
out="$(STUB_CONTENT="third attempt" run_step "$WORK/run/spec.md" 143)"; rc=$?
rc_is "still a pass"                     "$rc" 0
check "and it says the output stands"    "the output stands" "$out"

printf '\n== a retry that rewrote nothing at all still fails ==\n\n'
#
# The guard has to survive the fix. Both outputs present, neither touched: this
# is the session that described what it was about to do.
out="$(run_step "" 143)"; rc=$?
rc_is "it fails"                         "$rc" 1
check "naming the untouched files"       "Unchanged since before this attempt started" "$out"
check "and saying nothing else was written" "nothing else was written" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
