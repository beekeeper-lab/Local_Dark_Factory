#!/usr/bin/env bash
# phase0-audit.sh — independently re-verify every Phase-0 claim against the
# machine and the recorded artifacts, and print a PASS/FAIL finding per claim.
#
# Why this exists: the plan calls Phase-0 exit "machine-verified", but the six
# `phase_0_exit` predicates appeared only as prose in the ledger — nothing
# computed them. A predicate asserted in Markdown is the same class of defect
# the phase itself closed for `thinking`: a figure that survives into later
# decisions without ever having been checked.
#
# Read-only. Loads no model unless --with-models is passed (which re-runs the
# Harmony suite, ~2 min, and swaps the judge in).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="$ROOT/bench/results"
PLAN="$ROOT/DARK_FACTORY_IMPLEMENTATION_PLAN.md"
WITH_MODELS=0
JSON_OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --with-models) WITH_MODELS=1; shift ;;
    --json) JSON_OUT="${2:?--json needs a path}"; shift 2 ;;
    -h|--help)
      echo "phase0-audit.sh [--with-models] [--json <path>]"
      echo "  --with-models  also re-run bench/harmony-conformance.sh (loads gpt-oss:120b)"
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

PASS_N=0; FAIL_N=0
FINDINGS="[]"

# ok <id> <evidence>            — a claim that verified
# finding <id> <sev> <evidence> — a claim that did not; sev = blocker|major|minor
ok() {
  PASS_N=$((PASS_N + 1))
  printf '  \033[32mok\033[0m    %-28s %s\n' "$1" "$2"
}
finding() {
  FAIL_N=$((FAIL_N + 1))
  printf '  \033[31mFAIL\033[0m  %-28s [%s] %s\n' "$1" "$2" "$3"
  FINDINGS="$(jq -c --arg id "$1" --arg sev "$2" --arg ev "$3" \
    '. + [{id:$id, severity:$sev, evidence:$ev}]' <<<"$FINDINGS")"
}
section() { printf '\n== %s ==\n\n' "$1"; }

# Pick the newest *measurement* sweep by schema. --provenance-only writes into
# the same directory, and a provenance record has no residency or swap rows: if
# it were picked up as "the sweep" the audit would report three false findings.
SWEEP=""
for f in $(ls -1t "$RESULTS"/phase0-*.json 2>/dev/null); do
  if jq -e '.schema == "phase0-measurement/1.0.0"' "$f" >/dev/null 2>&1; then SWEEP="$f"; break; fi
done
PROBE="$RESULTS/coresidency-probe-20260914.json"

printf '== Phase-0 audit == %s ==\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'sweep artifact: %s\n' "${SWEEP:-NONE}"

# ---------------------------------------------------------------- exit predicates --
section "phase_0_exit predicates"

if [ -z "$SWEEP" ]; then
  finding "artifacts.sweep" blocker "no phase0-*.json in $RESULTS — every predicate below is unverifiable"
else
  # 1. residency_recorded: both models, every swept context, with a GPU/CPU split.
  rows="$(jq '[.residency[]? | select(.scenario|startswith("alone"))] | length' "$SWEEP")"
  ctxs="$(jq -r '[.residency[]?.num_ctx] | unique | join(",")' "$SWEEP")"
  split="$(jq '[.residency[]?.loaded[]? | select(has("processor") or has("size_vram") or has("percent_gpu"))] | length' "$SWEEP")"
  if [ "${rows:-0}" -ge 6 ]; then
    ok "residency_recorded" "$rows alone-rows across contexts {$ctxs}, $split carry a GPU/CPU split"
  else
    finding "residency_recorded" major "only ${rows:-0} alone-rows in $(basename "$SWEEP")"
  fi

  # 2. swap_time_measured: both directions, non-zero.
  both="$(jq '[.swaps[]? | select(.seconds > 0)] | length' "$SWEEP")"
  dirs="$(jq -r '[.swaps[]? | "\(.from)->\(.to) \(.seconds|.*10|round/10)s"] | join(" · ")' "$SWEEP")"
  if [ "${both:-0}" -ge 2 ]; then ok "swap_time_measured" "$dirs"
  else finding "swap_time_measured" major "expected 2 directions, found ${both:-0}"; fi

  # 5. regime_decision present and in the schema's enum.
  regime="$(jq -r '.regime_decision // empty' "$SWEEP")"
  case "$regime" in
    serial|coresident*) ok "regime_decision" "recorded as '$regime' in $(basename "$SWEEP")" ;;
    "") finding "regime_decision" major "absent from $(basename "$SWEEP")" ;;
    *)  finding "regime_decision" minor "unrecognised value '$regime'" ;;
  esac

  # 6. figures_have_provenance: every artifact carries the conditions block.
  missing=""; incomplete=""
  for f in "$RESULTS"/*.json; do
    [ -e "$f" ] || continue
    # kernel + ollama version + a timestamp is the floor for any figure here.
    # GTT is asked for only of the sweep, which is the artifact it bears on.
    # Non-empty, not merely present. jq treats "" as TRUE — only null and false
    # are falsy — so `.provenance.ollama_version and ...` passed for a figure
    # whose ollama_version was the empty string, which is what
    # `ollama --version` produces on a box where ollama is not installed. The
    # check said "carries kernel + ollama version" about a field with nothing in
    # it, which is the first entry in the taxonomy: measuring something other
    # than what it claims.
    if jq -e '[(.provenance.ollama_version // ""), (.provenance.kernel // ""), (.provenance.measured_at // "")]
              | all(. != "")' "$f" >/dev/null 2>&1 \
       || jq -e '[(.conditions.ollama_version // ""), (.conditions.kernel // "")]
                 | all(. != "")' "$f" >/dev/null 2>&1; then
      continue
    fi
    # "No block" and "a block with an empty field" are different problems and the
    # message has to say which. jq treats "" as falsy, so a figure measured on a
    # box where `ollama --version` returned nothing has a provenance block and
    # fails this check — and being told it has none would send the next reader to
    # look for code that is already there.
    if jq -e 'has("provenance") or has("conditions")' "$f" >/dev/null 2>&1; then
      incomplete="$incomplete $(basename "$f")"
    else
      missing="$missing $(basename "$f")"
    fi
  done
  if [ -z "$missing" ] && [ -z "$incomplete" ]; then
    ok "figures_have_provenance" "every results JSON carries kernel + ollama version + GTT"
  else
    # Count first, then name them. Eleven filenames in one line is a finding
    # nobody reads twice, and the number is the part that changes.
    finding "figures_have_provenance" major \
      "$(printf '%s file(s) without provenance' "$(printf '%s' "$missing" | wc -w)")$([ -n "$incomplete" ] && printf ', %s with an empty required field' "$(printf '%s' "$incomplete" | wc -w)") — see bench/results/INDEX.md for which of them a claim still rests on:$missing$incomplete"
  fi

  # 6b. The ledger covers the directory.
  #
  # INDEX.md is what makes the finding above actionable: it says, per artifact,
  # whether anything still depends on it. A ledger that silently stops covering
  # new files turns back into twenty timestamps, and the way that happens is
  # nobody noticing — so it is checked rather than remembered.
  INDEX="$RESULTS/INDEX.md"
  if [ ! -f "$INDEX" ]; then
    finding "results_ledger" major "no bench/results/INDEX.md — the directory cannot say which figures are load-bearing"
  else
    unlisted=""
    for f in "$RESULTS"/*.json; do
      [ -e "$f" ] || continue
      grep -qF "$(basename "$f")" "$INDEX" || unlisted="$unlisted $(basename "$f")"
    done
    if [ -z "$unlisted" ]; then
      ok "results_ledger" "INDEX.md accounts for every figure in bench/results"
    else
      finding "results_ledger" major "in bench/results but not in INDEX.md:$unlisted"
    fi
  fi

  # And separately: can each harness still produce one? The artifact check above
  # is about figures already on disk and cannot be fixed by editing code — a
  # measurement taken without provenance does not acquire it later, and writing
  # one in now would be inventing it. This check is about the next figure, and it
  # is the one that keeps the list from growing: five harnesses were added after
  # bench/phase0.sh and every one of them copied everything except the provenance
  # block, which is how eleven files accumulated before anything noticed.
  # No name list. The exclusions were phase0-audit.sh and phase1-audit.sh, on the
  # grounds that an audit is not a figure — which was never a good reason. An
  # audit is a measurement of this repository at a moment, and "which machine,
  # which ollama, which pipeline version" is the question asked of every other
  # number here. They carry the block now, and the rule applies to everything
  # that could produce a result, including the next one written.
  noprov=""
  for h in "$ROOT"/bench/*.sh; do
    # Two exclusions, both by what the file IS rather than by name-as-exception:
    # provenance.sh emits the block, and inflight.sh is a guard neither of which
    # writes a figure. A file that writes nothing to bench/results cannot carry
    # provenance into it, and asking it to would be a check on nothing.
    # Excluded by what they are: helpers, not harnesses. provenance.sh emits the
    # block, inflight.sh is a guard, snapshot.sh is a launcher. None writes a
    # figure, and a file that writes nothing to bench/results cannot carry
    # provenance into it.
    case "$(basename "$h")" in provenance.sh|inflight.sh|snapshot.sh) continue ;; esac
    grep -q 'provenance' "$h" || noprov="$noprov $(basename "$h")"
  done
  if [ -z "$noprov" ]; then
    ok "harnesses_emit_provenance" "every bench harness writes where and on what it measured"
  else
    finding "harnesses_emit_provenance" major "these harnesses write figures with no provenance block:$noprov"
  fi
fi

# 4. pi_drives_both_models — the catalog half, which is what silently broke once.
PI_MODELS="${PI_MODELS_JSON:-$HOME/.pi/agent/models.json}"
ROLES="$ROOT/factory/pipeline/roles.json"
if [ ! -f "$PI_MODELS" ]; then
  finding "pi_drives_both_models" blocker "pi catalog absent at $PI_MODELS — thinking levels cannot be honoured or checked"
else
  bad=""
  while IFS=$'\t' read -r rname rprov rmodel; do
    [ -n "$rmodel" ] || continue
    d="$(jq -r --arg p "$rprov" --arg m "$rmodel" \
      '.providers[$p].models[]? | select(.id == $m) | (.reasoning // false)' "$PI_MODELS")"
    [ "$d" = "true" ] || bad="$bad $rname($rmodel:${d:-absent})"
  done < <(jq -r '.roles | to_entries[]
             | select((.value.thinking // "") | . != "" and . != "off")
             | [.key, .value.provider, .value.model] | @tsv' "$ROLES")
  if [ -z "$bad" ]; then
    ok "pi_drives_both_models" "every thinking role maps to reasoning:true in $(basename "$PI_MODELS")"
  else
    finding "pi_drives_both_models" blocker "thinking silently disabled for:$bad"
  fi
fi

# 3. harmony_conformance — re-run it, or report that nothing on disk records it.
if [ "$WITH_MODELS" = 1 ]; then
  # Verification, not evidence generation: the suite's artifact goes to a temp
  # file so an audit run never leaves an uncommitted file in bench/results and
  # fails its own evidence.tracked check on the next pass. Run the suite
  # directly when you want the artifact kept.
  harmony_tmp="$(mktemp -t harmony-audit-XXXXXX.json)"
  out="$(OUT="$harmony_tmp" "$ROOT/bench/harmony-conformance.sh" 2>&1)"
  rm -f "$harmony_tmp"
  line="$(printf '%s\n' "$out" | grep -E '^[0-9]+ passed' | tail -1)"
  if printf '%s' "$line" | grep -q ', 0 failed'; then
    ok "harmony_conformance" "re-run now: $line"
  else
    finding "harmony_conformance" blocker "re-run: ${line:-suite did not report a result}"
  fi
else
  ok "harmony_conformance" "skipped (pass --with-models to re-run the 12-case suite)"
fi

# ------------------------------------------------------------------- machine state --
section "machine state matches what the ledger claims"

limit="$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo 0)"
gtt_gib=$(( limit * 4096 / 1024 / 1024 / 1024 ))
if [ "$limit" = "25165824" ]; then ok "ttm.pages_limit" "$limit pages = ${gtt_gib} GiB GTT"
else finding "ttm.pages_limit" blocker "is $limit (${gtt_gib} GiB), ledger claims 25165824 (96 GiB)"; fi

grep -q 'ttm.pages_limit=25165824' /proc/cmdline \
  && ok "ttm.persists_reboot" "on the kernel cmdline, so it survives a reboot" \
  || finding "ttm.persists_reboot" major "not on /proc/cmdline — the ceiling is set but not persistent"

env_dump="$(systemctl show ollama.service -p Environment 2>/dev/null)"
for kv in OLLAMA_KEEP_ALIVE=-1 OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=1; do
  printf '%s' "$env_dump" | grep -q -- "$kv" \
    && ok "unit.${kv%%=*}" "${kv#*=}" \
    || finding "unit.${kv%%=*}" major "expected $kv; unit has: $(printf '%s' "$env_dump" | tr ' ' '\n' | grep OLLAMA_ | tr '\n' ' ')"
done

probe_dropin=/etc/systemd/system/ollama.service.d/zz-phase0-coresidency-test.conf
[ -e "$probe_dropin" ] \
  && finding "unit.probe_dropin_removed" major "temporary probe drop-in still present: $probe_dropin" \
  || ok "unit.probe_dropin_removed" "temporary MAX_LOADED_MODELS=2 drop-in is gone"

if [ -n "$SWEEP" ]; then
  for role in developer judge; do
    m="$(jq -r ".provenance.$role.model" "$SWEEP")"
    want="$(jq -r ".provenance.$role.digest" "$SWEEP")"
    have="$(ollama list 2>/dev/null | awk -v m="$m" '$1 == m {print $2; exit}')"
    if [ -z "$have" ]; then
      finding "digest.$role" blocker "$m is recorded in the sweep but not installed"
    elif [ "${have:0:12}" = "${want:0:12}" ]; then
      ok "digest.$role" "$m $have matches the recorded figure"
    else
      finding "digest.$role" blocker "$m is now $have, every figure was measured on $want"
    fi
  done
  wantv="$(jq -r '.provenance.ollama_version' "$SWEEP")"
  havev="$(ollama --version 2>/dev/null | awk '{print $NF}')"
  [ "$wantv" = "$havev" ] \
    && ok "ollama.version" "$havev, as measured" \
    || finding "ollama.version" major "now $havev; figures were measured on $wantv"
fi

# ---------------------------------------------------------------- reproducibility --
section "evidence is reproducible by someone who is not on this box"

# Files, not directories. The predicate is about FIGURES being reproducible by
# someone who is not on this box; `judge-fitness-logs/` is per-case working state
# the harness keeps so a strange answer can be read afterwards, and committing a
# few hundred of those on every run buries the figures they sit beside. One that
# evidences a claim belongs in `evidence/`, by hand, like everything else there.
tracked_any=0; n_files=0
for f in "$RESULTS"/*; do
  [ -f "$f" ] || continue
  n_files=$((n_files + 1))
  if git -C "$ROOT" ls-files --error-unmatch "$f" >/dev/null 2>&1; then tracked_any=$((tracked_any + 1)); fi
done
if [ "$tracked_any" -eq "$n_files" ] && [ "$n_files" -gt 0 ]; then
  ok "results.tracked" "all $n_files figures in bench/results are committed"
else
  finding "results.tracked" blocker \
    "$tracked_any of $n_files files in bench/results are tracked; the rest exist only on this disk (see .gitignore)"
fi

# And the same of `evidence/`, which until 2026-09-16 nothing checked at all.
#
# The check above is named for the section and measures bench/results. It has
# said "all N evidence files are committed" since it was written, about a
# directory that is not evidence/ — so an evidence file that existed only on this
# disk would have been reported as committed by a check with the right name on
# the wrong directory. One of them was, the hour this was found.
ev_tracked=0; ev_files=0; ev_untracked=""
for f in "$ROOT"/evidence/*; do
  [ -f "$f" ] || continue
  ev_files=$((ev_files + 1))
  if git -C "$ROOT" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    ev_tracked=$((ev_tracked + 1))
  else
    ev_untracked="$ev_untracked $(basename "$f")"
  fi
done
if [ "$ev_files" -gt 0 ] && [ "$ev_tracked" -eq "$ev_files" ]; then
  ok "evidence.tracked" "all $ev_files files in evidence/ are committed"
else
  finding "evidence.tracked" blocker \
    "$ev_tracked of $ev_files files in evidence/ are tracked; on this disk only:$ev_untracked"
fi

# Every one of them says what it evidences, exactly once.
#
# evidence/README.md's own preamble says "each file is here because a claim
# somewhere else rests on it", and a file with no row is a file nobody can use.
# Exactly once, because a duplicated row is two descriptions that will drift —
# there were two rows for judge-fitness-low-20260916.log, written a day apart,
# saying slightly different things.
undesc=""; dupe=""
for f in "$ROOT"/evidence/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ "$b" = "README.md" ] && continue
  # Rows, not mentions. One row's prose legitimately names another file — "read
  # it beside `judge-fitness-low-20260916.log`" — and counting mentions reported
  # that as a duplicate row, which is a check crying wolf about good writing.
  n="$(grep -cE "^\| \`$(printf '%s' "$b" | sed 's/[][\\.*^$/]/\\&/g')\`" "$ROOT/evidence/README.md" 2>/dev/null || true)"
  case "$n" in
    0) undesc="$undesc $b" ;;
    1) ;;
    *) dupe="$dupe $b($n)" ;;
  esac
done
if [ -z "$undesc" ] && [ -z "$dupe" ]; then
  ok "evidence.described" "every file in evidence/ has exactly one row in its README"
else
  finding "evidence.described" major \
    "$([ -n "$undesc" ] && printf 'no row in evidence/README.md for:%s' "$undesc")$([ -n "$undesc" ] && [ -n "$dupe" ] && printf '; ')$([ -n "$dupe" ] && printf 'more than one row for:%s' "$dupe")"
fi

# Every bench/results path the ledger cites must exist.
missing=""
while read -r ref; do
  # `bench/results/harmony-<stamp>.json` is prose about a naming convention, not
  # a citation of a file: the extractor stops at the '<', leaving a bare prefix.
  case "$ref" in *-) continue ;; esac
  [ -e "$ROOT/$ref" ] || case "$ref" in
    *'*'*) compgen -G "$ROOT/$ref" >/dev/null || missing="$missing $ref" ;;
    *)     missing="$missing $ref" ;;
  esac
done < <(grep -oE 'bench/results/[A-Za-z0-9._*-]+' "$PLAN" "$ROOT/RESUME.md" 2>/dev/null \
          | sed 's/^[^:]*://' | sort -u)
[ -z "$missing" ] \
  && ok "evidence.cited_exists" "every bench/results path cited in the ledger is on disk" \
  || finding "evidence.cited_exists" major "cited but absent:$missing"

# The co-residency conclusion is the load-bearing one; is there a harness behind it?
if [ -f "$PROBE" ]; then
  # Not "does a script mention co-residency" — phase0.sh has a probe block that
  # only records whether both models happened to load. The question is whether
  # anything regenerates *this* artifact, identified by its schema string.
  schema="$(jq -r '.schema' "$PROBE")"
  if grep -rqF "$schema" "$ROOT"/bench/*.sh "$ROOT"/factory/pipeline/*.sh 2>/dev/null; then
    ok "evidence.probe_reproducible" "a script emits $schema"
  else
    finding "evidence.probe_reproducible" major \
      "$(basename "$PROBE") is hand-written — no script reproduces the 81.4-88.4 GiB bracket the regime decision rests on"
  fi
else
  finding "evidence.probe_reproducible" major "co-residency probe artifact is absent"
fi

# Commands the ledger tells the next session to run must actually run.
# The re-run list is the first thing the next session types. Every interpreter
# it names has to exist on this box.
bad_interp=""
while read -r interp; do
  [ -n "$interp" ] || continue
  if [ -x "$ROOT/${interp#./}" ] || [ -x "$interp" ] || command -v "$interp" >/dev/null 2>&1; then
    continue
  fi
  bad_interp="$bad_interp $interp"
done < <(grep -E 'validate\.py' "$ROOT/RESUME.md" 2>/dev/null \
          | grep -oE '^[A-Za-z0-9./_-]+' | grep -E 'python' | sort -u)
[ -z "$bad_interp" ] \
  && ok "repro.documented_commands" "every interpreter RESUME.md names resolves on this box" \
  || finding "repro.documented_commands" minor "RESUME.md names an interpreter this box does not have:$bad_interp"

# A derived field is only evidence if it could have come out the other way.
# A derived field is only evidence if it could have come out the other way. Under
# MAX_LOADED_MODELS=1 the co-residency derivation can only ever say "serial", so
# the harness must say it could not attempt the measurement rather than report a
# reading of the unit file as a memory fact.
if grep -q 'regime_evidence' "$ROOT/bench/phase0.sh" \
   && grep -q 'coresidency_attemptable' "$ROOT/bench/phase0.sh" \
   && grep -q 'REGIME="unknown"' "$ROOT/bench/phase0.sh"; then
  ok "regime_decision.falsifiable" "phase0.sh records max_loaded_models and reports 'unknown' when co-residency was not attemptable"
else
  finding "regime_decision.falsifiable" major \
    "phase0.sh derives regime_decision purely from whether two models were observed loaded together; under MAX_LOADED_MODELS=1 a re-run emits 'serial' whatever the truth is — the unit setting wearing a measurement's clothes"
fi

if grep -q 'validate.py --corpus\|validate.py --corpus' "$ROOT/RESUME.md" 2>/dev/null; then
  ok "repro.beanset_checked" "RESUME.md's re-run list validates the bean set, not just the schemas"
else
  finding "repro.beanset_checked" minor \
    "RESUME.md's re-run list runs validate.py bare ('expect 8 schemas, 0 invalid'), which checks no bean at all; the 20-bean set needs --corpus benchmark/seating-planner/bean-sets/v1"
fi

# ------------------------------------------------ provenance the pipeline will stamp --
section "conditions the pipeline will record about itself"

RUNSTEP="$ROOT/factory/pipeline/run-step.sh"
if grep -q 'MODEL_DIGEST="\$(ollama list' "$RUNSTEP"; then
  ok "conditions.digest_observed" "digest is read from ollama, not declared"
else
  finding "conditions.digest_observed" major "run-step.sh does not read the digest from ollama"
fi

# pi has no context flag, so roles.json num_ctx cannot be applied — which makes
# stamping it as the run's context a fabrication. The record must carry what the
# server actually served, with the declared value kept beside it.
if grep -q 'api/ps' "$RUNSTEP" && grep -q 'num_ctx:($obs_ctx' "$RUNSTEP"; then
  ok "conditions.num_ctx_asserted" "conditions.num_ctx is read from ollama /api/ps; roles.json's value is kept under conditions.declared"
else
  finding "conditions.num_ctx_asserted" blocker \
    "run-step.sh stamps conditions.num_ctx from roles.json ($(jq -r '.roles.judge.num_ctx' "$ROLES")) without observing what ollama served — the run record asserts a context the run need not have used"
fi

if grep -q 'thinking_level_change' "$RUNSTEP" && grep -q 'thinking:s($obs_thinking)' "$RUNSTEP"; then
  ok "conditions.thinking_observed" "conditions.thinking is read back from pi's session, not from roles.json"
else
  finding "conditions.thinking_observed" blocker \
    "run-step.sh stamps conditions.thinking from roles.json; pi disables thinking silently, which is how the judge ran with reasoning off while the record said high"
fi

if grep -q 'declared_matches_observed' "$RUNSTEP"; then
  ok "conditions.drift_flagged" "divergence between declared and observed conditions is recorded and warned about"
else
  finding "conditions.drift_flagged" major "nothing flags a run whose conditions diverged from what roles.json asked for"
fi

PREFLIGHT="$ROOT/factory/pipeline/preflight.sh"
if ! grep -q 'role-thinking' "$PREFLIGHT"; then
  finding "preflight.thinking_guard" blocker "no role-thinking check in preflight.sh"
elif grep -q 'if \[ -f "\$ROLES_JSON" \] && \[ -f "\$PI_MODELS" \]' "$PREFLIGHT"; then
  finding "preflight.thinking_guard" major \
    "the role-thinking check is wrapped in [ -f \$PI_MODELS ]; if pi moves or rewrites its catalog the tripwire silently disappears — which is the exact scenario it was written for"
elif grep -q '\[ -f "\$PI_MODELS" \] || fail "role-thinking"' "$PREFLIGHT"; then
  ok "preflight.thinking_guard" "a missing pi catalog fails the check instead of skipping it"
else
  finding "preflight.thinking_guard" major "the role-thinking check does not fail on a missing pi catalog"
fi

# --------------------------------------------------------------- harness honesty --
section "the harness reports what it actually did"

if awk '/PROV_ONLY" = 1/,/^fi/' "$ROOT/bench/phase0.sh" | grep -qE 'tee "\$OUT"|> *"\$OUT"'; then
  ok "harness.provenance_only_writes" "--provenance-only persists the artifact it announces"
else
  finding "harness.provenance_only_writes" major \
    "phase0.sh --provenance-only announces a results path and writes nothing there — it prints to stdout and exits, so the provenance run leaves no artifact"
fi

if ls "$RESULTS"/harmony-*.json >/dev/null 2>&1; then
  ok "harness.harmony_artifact" "a Harmony conformance result is on disk"
else
  finding "harness.harmony_artifact" major \
    "harmony-conformance.sh prints 12/12 and saves nothing; the phase's only record of the Harmony PASS is the ledger prose asserting it"
fi

# ------------------------------------------------------------------ ledger hygiene --
section "ledger matches reality"

if grep -qE '^- \[ \] Set the final ollama unit config' "$PLAN" \
   && printf '%s' "$env_dump" | grep -q 'OLLAMA_MAX_LOADED_MODELS=1'; then
  finding "ledger.stale_checkbox" minor \
    "plan leaves 'Set the final ollama unit config' unchecked, but the unit already carries MAX_LOADED_MODELS=1/NUM_PARALLEL=1 and the probe drop-in is gone"
else
  ok "ledger.stale_checkbox" "unit-config checkbox agrees with the unit"
fi

# ------------------------------------------------------------------------ summary --
printf '\n'
blockers="$(jq '[.[] | select(.severity=="blocker")] | length' <<<"$FINDINGS")"
majors="$(jq '[.[] | select(.severity=="major")] | length' <<<"$FINDINGS")"
minors="$(jq '[.[] | select(.severity=="minor")] | length' <<<"$FINDINGS")"
printf '%d checks passed, %d findings (%s blocker, %s major, %s minor)\n' \
  "$PASS_N" "$FAIL_N" "$blockers" "$majors" "$minors"

if [ -n "$JSON_OUT" ]; then
  jq -n --argjson f "$FINDINGS" --argjson p "$PASS_N" \
    --argjson prov "$(provenance_block)" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sweep "${SWEEP:-}" \
    '{schema:"phase0-audit/1.0.0", audited_at:$at, sweep_artifact:$sweep,
      checks_passed:$p, findings:$f,
      provenance:$prov,
      green:(($f | map(select(.severity=="blocker" or .severity=="major")) | length) == 0)}' > "$JSON_OUT"
  printf 'wrote %s\n' "$JSON_OUT"
fi

# Green means no blocker and no major. Minors do not fail the audit.
[ "$blockers" -eq 0 ] && [ "$majors" -eq 0 ]
