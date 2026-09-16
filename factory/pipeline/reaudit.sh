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
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
reaudit.sh — re-run a finished run's audits against a copy of it.

usage: reaudit.sh <run-dir> --bean <bean.yaml>
                  [--target spec|impl|doc|package|all] [--passes <n>]
                  [--keep <dir>] [--json <path>]

  --target   which audit (default: all four)
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

RUN_DIR=""; BEAN=""; TARGETS="spec impl doc package"; PASSES=3; KEEP=""; JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bean)   BEAN="${2:?--bean needs a file}"; shift 2 ;;
    --target) TARGETS="${2:?--target needs a name}"; [ "$TARGETS" = all ] && TARGETS="spec impl doc package"; shift 2 ;;
    --passes) PASSES="${2:?--passes needs a number}"; shift 2 ;;
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
if pgrep -f 'judge-fitness.sh|judge-variance.sh|size-sweep.sh|format-support.sh' >/dev/null 2>&1; then
  printf 'NOTE  a bench harness is running. Both will be slower and neither number will be clean.\n\n' >&2
fi

printf 'reaudit: %s\n  bean:  %s\n  keep:  %s\n\n' "$RUN_DIR" "$BEAN" "$KEEP"
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
    "$PIPELINE_DIR/judge.sh" "$R" --target "$t" --bean "$BEAN" \
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
if [ "$STAMPED_N" -lt "$TOTAL" ]; then
  printf '\nWhy each of the rest was refused:\n'
  jq -r '.[] | select(.stamped | not) | "  \(.pass)-\(.target)  \(.refused_because)"' <<<"$ROWS"
  printf '\nWhat it put in `criteria`, when it answered:\n'
  jq -r '.[] | select(.criteria_ids | length > 0) | "  \(.pass)-\(.target)  \(.criteria_ids | join(", "))"' <<<"$ROWS"
fi
printf '\nlogs and copies: %s\n' "$KEEP"

if [ -n "$JSON" ]; then
  mkdir -p "$(dirname "$JSON")"
  jq -n --argjson r "$ROWS" --arg run "$RUN_DIR" --arg bean "$BEAN" \
    --argjson stamped "$STAMPED_N" --argjson total "$TOTAL" --argjson passes "$PASSES" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:"reaudit/1.0.0", measured_at:$ts, run:$run, bean:$bean, passes:$passes,
      stamped:$stamped, total:$total, rows:$r,
      note:"Nothing was written to the run directory. Each row is a fresh copy of it with an empty verdicts/."}' \
    > "$JSON"
  printf '%s\n' "$JSON"
fi

[ "$STAMPED_N" -eq "$TOTAL" ]
