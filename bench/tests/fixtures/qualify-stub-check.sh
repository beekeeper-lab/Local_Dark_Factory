#!/usr/bin/env bash
# A stand-in for audit-check.sh in judge-qualify's own tests: it "stamps" a
# judgement by copying it to the verdict path, unless STUB_STAMP=0, in which case
# it refuses the way audit-check does, with an AUDIT line saying why.
set -uo pipefail
RD="$1"; shift; TARGET=""
while [ $# -gt 0 ]; do case "$1" in --target) TARGET="$2"; shift 2 ;; *) shift ;; esac; done
J="$RD/verdicts/$TARGET.attempt-1.judgement.json"
[ -f "$J" ] || { echo "AUDIT $TARGET: no judgement"; exit 1; }
[ "${STUB_STAMP:-1}" = 1 ] || { echo "AUDIT $TARGET: the judgement quotes text that is not in any artifact"; exit 1; }
cp "$J" "$RD/verdicts/$TARGET.attempt-1.json"
