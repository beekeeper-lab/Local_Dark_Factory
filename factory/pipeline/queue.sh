#!/usr/bin/env bash
# queue.sh — which beans are runnable, in what order, and why not the others.
#
# Until now a bean was run by typing its id. That works for one bean and is the
# wrong shape for twenty: the order is in the bean set, the dependencies are in
# the beans, and a person retyping both is a person who will eventually run
# bean-006 before bean-005 and spend an hour finding out.
#
# This is the read-only half — it computes the queue and refuses to include
# anything it should not. `factory go` runs what this returns. Kept separate so
# the decision can be inspected without running anything, which is also how it is
# tested.
#
# The one rule that is not about ordering: **a bean that is not `status:
# approved` is never queued.** §04 gates what enters the line, and a queue that
# quietly included a draft would route around the only human checkpoint before
# the model starts work.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
queue.sh — the approved beans, in run order, with what blocks each of the rest.

usage: queue.sh [--beans <dir>] [--json] [--all]

  --beans  bean directory (default: factory/beans in this repo)
  --json   machine-readable
  --all    include beans that are not runnable, with the reason

A bean is runnable when it is approved, has no unfinished dependency, and has not
already been built (no branch, no merged work). Order comes from
`approval.order`, then from the bean id.
EOF
}

BEANS=""; AS_JSON=0; SHOW_ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --beans) BEANS="${2:?}"; shift 2 ;;
    --json)  AS_JSON=1; shift ;;
    --all)   SHOW_ALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
require_cmd jq; require_cmd git

ROOT="$(repo_root)"
[ -n "$BEANS" ] || BEANS="$ROOT/factory/beans"
[ -d "$BEANS" ] || die "no beans directory at $BEANS"

# Every bean, as one JSON array. Read once: twenty yaml2json calls per question
# is the sort of thing that makes a queue feel slow enough to skip.
# A bean this cannot read is not a bean this may ignore.
#
# The first version did `|| continue` on a failed parse and on a missing id, so a
# malformed bean.yaml simply vanished from the queue — no row, no reason, and
# nothing anywhere saying a file under factory/beans/ had been skipped. That is
# failing open against §04: the gate is "a human approved this", and a bean whose
# status cannot be read has not been approved, it has been lost. It gets a row,
# and `factory go` refuses it like any other non-approved bean.
ALL='[]'
for d in "$BEANS"/*/; do
  b="$d/bean.yaml"
  [ -f "$b" ] || continue
  if ! bj="$("$PIPELINE_DIR/yaml2json.sh" "$b" 2>/dev/null)" || [ -z "$(jq -r '.id // empty' <<<"$bj" 2>/dev/null)" ]; then
    ALL="$(jq -c --arg path "$b" --arg id "$(basename "${d%/}")" \
      '. + [{id: $id, title: "", status: "unreadable", order: null, deps: [],
             tier: null, path: $path, parse_error: true}]' <<<"$ALL")"
    continue
  fi
  ALL="$(jq -c --argjson x "$bj" --arg path "$b" \
    '. + [{id: $x.id, title: ($x.title // ""), status: ($x.status // "unknown"),
           order: ($x.approval.order // null), deps: ($x.dependencies // []),
           tier: ($x.suggested_risk_tier // null), path: $path}]' <<<"$ALL")"
done
[ "$(jq 'length' <<<"$ALL")" -gt 0 ] || die "no bean.yaml files under $BEANS"

# A bean is done when a branch for it exists and its work is on the default
# branch, or when a pull request was opened for it. Branch naming comes from the
# repo's own config so this cannot drift from what the orchestrator creates.
CONFIG_FILE="$ROOT/factory/pipeline-config.json"
BRANCH_PAT="$(jq -r '.branch_pattern // "bean/BEAN-NNN-<slug>"' "$CONFIG_FILE" 2>/dev/null || echo 'bean/BEAN-NNN-<slug>')"
RUNS_ROOT="$ROOT/$(jq -r '.runs_root // "factory/runs"' "$CONFIG_FILE" 2>/dev/null || echo factory/runs)"

branch_for() { # branch_for <bean-id> -> the existing branch, or empty
  local id="$1" glob
  glob="$(printf '%s' "$BRANCH_PAT" | sed -e "s/BEAN-NNN/$id/" -e 's/<slug>/*/')"
  git -C "$ROOT" branch --list -- "$glob" 2>/dev/null | sed 's/^[ *]*//' | head -1
}
pr_for() { # pr_for <bean-id> -> a pr url recorded by ANY run of it, or empty
  # Any run, not the newest. The first version read the newest run.json and
  # returned whatever it found there — so a bean that opened a pull request and
  # was then re-run, with the second run halting before `pr`, went back to
  # looking unbuilt. The queue would offer it again, `factory go` would run it
  # again, and the second pull request is the thing pr.sh has an idempotency
  # check for precisely because it must not happen.
  local id="$1" d url
  for d in $(ls -1dt "$RUNS_ROOT/$id"-*/ 2>/dev/null); do
    [ -f "$d/run.json" ] || continue
    url="$(jq -r '.pr_url // empty' "$d/run.json" 2>/dev/null)"
    [ -n "$url" ] && { printf '%s' "$url"; return 0; }
  done
}

DEFAULT_BRANCH="$([ -f "$ROOT/factory/repo.yaml" ] && "$PIPELINE_DIR/yaml2json.sh" "$ROOT/factory/repo.yaml" 2>/dev/null | jq -r '.default_branch // "main"' || echo main)"

merged() { # merged <bean-id> — is this bean's work on the default branch?
  # The question the first version of this file never asked, and the one that
  # matters: a pull request being OPEN is the finished state of a bean's own run,
  # and it is not the finished state of the tree the next bean builds on.
  #
  # bean-002's spec step found this the hard way. bean-001's run recorded a pull
  # request, the queue called it done, bean-002 started — and the developer model
  # opened a tree with no `src/`, no `pyproject.toml` and no `tests/`, because
  # `merge_mode: human_required` means PR #1 is still open. It cross-checked the
  # tree against bean-001's own spec, refused to plan around a missing
  # precondition, and stopped. It was right, and the queue was wrong.
  #
  # Answered from git rather than from GitHub: a merge is a fact about the
  # default branch, the line runs offline by design, and `gh` would be a network
  # call per dependency per queue computation.
  local id="$1" br sha
  br="$(branch_for "$id")"
  if [ -n "$br" ]; then
    sha="$(git -C "$ROOT" rev-parse "$br" 2>/dev/null)"
  else
    # The branch is gone, which after a merge is the usual outcome. Fall back to
    # what the run recorded it as, if that ref still resolves.
    local d
    for d in $(ls -1dt "$RUNS_ROOT/$id"-*/ 2>/dev/null); do
      [ -f "$d/run.json" ] || continue
      sha="$(jq -r '.branch // empty' "$d/run.json" 2>/dev/null)"
      [ -n "$sha" ] && sha="$(git -C "$ROOT" rev-parse "$sha" 2>/dev/null || true)"
      [ -n "$sha" ] && break
    done
  fi
  # No sha to test is not a merge. Blocking on an unknown is the safe direction:
  # the cost is a bean that waits for a human who can look, and the cost of the
  # other answer is a bean built against a tree that does not have its
  # dependencies in it.
  [ -n "$sha" ] || return 1
  git -C "$ROOT" merge-base --is-ancestor "$sha" "$DEFAULT_BRANCH" 2>/dev/null
}

# ---------------------------------------------------------------- the queue --
ROWS='[]'
while IFS= read -r id; do
  [ -n "$id" ] || continue
  row="$(jq -c --arg i "$id" '.[] | select(.id == $i)' <<<"$ALL")"
  status="$(jq -r '.status' <<<"$row")"
  state=""; why=""

  if [ "$(jq -r '.parse_error // false' <<<"$row")" = true ]; then
    state=refused; why="$(jq -r '.path' <<<"$row") could not be read as a bean"
  elif [ "$status" != approved ]; then
    # The rule that matters. Not "skipped" — refused, and the record says so.
    state=refused; why="status is '$status', not approved"
  else
    pr="$(pr_for "$id")"
    br="$(branch_for "$id")"
    if [ -n "$pr" ] && merged "$id"; then
      state=done; why="merged: $pr"
    elif [ -n "$pr" ]; then
      # The state this queue was missing, and the one `merge_mode: human_required`
      # makes the normal case: the bean's work is finished and sitting in a pull
      # request nobody has merged. Its own run is done; the next bean's BASE does
      # not contain it.
      state=pr_open; why="pull request open, not merged: $pr"
    elif [ -n "$br" ]; then
      state=in_progress; why="branch $br already exists"
    else
      # Dependencies. A dependency that is itself refused blocks forever, and
      # saying which is the difference between a queue and a mystery.
      blocked=""
      while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        dstate="$(jq -r --arg d "$dep" '.[] | select(.id == $d) | .status' <<<"$ALL")"
        if [ -z "$dstate" ]; then blocked="$blocked $dep(unknown)"
        elif [ "$dstate" != approved ]; then blocked="$blocked $dep($dstate)"
        elif [ -z "$(pr_for "$dep")" ]; then blocked="$blocked $dep(not built)"
        elif ! merged "$dep"; then blocked="$blocked $dep(pull request not merged)"
        fi
      done < <(jq -r '.deps[]?' <<<"$row")
      if [ -n "$blocked" ]; then
        state=blocked; why="waiting on:$blocked"
      else
        state=ready; why=""
      fi
    fi
  fi
  ROWS="$(jq -c --argjson r "$row" --arg s "$state" --arg w "$why" \
    '. + [$r + {state:$s, why:$w}]' <<<"$ROWS")"
done < <(jq -r 'sort_by([(.order // 9999), .id]) | .[].id' <<<"$ALL")

if [ "$AS_JSON" = 1 ]; then
  jq -n --argjson r "$ROWS" \
    '{schema:"queue/1.0.0", beans:$r,
      ready: [$r[] | select(.state == "ready") | .id],
      note:"A bean that is not status: approved is refused, never skipped. §04 gates what enters the line, and a queue that quietly included a draft would route around the only human checkpoint before a model starts work."}'
  exit 0
fi

printf '\nqueue — %s bean(s)\n\n' "$(jq 'length' <<<"$ROWS")"
printf '%-10s %-12s %-44s %s\n' BEAN STATE TITLE WHY
jq -r '.[] | [.id, .state, (.title[0:42]), .why] | @tsv' <<<"$ROWS" \
  | while IFS=$'\t' read -r id state title why; do
      [ "$SHOW_ALL" = 1 ] || [ "$state" = ready ] || [ "$state" = refused ] \
        || [ "$state" = pr_open ] || continue
      printf '%-10s %-12s %-44s %s\n' "$id" "$state" "$title" "$why"
    done

# "queue — 20 bean(s)" followed by one row reads as a bug. It is not: the table
# shows the states a reader can act on. Say how many were left out and how to see
# them, because a number that does not match the rows under it is the shape of a
# thing that is broken.
if [ "$SHOW_ALL" != 1 ]; then
  HIDDEN="$(jq -r '[.[] | select(.state != "ready" and .state != "refused" and .state != "pr_open")] | length' <<<"$ROWS")"
  [ "${HIDDEN:-0}" -gt 0 ] && printf '\n(%s more, blocked or done — `factory queue --all`)\n' "$HIDDEN"
fi

READY="$(jq -r '[.[] | select(.state == "ready") | .id] | join(" ")' <<<"$ROWS")"
printf '\nready: %s\n' "${READY:-nothing}"
REFUSED="$(jq -r '[.[] | select(.state == "refused") | .id] | length' <<<"$ROWS")"
[ "$REFUSED" -gt 0 ] && printf 'refused: %s bean(s) not approved — §04 gates what enters the line\n' "$REFUSED"
WAITING="$(jq -r '[.[] | select(.state == "pr_open") | .id] | join(" ")' <<<"$ROWS")"
if [ -n "$WAITING" ]; then
  printf 'waiting on a human to merge: %s\n' "$WAITING"
  printf '  `merge_mode: human_required` means the line stops here by design. Until these\n'
  printf '  land on %s, everything downstream builds against a tree without them.\n' "$DEFAULT_BRANCH"
fi
printf '\n'
