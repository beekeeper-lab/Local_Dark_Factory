#!/usr/bin/env bash
# sync.sh — is the candidate still measured against the branch it will merge
# into? Controller only; no model runs here.
#
# Every verdict this line produces names a `base_sha` and a `candidate_sha`, and
# means "on top of that base, this candidate is acceptable". Main moves. If it
# moved while the bean was being built, the gate ran against a tree that no
# longer exists anywhere, and the audits approved a diff nobody will ever merge.
# The pull request would still open, the checks would still be green, and the
# merge would produce a third tree that nothing in the run has ever seen.
#
# So before the PR, the base is re-checked. If the branch is behind, it is
# rebased onto the default branch, and the results that were about the old base
# are moved aside rather than deleted — they are what happened, and the run
# record is the only place that says so. The gate and the two audits that judge
# the implementation then run again against the new candidate.
#
# The spec audit is not re-run and that is deliberate: it judged the plan, not
# the code, and a rebase does not change the plan. Nor is the document — the
# implementation it describes is the same implementation.
#
# Exit: 0 already current, nothing to do
#       9 rebased; <run>/rewind.json says what must run again
#       3 the rebase conflicts — a human decides, QUESTIONS.md written
#       1 a precondition failed (dirty tree, detached head, no upstream)
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
sync.sh — rebase the run branch onto the default branch if it has fallen behind.

usage: sync.sh <run_dir> [--repo-config <repo.yaml>] [--max-rebases N] [--no-fetch]

Exit: 0 current · 9 rebased (rewind.json written) · 3 conflict, human needed
      1 precondition failed
EOF
}

RUN_DIR=""; REPO_CONFIG=""; MAX_REBASES=2; FETCH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-config) REPO_CONFIG="${2:?}"; shift 2 ;;
    --max-rebases) MAX_REBASES="${2:?}"; shift 2 ;;
    --no-fetch)    FETCH=0; shift ;;
    -h|--help)     usage; exit 0 ;;
    --version)     cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*)            usage >&2; die "unknown flag: $1" ;;
    *)             [ -z "$RUN_DIR" ] || die "only one run dir"; RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || { usage >&2; exit 1; }
require_cmd jq; require_cmd git

ROOT="$(repo_root)"
[ -n "$REPO_CONFIG" ] || REPO_CONFIG="$ROOT/factory/repo.yaml"
DEFAULT_BRANCH="$([ -f "$REPO_CONFIG" ] && "$PIPELINE_DIR/yaml2json.sh" "$REPO_CONFIG" | jq -r '.default_branch // "main"' || echo main)"

printf '\nSYNC  %s\n\n' "$(basename "$RUN_DIR")"

BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null || true)"
if [ -z "$BRANCH" ]; then
  printf '  FAIL  branch                   detached HEAD — a rebase needs a branch to move\n'
  exit 1
fi
if [ "$BRANCH" = "$DEFAULT_BRANCH" ]; then
  printf '  FAIL  branch                   on %s — sync moves the bean branch, never the base\n' "$DEFAULT_BRANCH"
  exit 1
fi

# A rebase rewrites the working tree. Anything uncommitted would be carried into
# the rewrite or lost in it, and neither is something to do behind a person's
# back. The run directory is evidence, not source, so it is excluded by its real
# path exactly as pr.sh does.
RUN_REL=""
case "$(cd "$RUN_DIR" && pwd)/" in "$ROOT"/*) RUN_REL="$(realpath --relative-to="$ROOT" "$RUN_DIR")" ;; esac
DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null \
  | { [ -n "$RUN_REL" ] && grep -v -- " ${RUN_REL%%/*}/" || cat; } || true)"
if [ -n "$DIRTY" ]; then
  printf '  FAIL  clean tree               uncommitted changes; a rebase would rewrite them: %s\n' \
    "$(printf '%s' "$DIRTY" | head -3 | tr '\n' ' ')"
  exit 1
fi

# The comparison is against the remote's default branch when there is a remote,
# and the local one when there is not — a repository with no origin is a
# legitimate way to run this line, and refusing it would be refusing the offline
# case the whole factory is built for.
BASE_REF=""
if git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH"; then
  BASE_REF="origin/$DEFAULT_BRANCH"
  if [ "$FETCH" = 1 ]; then
    if git -C "$ROOT" fetch --quiet origin "$DEFAULT_BRANCH" 2>/dev/null; then
      printf '  ok    fetch                    origin/%s\n' "$DEFAULT_BRANCH"
    else
      # This used to warn and carry on, comparing against the last known
      # origin/main. That is failing open, in the precise sense the taxonomy in
      # RESUME.md names: the step would print a warning nobody reads and then
      # report SYNC CURRENT, which is a claim about the remote it did not test.
      #
      # A repository with no origin is a legitimate way to run this line and is
      # handled by the branch below — nothing can be behind a base that does not
      # exist. An origin that exists and cannot be reached is a different thing:
      # the answer is unknown, and the next step pushes to that same origin
      # anyway, so nothing is gained by guessing now.
      printf '  FAIL  fetch                    origin exists and could not be reached\n'
      printf '\nSYNC UNKNOWN — the last known %s may be stale, and "probably current" is not\n' "$BASE_REF"
      printf 'something this step is willing to record. Fix the network, or run with\n'
      printf '%s\n' '--no-fetch if you have just fetched by hand and know what you are doing.'
      exit 1
    fi
  fi
elif git -C "$ROOT" show-ref --verify --quiet "refs/heads/$DEFAULT_BRANCH"; then
  BASE_REF="$DEFAULT_BRANCH"
  printf '  ok    base                     local %s (no origin)\n' "$DEFAULT_BRANCH"
else
  printf '  FAIL  base                     no %s branch, local or remote, to measure against\n' "$DEFAULT_BRANCH"
  exit 1
fi

BEHIND="$(git -C "$ROOT" rev-list --count "HEAD..$BASE_REF" 2>/dev/null || echo '?')"
if [ "$BEHIND" = "?" ]; then
  printf '  FAIL  base                     could not count commits between HEAD and %s\n' "$BASE_REF"
  exit 1
fi
if [ "$BEHIND" = 0 ]; then
  printf '  ok    base                     %s has nothing this branch lacks\n' "$BASE_REF"
  printf '\nSYNC CURRENT — the candidate is measured against the tree it will merge into\n'
  exit 0
fi

printf '  ..    base                     %s is %s commit(s) ahead of this branch\n' "$BASE_REF" "$BEHIND"

# Rebasing repeatedly is a signal, not a solution. If main is moving faster than
# a bean takes to build, no amount of retrying converges; a person needs to know
# that rather than watch the line spin.
DONE_SO_FAR="$(jq -r '[.rebases[]?] | length' "$RUN_DIR/run.json" 2>/dev/null || echo 0)"
if [ "$DONE_SO_FAR" -ge "$MAX_REBASES" ]; then
  cat > "$RUN_DIR/QUESTIONS.md" <<EOF
# $BASE_REF keeps moving out from under this run

This branch has already been rebased $DONE_SO_FAR time(s), and $BASE_REF is
$BEHIND commit(s) ahead again. A third is not a retry: each rebase costs
a fresh gate and two fresh audits, and a base moving this fast is changing
faster than this bean takes to build.

Someone should decide whether to let it finish against a quiet base, split the
bean into something shorter, or land the intervening work first.

- branch: \`$BRANCH\`
- base: \`$BASE_REF\` at \`$(git -C "$ROOT" rev-parse --short "$BASE_REF")\`
- rebases so far: $DONE_SO_FAR (limit $MAX_REBASES)
EOF
  printf '\nSYNC BLOCKED — %s rebase(s) already, and the base moved again. See QUESTIONS.md\n' "$DONE_SO_FAR"
  exit 3
fi

OLD_HEAD="$(git -C "$ROOT" rev-parse HEAD)"
OLD_BASE="$(git -C "$ROOT" merge-base HEAD "$BASE_REF")"
NEW_BASE="$(git -C "$ROOT" rev-parse "$BASE_REF")"

if ! git -C "$ROOT" rebase --quiet "$BASE_REF" >/dev/null 2>&1; then
  CONFLICTS="$(git -C "$ROOT" diff --name-only --diff-filter=U 2>/dev/null | head -20)"
  git -C "$ROOT" rebase --abort >/dev/null 2>&1 || true
  cat > "$RUN_DIR/QUESTIONS.md" <<EOF
# The rebase onto $BASE_REF conflicts

$BASE_REF moved $BEHIND commit(s) ahead while this bean was being built, and the
branch does not replay cleanly onto it. The rebase was aborted, so the branch is
exactly as it was at \`${OLD_HEAD:0:12}\`; nothing has been lost.

A conflict means two changes to the same lines, and choosing between them is a
judgement about intent that nothing here is entitled to make.

Files that conflicted:

$(printf '%s\n' "${CONFLICTS:-  (git reported a failure but named no conflicted files)}" | sed 's/^/- `/; s/$/`/')

- branch: \`$BRANCH\` at \`$OLD_HEAD\`
- base was: \`$OLD_BASE\`
- base now: \`$NEW_BASE\`

Resolve it on the branch, then resume the run. The gate and the implementation
audits will run again against whatever the resolution produced — they must, since
none of them has seen it.
EOF
  printf '\nSYNC CONFLICT — the branch is untouched at %s. See QUESTIONS.md\n' "${OLD_HEAD:0:12}"
  exit 3
fi

NEW_HEAD="$(git -C "$ROOT" rev-parse HEAD)"
printf '  ok    rebase                   %s..%s replayed onto %s\n' \
  "${OLD_HEAD:0:12}" "${NEW_HEAD:0:12}" "${NEW_BASE:0:12}"

# ------------------------------------------------- the results that are now stale --
#
# Moved, not deleted. A verdict about the old base is still a true record of what
# was judged and when; what it is not is authority to merge the new candidate.
N=$((DONE_SO_FAR + 1))
STALE="$RUN_DIR/pre-rebase-$N"
mkdir -p "$STALE"
MOVED=()
if [ -f "$RUN_DIR/gate.json" ]; then
  mv "$RUN_DIR/gate.json" "$STALE/gate.json"; MOVED+=("gate.json")
fi
if [ -d "$RUN_DIR/verdicts" ]; then
  for f in "$RUN_DIR/verdicts/impl".* "$RUN_DIR/verdicts/package".*; do
    [ -e "$f" ] || continue
    mkdir -p "$STALE/verdicts"
    mv "$f" "$STALE/verdicts/"; MOVED+=("verdicts/$(basename "$f")")
  done
fi
cat > "$STALE/README.md" <<EOF
# Results from before rebase $N

These were produced against base \`$OLD_BASE\` with the candidate at
\`$OLD_HEAD\`. That tree no longer exists: the branch was rebased onto
\`$NEW_BASE\` and the candidate is now \`$NEW_HEAD\`.

They are kept because they are what happened. They are moved out of the run's
working paths because a verdict names the commit it judged, and this one no
longer names anything that will be merged.

The gate and the implementation and package audits ran again after the rebase.
The spec audit did not, and should not have: it judged the plan, and the plan did
not change. Neither did the implementation document.
EOF
printf '  ok    stale results            %s moved to pre-rebase-%s/\n' "${#MOVED[@]}" "$N"

# The run record carries the rebase, because "why does this run have two gate
# results" has to be answerable from the record alone a year from now.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -c --arg t "$TS" --arg ob "$OLD_BASE" --arg nb "$NEW_BASE" \
      --arg oh "$OLD_HEAD" --arg nh "$NEW_HEAD" --arg br "$BASE_REF" \
      --argjson n "$BEHIND" \
  '.rebases = ((.rebases // []) + [{at: $t, base_ref: $br, from_base: $ob, to_base: $nb,
                                    old_head: $oh, new_head: $nh, base_was_ahead_by: $n}])' \
  "$RUN_DIR/run.json" > "$RUN_DIR/run.json.tmp" && mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"

# What has to run again, named here rather than assumed by the caller, so the
# reason and the consequence live in the same file.
cat > "$RUN_DIR/rewind.json" <<EOF
{
  "reason": "rebased onto $BASE_REF ($BEHIND commit(s) ahead); the candidate is a new commit",
  "at": "$TS",
  "to": "gate",
  "force": ["gate", "audit-impl", "audit-package"],
  "old_head": "$OLD_HEAD",
  "new_head": "$NEW_HEAD"
}
EOF

printf '\nSYNC REBASED — gate, audit-impl and audit-package must run again on %s\n' "${NEW_HEAD:0:12}"
exit 9
