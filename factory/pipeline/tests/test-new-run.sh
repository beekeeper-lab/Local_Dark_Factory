#!/usr/bin/env bash
# test-new-run.sh — the record every other record hangs off.
#
# run.json is the run's own account of what it is and what it ran on, and for a
# long time it was the one declared contract nothing honoured: it wrote `bean`
# where the schema required `bean_id`, and omitted schema_version, corpus and
# conditions entirely. Nothing validated it, so the drift was invisible.
#
# `corpus.requirements_sha256` is the field that proves the input did not move
# between runs, which is the whole basis for comparing one run to another. A
# missing one has to be a refusal, not a blank.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$PIPELINE_DIR/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}
eq() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# ---------------------------------------------------------------- fixtures --
REPO="$WORK/repo"; git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e.com; git -C "$REPO" config user.name T
mkdir -p "$REPO/factory"
cat > "$REPO/factory/pipeline-config.json" <<'CFG'
{
  "runs_root": "factory/runs",
  "stack": "python",
  "gates_ref": "factory/gates.lock.yaml",
  "repo_config": "factory/repo.yaml",
  "corpus": {"name": "fixture-corpus", "bean_set": "v1", "requirements_sha256": "9f2c1a4b7d3e8056f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f701"}
}
CFG
cat > "$REPO/factory/gates.lock.yaml" <<'GL'
image: registry.example/factory-gate-python:20260914@sha256:cafebabe1234
GL
cat > "$REPO/factory/repo.yaml" <<'RY'
schema_version: repo-config/1.0.0
policy_ref: factory/risk-policy.yaml
RY
cat > "$REPO/factory/risk-policy.yaml" <<'RP'
policy_version: 3.1.4
RP
printf 'x\n' > "$REPO/keep.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init
git -C "$REPO" checkout -q -b bean/bean-001-thing

mkdir -p "$WORK/bin"
cat > "$WORK/bin/ollama" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = list ] && printf 'dev-model:latest\tdddd1111\t1 GB\njudge-model:latest\tjjjj2222\t2 GB\n'
exit 0
STUB
chmod +x "$WORK/bin/ollama"
export PATH="$WORK/bin:$PATH"

cat > "$WORK/roles.json" <<'RJ'
{"provider_allowlist": ["ollama"],
 "roles": {
   "developer": {"provider": "ollama", "model": "dev-model:latest", "num_ctx": 65536, "thinking": "medium"},
   "judge": {"provider": "ollama", "model": "judge-model:latest", "num_ctx": 32768, "thinking": "high"}}}
RJ

nr() { # <bean-id> [extra env already exported by caller]
  ( cd "$REPO" && PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
    ROLES_FILE="$WORK/roles.json" PI_SESSIONS_DIR="$WORK/no-sessions" \
    bash "$PIPELINE_DIR/new-run.sh" "$@" 2>&1 )
}

# --------------------------------------------------------------------------
printf '\n== the record a run starts with ==\n\n'
out="$(nr bean-001)"; rc=$?
rc_is "it succeeds"                    "$rc" 0
RD="$(printf '%s' "$out" | tail -1)"
want "it prints the run directory"     "the last line should be a directory" test -d "$RD"
want "with run.json in it"             "run.json should exist"               test -f "$RD/run.json"
J="$(cat "$RD/run.json")"

eq "the schema version is stamped"     "run-record/1.0.0" "$(jq -r '.schema_version' <<<"$J")"
eq "bean_id is what the schema asks for" "bean-001"       "$(jq -r '.bean_id' <<<"$J")"
# `bean` is kept alongside `bean_id` on purpose: every script here reads it, and
# renaming across a dozen call sites during a live run is the worse trade.
eq "and bean is kept beside it"        "bean-001"         "$(jq -r '.bean' <<<"$J")"
eq "the branch is recorded"            "bean/bean-001-thing" "$(jq -r '.branch' <<<"$J")"
eq "and the status"                    "running"          "$(jq -r '.status' <<<"$J")"
want "the run id matches the directory" "run_id should be the directory's basename" \
     test "$(jq -r '.run_id' <<<"$J")" = "$(basename "$RD")"

printf '\n-- the corpus, which is what makes two runs comparable --\n\n'
eq "the corpus is named"               "fixture-corpus"   "$(jq -r '.corpus.name' <<<"$J")"
eq "the bean set too"                  "v1"               "$(jq -r '.corpus.bean_set' <<<"$J")"
eq "and the requirements are pinned"   "9f2c1a4b7d3e8056f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f701"         "$(jq -r '.corpus.requirements_sha256' <<<"$J")"

printf '\n-- the conditions, all knowable before the first step runs --\n\n'
eq "the developer model"               "dev-model:latest" "$(jq -r '.conditions.developer.model' <<<"$J")"
eq "its context"                       "65536"            "$(jq -r '.conditions.developer.num_ctx' <<<"$J")"
eq "its thinking level"                "medium"           "$(jq -r '.conditions.developer.thinking' <<<"$J")"
# Digests, so a re-pointed tag cannot pass for the weights that were measured.
eq "and the digest, not just the tag"  "dddd1111"         "$(jq -r '.conditions.developer.digest' <<<"$J")"
eq "the judge model"                   "judge-model:latest" "$(jq -r '.conditions.judge.model' <<<"$J")"
eq "and its digest"                    "jjjj2222"         "$(jq -r '.conditions.judge.digest' <<<"$J")"
eq "the gate image digest"             "sha256:cafebabe1234" "$(jq -r '.conditions.gates_manifest_digest' <<<"$J")"
eq "the risk policy version"           "3.1.4"            "$(jq -r '.conditions.risk_policy_version' <<<"$J")"
eq "the stack"                         "python"           "$(jq -r '.conditions.stack' <<<"$J")"
eq "the regime in effect"              "serial"           "$(jq -r '.conditions.regime' <<<"$J")"
want "and the pipeline's own version"  "pipeline_version should not be empty" \
     test -n "$(jq -r '.conditions.pipeline_version // ""' <<<"$J")"

printf '\n-- and it validates against the contract it claims --\n\n'
if [ -f "$REPO_ROOT/bench/validate.py" ] && [ -x "$REPO_ROOT/.venv/bin/python" ]; then
  if "$REPO_ROOT/.venv/bin/python" "$REPO_ROOT/bench/validate.py" run-record "$RD/run.json" >/dev/null 2>&1
  then printf '  ok    run-record.schema.json accepts it\n'; PASS=$((PASS+1))
  else printf '  FAIL  run-record.schema.json rejects it\n'; FAIL=$((FAIL+1)); fi
else
  printf '  skip  no validator or venv on this box\n'
fi

# --------------------------------------------------------------------------
printf '\n== a missing corpus block is a refusal, not a blank field ==\n\n'
#
# requirements_sha256 is what proves the input did not move between runs. A run
# record without it compares two things that may not have had the same inputs,
# and a blank there would be invisible in every later comparison.
for missing in name bean_set requirements_sha256; do
  jq --arg k "$missing" 'del(.corpus[$k])' "$REPO/factory/pipeline-config.json" > "$WORK/cfg.json"
  out="$( cd "$REPO" && PIPELINE_CONFIG="$WORK/cfg.json" ROLES_FILE="$WORK/roles.json" \
          PI_SESSIONS_DIR="$WORK/no-sessions" bash "$PIPELINE_DIR/new-run.sh" bean-001 2>&1 )"; rc=$?
  rc_is "no corpus.$missing refuses"   "$rc" 1
done
check "and says why it matters"        "proves the input did not move between runs" "$out"
check "and how to fix it"              "factory/scaffold.sh" "$out"

# --------------------------------------------------------------------------
printf '\n== roles.json with no usable role ==\n\n'
#
# The run record cannot say what a run ran on if nothing tells it.
printf '{"roles": {"developer": {"provider": "ollama", "model": "dev-model:latest"}}}\n' > "$WORK/roles-nojudge.json"
out="$( cd "$REPO" && PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
        ROLES_FILE="$WORK/roles-nojudge.json" PI_SESSIONS_DIR="$WORK/no-sessions" \
        bash "$PIPELINE_DIR/new-run.sh" bean-001 2>&1 )"; rc=$?
rc_is "it refuses"                     "$rc" 1
check "and names the role"             "no usable 'judge' role" "$out"

# --------------------------------------------------------------------------
printf '\n== a bean id that is not one ==\n\n'
out="$(nr not-a-bean)"; rc=$?
rc_is "it refuses"                     "$rc" 1
check "before creating anything"       "bean id must look like bean-NNN" "$out"

# --------------------------------------------------------------------------
printf '\n== the SIGPIPE trap that once lost a whole run silently ==\n\n'
#
# `ollama list | awk '...{exit}'` sends SIGPIPE to ollama when awk leaves early,
# and under `set -o pipefail` that was exit 141 for the entire script: the run
# directory created, run.json never written, and not one word of error. The
# listing is read once and searched in-process now, so an ollama that produces a
# long listing cannot end the script.
cat > "$WORK/bin/ollama" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  printf 'dev-model:latest\tdddd1111\t1 GB\njudge-model:latest\tjjjj2222\t2 GB\n'
  # Thousands of further lines: the shape that made an early-exiting awk fatal.
  for i in $(seq 1 5000); do printf 'filler-%s:latest\tf%s\t1 GB\n' "$i" "$i"; done
fi
exit 0
STUB
out="$(nr bean-001)"; rc=$?
rc_is "a long listing is survivable"   "$rc" 0
RD2="$(printf '%s' "$out" | tail -1)"
want "and run.json is actually written" "the run directory must not be left empty" \
     test -s "$RD2/run.json"
eq "with the digest still found"       "dddd1111" "$(jq -r '.conditions.developer.digest' "$RD2/run.json" 2>/dev/null)"

# --------------------------------------------------------------------------
printf '\n== an ollama that is not running ==\n\n'
#
# Digests are evidence, not a precondition: a run on a box where the listing
# fails is still a run, and the record says what it knows rather than refusing.
cat > "$WORK/bin/ollama" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
out="$(nr bean-001)"; rc=$?
rc_is "the run still starts"           "$rc" 0
RD3="$(printf '%s' "$out" | tail -1)"
eq "the model is still recorded"       "dev-model:latest" "$(jq -r '.conditions.developer.model' "$RD3/run.json")"
eq "and the digest is simply absent"   "null" "$(jq -r '.conditions.developer.digest // "null"' "$RD3/run.json")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
