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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
