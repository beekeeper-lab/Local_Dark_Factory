#!/usr/bin/env bash
# reaudit.sh — run a finished run's audits again, without touching the run.
#
# Every time this project changes something about the judge — the token cap, the
# meaning of `met`, the artifact headers, the response grammar — the question is
# the same: does it change anything on a REAL run, as opposed to on the seeded
# defects in bench/judge-fitness.sh? Those are two different questions and only
# the second has a harness.
#
# The answer has been a throwaway script in a scratch directory three times. This
# is that script, kept, with the two things the throwaway versions had to get
# right each time:
#
#   * It never writes to the run directory. A finished run is evidence; an
#     experiment that stamps a fresh verdict into it has destroyed the record of
#     what the run actually produced. Everything happens in a copy.
#   * It repeats. This judge gives different verdicts for byte-identical input at
#     temperature 0, so one pass cannot tell a change from the spread — and the
#     first single-pass comparison this project ran did exactly that and read a
#     target swap as an improvement.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run from a copy of the pipeline, always, without anyone having to remember.
#
# bash reads a script by byte offset as it executes. A twelve-audit measurement is
# an hour, which is exactly the window in which someone improves the script — and
# on 2026-09-16, an hour into the first full run of this file, I edited a `pgrep`
# pattern near the top of it. The edit replaced one line with ten, shifting every
# byte after it, and the run was reading from the old offsets.
#
# `bench/snapshot.sh` exists for precisely this and every bench harness re-execs
# through it. This script is a measurement harness that happens to live in
# factory/pipeline, and it had none, which is how the lesson arrived a second time.
#
# The snapshot mirrors the REPOSITORY root rather than factory/, because
# audit-check climbs to "$PIPELINE_DIR/../../bench/validate.py" and to schemas/
# beside it — a copy of factory/ alone puts pipeline/ at the top and both are
# gone, quietly, with the verdict recorded as "structural checks only".
#
# FACTORY_NO_SNAPSHOT=1 opts out, for iterating on this file where seeing a change
# take effect is the point.
if [ "${FACTORY_REAUDIT_SNAPSHOTTED:-0}" != 1 ] && [ "${FACTORY_NO_SNAPSHOT:-0}" != 1 ]; then
  _fr="$(cd "$PIPELINE_DIR/../.." && pwd)"
  _snap="$(mktemp -d "${TMPDIR:-/tmp}/factory-reaudit-snap.XXXXXX")"
  mkdir -p "$_snap/factory"
  cp -r "$_fr/factory/." "$_snap/factory/" 2>/dev/null
  for _sib in schemas bench; do
    [ -d "$_fr/$_sib" ] && cp -r "$_fr/$_sib" "$_snap/$_sib" 2>/dev/null
  done
  # Asserted, not hoped for. A snapshot missing the validator does not fail; it
  # downgrades every verdict check to "structural only" and says so in a line
  # nobody reads.
  for _needed in factory/pipeline/judge.sh factory/pipeline/audit-check.sh \
                 factory/pipeline/roles.json schemas bench/validate.py; do
    [ -e "$_snap/$_needed" ] || { printf 'reaudit: the snapshot is missing %s — refusing to measure with a pipeline that is not the one in the repository.\n' "$_needed" >&2; rm -rf "$_snap"; exit 2; }
  done
  [ -x "$_fr/.venv/bin/python" ] && export PIPELINE_PYTHON="$_fr/.venv/bin/python"
  printf 'pipeline snapshot: %s/factory/pipeline\n' "$_snap" >&2
  FACTORY_REAUDIT_SNAPSHOTTED=1 bash "$_snap/factory/pipeline/reaudit.sh" "$@"; _rc=$?; rm -rf "$_snap"; exit "$_rc"
fi
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

# The same provenance block every figure in bench/results carries.
#
# This writes to bench/results and the Phase-0 audit checks that directory, so a
# reaudit artifact without one goes red — correctly. One emitter, because two
# lists of what a figure must record is one list that disagrees with itself; the
# file lives in bench/ and this climbs to it the same way audit-check climbs to
# the schema validator.
PROV_SH="$PIPELINE_DIR/../../bench/provenance.sh"
# shellcheck source=../../bench/provenance.sh
[ -f "$PROV_SH" ] && source "$PROV_SH"

usage() {
  cat <<'EOF'
reaudit.sh — re-run a finished run's audits against a copy of it.

usage: reaudit.sh <run-dir> --bean <bean.yaml>
                  [--target spec|impl|doc|package|all] [--passes <n>]
                  [--thinking <level>] [--keep <dir>] [--json <path>]

  --target   which audit (default: all four)
  --thinking override the level in roles.json for this experiment. The thinking
             level is the difference between a judge that answers and one that
             spends its budget reasoning, and it has already been changed once on
             measured grounds — so an experiment that does not say which level it
             ran at cannot be compared with another.
  --passes   how many times each (default: 3 — one pass cannot tell a change
             from this judge's spread)
  --keep     where to put the copies and logs (default: a temp dir, kept, and
             the path is printed)
  --json     also write the table as JSON

Nothing is written to <run-dir>. Exit 0 if every audit run produced a verdict
audit-check.sh stamped, 1 otherwise — so a green exit means "this configuration
can audit this run", which has never yet been true.
EOF
}

RUN_DIR=""; BEAN=""; TARGETS="spec impl doc package"; PASSES=3; KEEP=""; JSON=""; THINKING=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bean)   BEAN="${2:?--bean needs a file}"; shift 2 ;;
    --target) TARGETS="${2:?--target needs a name}"; [ "$TARGETS" = all ] && TARGETS="spec impl doc package"; shift 2 ;;
    --passes) PASSES="${2:?--passes needs a number}"; shift 2 ;;
    --thinking) THINKING="${2:?--thinking needs a level}"; shift 2 ;;
    --keep)   KEEP="${2:?--keep needs a directory}"; shift 2 ;;
    --json)   JSON="${2:?--json needs a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*) usage >&2; die "unknown flag: $1" ;;
    *)  [ -z "$RUN_DIR" ] && RUN_DIR="$1" || die "unexpected argument: $1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] || { usage >&2; exit 2; }
[ -d "$RUN_DIR" ] || die "no such run directory: $RUN_DIR"
[ -n "$BEAN" ] && [ -f "$BEAN" ] || die "--bean must name the bean this run was for (an audit without it reports on criteria nobody declared)"
case "$PASSES" in ''|*[!0-9]*) die "--passes wants a number, got '$PASSES'" ;; esac
[ "$PASSES" -ge 1 ] || die "--passes must be at least 1"
for t in $TARGETS; do
  case "$t" in spec|impl|doc|package) ;; *) die "unknown target '$t' (expected spec|impl|doc|package|all)" ;; esac
done

[ -n "$KEEP" ] || KEEP="$(mktemp -d "${TMPDIR:-/tmp}/reaudit.XXXXXX")"
mkdir -p "$KEEP"

# Said, not enforced. This is an operator command and the operator may have a
# reason; a measurement that silently competes for the GPU with another one is
# how a 212-second case became a 395-second cut-off, so it is worth a line.
# `bench/` in the pattern, not a bare filename. `pgrep -f` matches whole command
# lines, so a bare `judge-variance.sh` matches any shell that merely MENTIONS it —
# including the watcher loop `until ! pgrep -f 'judge-variance.sh'`, which matches
# itself and therefore never exits. Both of those were running when this note
# first fired, and neither was a harness.
#
# This is the sixth time in this project that matching a process by pattern has
# matched the wrong thing; the rule is by pid, and where a pattern is
# unavoidable it has to be specific enough that only the real invocation matches.
if pgrep -f 'bench/(judge-fitness|judge-variance|size-sweep|format-support)\.sh' >/dev/null 2>&1; then
  printf 'NOTE  a bench harness is running. Both will be slower and neither number will be clean.\n\n' >&2
fi

printf 'reaudit: %s\n  bean:  %s\n  keep:  %s\n' "$RUN_DIR" "$BEAN" "$KEEP"
printf '  judge: %s thinking\n\n' \
  "${THINKING:-$(jq -r '.roles.judge.thinking // "?"' "${ROLES_FILE:-$PIPELINE_DIR/roles.json}" 2>/dev/null)}"
printf '%-9s %-5s %-9s %-10s %-9s %s\n' TARGET PASS JUDGE-RC VERDICT STAMPED NOTE

ROWS='[]'
STAMPED_N=0; TOTAL=0
for pass in $(seq 1 "$PASSES"); do
  for t in $TARGETS; do
    R="$KEEP/run-$pass-$t"
    rm -rf "$R"; cp -r "$RUN_DIR" "$R"
    # A fresh verdicts directory, or an old attempt's judgement is read as this
    # one's — the same defect run-step.sh had, arriving by a different door.
    rm -rf "$R/verdicts"; mkdir -p "$R/verdicts"
    jrc=0
    "$PIPELINE_DIR/judge.sh" "$R" --target "$t" --bean "$BEAN" ${THINKING:+--thinking "$THINKING"} \
      > "$KEEP/judge-$pass-$t.log" 2>&1 || jrc=$?
    J="$R/verdicts/$t.attempt-1.judgement.json"
    v="-"; note=""; crit=0; find_n=0
    if [ -f "$J" ]; then
      v="$(jq -r '.verdict // "?"' "$J" 2>/dev/null || echo '?')"
      crit="$(jq '(.criteria // []) | length' "$J" 2>/dev/null || echo 0)"
      find_n="$(jq '(.findings // []) | length' "$J" 2>/dev/null || echo 0)"
      note="$find_n finding(s), $crit criteria, conf $(jq -r '.confidence // "?"' "$J" 2>/dev/null)"
    else
      note="$(grep -m1 '^JUDGE  [a-z-]*: ' "$KEEP/judge-$pass-$t.log" 2>/dev/null | sed 's/^JUDGE  //' | head -c 70)"
      [ -n "$note" ] || note="$(tail -1 "$KEEP/judge-$pass-$t.log" 2>/dev/null | head -c 70)"
    fi
    arc=0
    "$PIPELINE_DIR/audit-check.sh" "$R" --target "$t" --bean "$BEAN" \
      > "$KEEP/check-$pass-$t.log" 2>&1 || arc=$?
    stamped=no
    [ -f "$R/verdicts/$t.attempt-1.json" ] && { stamped=yes; STAMPED_N=$((STAMPED_N + 1)); }
    TOTAL=$((TOTAL + 1))
    why="$(head -1 "$KEEP/check-$pass-$t.log" 2>/dev/null | sed 's/^AUDIT [a-z]*: //' | head -c 90)"
    printf '%-9s %-5s %-9s %-10s %-9s %s\n' "$t" "$pass" "$jrc" "$v" "$stamped" "$note"
    ROWS="$(jq -c --arg t "$t" --argjson p "$pass" --argjson jrc "$jrc" --arg v "$v" \
      --arg st "$stamped" --argjson c "$crit" --argjson f "$find_n" --arg why "$why" \
      --argjson ids "$( [ -f "$J" ] && jq -c '[(.criteria // [])[].id]' "$J" 2>/dev/null || echo '[]')" \
      '. + [{target:$t, pass:$p, judge_rc:$jrc, verdict:$v, stamped:($st=="yes"),
             criteria:$c, criteria_ids:$ids, findings:$f, refused_because:$why}]' <<<"$ROWS")"
  done
done

printf '\n%s of %s audit run(s) produced a verdict the controller stamped.\n' "$STAMPED_N" "$TOTAL"

# The refusal reasons, tallied.
#
# "Five of seven answers quoted text that is on disk nowhere" is the single most
# informative number this harness produces about the judge, and it was only ever
# available by reading twelve log files. It is a measurement of how often the
# judge invents the evidence for a verdict it has already reached — see
# evidence/judge-invented-quotes-20260916.md for what that looks like — and it
# belongs beside the stamped count rather than under it.
TALLY="$(jq -r '[.[] | select(.stamped | not) | .refused_because
                 | if . == "" then "(no reason recorded)"
                   elif test("quotes text that is not on disk") then "quoted text that is on disk nowhere"
                   elif test("no quote long enough") then "no quote long enough to prove anything"
                   elif test("wrote no judgement") then "no judgement at all"
                   elif test("does not report on the criteria") then "wrong criteria"
                   elif test("zero findings") then "revise with no findings"
                   elif test("confidence") then "confidence outside 0..1"
                   else (.[0:52]) end]
               | group_by(.) | map({r: .[0], n: length}) | sort_by(-.n)
               | .[] | "  \(.n)  \(.r)"' <<<"$ROWS")"
[ -n "$TALLY" ] && printf '\nwhy the rest were refused:\n%s\n' "$TALLY"
if [ "$STAMPED_N" -lt "$TOTAL" ]; then
  printf '\nWhy each of the rest was refused:\n'
  jq -r '.[] | select(.stamped | not) | "  \(.pass)-\(.target)  \(.refused_because)"' <<<"$ROWS"
  printf '\nWhat it put in `criteria`, when it answered:\n'
  jq -r '.[] | select(.criteria_ids | length > 0) | "  \(.pass)-\(.target)  \(.criteria_ids | join(", "))"' <<<"$ROWS"
fi
printf '\nlogs and copies: %s\n' "$KEEP"

if [ -n "$JSON" ]; then
  mkdir -p "$(dirname "$JSON")"
  PROV='{}'
  if declare -F provenance_block >/dev/null 2>&1; then
    PROV="$(provenance_block "$(jq -r '.roles.judge.model' "${ROLES_FILE:-$PIPELINE_DIR/roles.json}" 2>/dev/null)")"
  fi
  jq -n --argjson r "$ROWS" --arg run "$RUN_DIR" --arg bean "$BEAN" \
    --argjson prov "$PROV" \
    --argjson stamped "$STAMPED_N" --argjson total "$TOTAL" --argjson passes "$PASSES" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg thinking "${THINKING:-$(jq -r '.roles.judge.thinking // "?"' "${ROLES_FILE:-$PIPELINE_DIR/roles.json}" 2>/dev/null)}" \
    --argjson tally "$(jq -c '[.[] | select(.stamped | not) | .refused_because] | group_by(.) | map({reason: .[0], count: length}) | sort_by(-.count)' <<<"$ROWS")" \
    '{schema:"reaudit/1.3.0", measured_at:$ts, provenance:$prov, run:$run, bean:$bean, passes:$passes, thinking:$thinking,
      refused_because:$tally,
      stamped:$stamped, total:$total, rows:$r,
      note:"Nothing was written to the run directory. Each row is a fresh copy of it with an empty verdicts/."}' \
    > "$JSON"
  printf '%s\n' "$JSON"
fi

[ "$STAMPED_N" -eq "$TOTAL" ]
