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
ALL='[]'
for d in "$BEANS"/*/; do
  b="$d/bean.yaml"
  [ -f "$b" ] || continue
  bj="$("$PIPELINE_DIR/yaml2json.sh" "$b" 2>/dev/null)" || continue
  [ -n "$(jq -r '.id // empty' <<<"$bj")" ] || continue
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

# ---------------------------------------------------------------- the queue --
ROWS='[]'
while IFS= read -r id; do
  [ -n "$id" ] || continue
  row="$(jq -c --arg i "$id" '.[] | select(.id == $i)' <<<"$ALL")"
  status="$(jq -r '.status' <<<"$row")"
  state=""; why=""

  if [ "$status" != approved ]; then
    # The rule that matters. Not "skipped" — refused, and the record says so.
    state=refused; why="status is '$status', not approved"
  else
    pr="$(pr_for "$id")"
    br="$(branch_for "$id")"
    if [ -n "$pr" ]; then
      state=done; why="a pull request was opened: $pr"
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
      [ "$SHOW_ALL" = 1 ] || [ "$state" = ready ] || [ "$state" = refused ] || continue
      printf '%-10s %-12s %-44s %s\n' "$id" "$state" "$title" "$why"
    done

READY="$(jq -r '[.[] | select(.state == "ready") | .id] | join(" ")' <<<"$ROWS")"
printf '\nready: %s\n' "${READY:-nothing}"
REFUSED="$(jq -r '[.[] | select(.state == "refused") | .id] | length' <<<"$ROWS")"
[ "$REFUSED" -gt 0 ] && printf 'refused: %s bean(s) not approved — §04 gates what enters the line\n' "$REFUSED"
printf '\n'
