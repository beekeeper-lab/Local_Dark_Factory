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

# pr_closed <url> — did someone close this pull request without merging it?
#
# The one question in this file only GitHub can answer. bean-004's PR #5 was
# closed on 2026-09-24 so the bean could be re-run with a new criterion, and the
# queue went on calling it `pr_open` — a closed pull request leaves nothing
# local behind: run.json still records its url, and an unmerged branch looks the
# same whether its pull request is open or closed. So the queue told a human to
# merge a pull request that no longer existed, and hid the re-run behind it.
#
# Asked only for a pull request that would otherwise be reported `pr_open` —
# merged ones are settled from git below, before this is reached — once per url,
# and bounded by a timeout. Anything but an answer of CLOSED keeps `pr_open`:
# no network, no `gh`, no auth all mean "unknown", and an unknown blocks.
# QUEUE_GH names the command, so the tests can answer without a network.
declare -A PR_CLOSED_CACHE=()
pr_closed() {
  local url="$1" state
  if [ -z "${PR_CLOSED_CACHE[$url]+x}" ]; then
    state="$(timeout 15 "${QUEUE_GH:-gh}" pr view "$url" --json state -q .state 2>/dev/null || true)"
    PR_CLOSED_CACHE[$url]="$state"
  fi
  [ "${PR_CLOSED_CACHE[$url]}" = CLOSED ]
}

DEFAULT_BRANCH="$([ -f "$ROOT/factory/repo.yaml" ] && "$PIPELINE_DIR/yaml2json.sh" "$ROOT/factory/repo.yaml" 2>/dev/null | jq -r '.default_branch // "main"' || echo main)"

# resolve_branch <recorded-name> -> a sha, or empty.
#
# A merged pull request usually takes the branch with it: GitHub deletes the
# remote branch, `git fetch --prune` deletes the tracking ref, and a local branch
# that was never created here — the pull request was opened by `gh` from a
# worktree, not from a checkout — never existed to begin with. bean-003 merged
# 2026-09-22 and the queue still called it `pr_open`, because the fallback below
# rev-parsed the bare name `bean/bean-003-...`, nothing by that name resolves
# locally, and no sha means not merged. The queue was telling a human to merge a
# pull request they had merged an hour earlier, and bean-004 and bean-005 sat
# behind it.
#
# So try the tracking refs too, in order of how much they are worth trusting: a
# local branch, then this remote's copy, then any remote's. Still all local
# reads — no network, which is the property the comment below is protecting.
resolve_branch() {
  local name="$1" r
  git -C "$ROOT" rev-parse --verify --quiet "refs/heads/$name" 2>/dev/null && return 0
  for r in $(git -C "$ROOT" remote 2>/dev/null); do
    git -C "$ROOT" rev-parse --verify --quiet "refs/remotes/$r/$name" 2>/dev/null && return 0
  done
  return 1
}

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
      [ -n "$sha" ] && sha="$(resolve_branch "$sha")"
      [ -n "$sha" ] && break
    done
  fi
  # No sha to test is not a merge. Blocking on an unknown is the safe direction:
  # the cost is a bean that waits for a human who can look, and the cost of the
  # other answer is a bean built against a tree that does not have its
  # dependencies in it.
  [ -n "$sha" ] || return 1
  git -C "$ROOT" merge-base --is-ancestor "$sha" "$DEFAULT_BRANCH" 2>/dev/null || return 1
  # Being an ancestor is not being merged. A branch cut from the default branch
  # and not yet committed to is an ancestor too — it IS a commit of main. Found
  # 2026-09-24 when bean-004 was re-run after its PR #5 was closed: the new
  # branch sat at main's tip, the queue called bean-004 `done` on the strength of
  # the closed pull request, and offered bean-017, which depends on it.
  #
  # A merge brings the branch in through a merge commit's second parent, so its
  # tip is off main's first-parent line; the point a branch was cut from is on
  # it. A fast-forward merge also lands on the line and reads as unmerged here —
  # the blocking direction, and not how pull requests merge in these repos.
  # (grep reads it all: -q would stop early, and under pipefail the SIGPIPE
  # rev-list takes for it would read as "not on the line".)
  ! git -C "$ROOT" rev-list --first-parent "$DEFAULT_BRANCH" 2>/dev/null | grep -xF "$sha" >/dev/null
}

# halted_run_for <bean-id> — the newest run of this bean that stopped for a human.
#
# A bean can be `ready` and still have a halted run sitting beside it: bean-002
# halted on a missing precondition that merging bean-001's pull request fixes, so
# the moment that merge lands the bean is runnable and the old run directory is
# still there. `factory go` would start a second one and leave the first, which is
# the right behaviour — the halt had an external cause and the evidence should not
# be overwritten — but an operator who is not told will wonder which run the line
# is talking about, at exactly the moment they are least able to check.
halted_run_for() {
  local id="$1" d
  for d in $(ls -1dt "$RUNS_ROOT/$id"-*/ 2>/dev/null); do
    [ -f "$d/run.json" ] || continue
    if [ "$(jq -r '.status // ""' "$d/run.json" 2>/dev/null)" = halted ]; then
      printf '%s' "${d%/}"; return 0
    fi
  done
  return 1
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
    closed=""
    if [ -n "$pr" ] && ! merged "$id" && pr_closed "$pr"; then
      # Closed unmerged: the bean is not built, so it is judged as if no pull
      # request had been opened — in progress if its branch exists, otherwise
      # by its dependencies — and the row says why the url is being ignored.
      closed="$pr"; pr=""
    fi
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
        elif ! merged "$dep" && pr_closed "$(pr_for "$dep")"; then
          blocked="$blocked $dep(pull request closed, not merged)"
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
  [ -n "${closed:-}" ] && why="${why:+$why; }pull request closed without merging: $closed"
  closed=""
  halted=""
  case "$state" in
    ready|blocked) halted="$(halted_run_for "$id" || true)" ;;
  esac
  ROWS="$(jq -c --argjson r "$row" --arg s "$state" --arg w "$why" --arg h "$halted" \
    '. + [$r + {state:$s, why:$w} + (if $h == "" then {} else {halted_run:$h} end)]' <<<"$ROWS")"
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

# A halted run beside a runnable bean, said before the operator runs anything.
HALTED="$(jq -r '[.[] | select(.halted_run) | "  \(.id) — \(.halted_run)"] | join("\n")' <<<"$ROWS")"
if [ -n "$HALTED" ]; then
  printf '\nhalted run(s) still on disk for beans that are not finished:\n%s\n' "$HALTED"
  printf '  A new run starts in a new directory; these are left alone, because the halt\n'
  printf '  is evidence and QUESTIONS.md in them is often the most useful thing the run\n'
  printf '  produced. Read them, then delete them if you do not want them counted.\n'
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
  # And what merging buys. "ready: nothing" is a true and unhelpful answer to the
  # question the operator is actually asking, which is what happens next — and
  # that is computable from the same dependency graph this queue already walked.
  # A bean whose ONLY remaining blocker is one of these becomes ready the moment
  # it lands.
  # `$open | index($d)`, with the dep BOUND first.
  #
  # Written as `$open | index(.)` this reported every blocked bean as unblocked,
  # including ones two dependencies deep. Inside `$open | ...` the `.` is $open,
  # so `index(.)` asks whether the array contains itself — 0, truthy, every dep
  # "found", every bean "ready on merge". The same class as `jq -e` on a string:
  # a jq expression that is valid, runs, and answers a different question.
  UNBLOCKS="$(jq -r --argjson rows "$ROWS" '
    ($rows | map(select(.state == "pr_open") | .id)) as $open
    | [ $rows[]
        | select(.state == "blocked")
        | . as $b
        | select([ $b.deps[]? | . as $d | select(($open | index($d)) | not) ] | length == 0)
        | select([ $b.deps[]? | . as $d | select($open | index($d)) ] | length > 0)
        | .id ]
    | join(" ")' <<<'null')"
  if [ -n "$UNBLOCKS" ]; then
    printf '  Merging %s makes these ready: %s\n' \
      "$(printf '%s' "$WAITING" | tr ' ' ',' | sed 's/,$//')" "$UNBLOCKS"
  fi
fi
printf '\n'
