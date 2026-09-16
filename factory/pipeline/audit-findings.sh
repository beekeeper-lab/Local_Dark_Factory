#!/usr/bin/env bash
# audit-findings.sh — what a failed audit may tell the worker.
#
# The re-entered authoring step used to be handed the verdict file itself. After
# audit-check.sh that file carries base_sha, candidate_sha, diff_sha256,
# model_digest, gate_manifest_digest, invariants_digest, policy_version,
# prompt_version and the artifact hashes: provenance, for a human and for the pull
# request body. The worker can act on none of it, and it should not be reasoning
# about some of it at all — a worker that can see the judge's model_digest is a
# worker that can start theorising about the judge instead of fixing the artifact.
#
# What it gets is what it can act on: the verdict word, the findings, the
# feedback, and the criteria the audit says are not met.
#
# Markdown rather than JSON, because the prompt this is appended to is prose and a
# worker handed JSON tends to write about the JSON.
set -uo pipefail

usage() {
  cat <<'EOF'
audit-findings.sh — the part of a verdict a worker may read.

usage: audit-findings.sh <verdict.json> <target> [out-file]

With no out-file the document goes to stdout.
Exit: 0 written · 2 the verdict file is missing or not JSON.
EOF
}

case "${1:-}" in -h|--help) usage; exit 0 ;; "") usage >&2; exit 2 ;; esac
VF="$1"; TARGET="${2:?target}"; OUT="${3:-}"
[ -f "$VF" ] || { printf 'audit-findings: no such verdict file: %s\n' "$VF" >&2; exit 2; }
jq -e . >/dev/null 2>&1 < "$VF" || { printf 'audit-findings: not JSON: %s\n' "$VF" >&2; exit 2; }

render() {
  printf '# The %s audit did not pass\n\n' "$TARGET"
  printf 'Verdict: **%s**\n\n' "$(jq -r '.verdict // "?"' "$VF")"
  local fb
  fb="$(jq -r '.feedback_to_worker // empty' "$VF")"
  [ -n "$fb" ] && printf '%s\n\n' "$fb"

  printf '## Findings\n\n'
  local n
  n="$(jq '(.findings // []) | length' "$VF")"
  if [ "$n" -gt 0 ]; then
    jq -r '(.findings // [])[] | "- **\(.severity)** — \(.summary)\n  - \(.evidence)"' "$VF"
  else
    # Said out loud rather than left blank. audit-check refuses a revise with no
    # findings, so this should be unreachable from the live line — and a blank
    # section in a prompt reads as "nothing was wrong", which is the opposite of
    # what a failed audit means.
    printf -- '- The audit recorded none. That is a defect in the audit, not a sign that\n'
    printf -- '  nothing is wrong: ask a human rather than guessing at what to change.\n'
  fi

  local unmet
  unmet="$(jq -r '[(.criteria // [])[] | select(.met == false)] | .[] | "- `\(.id)` — \(.evidence)"' "$VF")"
  if [ -n "$unmet" ]; then
    printf '\n## Acceptance criteria the audit says are not met\n\n%s\n' "$unmet"
  fi

  printf '\nFix these in the artifact. Do not write a reply about the audit.\n'
}

if [ -n "$OUT" ]; then
  render > "$OUT"
  printf '%s\n' "$OUT"
else
  render
fi
