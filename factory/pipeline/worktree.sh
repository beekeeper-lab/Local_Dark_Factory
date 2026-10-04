#!/usr/bin/env bash
# worktree.sh — one git worktree per in-flight bean (§09, Phase 4 task 2).
#
#   <main checkout>/../<repo>.worktrees/<bean-id>/   (FACTORY_WORKTREES overrides the parent)
#
# Until Phase 4 the line ran in the target repository's own checkout and switched
# its branch, so one bean at a time could be in flight and nobody could read main
# while it ran. A worktree per bean lets two beans be in flight (`factory go
# --max-inflight 2`): one in its gates or waiting on CI while the other has the
# GPU. Run records, the state log and the leases stay with the main checkout
# (lib.sh runs_root_dir), so the queue and reconciliation see every bean.
#
# A worktree is created detached at main's tip, which preflight accepts as "on
# main" for a linked worktree; the run then cuts its bean branch as usual. It is
# removed when its bean is done, and KEPT when the bean is blocked: the tree a run
# halted in is evidence (§09), and a person clears it.
#
# usage: worktree.sh add <bean> | path <bean> | remove <bean> [--force] | list | prune
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

MAIN="$(main_root)"
BASE="${FACTORY_WORKTREES:-$(dirname "$MAIN")/$(basename "$MAIN").worktrees}"
wt_path() { printf '%s/%s\n' "$BASE" "$1"; }

bean_state() { # the §09 state, or empty when there is no log
  local sd; sd="${FACTORY_STATE_DIR:-$(runs_root_dir 2>/dev/null)/.state}"
  FACTORY_STATE_DIR="$sd" "$(factory_python)" "$PIPELINE_DIR/beanstate.py" state "$1" --json 2>/dev/null \
    | jq -r --arg b "$1" '.[$b].state // empty'
}

# Local main must be origin/main before a worktree is cut from it: the gate diffs
# against local main, and a stale one counts main's new files as bean output
# (bean-014, 2026-09-28).
refresh_main() {
  git -C "$MAIN" fetch -q origin main 2>/dev/null || return 0
  local on dirty
  on="$(git -C "$MAIN" branch --show-current)"
  if [ "$on" = main ]; then
    dirty="$(git -C "$MAIN" status --porcelain --untracked-files=no)"
    [ -z "$dirty" ] || die "the main checkout is on main with uncommitted changes; cannot bring main up to date"
    git -C "$MAIN" merge -q --ff-only origin/main || die "local main cannot fast-forward to origin/main"
  else
    git -C "$MAIN" update-ref refs/heads/main refs/remotes/origin/main
  fi
}

cmd="${1:-}"; bean="${2:-}"
case "$cmd" in
  path)
    [ -n "$bean" ] || die "usage: worktree.sh path <bean>"
    wt_path "$bean" ;;
  add)
    [ -n "$bean" ] || die "usage: worktree.sh add <bean>"
    p="$(wt_path "$bean")"
    if [ -d "$p" ]; then
      # An existing worktree is reused only when it is clean: a resume runs where
      # its run left off; anything else is evidence nobody has looked at.
      [ -z "$(git -C "$p" status --porcelain 2>/dev/null)" ] \
        || die "worktree for $bean exists and is dirty: $p — evidence of an earlier run; reconcile or remove it first"
      printf '%s\n' "$p"; exit 0
    fi
    refresh_main
    mkdir -p "$BASE"
    git -C "$MAIN" worktree add -q --detach "$p" main >/dev/null 2>&1 \
      || die "git worktree add failed for $bean at $p"
    printf '%s\n' "$p" ;;
  remove)
    [ -n "$bean" ] || die "usage: worktree.sh remove <bean> [--force]"
    p="$(wt_path "$bean")"
    [ -d "$p" ] || { printf 'no worktree for %s\n' "$bean"; exit 0; }
    st="$(bean_state "$bean")"
    if [ "$st" = blocked ] && [ "${3:-}" != --force ]; then
      printf 'kept: %s is blocked, and its worktree is the evidence (%s). --force to remove.\n' "$bean" "$p"; exit 3
    fi
    if [ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ] && [ "${3:-}" != --force ]; then
      printf 'kept: %s has uncommitted changes in %s. --force to remove.\n' "$bean" "$p"; exit 3
    fi
    git -C "$MAIN" worktree remove ${3:+--force} "$p" && printf 'removed %s\n' "$p" ;;
  list)
    git -C "$MAIN" worktree list | grep -F "$BASE/" || true ;;
  prune)
    # Done beans give their worktree back. Blocked ones keep it.
    for p in "$BASE"/*/; do
      [ -d "$p" ] || continue
      b="$(basename "$p")"; st="$(bean_state "$b")"
      case "$st" in
        merged|merge_pending|pr_open|ci_pending|deployed_test)
          if [ -z "$(git -C "$p" status --porcelain 2>/dev/null)" ]; then
            git -C "$MAIN" worktree remove "$p" && printf 'pruned %s (%s)\n' "$b" "$st"
          fi ;;
      esac
    done
    git -C "$MAIN" worktree prune ;;
  *) die "usage: worktree.sh add <bean> | path <bean> | remove <bean> [--force] | list | prune" ;;
esac
