#!/usr/bin/env bash
# new-run.sh — create a pipeline run directory (run.json) for a bean.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="new-run.sh <BEAN-ID>"
case "${1:-}" in
  --version)
    cat "$PIPELINE_DIR/VERSION"
    exit 0
    ;;
  -h|--help)
    echo "new-run.sh — create ai/runs/<BEAN-ID>-<UTC stamp>/ with run.json for a pipeline run."
    echo "$USAGE"
    exit 0
    ;;
esac
require_args "$#" 1 "$USAGE"
require_cmd jq

BEAN_ID="$1"
[[ "$BEAN_ID" =~ ^([Bb][Ee][Aa][Nn])-[0-9]+$ ]] || die "bean id must look like bean-NNN (got: $BEAN_ID)"

require_config
root="$(repo_root)"
runs_root="$(jq -r '.runs_root' "$CONFIG_PATH")"
[[ "$runs_root" =~ ^[A-Za-z0-9._/-]+$ ]] || die "suspicious runs_root in config: $runs_root"

branch="$(git -C "$root" branch --show-current 2>/dev/null || true)"
[ -n "$branch" ] || die "could not determine current branch in $root"

# Resolve the newest Pi session JSONL whose session entry has cwd == this repo.
# Optional: a run driven outside a Pi session (tests, cron) records null and the
# orchestrator row of the telemetry report is empty.
sess_base="$(pi_sessions_dir)"
sess_file=""
if [ -d "$sess_base" ]; then
  for d in "$sess_base"/*/; do
    newest="$(ls -t "$d"*.jsonl 2>/dev/null | head -n 1 || true)"
    [ -n "$newest" ] || continue
    cwd="$(jq -r 'select(.type == "session") | .cwd' "$newest" 2>/dev/null | head -n 1 || true)"
    if [ "$cwd" = "$root" ]; then
      sess_file="$newest"
      break
    fi
  done
else
  printf 'warning: Pi sessions directory not found: %s\n' "$sess_base" >&2
fi
if [ -z "$sess_file" ]; then
  printf 'warning: no Pi session JSONL found for cwd %s under %s; recording a null orchestrator session\n' "$root" "$sess_base" >&2
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
rundir="$(resolve_repo_path "$runs_root")/$BEAN_ID-$stamp"
mkdir -p "$rundir"

started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
run_id="$(basename "$rundir")"

# The record conforms to run-record.schema.json, which it did not.
#
# It wrote `bean` where the schema requires `bean_id`, and omitted
# schema_version, corpus and conditions entirely. Nothing validated it, so one of
# the eight declared contracts was simply not honoured by the thing that produces
# it — and `corpus.requirements_sha256` is the field that proves the input never
# moved between runs, which is the whole basis for comparing one run against
# another.
#
# `bean` is kept alongside `bean_id`: every script here reads it, and a rename
# across a dozen call sites during a live run is a worse trade than one duplicated
# string. The schema allows it (additionalProperties is not false at the top
# level).
CORPUS_NAME="$(jq -r '.corpus.name // empty' "$CONFIG_PATH" 2>/dev/null)"
CORPUS_SET="$(jq -r '.corpus.bean_set // empty' "$CONFIG_PATH" 2>/dev/null)"
REQ_SHA="$(jq -r '.corpus.requirements_sha256 // empty' "$CONFIG_PATH" 2>/dev/null)"
if [ -z "$CORPUS_NAME" ] || [ -z "$CORPUS_SET" ] || [ -z "$REQ_SHA" ]; then
  die "this repo's factory/pipeline-config.json has no complete \`corpus\` block.
  run-record.schema.json requires name, bean_set and requirements_sha256 on every run
  record, and requirements_sha256 is what proves the input did not move between runs —
  without it, comparing this run to another compares two things that may not have had the
  same requirements. Re-run factory/scaffold.sh against this repo; it copies all three
  from the bean set's manifest."
fi

# The run-level conditions: what this run is being carried out BY, as opposed to
# the per-step conditions in steps.jsonl which record what each step actually
# got. Every field here is knowable before the first step runs — roles.json, the
# pinned gate manifest, the risk policy, this pipeline's own version — and the
# schema has required them since it was written. Nothing filled them, because
# nothing validated the record.
#
# The regime is the Phase-0 measurement in effect: serial, one model resident at
# a time. Recorded rather than assumed, because the comparison arm (co-resident
# Q4 developer) is a live decision with a stated revisit trigger.
ROLES="${ROLES_FILE:-$PIPELINE_DIR/roles.json}"
role_json() { # role_json <role>
  jq -c --arg r "$1" '
    .roles[$r] as $c
    | {model: $c.model, num_ctx: $c.num_ctx, provider: $c.provider}
    + (if $c.thinking then {thinking: $c.thinking} else {} end)' "$ROLES" 2>/dev/null
}
dev_cond="$(role_json developer)"; judge_cond="$(role_json judge)"
for pair in "developer:$dev_cond" "judge:$judge_cond"; do
  [ -n "${pair#*:}" ] && [ "${pair#*:}" != null ]     || die "roles.json has no usable '${pair%%:*}' role; the run record cannot say what this run ran on"
done
# Digests, so a re-pointed tag cannot pass for the weights that were measured.
dev_model="$(jq -r '.model' <<<"$dev_cond")"
judge_model="$(jq -r '.model' <<<"$judge_cond")"
# `ollama list | awk '...{exit}'` sends SIGPIPE to ollama when awk leaves early,
# and under `set -o pipefail` that is exit 141 for the whole script — the run
# directory was created and run.json never written, with no error message at all.
# Read the listing once and search it in-process.
OLLAMA_LIST="$(ollama list 2>/dev/null || true)"
dev_dig="$(awk -v m="$dev_model" '$1==m{print $2}' <<<"$OLLAMA_LIST" | head -1)"
judge_dig="$(awk -v m="$judge_model" '$1==m{print $2}' <<<"$OLLAMA_LIST" | head -1)"
[ -n "$dev_dig" ] && dev_cond="$(jq -c --arg d "$dev_dig" '. + {digest:$d}' <<<"$dev_cond")"
[ -n "$judge_dig" ] && judge_cond="$(jq -c --arg d "$judge_dig" '. + {digest:$d}' <<<"$judge_cond")"

gates_ref="$(jq -r '.gates_ref // "factory/gates.lock.yaml"' "$CONFIG_PATH" 2>/dev/null)"
gates_digest=""
[ -f "$(resolve_repo_path "$gates_ref")" ]   && gates_digest="$("$PIPELINE_DIR/yaml2json.sh" "$(resolve_repo_path "$gates_ref")" 2>/dev/null | jq -r '.image // ""' | sed 's/.*@//')"
policy_ref="$(jq -r '.policy_ref // "factory/risk-policy.yaml"' "$(resolve_repo_path "$(jq -r '.repo_config // "factory/repo.yaml"' "$CONFIG_PATH")")" 2>/dev/null || echo "factory/risk-policy.yaml")"
policy_version=""
[ -f "$(resolve_repo_path "$policy_ref")" ]   && policy_version="$("$PIPELINE_DIR/yaml2json.sh" "$(resolve_repo_path "$policy_ref")" 2>/dev/null | jq -r '.policy_version // ""')"

conditions="$(jq -cn   --argjson dev "$dev_cond" --argjson judge "$judge_cond"   --arg stack "$(jq -r '.stack // "python"' "$CONFIG_PATH" 2>/dev/null)"   --arg pv "$(cat "$PIPELINE_DIR/VERSION" 2>/dev/null || echo unknown)"   --arg regime "${FACTORY_REGIME:-serial}"   --arg gd "$gates_digest" --arg rp "$policy_version"   '{developer:$dev, judge:$judge, stack:$stack, pipeline_version:$pv, regime:$regime}
   + (if $gd == "" then {} else {gates_manifest_digest:$gd} end)
   + (if $rp == "" then {} else {risk_policy_version:$rp} end)')"

jq -n \
  --argjson conditions "$conditions" \
  --arg run_id "$run_id" \
  --arg bean "$BEAN_ID" \
  --arg branch "$branch" \
  --arg started_at "$started_at" \
  --arg sess "$sess_file" \
  --arg cname "$CORPUS_NAME" \
  --arg cset "$CORPUS_SET" \
  --arg csha "$REQ_SHA" \
  '{
    schema_version: "run-record/1.0.0",
    run_id: $run_id,
    bean_id: $bean,
    bean: $bean,
    branch: $branch,
    corpus: {name: $cname, bean_set: $cset, requirements_sha256: $csha},
    conditions: $conditions,
    started_at: $started_at,
    status: "running"
  }
  + (if $sess == "" then {} else {pi_session_file: $sess} end)' > "$rundir/run.json"

# Validate what was just written, if the validator is reachable.
#
# run-record.schema.json existed and nothing checked anything against it, so the
# record drifted: `bean` where the schema said `bean_id`, and no schema_version,
# corpus or conditions at all. A contract nobody validates is a contract that
# stops being true without anyone finding out.
VALIDATOR="${NEW_RUN_VALIDATOR:-$PIPELINE_DIR/../../bench/validate.py}"
PY_BIN="$(factory_python)"
if [ -f "$VALIDATOR" ] && [ -x "$PY_BIN" ]; then
  if ! out="$("$PY_BIN" "$VALIDATOR" run-record "$rundir/run.json" 2>&1)"; then
    printf '%s\n' "$out" >&2
    die "the run record just written does not validate against run-record.schema.json"
  fi
fi

printf '%s\n' "$rundir"
