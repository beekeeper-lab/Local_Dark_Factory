#!/usr/bin/env bash
# test-cli.sh — the operator surface, which had no tests at all.
#
# `factory` is the front door: doctor answers "can this repo be run against",
# runs is the only view of the history, read settles the one phase-1 predicate a
# script cannot, policy is how the risk file gets reviewed by its consequences.
# All of it was written by hand and checked by running it once, which is the
# same standard the pipeline steps are held to except that nothing would notice
# when it drifted. The usage text had already drifted: it named steps `specify`
# and `document`, which the orchestrator refuses.
set -uo pipefail

FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FACTORY="$FACTORY_ROOT/bin/factory"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

REPO="$WORK/repo"; git init -q -b main "$REPO"
git -C "$REPO" config user.email operator@example.com
git -C "$REPO" config user.name "The Operator"
mkdir -p "$REPO/factory/beans/bean-001-a-thing" "$REPO/factory/runs"
cat > "$REPO/factory/pipeline-config.json" <<'CFG'
{
  "runs_root": "factory/runs",
  "bean_dir_pattern": "factory/beans/BEAN-NNN-<slug>",
  "bean_index_path": "factory/beans/INDEX.md",
  "corpus": {"name": "fixture", "bean_set": "v1", "requirements_sha256": "0000"}
}
CFG
printf '# Beans\n\n1. bean-001 — a thing\n' > "$REPO/factory/beans/INDEX.md"
printf 'schema_version: bean/2.0.0\nid: bean-001\ntitle: a thing\n' > "$REPO/factory/beans/bean-001-a-thing/bean.yaml"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init

fac() { ( cd "$REPO" && "$FACTORY" "$@" 2>&1 ); }

# --------------------------------------------------------------------------
printf '\n== the usage text names steps the orchestrator will accept ==\n\n'
#
# It named `specify` and `document` for weeks. Both are refused by
# `--stop-after`, so the only two step names a person was likely to copy out of
# the help were the two that could not work.
usage="$(fac --help)"
STEPS_LINE="$(sed -n 's/^  full)  STEPS=(\(.*\)) ;;$/\1/p' "$FACTORY_ROOT/pipeline/orchestrate.sh")"
want "the orchestrator's full tier was found" "could not read STEPS from orchestrate.sh" \
     test -n "$STEPS_LINE"
missing=""
for s in $STEPS_LINE; do
  grep -qF -- " $s" <<<"$usage" || missing="$missing $s"
done
want "every real step appears in the help" "not named in usage:$missing" test -z "$missing"
# And the reverse: nothing in the "steps in order" line that the orchestrator
# would reject.
order="$(sed -n '/^Steps in order:/,/^$/p' <<<"$usage" | tr -d '\n' | sed 's/Steps in order://')"
bogus=""
for s in $order; do
  case " $STEPS_LINE " in *" $s "*) ;; *) bogus="$bogus $s" ;; esac
done
want "and nothing that is not a step" "named in usage but not a step:$bogus" test -z "$bogus"
nope "the old wrong name is gone"    " specify," "$usage"

# --------------------------------------------------------------------------
printf '\n== doctor answers the question it exists to answer ==\n\n'
out="$(fac doctor)"; rc=$?
check "it names the repo"            "$REPO" "$out"
check "it finds the config"          "pipeline-config.json" "$out"
check "it counts the beans"          "1 installed" "$out"
check "it reports the corpus"        "fixture v1" "$out"
check "a missing repo.yaml is a failure" "repo.yaml" "$out"
rc_is "and the exit code says so"    "$rc" 1
check "it says what to do"           "not ready" "$out"

printf '\n-- a config with no corpus block is caught here, not by the first run --\n\n'
jq 'del(.corpus)' "$REPO/factory/pipeline-config.json" > "$WORK/c" && mv "$WORK/c" "$REPO/factory/pipeline-config.json"
out="$(fac doctor)"
check "the missing corpus is named"  "missing: name bean_set requirements_sha256" "$out"
check "with the fix"                 "scaffold.sh" "$out"
git -C "$REPO" checkout -q -- factory/pipeline-config.json

printf '\n-- free space where the line actually writes --\n\n'
#
# The gate tree, the pipeline snapshot, every worker's agent directory and the
# model gateway all live under TMPDIR. When it filled, a contained worker's write
# failed with "Unknown system error -122", pi exited 1, and the run recorded a doc
# step that produced nothing. Nothing in that chain says "the disk is full".
out="$(fac doctor)"
check "free space is reported"       "temp space" "$out"
check "and where it was measured"    "${TMPDIR:-/tmp}" "$out"
out="$(TMPDIR=/nonexistent-for-df fac doctor 2>&1)"
check "an unreadable temp root fails" "cannot read free space" "$out"

printf '\n-- required_checks that nothing produces is said out loud --\n\n'
#
# A config naming a check that no workflow produces and no step waits on reads
# exactly like protection that is in force. That is how "failing open" starts,
# and the only defence is for the tool to say the true thing unprompted.
cat > "$REPO/factory/repo.yaml" <<'RC'
schema_version: repo-config/1.0.0
repo: example/x
default_branch: main
merge_mode: human_required
required_checks:
  - gates
RC
out="$(fac doctor)"
check "the check is named"           "gates" "$out"
check "and so is the absence of CI"  "no .github/workflows" "$out"
check "naming where it looked"       "the working tree has no" "$out"
check "and what the ci step will do"  "refuse rather than wait" "$out"
check "as a note, not a pass"        "note   required_checks" "$out"
mkdir -p "$REPO/.github/workflows" && printf 'name: gates\n' > "$REPO/.github/workflows/gates.yml"
out="$(fac doctor)"
check "workflows change the wording" ".github/workflows exists in the working tree" "$out"
check "and points at the branch check" "the ci step asks the same of the branch" "$out"
rm -rf "$REPO/.github"

printf '\n-- "could not ask ollama" is not "the model is missing" --\n\n'
#
# This was `ollama list 2>/dev/null | grep -q` per role, so a list that failed
# produced empty input, no match, and the words "is not pulled" about a model
# sitting on disk. Observed while a judge measurement had the GPU: doctor said
# the developer model was missing; `ollama list` a second later showed it, 29 GB,
# three days old.
mkdir -p "$WORK/badbin"
printf '#!/usr/bin/env bash\nexit 7\n' > "$WORK/badbin/ollama"
chmod +x "$WORK/badbin/ollama"
out="$(PATH="$WORK/badbin:$PATH" fac doctor)"
check "it says it could not ask"     "cannot ask ollama what is pulled" "$out"
check "and names the exit code"      "list exited 7" "$out"
nope "and does not claim absence"    "is not pulled" "$out"

printf '\n-- hidden tests, reported whether or not they exist --\n\n'
#
# A doctor silent about a check nobody set up reads the same as a doctor
# reporting it green, and the value of hidden tests is that a reader knows
# whether the worker was measured by something it could not read.
out="$(fac doctor)"
check "none configured is said"      "none configured" "$out"
check "and what that means"          "every check in this repo runs code the worker could read" "$out"

HTD="$WORK/hidden/bean-001"; mkdir -p "$HTD"
printf 'def test_h():\n    assert True\n' > "$HTD/test_h.py"
jq --arg d "$WORK/hidden/<bean>" '.hidden_tests = {dir:$d}' \
  "$REPO/factory/pipeline-config.json" > "$WORK/c" && mv "$WORK/c" "$REPO/factory/pipeline-config.json"
out="$(fac doctor)"
check "a per-bean root is counted"   "1 file(s) for 1 bean(s), outside the repository" "$out"

# Inside the repository is the one that matters: the worker mounts the whole tree.
mkdir -p "$REPO/hidden-inside"
printf 'def test_h():\n    assert True\n' > "$REPO/hidden-inside/test_h.py"
jq --arg d "$REPO/hidden-inside" '.hidden_tests = {dir:$d}' \
  "$REPO/factory/pipeline-config.json" > "$WORK/c" && mv "$WORK/c" "$REPO/factory/pipeline-config.json"
out="$(fac doctor)"
check "inside the repository fails"  "is inside the repository" "$out"
check "and says what reads it"       "the worker mounts the whole tree" "$out"
jq 'del(.hidden_tests)' "$REPO/factory/pipeline-config.json" > "$WORK/c" && mv "$WORK/c" "$REPO/factory/pipeline-config.json"
rm -rf "$REPO/hidden-inside"

# --------------------------------------------------------------------------
printf '\n== runs lists the history, which is the only place it is visible ==\n\n'
out="$(fac runs 2>&1)"; rc=$?
rc_is "with no runs it refuses"      "$rc" 1
check "and says where it looked"     "factory/runs" "$out"

mk_run() { # <id> <status> <steps...>
  local id="$1" status="$2"; shift 2
  local d="$REPO/factory/runs/$id"
  mkdir -p "$d"
  jq -n --arg i "$id" --arg s "$status" \
    '{schema_version:"run/1.0.0", run_id:$i, bean:"bean-001", bean_id:"bean-001",
      branch:"factory/bean-001", status:$s, started_at:"2026-09-15T10:00:00Z",
      finished_at:"2026-09-15T11:00:00Z"}' > "$d/run.json"
  : > "$d/steps.jsonl"
  local t=0 s
  for s in "$@"; do
    printf '{"ts":"2026-09-15T10:%02d:00.000Z","step":"%s","event":"start","attempt":1,"verdict":null}\n' "$t" "$s" >> "$d/steps.jsonl"
    t=$((t + 1))
    printf '{"ts":"2026-09-15T10:%02d:00.000Z","step":"%s","event":"end","attempt":1,"verdict":"PASS"}\n' "$t" "$s" >> "$d/steps.jsonl"
    t=$((t + 1))
  done
}
mk_run "bean-001-20260915T100000Z" completed preflight spec build
sleep 1
mk_run "bean-001-20260915T120000Z" halted preflight spec
out="$(fac runs)"
check "both runs are listed"         "bean-001-20260915T100000Z" "$out"
check "newest first"                 "bean-001-20260915T120000Z" "$out"
want  "and it is actually first"     "the newer run should be the first row" \
      test "$(grep -n 'bean-001-20260915T120000Z' <<<"$out" | cut -d: -f1)" \
      -lt "$(grep -n 'bean-001-20260915T100000Z' <<<"$out" | cut -d: -f1)"
check "the status is shown"          "halted" "$out"
check "and how many steps ended"     "3" "$out"
check "and how long it took"         "s" "$out"

# --------------------------------------------------------------------------
printf '\n== status reads one run ==\n\n'
out="$(fac status)"
check "it names the newest run"      "bean-001-20260915T120000Z" "$out"
check "and its branch"               "factory/bean-001" "$out"
out="$(fac status "$REPO/factory/runs/bean-001-20260915T100000Z")"
check "a named run overrides"        "bean-001-20260915T100000Z" "$out"

# --------------------------------------------------------------------------
printf '\n== read refuses until there is something to read ==\n\n'
#
# `docs_rendered_and_read` is the one exit predicate a script cannot settle, so
# the command that records it must not be able to record it for a run with no
# documents — that would turn the predicate into a formality, which is exactly
# what having a command for it is supposed to prevent.
R="$REPO/factory/runs/bean-001-20260915T120000Z"
out="$(fac read "$R" 2>&1)"; rc=$?
rc_is "no rendered documents, no record" "$rc" 1
check "and it says which is missing" "spec.html" "$out"
want  "nothing was written"          "documents-read-by.txt must not exist" \
      test ! -f "$R/documents-read-by.txt"

printf '<html>spec</html>\n' > "$R/spec.html"
out="$(fac read "$R" 2>&1)"; rc=$?
rc_is "one document is not both"     "$rc" 1
check "and it names the other"       "impl-detail.html" "$out"

printf '<html>impl</html>\n' > "$R/impl-detail.html"
# `read` asks on /dev/tty deliberately: a confirmation that can be piped in is a
# confirmation that can be automated, and this one must not be.
out="$( cd "$REPO" && printf 'y\n' | "$FACTORY" read "$R" 2>&1 )"; rc=$?
want "a piped yes does not count"    "documents-read-by.txt must not exist after a piped answer" \
     test ! -f "$R/documents-read-by.txt"

if [ -e /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then
  out="$( cd "$REPO" && "$FACTORY" read "$R" < /dev/null 2>&1 <<<'' )" || true
fi
# Answering for real needs a terminal, which a test does not have. What can be
# checked without one is that the prompt says what confirming means.
out="$( cd "$REPO" && "$FACTORY" read "$R" 2>&1 </dev/null )" || true
check "the prompt says what it means" "they teach" "$out"
check "and names both documents"      "impl-detail.html" "$out"

# --------------------------------------------------------------------------
printf '\n== beans, and the refusals ==\n\n'
out="$(fac beans)"
check "the index is printed"         "bean-001" "$out"

out="$(fac nonsense 2>&1)"; rc=$?
rc_is "an unknown command refuses"   "$rc" 1
check "and names it"                 "unknown command: nonsense" "$out"

out="$( cd "$WORK" && "$FACTORY" doctor 2>&1 )"; rc=$?
rc_is "outside a git repo it refuses" "$rc" 1
check "and says why"                  "not inside a git repository" "$out"

BARE="$WORK/bare"; git init -q -b main "$BARE"
out="$( cd "$BARE" && "$FACTORY" doctor 2>&1 )"; rc=$?
rc_is "an unscaffolded repo refuses"  "$rc" 1
check "and says how to scaffold it"   "scaffold.sh" "$out"

printf '\n== `factory read` needs a person, and says so instead of leaking ==\n\n'
#
# `docs_rendered_and_read` is the one Phase-1 predicate a script cannot settle, so
# the confirmation comes from a terminal or not at all — there is deliberately no
# --yes, because a flag that lets a script record that a human read something
# turns the predicate into a formality.
#
# What it did without one: `read </dev/tty` with no controlling terminal, which
# leaked `line 733: /dev/tty: No such device or address` and then said "Not
# recorded." The outcome was right and the message was a bash error.
#
# `[ -r /dev/tty ]` does not catch it either: the device node exists and the
# permissions allow it, always. The open is the test.
mkdir -p "$REPO/factory/runs/bean-001-20260102T000000Z"
printf '<html>spec</html>\n' > "$REPO/factory/runs/bean-001-20260102T000000Z/spec.html"
printf '<html>impl</html>\n' > "$REPO/factory/runs/bean-001-20260102T000000Z/impl-detail.html"
printf '{"run_id":"r","bean":"bean-001"}\n' > "$REPO/factory/runs/bean-001-20260102T000000Z/run.json"
out="$(fac read factory/runs/bean-001-20260102T000000Z </dev/null)"
check "it says there is nobody to ask"  "no terminal here, so there is nobody to ask" "$out"
check "and why there is no flag"        "There is no --yes for the same reason" "$out"
check "and how to do it properly"       "Run it from an interactive shell" "$out"
nope  "without a bash error"            "/dev/tty: No such device" "$out"
if [ -f "$REPO/factory/runs/bean-001-20260102T000000Z/documents-read-by.txt" ]; then
  printf '  FAIL  it recorded a reading nobody did\n'; FAIL=$((FAIL+1))
else
  printf '  ok    and nothing is recorded\n'; PASS=$((PASS+1))
fi

printf '\n-- and an unrendered run is refused before any of that --\n\n'
mkdir -p "$REPO/factory/runs/bean-001-20260103T000000Z"
printf '{"run_id":"r","bean":"bean-001"}\n' > "$REPO/factory/runs/bean-001-20260103T000000Z/run.json"
out="$(fac read factory/runs/bean-001-20260103T000000Z </dev/null)"
check "it names what is missing"        "is not rendered" "$out"
nope  "and does not ask to record it"   "Record that?" "$out"
rm -rf "$REPO/factory/runs/bean-001-20260102T000000Z" "$REPO/factory/runs/bean-001-20260103T000000Z"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
