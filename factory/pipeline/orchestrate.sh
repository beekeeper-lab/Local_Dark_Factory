#!/usr/bin/env bash
# orchestrate.sh — the pipeline driver.
#
# Owns the loop, the tier, the retry cap, and the halt. It NEVER does a step's
# work itself:
#   - child steps (spec, implement, doc, audit-*, pr) go through run-step.sh,
#     which launches the step's skill in a fresh child pi process;
#   - the two script steps (preflight, checks) invoke the canonical scripts,
#     which are the authoritative implementation of those steps.
#
# Tiers — read from the `**Pipeline Tier**` row of the bean's table; absent → full:
#   small: preflight → spec → build → gate → audit-impl → audit-package → pr
#   full:  preflight → spec → audit-spec → build → gate → audit-impl
#          → doc → audit-doc → audit-package → pr
#
# `gate` is "contain, classify, gate" (§06 step 6): the WHOLE diff checked
# against the bean's paths intersected with the repo's approved surface, the
# binding tier computed from the paths the diff actually touched, the size
# budget, a secret scan, then every gate, acceptance criterion and independent
# invariant run inside the sandbox. It replaces the older `checks` step, which
# only ran the gate commands.
#
# `build` is the task loop (spec §06 step 5), and it is a CONTROLLER step, not a
# model step: build-loop.sh drives it, opening one worker session per task and
# deciding each task itself. The one-shot `implement` step it replaces handed the
# whole spec to a single session — the largest single reason a 27B fails work it
# is otherwise capable of (§04).
# small still runs `spec` (JSON, no HTML): every audit needs a contract to
# judge against, and the package audit's scope check needs the spec's file list.
#
# Retry and halt (VERDICT-SCHEMA rule 3 — key off failed attempts, not
# attempts started):
#   - An audit FAIL is routed back to the step that made the artifact: that
#     step is re-entered with the FAIL verdict's findings, then the audit is
#     re-run. Each failed attempt is recorded under failed-attempts/.
#   - After the second failed attempt on the same step the run halts:
#     QUESTIONS.md is written at the run dir root and no third attempt is
#     started — not on resume either (the cap counts recorded failures).
#   - A non-audit step failing without a verdict is never retried blindly:
#     there are no findings to pass to a retry, so the run halts and
#     escalates immediately.
#
# --resume <run_dir>: continue at the first tier step with no recorded PASS;
# completed steps are not re-run. On resume the run keeps the branch run.json
# recorded — it is checked out, never recreated.
# --stop-after <step>: end the run cleanly after that step.
#
# Branching: the pipeline never authors on main. After preflight, the run
# branch bean/BEAN-NNN-<slug> (config branch_pattern, slug from the bean dir
# name) is created off main; run.json records it. A run that finds itself on
# main at an authoring step halts (PIPELINE_SKIP_BRANCH_CREATION=1 is a test
# seam that bypasses creation so the guard can be exercised).
#
# On a completed run (fully done, or clean stop), telemetry-report.sh runs
# and its table is printed.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

HALT_RC=3

usage() {
  cat <<'EOF'
orchestrate.sh — the pipeline driver (tier, loop, retry cap, halt, rollup).

usage:
  orchestrate.sh <BEAN_ID> [--stop-after <step>]
  orchestrate.sh <BEAN_ID> --resume <run_dir>

Tiers (from the bean's `**Pipeline Tier**` table row; absent → full):
  small: preflight spec build gate audit-impl audit-package pr
  full:  preflight spec audit-spec build gate audit-impl doc audit-doc audit-package pr

An audit FAIL re-enters the authoring step with the verdict's findings, then
re-audits; a second failed attempt on the same step halts the run and writes
QUESTIONS.md. A non-audit step failure halts immediately (no findings to
retry with). --resume continues at the first step with no recorded PASS.
EOF
}

# ------------------------------------------------------------------ arguments
BEAN_ID=""
RESUME_DIR=""
STOP_AFTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --stop-after)
      [ $# -ge 2 ] || die "--stop-after requires a step name"
      STOP_AFTER="$2"; shift ;;
    --resume)
      [ $# -ge 2 ] || die "--resume requires a run directory"
      RESUME_DIR="$2"; shift ;;
    -*) die "unknown flag '$1' (only --stop-after and --resume are supported)" ;;
    *)
      [ -z "$BEAN_ID" ] || die "only one <BEAN_ID> is allowed (got '$1' after '$BEAN_ID')"
      BEAN_ID="$1" ;;
  esac
  shift
done
[ -n "$BEAN_ID" ] || { usage >&2; die "missing <BEAN_ID>"; }
# bean.schema.json says `^bean-[0-9]+$` and the benchmark corpus uses it; the
# forked scripts were written against an uppercase BEAN-NNN convention. The
# schema is the contract, so both spellings are accepted and the id is used as
# written from here on.
[[ "$BEAN_ID" =~ ^([Bb][Ee][Aa][Nn])-[0-9]+$ ]] || die "bean id must look like bean-NNN (got: $BEAN_ID)"
[ "$STOP_AFTER" = "" ] || [[ "$STOP_AFTER" =~ ^[a-z]+(-[a-z]+)*$ ]] \
  || die "--stop-after step name must be lowercase alphanumeric/hyphen (got: $STOP_AFTER)"
require_cmd jq
require_config

# -------------------------------------------------------------------- tier --
bean_dir() {
  local pattern d
  pattern="$(jq -r '.bean_dir_pattern // "ai/beans/BEAN-NNN-<slug>"' "$CONFIG_PATH")"
  pattern="${pattern//BEAN-NNN/$BEAN_ID}"
  local root
  root="$(repo_root)"
  local glob
  glob="$(cd "$root" && printf '%s ' "${pattern//<slug>/*}")"
  for d in $glob; do
    if [ -d "$d" ]; then printf '%s\n' "$d"; return 0; fi
  done
  return 1
}

BEAN_DIR="$(bean_dir)" || die "no bean directory for $BEAN_ID (looked under $(repo_root))"
BEAN_MD="$BEAN_DIR/bean.md"
[ -f "$BEAN_MD" ] || die "bean file not found: $BEAN_MD"

# -------------------------------------------------------------- run branch --
# The pipeline exists to end at a pull request, so its code changes land on the
# bean's branch: bean_pattern with the slug taken from the bean directory name
# (ai/beans/BEAN-125-pipeline-version -> bean/BEAN-125-pipeline-version).
branch_pattern="$(jq -r '.branch_pattern' "$CONFIG_PATH")"
[[ "$branch_pattern" == *"<slug>"* ]] || die "config branch_pattern must contain <slug>: $branch_pattern"
base="$(basename "$BEAN_DIR")"
if [[ "$base" == "$BEAN_ID-"* ]]; then slug="${base#"$BEAN_ID"-}"; else slug="$base"; fi
RUN_BRANCH="${branch_pattern//BEAN-NNN/$BEAN_ID}"
RUN_BRANCH="${RUN_BRANCH//<slug>/$slug}"
[ "$RUN_BRANCH" != "main" ] || die "branch_pattern resolves to 'main' — refuse to run on main: $branch_pattern"

# bean_tier — the value of the `**Pipeline Tier**` table row; "" if there is no row.
bean_tier() {
  local line val
  line="$(grep -m 1 -Ei 'pipeline[ _]tier' "$BEAN_MD" || true)"
  [ -n "$line" ] || { printf ''; return 0; }
  val="$(printf '%s\n' "$line" | awk -F'|' '
    { for (i = 1; i < NF; i++) {
        c = $i; gsub(/[^A-Za-z]/, "", c)
        if (c == "PipelineTier") { v = $(i+1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
      }
  }')"
  printf '%s\n' "${val:-}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[[:space:]]//g'
}

if [ -n "$RESUME_DIR" ]; then
  # A resumed run keeps the tier it started with (stamped into run.json).
  TIER="$(jq -r '.tier // empty' "$RESUME_DIR/run.json" 2>/dev/null || true)"
  [ -n "$TIER" ] || TIER="$(bean_tier)"
else
  TIER="$(bean_tier)"
fi
[ -n "$TIER" ] || TIER="full"

case "$TIER" in
  small) STEPS=(preflight spec build gate audit-impl audit-package pr) ;;
  full)  STEPS=(preflight spec audit-spec build gate audit-impl doc audit-doc audit-package pr) ;;
  *) die "unknown pipeline tier '$TIER' in $BEAN_MD (expected small|full)" ;;
esac

if [ -n "$STOP_AFTER" ]; then
  found=0
  for s in "${STEPS[@]}"; do [ "$s" = "$STOP_AFTER" ] && found=1; done
  [ "$found" = 1 ] || die "--stop-after '$STOP_AFTER' is not in the $TIER tier: ${STEPS[*]}"
fi

# ---------------------------------------------------------------- run dir --
if [ -n "$RESUME_DIR" ]; then
  RUN_DIR="$RESUME_DIR"
  [ -f "$RUN_DIR/run.json" ] || die "run directory has no run.json: $RUN_DIR"
  bean_recorded="$(jq -r '.bean // empty' "$RUN_DIR/run.json")"
  [ "$bean_recorded" = "$BEAN_ID" ] || die "run.json bean is '$bean_recorded', expected '$BEAN_ID'"
else
  # A fresh run creates NO run dir before preflight has run: the run dir
  # itself (ai/runs/…) dirties the tree that preflight inspects.
  RUN_DIR=""
fi

# A fresh run creates its run dir on first need (idempotent). In the
# preflight path this happens after the check, so the clean-tree state is
# intact while preflight runs.
ensure_run_dir() {
  [ -n "$RUN_DIR" ] && return 0
  RUN_DIR="$("$PIPELINE_DIR/new-run.sh" "$BEAN_ID")"
  jq -c --arg t "$TIER" '. + {tier: $t}' "$RUN_DIR/run.json" > "$RUN_DIR/run.json.tmp"
  mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"
  FAILDIR="$RUN_DIR/failed-attempts"
}

FAILDIR=""
if [ -n "$RUN_DIR" ]; then
  [ -f "$RUN_DIR/steps.jsonl" ] || : > "$RUN_DIR/steps.jsonl"
  FAILDIR="$RUN_DIR/failed-attempts"
fi

# ------------------------------------------------------------------ helpers --
is_audit_step() { case "$1" in audit-*) return 0 ;; *) return 1 ;; esac; }

authoring_for_audit() {
  case "$1" in
    audit-spec)    printf 'spec' ;;
    audit-impl)    printf 'build' ;;
    audit-doc)     printf 'doc' ;;
    audit-package) printf 'build' ;;
    *) : ;;
  esac
}

failed_count() {
  local s="$1" n=0 f
  for f in "$FAILDIR/${s}".*; do
    [ -e "$f" ] || continue
    n=$((n+1))
  done
  printf '%s\n' "$n"
}

record_failure() { # <step> <exit-status> [context note...]
  # BEAN-127: the record must be real evidence, not a zero-byte stub. It
  # carries what is actually known: when, which step, the exit status, the
  # verdict last recorded in steps.jsonl, and context notes from the caller.
  local s="$1" ec="$2"
  shift 2
  ensure_run_dir
  mkdir -p "$FAILDIR"
  local n v
  n="$(failed_count "$s")"
  v="$(jq -rs --arg x "$s" '[.[] | select(.step == $x and .event == "end")] | last.verdict // "none recorded"' \
    "$RUN_DIR/steps.jsonl" 2>/dev/null || echo 'none recorded')"
  {
    printf 'recorded:  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'step:      %s\n' "$s"
    printf 'exit:      %s\n' "$ec"
    printf 'verdict:   %s\n' "$v"
    for note in "$@"; do printf 'note:      %s\n' "$note"; done
  } > "$FAILDIR/${s}.$((n+1))"
}

step_is_pass() {
  local s="$1" v
  v="$(jq -rs --arg x "$s" '[.[] | select(.step == $x and .event == "end")] | last.verdict // "missing"' \
    "$RUN_DIR/steps.jsonl" 2>/dev/null || echo missing)"
  [ "$v" = "PASS" ]
}

# ensure_run_branch — create (or check out) the run branch off main; record it
# in run.json. A run resuming keeps the branch run.json already recorded, so a
# second branch is never created for the same bean.
ensure_run_branch() {
  local root cur recorded dirty
  root="$(repo_root)"
  cur="$(git -C "$root" branch --show-current 2>/dev/null || true)"
  recorded=""
  if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/run.json" ]; then
    recorded="$(jq -r '.branch // empty' "$RUN_DIR/run.json")"
  fi
  if [ -n "$recorded" ] && [ "$recorded" != "main" ] \
     && git -C "$root" show-ref --verify --quiet "refs/heads/$recorded"; then
    [ "$cur" = "$recorded" ] || git -C "$root" checkout -q "$recorded"
    RUN_BRANCH="$recorded"
    return 0
  fi
  [ "$cur" = "$RUN_BRANCH" ] && return 0
  dirty="$(git -C "$root" status --porcelain)"
  [ -z "$dirty" ] || die "cannot switch to run branch '$RUN_BRANCH': working tree is dirty:
$dirty"
  if git -C "$root" show-ref --verify --quiet "refs/heads/$RUN_BRANCH"; then
    git -C "$root" checkout -q "$RUN_BRANCH"
  else
    # Fresh run: preflight already verified on main, clean tree, main current.
    git -C "$root" branch "$RUN_BRANCH" main
    git -C "$root" checkout -q "$RUN_BRANCH"
  fi
  # Record the run branch (not main) now that the run dir exists (post-preflight).
  if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/run.json" ]; then
    jq -c --arg b "$RUN_BRANCH" '.branch = $b' "$RUN_DIR/run.json" > "$RUN_DIR/run.json.tmp"
    mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"
  fi
}

# assert_off_main — a pipeline that can silently write to main is worse than one
# that stops. Authoring steps (spec, implement, doc, pr) never run on main.
halt_on_main() { # <step> — never returns
  local step="$1"
  local cur ts repo
  preserve_worker_questions "$step" >/dev/null
  repo="$(repo_root)"
  cur="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf '# QUESTIONS — %s: pipeline halted before `%s`\n\n' "$BEAN_ID" "$step"
    printf -- '- Run directory: `%s`\n' "${RUN_DIR:--}"
    printf -- '- Stopped: %s\n\n' "$ts"
    printf '## What happened\n\n'
    printf 'Authoring step `%s` was about to run while the repo is on `%s`.\n'
    printf 'The run branch for this bean is `%s`. The pipeline never authors\n' "$step" "${cur:--(no branch, detached HEAD)}" "$RUN_BRANCH"
    printf 'on main — that would mean code committed straight to main with no\n'
    printf 'branch and no PR. This is a pipeline defect, not a task problem.\n'
  } > "${RUN_DIR}/QUESTIONS.md"
  if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/run.json" ]; then
    jq -c --arg s "$step" --arg t "$ts" --arg g "on-main" \
      '. + {status: "halted", halted_at_step: $s, halted_at: $t, halt_reason: $g}' \
      "$RUN_DIR/run.json" > "$RUN_DIR/run.json.tmp"
    mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"
  fi
  printf '\nHALT   authoring step `%s` blocked on branch `%s` (run branch is `%s`)\n' "$step" "${cur:--}" "$RUN_BRANCH" >&2
  exit "$HALT_RC"
}

assert_off_main() { # <authoring step>
  local repo cur
  repo="$(repo_root)"
  cur="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  if [ "$cur" = "main" ] || [ -z "$cur" ]; then
    halt_on_main "$1"
  fi
}

latest_verdict_file() { # <target> → path of the highest attempt-<n> verdict file ("" if none)
  local target="$1" best="" bestn=0 f n
  for f in "$RUN_DIR/verdicts/$target".attempt-*.json; do
    [ -e "$f" ] || continue
    n="${f##*attempt-}"; n="${n%.json}"
    if [ "$n" -gt "$bestn" ]; then bestn="$n"; best="$f"; fi
  done
  printf '%s\n' "$best"
}

# --------------------------------------------------------------- step runner --
# Script steps (preflight, checks): the canonical script IS the step; we only
# add the start/end bookkeeping around it.
run_script_step() {
  local step="$1"; shift
  local rc=0
  if [ -n "$RUN_DIR" ]; then
    "$PIPELINE_DIR/step.sh" "$RUN_DIR" "$step" start
  fi
  "$@" || rc=$?
  # A fresh run's dir is created after the command has run, so preflight
  # inspects an untouched tree.
  if [ -z "$RUN_DIR" ]; then
    ensure_run_dir
    "$PIPELINE_DIR/step.sh" "$RUN_DIR" "$step" start
  fi
  if [ "$rc" -eq 0 ]; then
    "$PIPELINE_DIR/step.sh" "$RUN_DIR" "$step" end PASS
  else
    "$PIPELINE_DIR/step.sh" "$RUN_DIR" "$step" end FAIL
  fi
  return "$rc"
}

# bean_yaml — the machine-readable bean (bean/2.0.0). The build loop needs its
# `allowed_write_paths` to bound every task, and refuses to run without them; the
# fork's `bean.md` carries prose and a tier row, not paths.
bean_yaml() {
  local pat cand
  pat="$(jq -r '.bean_file_pattern // empty' "$CONFIG_PATH")"
  if [ -n "$pat" ]; then
    cand="$(resolve_repo_path "${pat//BEAN-NNN/$BEAN_ID}")"
    [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  fi
  for cand in "$BEAN_DIR/bean.yaml" "$BEAN_DIR/$BEAN_ID.yaml" "$BEAN_DIR/../$BEAN_ID.yaml"; do
    [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

run_step() { # <step> [-- <extra args carried through to the child>]
  local step="$1"; shift
  case "$step" in
    preflight) run_script_step "$step" "$PIPELINE_DIR/preflight.sh" "$BEAN_ID" ;;
    checks)    run_script_step "$step" "$PIPELINE_DIR/checks.sh" "$RUN_DIR" ;;
    audit-*)
      local rc=0 ay
      mkdir -p "$RUN_DIR/verdicts"
      # The judge does not run as a pi session. gpt-oss reaches for a
      # `repo_browser` tool namespace that does not exist here, gets nothing, and
      # answers anyway — a fluent audit of a document it never read. judge.sh
      # puts the artifacts in the question instead. See its header.
      "$PIPELINE_DIR/judge.sh" "$RUN_DIR" --target "${step#audit-}" --bean "$(bean_yaml)" || rc=$?
      # The judge's own exit code was being captured and then thrown away by an
      # unconditional reset on the next line, so a judge that never answered was
      # handed to audit-check, which reported a missing judgement — a true
      # statement about the wrong thing. 8 is the one worth naming: it means the
      # model spent its whole token budget reasoning and wrote nothing. That is
      # ours to fix, not the authoring step's, and re-running the spec would be
      # spending an attempt on a problem the spec does not have.
      if [ "$rc" -eq 8 ]; then
        printf '\nNO ANSWER  %s — the judge ran out of room before writing one.\n' "$step"
        printf '           Raise JUDGE_NUM_PREDICT and resume; the spec is not what failed.\n'
        record_failure "$step" 8 "the judge exhausted its token budget before answering"
        halt "$step" 8
      elif [ "$rc" -ne 0 ]; then
        printf '\nNO JUDGEMENT  %s — the judge did not produce one (exit %s).\n' "$step" "$rc"
        record_failure "$step" "$rc" "the judge produced no judgement"
        halt "$step" "$rc"
      fi
      # The judge wrote a judgement; the controller turns it into a verdict,
      # stamping the SHAs, digests, tier and versions it must not have invented.
      ay="$(bean_yaml)" || die "no bean YAML for $BEAN_ID; a verdict cannot be stamped without it"
      rc=0
      "$PIPELINE_DIR/audit-check.sh" "$RUN_DIR" --target "${step#audit-}" --bean "$ay" || rc=$?
      # 7 means the judge abstained. There is nothing for the authoring step to
      # act on — "the judge was unsure" is not a finding — so the run stops for a
      # person instead of spending an attempt.
      if [ "$rc" -eq 7 ]; then
        printf '\nABSTAINED  %s — the judge could not form a judgement. A human decides.\n' "$step"
        record_failure "$step" 7 "the judge abstained; routed to a human rather than retried"
        halt "$step" 7
      fi
      return "$rc" ;;
    doc)
      local rc=0
      # The document is written FROM the diff, so put the diff where the skill
      # can read it. A model asked to describe a change it has to remember will
      # describe the change it expected.
      local mb
      mb="$(git -C "$(repo_root)" merge-base main HEAD 2>/dev/null || echo main)"
      git -C "$(repo_root)" diff "$mb"...HEAD > "$RUN_DIR/diff.txt" 2>/dev/null || true
      "$PIPELINE_DIR/run-step.sh" "$RUN_DIR" "$step" "$@" || rc=$?
      [ "$rc" -eq 0 ] || return "$rc"
      "$PIPELINE_DIR/doc-check.sh" "$RUN_DIR" || rc=$?
      return "$rc" ;;
    spec)
      local rc=0 sy
      if [ $# -gt 0 ]; then
        "$PIPELINE_DIR/run-step.sh" "$RUN_DIR" "$step" "$@" || rc=$?
      else
        "$PIPELINE_DIR/run-step.sh" "$RUN_DIR" "$step" || rc=$?
      fi
      [ "$rc" -eq 0 ] || return "$rc"
      # The controller half: sections, schema, claimed criteria, paths, budget,
      # and the rendering. A judge should spend its attention on whether the plan
      # is right, not on whether it is a plan.
      sy="$(bean_yaml)" || die "no bean YAML for $BEAN_ID; the spec cannot be checked against the bean"
      "$PIPELINE_DIR/spec-check.sh" "$RUN_DIR" --bean "$sy" || rc=$?
      return "$rc" ;;
    pr)
      local py
      py="$(bean_yaml)" || die "no bean YAML for $BEAN_ID; a pull request names the bean it came from"
      run_script_step "$step" "$PIPELINE_DIR/pr.sh" "$RUN_DIR" --bean "$py" ;;
    gate)
      local gy
      gy="$(bean_yaml)" || die "no bean YAML for $BEAN_ID; the gate cannot contain a diff without the bean's allowed_write_paths"
      run_script_step "$step" "$PIPELINE_DIR/gate.sh" "$RUN_DIR" --bean "$gy" ;;
    build)
      local by
      by="$(bean_yaml)" || die "no bean YAML for $BEAN_ID (looked for bean_file_pattern in config, then $BEAN_DIR/bean.yaml). The build loop bounds every task by the bean's allowed_write_paths and will not run without them."
      run_script_step "$step" "$PIPELINE_DIR/build-loop.sh" "$RUN_DIR" --bean "$by" ;;
    *)
      local rc=0
      if [ $# -gt 0 ]; then
        "$PIPELINE_DIR/run-step.sh" "$RUN_DIR" "$step" "$@" || rc=$?
      else
        "$PIPELINE_DIR/run-step.sh" "$RUN_DIR" "$step" || rc=$?
      fi
      return "$rc"
      ;;
  esac
}

# ------------------------------------------------------------------- halt --
# preserve_worker_questions <step> — never overwrite what the model wrote.
#
# The skills tell a worker that when the bean conflicts with the code, it should
# stop and write QUESTIONS.md rather than invent a workaround. On the first real
# run a 27B did exactly that, and correctly: it found that an acceptance
# criterion could not pass in the gate container. Then halt() wrote its own
# QUESTIONS.md over the top, and the single most valuable thing the run produced
# — the model's reasoning, addressed to a human — was gone.
#
# A controller that destroys the evidence it asked for is worse than one that
# never asked.
preserve_worker_questions() {
  local step="$1" existing="$RUN_DIR/QUESTIONS.md" kept
  [ -f "$existing" ] || { printf ''; return 0; }
  # Our own halt output is recognisable; leave it to be replaced.
  if head -1 "$existing" | grep -q 'pipeline halted'; then printf ''; return 0; fi
  mkdir -p "$RUN_DIR/questions-from-worker"
  kept="questions-from-worker/${step}-$(date -u +%Y%m%dT%H%M%SZ).md"
  mv "$existing" "$RUN_DIR/$kept"
  printf '%s' "$kept"
}

halt() { # <step> [exit-status] — write QUESTIONS.md, mark the run, stop. Never returns.
  local step="$1" ec="${2:-?}"
  local worker_questions
  worker_questions="$(preserve_worker_questions "$step")"
  local n target f att v summary authoring ts
  n="$(failed_count "$step")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  {
    printf '# QUESTIONS — %s: pipeline halted at `%s`\n\n' "$BEAN_ID" "$step"
    printf -- '- Run directory: `%s`\n' "$RUN_DIR"
    printf -- '- Tier: %s\n' "$TIER"
    printf -- '- Stopped: %s\n' "$ts"
    if [ -n "$worker_questions" ]; then
      printf '\n> **The model stopped and wrote its own questions first: `%s`.**\n' "$worker_questions"
      printf '> Read that before anything below it. It is the account of someone who had the\n'
      printf '> bean and the code in front of it; this file is only what the controller could\n'
      printf '> see from outside.\n'
    fi
    if is_audit_step "$step"; then
      target="${step#audit-}"
      printf '\n## Failed audit attempts on `%s` (%s recorded)\n\n' "$step" "$n"
      local listing
      listing="$(ls "$RUN_DIR/verdicts/$target".attempt-*.json 2>/dev/null | sort -t'-' -k3 -n || true)"
      if [ -n "$listing" ]; then
        while IFS= read -r f; do
          [ -e "$f" ] || continue
          att="${f##*attempt-}"; att="${att%.json}"
          v="$(jq -r '.verdict // "?"' "$f" 2>/dev/null || echo '?')"
          summary="$(jq -r '[(.findings // [])[] | select(.severity=="blocker" or .severity=="major")] | map("\(.severity): \(.summary)") | join("; ")' "$f" 2>/dev/null || true)"
          printf -- '- attempt %s: `%s` — %s\n' "$att" "$v" "${summary:-no blocker/major findings recorded}"
          printf '  - verdict file: `%s`\n' "$f"
        done <<< "$listing"
      else
        printf -- '- no `%s` verdict file (expected name: `%s/verdicts/%s.attempt-*.json`)\n' "$target" "$RUN_DIR" "$target"
        others="$(ls "$RUN_DIR/verdicts/" 2>/dev/null || true)"
        others="${others//$'\n'/ }"
        [ -z "$others" ] || printf '  - verdicts/ does contain: %s — not counted, wrong target name in the file name\n' "$others"
      fi
      authoring="$(authoring_for_audit "$step")"
      printf '\n## Question for a human\n\n'
      if [ "$n" -ge 2 ]; then
        printf '%s failed on %s recorded attempt(s). I re-entered `%s` with the findings and re-ran the audit, and it failed again. What should %s be doing differently, and which of the findings above must drive the fix?\n' \
          "$step" "$n" "${authoring:-the authoring step}" "${authoring:-the authoring step}"
      else
        printf '%s failed on its single recorded attempt with no usable (correctly named) verdict file, so there were no findings to pass to a retry. Where is the verdict from that attempt, and what should %s be doing differently?\n' \
          "$step" "${authoring:-the authoring step}"
      fi
    else
      printf '\n## What happened\n\n'
      printf -- '- Step `%s` exited with status %s (non-zero).\n' "$step" "$ec"
      local rv
      rv="$(jq -rs --arg x "$step" '[.[] | select(.step == $x and .event == "end")] | last.verdict // "none"' "$RUN_DIR/steps.jsonl" 2>/dev/null || echo '?')"
      printf -- '- Last recorded verdict for `%s` in steps.jsonl: `%s`\n' "$step" "$rv"
      # BEAN-127: never invent a gate failure. Claim gates only when checks.json
      # actually records a failing gate; otherwise say plainly what it does say.
      if [ -f "$RUN_DIR/checks.json" ]; then
        local nfail
        nfail="$(jq -r '[.gates[]? | select(.status == "fail")] | length' "$RUN_DIR/checks.json" 2>/dev/null || echo '?')"
        if [ "$nfail" != "?" ] && [ "$nfail" -gt 0 ]; then
          printf '\nFailing gates from `checks.json`:\n\n'
          jq -r '.gates[] | select(.status == "fail") | "- \(.name) (exit \(.exit_code)): \((.output_tail // []) | join(" | "))"' "$RUN_DIR/checks.json"
        else
          printf '\n- `checks.json` records overall `%s` — no gate is failing, so this halt is the step failure itself, not a gate.\n' \
            "$(jq -r '.overall // "?"' "$RUN_DIR/checks.json" 2>/dev/null || echo '?')"
        fi
      else
        printf '\n- `checks.json` does not exist — the gates have not run, so they cannot be the cause of this halt.\n'
      fi
      if [ -f "$RUN_DIR/gate.json" ] && [ "$(jq -r '.overall // ""' "$RUN_DIR/gate.json" 2>/dev/null)" = "fail" ]; then
        printf '\n- The gate failed. What it found, in `%s/gate.json`:\n' "$RUN_DIR"
        jq -r '(if (.containment.contained | not) then "  - containment: " + (.containment.violations | join(", ")) else empty end),
               (.gates[]? | select(.status != "pass") | "  - gate " + .id + ": exit " + (.exit_code|tostring)),
               (.acceptance_criteria[]? | select(.status != "pass") | "  - " + .id + ": " + (.reason // .command // "failed")),
               (if (.invariants != null and .invariants.status != "pass") then "  - invariants: " + (.invariants.reason // .invariants.ref) else empty end)' \
          "$RUN_DIR/gate.json" 2>/dev/null
      fi
      local blocked
      blocked="$(ls -1 "$RUN_DIR"/build/*/BLOCKED.md 2>/dev/null | head -1 || true)"
      if [ -n "$blocked" ]; then
        printf '\n- A task exhausted its attempts. Its evidence — every attempt, the '
        printf 'containment result and the last failure in full — is in `%s`.\n' "$blocked"
      fi
      printf '\n## Question for a human\n\n'
      printf 'I do not retry `%s` blindly: the failure carries no findings a retry could address. What precondition or fix does `%s` need before this run can continue?\n' "$step" "$step"
    fi
  } > "$RUN_DIR/QUESTIONS.md"

  jq -c --arg s "$step" --arg t "$ts" '. + {status: "halted", halted_at_step: $s, halted_at: $t}' \
    "$RUN_DIR/run.json" > "$RUN_DIR/run.json.tmp"
  mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"

  printf '\nHALT  %s after %s failed attempt(s) — see %s/QUESTIONS.md\n' "$step" "$n" "$RUN_DIR"
  exit "$HALT_RC"
}

# ----------------------------------------------------------------- failures --
handle_other_failure() { # a non-audit step failed: no findings, no blind retry
  local step="$1" rc="${2:-1}"
  record_failure "$step" "$rc" "a non-audit step failure carries no findings a retry could address"
  halt "$step" "$rc"
}

handle_audit_failure() { # audit FAIL: route back to the authoring step with findings
  local step="$1" n target vf authoring rc
  record_failure "$step" 1 "audit verdict FAIL for this attempt"
  n="$(failed_count "$step")"
  if [ "$n" -ge 2 ]; then
    halt "$step"
  fi
  target="${step#audit-}"
  vf="$(latest_verdict_file "$target")"
  authoring="$(authoring_for_audit "$step")"
  if [ -z "$vf" ] || [ -z "$authoring" ]; then
    printf 'HALT  %s failed with no usable verdict file (got: %s) — not retrying blind\n' \
      "$step" "${vf:-<none>}" >&2
    halt "$step"
  fi
  printf '\nRETRY  %s FAIL (attempt %s) → re-entering `%s` with findings, then re-auditing\n' \
    "$step" "$n" "$authoring"
  rc=0
  run_step "$authoring" -- "$vf" || rc=$?
  if [ "$rc" -ne 0 ]; then
    record_failure "$authoring" "$rc" "re-entered authoring step exited non-zero"
    halt "$authoring" "$rc"
  fi
  rc=0
  run_step "$step" || rc=$?
  if [ "$rc" -ne 0 ]; then
    record_failure "$step" 1 "re-audit after re-entry still failed"
    halt "$step" 1
  fi
  printf 'PASS   re-audit of %s passed after re-entry\n' "$step"
}

# ------------------------------------------------------------------- loop --
for STEP in "${STEPS[@]}"; do
  # Preflight runs on main (it verifies that). Every step after it — including
  # audits and the run dir's gates — runs on the bean's branch, and the on-main
  # guard is the belt to ensure_run_branch's braces.
  if [ "$STEP" != "preflight" ]; then
    if [ "${PIPELINE_SKIP_BRANCH_CREATION:-0}" = "1" ]; then
      : # test seam only — exercises the on-main guard (see tests/test-orchestrator.sh)
    else
      ensure_run_branch
    fi
    case "$STEP" in
      spec|build|implement|doc|pr) assert_off_main "$STEP" ;;  # pr is controller work, but still never from main
    esac
  fi
  if step_is_pass "$STEP"; then
    printf 'SKIP   %-14s already PASS\n' "$STEP"
  else
    existing="$(failed_count "$STEP")"
    if [ "$existing" -ge 2 ]; then
      printf 'HALT   %s already has %s failed attempts — not starting a third\n' "$STEP" "$existing"
      halt "$STEP"
    fi
    rc=0
    run_step "$STEP" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if is_audit_step "$STEP"; then
        handle_audit_failure "$STEP"
      else
        handle_other_failure "$STEP" "$rc"
      fi
    fi
  fi
  if [ -n "$STOP_AFTER" ] && [ "$STEP" = "$STOP_AFTER" ]; then
    break
  fi
done

# ------------------------------------------------------------------ finish --
finish() { # <stopped-after step or empty>
  local stopped="${1:-}" ts qname
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # A successful finish clears the halt: QUESTIONS.md moves out of the way so
  # the history survives, and the run.json status stops saying 'halted'.
  if [ -f "$RUN_DIR/QUESTIONS.md" ]; then
    mkdir -p "$RUN_DIR/resolved-questions"
    qname="QUESTIONS.md.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$RUN_DIR/QUESTIONS.md" "$RUN_DIR/resolved-questions/$qname"
  fi
  if [ -n "$stopped" ]; then
    jq -c --arg s "$stopped" --arg t "$ts" \
      '. + {status: "completed", stopped_after: $s, finished_at: $t} | del(.halted_at_step, .halted_at, .halt_reason)' \
      "$RUN_DIR/run.json" > "$RUN_DIR/run.json.tmp"
  else
    # A resumed run drops a `stopped_after` stamped by an earlier stop.
    jq -c --arg t "$ts" \
      '. + {status: "completed", finished_at: $t} | del(.stopped_after, .halted_at_step, .halted_at, .halt_reason)' \
      "$RUN_DIR/run.json" > "$RUN_DIR/run.json.tmp"
  fi
  mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"

  printf '\nRUN COMPLETE  %s (tier: %s%s)\n' "$RUN_DIR" "$TIER" \
    "${stopped:+, stopped after $stopped}"

  printf '\nStep verdicts:\n'
  local s v
  for s in "${STEPS[@]}"; do
    v="$(jq -rs --arg x "$s" '[.[] | select(.step == $x and .event == "end")] | last.verdict // "-"' \
      "$RUN_DIR/steps.jsonl" 2>/dev/null || echo '-')"
    printf '  %-14s %s\n' "$s" "$v"
  done

  printf '\nTelemetry:\n'
  if ! "$PIPELINE_DIR/telemetry-report.sh" "$RUN_DIR"; then
    printf 'warning: telemetry-report.sh failed for this run (run dir: %s)\n' "$RUN_DIR" >&2
  fi
}

if [ -n "$STOP_AFTER" ]; then
  finish "$STOP_AFTER"
else
  finish
fi
exit 0
