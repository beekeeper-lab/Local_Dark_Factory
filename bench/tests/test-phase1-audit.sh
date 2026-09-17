#!/usr/bin/env bash
# test-phase1-audit.sh — the audit that decides whether Phase 1 is over.
#
# Eight predicates, and the only thing anyone reads is the block of words at the
# bottom. Nothing tested the script that writes it until 2026-09-17, when
# `every_handoff_is_commit` went from pass to blocker on bean-001 an hour after
# bean-001 merged — because it counted `rev-list main..<branch>`, the number of
# commits NOT YET on main, which a successful merge takes to zero.
#
# That is the failure this suite is for. An audit does not fail loudly when its
# instrument is wrong; it prints a different word in the same shape of line, and
# the only way to notice is to hand it a case whose answer is known.
#
# Each predicate gets a run directory built here, so the fixtures say in one
# place what a passing run looks like — which is also documentation nobody has
# to keep in sync by hand.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
AUDIT="$ROOT/bench/phase1-audit.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
          else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" \
                 "$(grep -E 'every_handoff|run_record|docs_rendered' <<<"$3" | head -3)"; FAIL=$((FAIL+1)); fi }
nope()  { if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s\n          must NOT contain: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
          else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi }
pred()  { # pred <name> <expected value> <output>
  local got; got="$(sed -n "s/^  $1: //p" <<<"$3" | tail -1)"
  if [ "$got" = "$2" ]; then printf '  ok    %s: %s\n' "$1" "$2"; PASS=$((PASS+1))
  else printf '  FAIL  %s should be %s, got %s\n' "$1" "$2" "${got:-<none>}"; FAIL=$((FAIL+1)); fi
}

[ -f "$AUDIT" ] || { printf '  SKIP  no phase1-audit.sh\n\n0 passed, 0 failed\n'; exit 0; }

# ------------------------------------------------------------------ fixture --
#
# A repository with a main, a bean branch whose commits look like the build
# loop's, and a run directory. Deliberately minimal: what is under test is how
# the audit READS a run, not whether the line can produce one.
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email a@b.c; git -C "$REPO" config user.name T
printf 'x\n' > "$REPO/README.md"
# `factory/` has to be TRACKED, or git reports the whole directory as one
# untracked entry `?? factory/` and the audit's dirty check — which ignores
# `?? factory/runs/`, the run directories a run necessarily leaves behind —
# sees an untracked tree and calls the handoff dirty. A real scaffolded repo
# tracks factory/; a fixture that does not is testing a repository that cannot
# exist.
mkdir -p "$REPO/factory"; printf 'scaffolded\n' > "$REPO/factory/repo.yaml"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init

BRANCH="bean/bean-001-x"
git -C "$REPO" checkout -q -b "$BRANCH"
SHAS=""
for t in task-1 task-2; do
  printf '%s\n' "$t" > "$REPO/$t.py"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "$(printf 'build(%s): a task\n\nbean: bean-001\nattempt: 1\nresult: verified\n' "$t")"
  SHAS="$SHAS $(git -C "$REPO" rev-parse HEAD)"
done

RUN="$REPO/factory/runs/bean-001-20260917T000000Z"
mkdir -p "$RUN/verdicts" "$RUN/build/task-1/attempt-1" "$RUN/build/task-2/attempt-1"
cat > "$RUN/run.json" <<JSON
{
 "schema_version": "run-record/1.0.0",
 "run_id": "bean-001-20260917T000000Z",
 "bean_id": "bean-001",
 "bean": "bean-001",
 "branch": "$BRANCH",
 "corpus": {
  "name": "seating-planner",
  "bean_set": "v1",
  "requirements_sha256": "73512dcd5b1e39493ba8a6fcbf6cd464cfe8ab1bc0d1625d73bb94b10fcc18e5"
 },
 "conditions": {
  "developer": {
   "model": "qwen3.8:27b-mtp-q8_0",
   "num_ctx": 65536,
   "provider": "ollama",
   "thinking": "medium",
   "digest": "8a1582877303"
  },
  "judge": {
   "model": "gpt-oss:120b",
   "num_ctx": 32768,
   "provider": "ollama",
   "thinking": "low",
   "digest": "a951a23b46a1"
  },
  "stack": "python",
  "pipeline_version": "1.4.0-df.1",
  "regime": "serial",
  "gates_manifest_digest": "sha256:77f23eb0d12c55050df64278bfbaa08a4040722d8202506555bcbd3afddd27c2",
  "risk_policy_version": "risk/2026-09-14"
 },
 "started_at": "2026-09-17T18:22:00Z",
 "status": "completed",
 "pi_session_file": "/home/gregg/.pi/agent/sessions/--home-gregg-workspace-seating-planner-py--/2026-09-15T15-21-08-910Z_01a0a5a8-5a2d-7054-9d59-5f3dd5551553.jsonl",
 "tier": "full"
}
JSON
printf 'spec\n' > "$RUN/spec.html"; printf 'impl\n' > "$RUN/impl-detail.html"
tasks_log() { : > "$RUN/tasks.jsonl"
  for t in task-1 task-2; do
    printf '{"ts":"2026-09-17T00:0%s:00Z","event":"task","task":"%s","result":"verified","attempts":1}\n' "${t##*-}" "$t" >> "$RUN/tasks.jsonl"
  done
}
tasks_log
run_audit() { ( cd "$REPO" && bash "$AUDIT" "$RUN" --repo "$REPO" 2>&1 ); }

# ---------------------------------------------------------------------------
printf '\n== a merged branch is not a run that handed nothing off ==\n\n'
#
# The bug, exactly: `main..<branch>` is empty once the branch is merged, so the
# predicate reported a blocker BECAUSE the bean had succeeded. The fixture merges
# and then asks again; the answer has to be the same both times.
out="$(run_audit)"
check "before the merge it passes"  "every_handoff_is_commit" "$out"
pred  every_handoff_is_commit pass "$out"

git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --no-ff -m "merge the bean" "$BRANCH"
git -C "$REPO" checkout -q "$BRANCH"
out="$(run_audit)"
pred  every_handoff_is_commit pass "$out"
check "and it says how it counted"  "found by message" "$out"
nope  "never by a range against main" "main..bean/bean-001-x" "$out"

printf '\n-- and the shas the build loop records are preferred to the message --\n\n'
#
# Newer runs write one `commit` event per task. That is the fact itself rather
# than a reconstruction of it, so it wins, and the report says which was used.
i=0
for sha in $SHAS; do
  i=$((i+1))
  printf '{"ts":"2026-09-17T00:05:00Z","event":"commit","task":"task-%s","sha":"%s","attempt":1,"paths":["a.py"]}\n' \
    "$i" "$sha" >> "$RUN/tasks.jsonl"
done
out="$(run_audit)"
pred  every_handoff_is_commit pass "$out"
check "naming the better instrument" "recorded by the build loop" "$out"

printf '\n-- a recorded sha that no longer resolves is said out loud --\n\n'
#
# Counting a sha git cannot find would be the same class of mistake in reverse:
# the record says a handoff happened and nothing checks that it still exists.
tasks_log
printf '{"ts":"2026-09-17T00:05:00Z","event":"commit","task":"task-1","sha":"%s","attempt":1,"paths":["a.py"]}\n' \
  "${SHAS%% *}" >> "$RUN/tasks.jsonl"
printf '{"ts":"2026-09-17T00:06:00Z","event":"commit","task":"task-2","sha":"%s","attempt":1,"paths":["a.py"]}\n' \
  "0000000000000000000000000000000000000000" >> "$RUN/tasks.jsonl"
out="$(run_audit)"
pred  every_handoff_is_commit fail "$out"
check "and it says how many vanished" "no longer resolve" "$out"
tasks_log

# ---------------------------------------------------------------------------
printf '\n== a run older than the schema is told apart from a malformed one ==\n\n'
#
# A reader sent to fix a record that predates the field it is missing wastes the
# trip. The finding stands — it did not validate — but it says which it is.
cp "$RUN/run.json" "$WORK/run.json.good"
jq 'del(.schema_version, .corpus)' "$WORK/run.json.good" > "$RUN/run.json"
out="$(run_audit)"
pred  run_record_conforms fail "$out"
check "it names the vintage"        "predates the schema" "$out"
cp "$WORK/run.json.good" "$RUN/run.json"
out="$(run_audit)"
pred  run_record_conforms pass "$out"
nope  "and says nothing about vintage when it validates" "predates the schema" "$out"

# ---------------------------------------------------------------------------
printf '\n== the read predicate does not close on an agent ==\n\n'
#
# `factory read --as-agent` records a weaker, true fact. The whole value of it is
# that it does not close the predicate, so that is asserted here rather than in
# the CLI alone — three readers have to agree and this is one of them.
printf 'read by: Some Agent (NOT a person)\nnote: it says what it found\n' > "$RUN/documents-read-by.txt"
out="$(run_audit)"
pred  docs_rendered_and_read pending "$out"
check "and it says an agent is not a person" "not a person" "$out"

printf '\n-- an unrendered document is a blocker, not a pending --\n\n'
rm -f "$RUN/impl-detail.html"
out="$(run_audit)"
pred  docs_rendered_and_read fail "$out"
check "naming what is missing"      "impl-detail.html" "$out"
printf 'impl\n' > "$RUN/impl-detail.html"

# ---------------------------------------------------------------------------
printf '\n== every predicate it can pass is one it can also fail ==\n\n'
#
# Same argument as the phase-0 suite: a predicate with only a pass path is a line
# that always reads green, and one with only a fail path reads as a permanent
# fault nobody can clear. Read from the script, not from a list kept beside it.
NAMES="$(grep -oE 'pred [a-z_]+ ' "$AUDIT" | awk '{print $2}' | sort -u)"
N="$(printf '%s\n' "$NAMES" | grep -c .)"
only_ok=""; only_fail=""
while IFS= read -r nm; do
  [ -n "$nm" ] || continue
  grep -qE "pred $nm (pass|pass_for_its_version|mechanism_proven)" "$AUDIT" || only_fail="$only_fail $nm"
  grep -qE "pred $nm (fail|pending|not_exercised)" "$AUDIT"                 || only_ok="$only_ok $nm"
done <<< "$NAMES"
if [ -z "$only_ok" ]; then printf '  ok    none of the %s predicates is green-only\n' "$N"; PASS=$((PASS+1))
else printf '  FAIL  these can pass and never fail:%s\n' "$only_ok"; FAIL=$((FAIL+1)); fi
if [ -z "$only_fail" ]; then printf '  ok    and none can only ever fail\n'; PASS=$((PASS+1))
else printf '  FAIL  these can fail and never pass:%s\n' "$only_fail"; FAIL=$((FAIL+1)); fi

printf '\n-- and the report names all eight, every time --\n\n'
out="$(run_audit)"
while IFS= read -r nm; do
  [ -n "$nm" ] || continue
  grep -qE "^  $nm: " <<<"$out" || { printf '  FAIL  %s is missing from phase_1_exit\n' "$nm"; FAIL=$((FAIL+1)); continue; }
done <<< "$NAMES"
printf '  ok    all %s predicates appear in the block\n' "$N"; PASS=$((PASS+1))

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
