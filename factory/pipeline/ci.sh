#!/usr/bin/env bash
# ci.sh — wait for the remote checks on the pull request, and act on what they say.
#
# The gates run twice: once here, in the pinned image, before anything is pushed,
# and once on GitHub against the same image by digest. The second run is not
# redundant. It is the only one a reviewer can see without trusting this machine,
# and it runs on a tree assembled by a merge rather than by the branch alone.
#
# A required check that fails is not a reason to stop; it is a finding, and the
# line already knows how to act on findings. So this writes what failed, works out
# which tasks the failure touches, and sends the run back to `build` for those
# tasks only — rebuilding the whole bean because one gate found one thing throws
# away work CI did not object to.
#
# Exit: 0 every required check green · 9 a check failed, rewind.json written
#       3 the checks never finished (timeout, or none were reported) · 1 precondition
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
ci.sh — wait for the pull request's required checks and act on the result.

usage: ci.sh <run_dir> [--repo-config <repo.yaml>] [--timeout <s>] [--interval <s>]

Exit: 0 green · 9 a required check failed (rewind.json written) · 3 never finished
      1 a precondition failed
EOF
}

RUN_DIR=""; REPO_CONFIG=""; TIMEOUT="${FACTORY_CI_TIMEOUT:-2700}"; INTERVAL="${FACTORY_CI_INTERVAL:-30}"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-config) REPO_CONFIG="${2:?}"; shift 2 ;;
    --timeout)     TIMEOUT="${2:?}"; shift 2 ;;
    --interval)    INTERVAL="${2:?}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    --version)     cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*)            usage >&2; die "unknown flag: $1" ;;
    *)             [ -z "$RUN_DIR" ] || die "only one run dir"; RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || { usage >&2; exit 1; }
require_cmd jq; require_cmd gh

ROOT="$(repo_root)"
[ -n "$REPO_CONFIG" ] || REPO_CONFIG="$ROOT/factory/repo.yaml"
REQUIRED="$([ -f "$REPO_CONFIG" ] && "$PIPELINE_DIR/yaml2json.sh" "$REPO_CONFIG" | jq -r '[.required_checks[]?] | join(" ")' || echo "")"
PR_URL="$(jq -r '.pr_url // empty' "$RUN_DIR/run.json" 2>/dev/null || true)"

# Every path through this step leaves a record.
#
# ci.json was written only when the checks became terminal, so a run that halted
# on "no workflow can report this" or "they never finished" left nothing in the
# run directory saying the step had run at all. A reader could not tell CI from
# a step that was skipped — which is the gap doc-check had until last night, and
# the gap package-check exists to close.
ci_record() { # ci_record <status> <failed-space-separated> <why>
  jq -n --arg st "$1" --arg failed "$2" --arg why "$3" \
     --arg sha "${HEAD_SHA:-}" --arg pr "${PR_URL:-}" --arg required "${REQUIRED:-}" \
     --argjson rows "${ROWS:-[]}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:"ci/1.1.0", status:$st, checked_at:$ts,
      pull_request:(if $pr == "" then null else $pr end),
      candidate_sha:(if $sha == "" then null else $sha end),
      required:(if $required == "" then [] else ($required | split(" ")) end),
      failed:(if $failed == "" then [] else ($failed | split(" ")) end),
      why:(if $why == "" then null else $why end),
      checks:$rows}' > "$RUN_DIR/ci.json"
}

printf '\nCI  %s\n\n' "$(basename "$RUN_DIR")"

if [ -z "$PR_URL" ]; then
  printf '  FAIL  pull request            run.json records no pr_url — there is nothing to watch\n'
  exit 1
fi
if [ -z "$REQUIRED" ]; then
  # Not a pass. The repo names no required checks, so there is nothing this step
  # can assert, and saying "green" would be asserting it anyway.
  printf '  --    required_checks         none named in %s; nothing to wait for\n' "$(basename "$REPO_CONFIG")"
  ci_record not_asked "" "the repository names no required checks"
  printf '\nCI NOT ASKED — this repository names no required checks, so a green here would\n'
  printf 'mean only that nothing was checked.\n'
  exit 0
fi
printf '  ok    pull request            %s\n' "$PR_URL"
printf '  ok    required                %s\n' "$REQUIRED"

# The commit the checks have to be about, read before anything uses it. The
# fail-fast branch below quotes it, and at first it was written above the line
# that defines it — so the heredoc died on an unbound variable and wrote an empty
# QUESTIONS.md while the step still printed its explanation to the terminal. The
# operator would have been told to read a file with nothing in it.
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"

# Waiting is only worth doing for something that can happen. A repository that
# names required checks and carries no workflows will never report one, and
# forty-five minutes of polling ends at the same conclusion this line can reach
# now — with the difference that a run which halts immediately gets fixed, and one
# that halts after forty-five minutes gets abandoned.
#
# Checked against the branch, not the working tree: the pull request is about the
# commit that was pushed, and what matters is whether a workflow exists there.
if ! git -C "$ROOT" ls-tree -r --name-only HEAD -- .github/workflows 2>/dev/null | grep -q .; then
  printf '  FAIL  workflows               none on this branch under .github/workflows\n'
  cat > "$RUN_DIR/QUESTIONS.md" <<EOF
# This repository requires checks that nothing can produce

\`factory/repo.yaml\` names required checks —$( for c in $REQUIRED; do printf ' \`%s\`' "$c"; done ) —
and the branch this pull request is from carries no \`.github/workflows\`. Nothing
will ever report them, so waiting is only a slower way of finding that out.

- pull request: $PR_URL
- candidate: \`$HEAD_SHA\`

Either install the workflow — \`factory/scaffold.sh <repo>\` copies it, and it runs
the image \`gates.lock.yaml\` pins, which has to be published to a registry first
(\`factory/gate-image/publish.sh --registry ghcr.io/<org>\`) — or remove
\`required_checks\` from repo.yaml, which is the honest thing to do if this
repository is not going to have CI.
EOF
  ci_record impossible "$REQUIRED" "no .github/workflows on this branch, so nothing can report the required checks"
  printf '\nCI IMPOSSIBLE — required checks are named and no workflow exists to report them.\n'
  printf 'See QUESTIONS.md. Not waiting %ss to reach the same conclusion.\n' "$TIMEOUT"
  exit 3
fi
printf '  ok    workflows               %s on this branch\n' \
  "$(git -C "$ROOT" ls-tree -r --name-only HEAD -- .github/workflows 2>/dev/null | wc -l)"

# The checks have to be about the commit that was pushed, not about whatever the
# branch points at now. A green check on a different commit is not evidence about
# this one — the same rule pr.sh applies to a verdict. HEAD_SHA is read above.

DEADLINE=$(( $(date +%s) + TIMEOUT ))
STATE=""; ROWS=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  # `bucket`, not `state`. gh documents bucket as the normalisation of state into
  # pass/fail/pending/skipping/cancel, and it is the field that stays meaningful
  # across check types — GitHub Actions, external statuses, and whatever the next
  # integration reports. Matching on raw state works until a check reports one
  # this list has never seen, at which point it reads as neither terminal nor
  # failed and the step waits for it forever. `state` is kept for the message,
  # because "FAILURE" is what a person will see in the GitHub UI.
  ROWS="$(gh pr checks "$PR_URL" --json name,state,bucket,link 2>/dev/null || true)"
  if [ -z "$ROWS" ] || ! jq -e '. | type == "array"' >/dev/null 2>&1 <<<"$ROWS"; then
    sleep "$INTERVAL"; continue
  fi
  pending=0
  for c in $REQUIRED; do
    b="$(jq -r --arg n "$c" '[.[] | select(.name == $n)] | last.bucket // "missing"' <<<"$ROWS")"
    case "$b" in
      pass|fail|cancel|skipping) ;;
      *) pending=1 ;;      # pending, and missing: it may not have started yet
    esac
  done
  [ "$pending" = 0 ] && { STATE=done; break; }
  sleep "$INTERVAL"
done

if [ "$STATE" != "done" ]; then
  # Two different things end up here and they need different words. A check that
  # is PENDING is slow. A check that has never appeared in the list at all is a
  # required check that does not run — which is not a slow check, it is a missing
  # guarantee, and it is the one that looks most like nothing happening.
  NEVER=""; SLOW=""
  for c in $REQUIRED; do
    st="$(jq -r --arg n "$c" '[.[] | select(.name == $n)] | last.state // "MISSING"' <<<"${ROWS:-[]}" 2>/dev/null || echo MISSING)"
    b="$(jq -r --arg n "$c" '[.[] | select(.name == $n)] | last.bucket // "missing"' <<<"${ROWS:-[]}" 2>/dev/null || echo missing)"
    if [ "$b" = "missing" ]; then
      NEVER="$NEVER $c"
      printf '  FAIL  %-23s never reported — a required check that does not run is not a check\n' "$c"
    else
      SLOW="$SLOW $c"
      printf '  FAIL  %-23s %s after %ss\n' "$c" "$st" "$TIMEOUT"
    fi
  done
  cat > "$RUN_DIR/QUESTIONS.md" <<EOF
# The pull request's required checks never finished

Waited ${TIMEOUT}s for:$( for c in $REQUIRED; do printf ' \`%s\`' "$c"; done )
${NEVER:+
Never reported at all:$NEVER — a required check that does not run is not a check.
The usual cause is that the workflow is not installed in this repository.}
${SLOW:+
Still running:$SLOW.}

- pull request: $PR_URL
- candidate: \`$HEAD_SHA\`

What this step will not do is call that green. Either the workflow is not
installed in this repository (\`.github/workflows/\`), or it is queued behind
something, or it never started. \`gh pr checks $PR_URL\` says which.
EOF
  ci_record unfinished "${NEVER}${SLOW}" "not terminal after ${TIMEOUT}s"
  printf '\nCI UNFINISHED — see QUESTIONS.md\n'
  exit 3
fi

FAILED=""
for c in $REQUIRED; do
  b="$(jq -r --arg n "$c" '[.[] | select(.name == $n)] | last.bucket // "missing"' <<<"$ROWS")"
  st="$(jq -r --arg n "$c" '[.[] | select(.name == $n)] | last.state // "MISSING"' <<<"$ROWS")"
  link="$(jq -r --arg n "$c" '[.[] | select(.name == $n)] | last.link // ""' <<<"$ROWS")"
  case "$b" in
    pass)    printf '  ok    %-23s %s\n' "$c" "$st" ;;
    missing) printf '  FAIL  %-23s never reported — a required check that does not run is not a check\n' "$c"
             FAILED="$FAILED $c" ;;
    # A skipped required check is not a passing one. GitHub skips jobs for all
    # sorts of good reasons — a path filter, a matrix exclusion — and every one
    # of them means the gates did not run on this commit, which is the one thing
    # `required_checks` exists to rule out.
    skipping) printf '  FAIL  %-23s skipped — the gates did not run on this commit\n' "$c"
             FAILED="$FAILED $c" ;;
    *)       printf '  FAIL  %-23s %s  %s\n' "$c" "$st" "$link"; FAILED="$FAILED $c" ;;
  esac
done

ci_record "$([ -z "$FAILED" ] && echo pass || echo failed)" "${FAILED# }" ""

if [ -z "$FAILED" ]; then
  printf '\nCI PASS — every required check is green on %s\n' "${HEAD_SHA:0:12}"
  exit 0
fi

# ------------------------------------------------ what the failure touches --
#
# Targeted, not wholesale. The failing logs name files; a task owns the files its
# write_paths cover; those tasks go back. A failure that names no file this bean
# wrote re-opens nothing and says so, because guessing would be worse than
# admitting the log does not say.
LOGS="$RUN_DIR/ci-logs.txt"
: > "$LOGS"
for c in $FAILED; do
  printf '=== %s ===\n' "$c" >> "$LOGS"
  run_id="$(jq -r --arg n "$c" '[.[] | select(.name == $n)] | last.link // ""' <<<"$ROWS" | grep -oE '/runs/[0-9]+' | head -1 | tr -dc '0-9')"
  if [ -n "$run_id" ]; then
    gh run view "$run_id" --log-failed >> "$LOGS" 2>/dev/null \
      || printf '(could not fetch the log for %s)\n' "$c" >> "$LOGS"
  else
    printf '(no run id in the check link; %s)\n' "$c" >> "$LOGS"
  fi
done

TASKS_FILE="$RUN_DIR/tasks.yaml"
REOPEN=""
if [ -f "$TASKS_FILE" ]; then
  TASKS_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$TASKS_FILE" 2>/dev/null || echo '{}')"
  while IFS= read -r tid; do
    [ -n "$tid" ] || continue
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      # A glob in the task's write_paths, reduced to the literal prefix before
      # the first wildcard: `src/**` matches any log line naming `src/`.
      lit="${pat%%\**}"
      [ -n "$lit" ] || continue
      if grep -qF -- "$lit" "$LOGS" 2>/dev/null; then
        case " $REOPEN " in *" $tid "*) ;; *) REOPEN="$REOPEN $tid" ;; esac
        break
      fi
    done < <(jq -r --arg i "$tid" '.tasks[] | select(.id == $i) | .write_paths[]?' <<<"$TASKS_JSON")
  done < <(jq -r '.tasks[]?.id' <<<"$TASKS_JSON")
fi

{
  printf '# The remote gates disagreed with the local ones\n\n'
  printf 'These required checks failed on `%s`:\n\n' "${HEAD_SHA:0:12}"
  for c in $FAILED; do printf -- '- `%s`\n' "$c"; done
  printf '\nThe same gates passed here, in the same image, before the push. Whatever the\n'
  printf 'difference is, the remote run is the one a reviewer can see, so it wins.\n\n'
  printf 'The failing output is in `ci-logs.txt` beside this file. Read it before\n'
  printf 'changing anything: the most common cause is not a bug in the code but a\n'
  printf 'difference between the two trees — a file that is gitignored here and so\n'
  printf 'never reached the push, or a path that only exists on this machine.\n'
} > "$RUN_DIR/ci-findings.md"

if [ -n "$REOPEN" ]; then
  printf '%s\n' $REOPEN > "$RUN_DIR/reopened-tasks.txt"
  printf '\n  --    re-opening             %s\n' "${REOPEN# }"
else
  rm -f "$RUN_DIR/reopened-tasks.txt"
  printf '\n  --    re-opening             nothing — the logs name no file this bean wrote\n'
fi

cat > "$RUN_DIR/rewind.json" <<EOF
{
  "reason": "required check(s) failed on the pull request:${FAILED}",
  "at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "to": "build",
  "force": ["build", "gate", "audit-impl", "doc", "audit-doc", "audit-package", "sync", "pr"],
  "reopened_tasks": [$(for t in $REOPEN; do printf '"%s",' "$t"; done | sed 's/,$//')],
  "candidate_sha": "$HEAD_SHA"
}
EOF

printf '\nCI FAILED —%s. The run goes back to build; see ci-findings.md\n' "$FAILED"
exit 9
