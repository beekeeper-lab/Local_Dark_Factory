#!/usr/bin/env bash
# test-reaudit.sh — the experiment harness for "did that change anything on a
# real run?", which has been a throwaway script in a scratch directory three
# times.
#
# Two properties it has to have, and both were things the throwaway versions had
# to be got right each time:
#
#   * it never writes to the run directory — a finished run is evidence, and an
#     experiment that stamps a fresh verdict into it has destroyed the record of
#     what the run produced;
#   * it repeats, because this judge gives different verdicts for byte-identical
#     input and one pass reads a target swap as an improvement.
#
# Driven against a stub judge, so the classification is the only thing varying.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# A pipeline copy with a stub judge and a stub audit-check, so nothing here needs
# a model or a repository.
PIPE="$WORK/pipeline"; cp -r "$PIPELINE_DIR" "$PIPE"
cat > "$PIPE/judge.sh" <<'STUB'
#!/usr/bin/env bash
# Writes a judgement whose shape comes from $STUB_JUDGE, into the run it is given.
R="$1"; shift
T=""; while [ $# -gt 0 ]; do [ "$1" = --target ] && T="$2"; shift; done
mkdir -p "$R/verdicts"
case "${STUB_JUDGE:-ok}" in
  none) printf 'JUDGE  %s: the judge wrote nothing (stub)\n' "$T" >&2; exit 1 ;;
  *) printf '{"verdict":"accept","confidence":0.9,"criteria":[{"id":"ac1","met":true,"evidence":"e","quote":"q"}],"findings":[]}\n' \
       > "$R/verdicts/$T.attempt-1.judgement.json" ;;
esac
STUB
cat > "$PIPE/audit-check.sh" <<'STUB'
#!/usr/bin/env bash
R="$1"; shift
T=""; while [ $# -gt 0 ]; do [ "$1" = --target ] && T="$2"; shift; done
[ -f "$R/verdicts/$T.attempt-1.judgement.json" ] || { printf 'AUDIT %s: the judge wrote no judgement file.\n' "$T" >&2; exit 2; }
[ "${STUB_CHECK:-stamp}" = refuse ] && { printf 'AUDIT %s: refused by the stub.\n' "$T" >&2; exit 1; }
cp "$R/verdicts/$T.attempt-1.judgement.json" "$R/verdicts/$T.attempt-1.json"
STUB
chmod +x "$PIPE/judge.sh" "$PIPE/audit-check.sh"

RUN="$WORK/run"; mkdir -p "$RUN/verdicts"
printf '{"run_id":"R","bean_id":"bean-001"}\n' > "$RUN/run.json"
printf 'the original spec\n' > "$RUN/spec.md"
# A verdict already in the run, from when it was really audited. The experiment
# must not read it as its own, and must not overwrite it.
printf '{"verdict":"block","from":"the original run"}\n' > "$RUN/verdicts/spec.attempt-1.json"
BEFORE="$(find "$RUN" -type f -exec sha256sum {} + | sort -k2 | sha256sum)"

printf 'schema_version: bean/2.0.0\nid: bean-001\ntitle: t\nintent: i\n' > "$WORK/bean.yaml"
re() { bash "$PIPE/reaudit.sh" "$RUN" --bean "$WORK/bean.yaml" "$@" 2>&1; }

printf '\n== it never writes to the run it is auditing ==\n\n'
#
# A finished run is evidence. An experiment that stamps a fresh verdict into it
# has destroyed the record of what the run actually produced.
out="$(re --passes 2 --keep "$WORK/k1")"; rc=$?
AFTER="$(find "$RUN" -type f -exec sha256sum {} + | sort -k2 | sha256sum)"
eq "the run directory is byte-identical" "$BEFORE" "$AFTER"
check "the original verdict is untouched" "the original run" "$(cat "$RUN/verdicts/spec.attempt-1.json")"
rc_is "and a fully stamped experiment exits 0" "$rc" 0

printf '\n-- and each pass starts from an empty verdicts/ --\n\n'
#
# Otherwise the run own old verdict is read as this pass result, which is the
# defect run-step.sh already had, arriving by a different door.
nope "the old verdict did not leak in"  "the original run" "$(cat "$WORK/k1/run-1-spec/verdicts/spec.attempt-1.json")"

printf '\n== every target, every pass ==\n\n'
eq "four targets times two passes"      "8" "$(grep -cE '^(spec|impl|doc|package) +[0-9]' <<<"$out")"
check "the table names the targets"     "package" "$out"
check "and counts what was stamped"     "8 of 8 audit run(s) produced a verdict" "$out"

printf '\n== a refusal is reported, with its reason, not just a count ==\n\n'
out="$(STUB_CHECK=refuse re --passes 1 --target spec --keep "$WORK/k2")"; rc=$?
rc_is "it exits non-zero"               "$rc" 1
check "and says how many"               "0 of 1 audit run(s)" "$out"
check "and why each was refused"        "refused by the stub" "$out"

printf '\n-- and a judge that writes nothing is a different row from one that is refused --\n\n'
out="$(STUB_JUDGE=none re --passes 1 --target doc --keep "$WORK/k3")"
check "the judge exit code is shown"    "the judge wrote nothing" "$out"
check "and it is not stamped"           "0 of 1" "$out"

printf '\n== the JSON says what the table says ==\n\n'
re --passes 2 --target spec --keep "$WORK/k4" --json "$WORK/r.json" >/dev/null
eq "one row per pass"                   "2" "$(jq '.rows | length' "$WORK/r.json")"
eq "the run is named"                   "$RUN" "$(jq -r '.run' "$WORK/r.json")"
eq "and the stamped count"              "2" "$(jq -r '.stamped' "$WORK/r.json")"
check "the criterion ids are recorded"  "ac1" "$(jq -c '.rows[0].criteria_ids' "$WORK/r.json")"

printf '\n== it refuses what it cannot audit ==\n\n'
out="$(bash "$PIPE/reaudit.sh" "$WORK/nope" --bean "$WORK/bean.yaml" 2>&1)"; rc=$?
check "a missing run directory"         "no such run directory" "$out"
out="$(bash "$PIPE/reaudit.sh" "$RUN" 2>&1)"; rc=$?
check "and a missing bean"              "--bean must name the bean" "$out"
check "saying why that matters"         "criteria nobody declared" "$out"
out="$(re --passes zero 2>&1)"
check "a non-numeric --passes"          "wants a number" "$out"
out="$(re --target sideways 2>&1)"
check "and an unknown target"           "unknown target" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
