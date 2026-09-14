#!/usr/bin/env bash
# preflight.sh — verify the branch/bean/workspace preconditions for a pipeline run.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="preflight.sh <BEAN-ID>"
case "${1:-}" in
  --version)
    cat "$PIPELINE_DIR/VERSION"
    exit 0
    ;;
  -h|--help)
    echo "preflight.sh — fail fast before a pipeline run starts."
    echo "$USAGE"
    echo ""
    echo "Checks: clean working tree, on main, main not behind origin/main,"
    echo "bean status is Approved, and no existing branch for the bean."
    exit 0
    ;;
esac
require_args "$#" 1 "$USAGE"
require_cmd jq

BEAN_ID="$1"
[[ "$BEAN_ID" =~ ^BEAN-[0-9]+$ ]] || die "BEAN-ID must look like BEAN-NNN (got: $BEAN_ID)"

require_config
root="$(repo_root)"
cd "$root"

fail() {
  printf 'FAIL  %-22s %s\n' "$1" "$2"
  exit 1
}
pass() {
  printf 'PASS  %-22s %s\n' "$1" "$2"
}

# 1. Clean working tree
dirty="$(git status --porcelain)"
if [ -n "$dirty" ]; then
  fail "clean-tree" "working tree is dirty:
$dirty"
fi
pass "clean-tree" "working tree is clean"

# 2. On main
branch="$(git branch --show-current)"
[ "$branch" = "main" ] || fail "on-main" "current branch is '$branch', expected 'main'"
pass "on-main" "on main"

# 3. main not behind origin/main
if git remote get-url origin >/dev/null 2>&1; then
  if ! git fetch origin main >/dev/null 2>&1; then
    fail "up-to-date" "git fetch origin main failed; cannot verify main is up to date"
  fi
  behind="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo '?')"
  if [ "$behind" != "0" ]; then
    fail "up-to-date" "local main is $behind commit(s) behind origin/main"
  fi
  pass "up-to-date" "main is up to date with origin/main"
else
  fail "up-to-date" "no 'origin' remote; cannot verify main is up to date"
fi

# 4. Bean status is Approved in the index
index_path="$(resolve_repo_path "$(jq -r '.bean_index_path' "$CONFIG_PATH")")"
[ -f "$index_path" ] || fail "bean-approved" "bean index not found: $index_path"
status="$(awk -F'|' -v id="$BEAN_ID" '
  {
    cell = $2
    gsub(/^[ \t]+|[ \t]+$/, "", cell)
    if (cell == id) {
      gsub(/^[ \t]+|[ \t]+$/, "", $6)
      print $6
      exit
    }
  }' "$index_path")"
[ -n "$status" ] || fail "bean-approved" "bean $BEAN_ID not found in $index_path"
[ "$status" = "Approved" ] || fail "bean-approved" "bean $BEAN_ID status is '$status', expected 'Approved'"
pass "bean-approved" "bean $BEAN_ID is Approved"

# 5. No existing branch for the bean
pattern="$(jq -r '.branch_pattern' "$CONFIG_PATH")"
glob="$(printf '%s' "$pattern" \
  | sed -e "s/BEAN-NNN/$BEAN_ID/" -e 's/<slug>/*/')"
existing="$(git branch --list -- "$glob" 2>/dev/null | sed 's/^[ *]*//' || true)"
[ -z "$existing" ] || fail "no-branch" "a branch for this bean already exists: $existing"
pass "no-branch" "no existing branch matching $glob"

echo "PASS  preflight: all checks passed for $BEAN_ID"
