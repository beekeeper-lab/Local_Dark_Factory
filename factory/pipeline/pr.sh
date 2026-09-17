#!/usr/bin/env bash
# pr.sh — push the candidate and open the pull request. Controller only.
#
# No model runs in this step, and that is the design rather than an omission.
# §06 stage 11 makes push and PR pure controller work: the pre-PR audit has
# already drafted what needs saying, and everything else in the body is a fact
# the controller can read off disk. Putting a model here would mean a model in a
# process that holds a GitHub credential, for the sake of composing prose that is
# already written.
#
# It opens a PR and stops. It never merges, never force-pushes, never targets
# anything but the repository's default branch, and passes no `--auto`. In
# `human_required` mode — the default and the only mode this line has ever run in
# — a human merges or nothing does.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
pr.sh — push the run branch and open a pull request.

usage: pr.sh <run_dir> --bean <bean.yaml> [--repo-config <repo.yaml>] [--dry-run]

Refuses unless: the package (or impl) verdict is `accept`; gate.json is `pass`;
the working tree is clean and on the run's branch; the candidate the verdict
judged is HEAD; and no QUESTIONS.md is outstanding.

Exit: 0 the PR is open · 1 a precondition failed · 2 the push or the PR failed.
EOF
}

RUN_DIR=""; BEAN_FILE=""; REPO_CONFIG=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bean)        BEAN_FILE="${2:?}"; shift 2 ;;
    --repo-config) REPO_CONFIG="${2:?}"; shift 2 ;;
    --dry-run)     DRY=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    --version)     cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    -*)            usage >&2; die "unknown flag: $1" ;;
    *)             [ -z "$RUN_DIR" ] || die "only one run dir"; RUN_DIR="$1"; shift ;;
  esac
done
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || { usage >&2; exit 1; }
[ -n "$BEAN_FILE" ] && [ -f "$BEAN_FILE" ] || die "--bean is required and must exist"
require_cmd jq; require_cmd git

ROOT="$(repo_root)"
[ -n "$REPO_CONFIG" ] || REPO_CONFIG="$ROOT/factory/repo.yaml"
BEAN_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$BEAN_FILE")"
BEAN_ID="$(jq -r '.id' <<<"$BEAN_JSON")"
BEAN_TITLE="$(jq -r '.title' <<<"$BEAN_JSON")"

FAILED=0
ok()  { printf '  ok    %-24s %s\n' "$1" "$2"; }
bad() { printf '  FAIL  %-24s %s\n' "$1" "$2"; FAILED=1; }

printf '\nPR %s\n\n' "$BEAN_ID"

# ------------------------------------------------------------ preconditions --
BRANCH="$(git -C "$ROOT" branch --show-current 2>/dev/null)"
RECORDED="$(jq -r '.branch // empty' "$RUN_DIR/run.json" 2>/dev/null)"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "main" ]; then
  bad "branch" "on '${BRANCH:-detached}' — a PR is opened from the bean's branch, never from main"
elif [ -n "$RECORDED" ] && [ "$BRANCH" != "$RECORDED" ]; then
  bad "branch" "on '$BRANCH' but run.json records '$RECORDED'"
else
  ok "branch" "$BRANCH"
fi

# The run directory is evidence, not source. A scaffolded repo gitignores it, but
# do not depend on that: exclude it by its real path rather than by a guess at
# its name, or the last stage refuses every run over its own output.
RUN_REL=""
case "$(cd "$RUN_DIR" && pwd)/" in "$ROOT"/*) RUN_REL="$(realpath --relative-to="$ROOT" "$RUN_DIR")" ;; esac
DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null \
  | { [ -n "$RUN_REL" ] && grep -v -- " ${RUN_REL%%/*}/" || cat; } || true)"
[ -z "$DIRTY" ] && ok "clean tree" "nothing uncommitted" \
  || bad "clean tree" "uncommitted changes would not be in the PR: $(printf '%s' "$DIRTY" | head -3 | tr '\n' ' ')"

if [ -f "$RUN_DIR/QUESTIONS.md" ]; then
  bad "questions" "QUESTIONS.md is still at the run root — something asked for a human and never got one"
else
  ok "questions" "none outstanding"
fi

# The verdict that authorises this PR, and the candidate it judged.
VERDICT_FILE=""; VN=0
for target in package impl; do
  for f in "$RUN_DIR/verdicts/$target".attempt-*.json; do
    [ -e "$f" ] || continue
    case "$f" in *judgement.json) continue ;; esac
    n="${f##*attempt-}"; n="${n%.json}"
    if [ "$n" -ge "$VN" ]; then VN="$n"; VERDICT_FILE="$f"; fi
  done
  [ -n "$VERDICT_FILE" ] && break
done

# Advisory audits produce no verdict, on purpose and with the reason on disk.
#
# The judge is measured as not reproducible on identical input, so this line has
# been running with its verdicts recorded rather than binding. That is an operator
# decision, and it collides with the rule directly below: a PR needs an accepting
# verdict on the exact candidate, and in advisory mode there is none to have.
#
# The resolution is not to relax the rule. It is that in advisory mode a
# DIFFERENT set of things authorises the PR — the deterministic ones, which do
# not vary between runs: the gate passed on this candidate, the package record is
# internally consistent, and every audit that reached no verdict left a record
# saying why. Those are checked below like any other precondition.
#
# What must not happen is a pull request that looks the same as one a judge
# accepted. The body says so first, in its own section, before anything else.
ADVISORY_TARGETS=""
for t in spec impl doc package; do
  for f in "$RUN_DIR/failed-attempts/audit-$t".advisory.* \
           "$RUN_DIR/failed-attempts/resolved/audit-$t".advisory.*; do
    [ -e "$f" ] && { ADVISORY_TARGETS="$ADVISORY_TARGETS $t"; break; }
  done
done

HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
if [ -z "$VERDICT_FILE" ] && [ -n "$ADVISORY_TARGETS" ]; then
  # No verdict, and the run says why. The deterministic record has to carry it.
  ok "verdict" "none — audits ran advisory:$ADVISORY_TARGETS (see below)"
  if [ -f "$RUN_DIR/package-check.json" ] \
     && [ "$(jq -r '.internally_consistent' "$RUN_DIR/package-check.json" 2>/dev/null)" = "true" ]; then
    ok "package record" "internally consistent"
  else
    bad "package record" "package-check.json is missing or says the record contradicts itself — with no judge verdict, this is the only thing left that could authorise a PR"
  fi
  if [ -f "$RUN_DIR/doc-check.json" ] \
     && [ "$(jq -r '.status // "fail"' "$RUN_DIR/doc-check.json" 2>/dev/null)" = "pass" ]; then
    ok "document" "doc-check passed"
  elif [ -f "$RUN_DIR/impl-detail.html" ]; then
    ok "document" "rendered"
  else
    bad "document" "no implementation document — in advisory mode the documents are most of what a reviewer has"
  fi
elif [ -z "$VERDICT_FILE" ]; then
  bad "verdict" "no package or impl verdict, and no advisory record explaining the absence — nothing authorises this PR"
else
  V="$(cat "$VERDICT_FILE")"
  vword="$(jq -r '.verdict' <<<"$V")"
  cand="$(jq -r '.candidate_sha' <<<"$V")"
  if [ "$vword" != "accept" ]; then
    bad "verdict" "$(basename "$VERDICT_FILE") says '$vword' — only an accept opens a PR"
  elif [ "$cand" != "$HEAD_SHA" ]; then
    # §09: a verdict is about one commit. If HEAD has moved, the audit that
    # authorised this has not seen what would be pushed.
    bad "verdict" "judged ${cand:0:12} but HEAD is ${HEAD_SHA:0:12} — the audit did not see what would be pushed"
  else
    ok "verdict" "$(basename "$VERDICT_FILE") accept, on ${cand:0:12}"
  fi
fi

# The verdict binds a candidate to a base. If the base has moved, the merge would
# produce a third tree that neither the gate nor any audit has seen. sync.sh is
# the step that fixes this; the check is repeated here because opening the PR is
# the last moment it can still be caught, and a precondition worth having is
# worth having at the door as well as up the corridor.
DEFAULT_BRANCH_EARLY="$([ -f "$REPO_CONFIG" ] && "$PIPELINE_DIR/yaml2json.sh" "$REPO_CONFIG" | jq -r '.default_branch // "main"' || echo main)"
BASE_REF_EARLY=""
if git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$DEFAULT_BRANCH_EARLY"; then
  BASE_REF_EARLY="origin/$DEFAULT_BRANCH_EARLY"
elif git -C "$ROOT" show-ref --verify --quiet "refs/heads/$DEFAULT_BRANCH_EARLY"; then
  BASE_REF_EARLY="$DEFAULT_BRANCH_EARLY"
fi
if [ -n "$BASE_REF_EARLY" ]; then
  behind_n="$(git -C "$ROOT" rev-list --count "HEAD..$BASE_REF_EARLY" 2>/dev/null || echo '?')"
  if [ "$behind_n" = "?" ]; then
    bad "up to date" "could not compare HEAD with $BASE_REF_EARLY"
  elif [ "$behind_n" != 0 ]; then
    bad "up to date" "$BASE_REF_EARLY is $behind_n commit(s) ahead — run sync, then gate and the implementation audits again"
  else
    ok "up to date" "nothing in $BASE_REF_EARLY that this branch lacks"
  fi
else
  ok "up to date" "no $DEFAULT_BRANCH_EARLY to measure against"
fi

if [ -f "$RUN_DIR/gate.json" ]; then
  g="$(jq -r '.overall' "$RUN_DIR/gate.json")"
  [ "$g" = "pass" ] && ok "gate" "pass" || bad "gate" "gate.json says '$g'"
else
  bad "gate" "no gate.json — the change was never gated"
fi

MERGE_MODE="$([ -f "$REPO_CONFIG" ] && "$PIPELINE_DIR/yaml2json.sh" "$REPO_CONFIG" | jq -r '.merge_mode // "human_required"' || echo human_required)"
ok "merge mode" "$MERGE_MODE (this step never merges in any mode)"

if [ "$FAILED" -ne 0 ]; then
  printf '\nPR REFUSED — the preconditions are what make a pull request mean something\n'
  exit 1
fi

# -------------------------------------------------------------- the body --
TIER="$([ -n "${V:-}" ] && jq -r '.effective_risk_tier // "—"' <<<"$V" || echo "—")"
BODY="$(mktemp)"
{
  printf '## %s — %s\n\n' "$BEAN_ID" "$BEAN_TITLE"
  jq -r '.intent' <<<"$BEAN_JSON"
  printf '\n\n**Nothing in this pull request was written by a human.** It was planned, built,\n'
  printf 'documented and audited by local models under `factory/`, and audited by a\n'
  printf 'different model family than the one that wrote it. Read the two documents\n'
  printf 'before the diff — they are the point.\n\n'

  # The first thing a reviewer sees, when it applies. A pull request opened with
  # no judge verdict must not look like one a judge accepted.
  if [ -n "$ADVISORY_TARGETS" ]; then
    printf -- '---\n\n'
    printf '### ⚠ No audit verdict authorises this pull request\n\n'
    printf 'The audits ran in **advisory** mode and reached no verdict for:%s.\n\n' "$ADVISORY_TARGETS"
    printf 'That is a recorded operator decision, not a failure of this run: the judge\n'
    printf 'model is measured as not reproducible on identical input at temperature 0\n'
    printf '(`bench/judge-variance.sh`), so its opinions are recorded rather than used\n'
    printf 'as a gate. Each absence has a record in `failed-attempts/` saying why.\n\n'
    printf 'What *did* authorise it is deterministic and is listed below: the pinned\n'
    printf 'gates and every acceptance criterion passed against this exact commit, the\n'
    printf 'whole diff stayed inside the paths the bean declares, the tests were shown\n'
    printf 'to fail without the change, and the run record is internally consistent.\n\n'
    printf '**Read the two documents and the diff yourself.** On this pull request they\n'
    printf 'are the review, not a summary of one.\n\n'
    printf -- '---\n\n'
  fi

  # The documents are posted as comments on this pull request, not linked by path.
  #
  # The body used to link `factory/runs/<run>/spec.html`. That directory is
  # gitignored — deliberately, it is the run's evidence and not the project's
  # source — so the links were dead for everyone except someone sitting at the
  # machine that built the branch. A pull request that says "read the two
  # documents, they are the point" and then points at nothing is worse than one
  # that does not mention them.
  #
  # Comments rather than commits: committing the rendered documents onto the
  # branch would change the candidate after the gate ran and after the audits
  # judged it, and `candidate_sha` matching HEAD is the invariant the whole audit
  # chain rests on. The diff a reviewer sees stays exactly the diff that was
  # gated.
  printf '### Documents\n\n'
  printf 'Posted as comments on this pull request — the plan first, then what was\n'
  printf 'built. They are not in the diff: the run directory they come from is\n'
  printf 'evidence rather than source, and committing them would change the commit\n'
  printf 'the audits judged.\n'
  for pair in "The plan:spec.md" "What was built:impl-detail.md"; do
    label="${pair%%:*}"; f="${pair#*:}"
    [ -f "$RUN_DIR/$f" ] && printf -- '\n- %s — %s bytes, sha256 `%s`' \
      "$label" "$(wc -c < "$RUN_DIR/$f")" "$(sha256sum "$RUN_DIR/$f" | cut -c1-16)"
  done
  printf '\n'

  printf '\n### Verdicts\n\n'
  printf '| Stage | Verdict | Tier | Findings |\n|---|---|---|---|\n'
  for f in "$RUN_DIR"/verdicts/*.attempt-*.json; do
    [ -e "$f" ] || continue
    case "$f" in *judgement.json) continue ;; esac
    jf="${f%.json}.judgement.json"
    nf="$([ -f "$jf" ] && jq '[.findings[]?] | length' "$jf" 2>/dev/null || echo 0)"
    printf '| %s | **%s** | %s | %s |\n' \
      "$(jq -r '.stage' "$f")" "$(jq -r '.verdict' "$f")" "$(jq -r '.effective_risk_tier' "$f")" "$nf"
  done

  # Non-blocking findings are the most useful thing in a PR body: they are what
  # the audits saw and decided not to stop for, which is exactly what a reviewer
  # would otherwise have to rediscover.
  printf '\n### What the audits saw and did not block on\n\n'
  found=0
  for jf in "$RUN_DIR"/verdicts/*.judgement.json; do
    [ -e "$jf" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] && { printf -- '- %s\n' "$line"; found=1; }
    done < <(jq -r '.findings[]? | select(.severity != "blocker") | "\(.severity): \(.summary)"' "$jf" 2>/dev/null)
  done
  if [ "$found" = 0 ] && [ -n "$ADVISORY_TARGETS" ]; then
    printf 'Nothing — and that is an absence of findings, not a clean bill. The audits\n'
    printf 'for%s reached no verdict at all; see the section at the top.\n' "$ADVISORY_TARGETS"
  elif [ "$found" = 0 ]; then
    printf 'Nothing. Every audit was clean.\n'
  fi

  printf '\n### Gates\n\n'
  if [ -f "$RUN_DIR/gate.json" ]; then
    jq -r '.gates[]? | "- `\(.id)` \(.status)"' "$RUN_DIR/gate.json"
    jq -r '.acceptance_criteria[]? | "- `\(.id)` \(.status) — \(.command // "")"' "$RUN_DIR/gate.json"
    if [ "$(jq -r '.invariants // "null"' "$RUN_DIR/gate.json")" != "null" ]; then
      printf -- '- independent invariants: %s (`%s`)\n' \
        "$(jq -r '.invariants.status' "$RUN_DIR/gate.json")" "$(jq -r '.invariants.ref' "$RUN_DIR/gate.json")"
    fi
    # Hidden tests, said out loud in both directions.
    #
    # This is the line a human reviewer most wants and cannot get anywhere else:
    # whether the change was measured by something the model that wrote it could
    # not read. "None configured" is printed too, because a pull request silent
    # about them reads exactly like one where they passed — and the whole value of
    # the mechanism is that a reader knows which.
    #
    # A count and a hash. No names, no assertions, no output: this body is public,
    # and a reviewer who wants the detail has the path in gate.json.
    ht="$(jq -r '.hidden_tests.status // "absent"' "$RUN_DIR/gate.json")"
    case "$ht" in
      passed)   printf -- '- hidden tests: **passed** — %s file(s) written from the bean, kept outside this repository, never readable by the model that wrote this change (`%s`)\n' \
                  "$(jq -r '.hidden_tests.test_files // 0' "$RUN_DIR/gate.json")" \
                  "$(jq -r '(.hidden_tests.dir_sha256 // "")[0:12]' "$RUN_DIR/gate.json")" ;;
      failed)   printf -- '- hidden tests: **FAILED**, %s of them — full output outside this repository, see `hidden_tests.output_path` in gate.json\n' \
                  "$(jq -r '.hidden_tests.failed_count // "?"' "$RUN_DIR/gate.json")" ;;
      could_not_run) printf -- '- hidden tests: **did not run** — %s. Not a pass.\n' \
                  "$(jq -r '.hidden_tests.why // "no reason recorded"' "$RUN_DIR/gate.json")" ;;
      not_configured) printf -- '- hidden tests: none for this bean. Every check above ran code the model could read.\n' ;;
      *) ;;
    esac
  fi

  printf '\n### Provenance\n\n'
  printf '| | |\n|---|---|\n'
  # In advisory mode there is no verdict to read these off, so they come from the
  # run record and the gate — the same facts, stamped by the controller rather
  # than carried in a judgement.
  if [ -n "${V:-}" ]; then
    printf '| base | `%s` |\n' "$(jq -r '.base_sha' <<<"$V")"
    printf '| candidate | `%s` |\n' "$(jq -r '.candidate_sha' <<<"$V")"
    printf '| diff sha256 | `%s` |\n' "$(jq -r '.diff_sha256' <<<"$V")"
    printf '| binding tier | %s |\n' "$TIER"
    printf '| gate image | `%s` |\n' "$(jq -r '.gate_manifest_digest' <<<"$V")"
  else
    printf '| base | `%s` |\n' "$(git -C "$ROOT" merge-base HEAD "$DEFAULT_BRANCH_EARLY" 2>/dev/null || echo '—')"
    printf '| candidate | `%s` |\n' "$HEAD_SHA"
    printf '| binding tier | %s |\n' "$(jq -r '.tier.final_tier // "—"' "$RUN_DIR/gate.json" 2>/dev/null || echo '—')"
    printf '| gate image | `%s` |\n' "$(jq -r '.gate_manifest.image // "—"' "$RUN_DIR/gate.json" 2>/dev/null || echo '—')"
    printf '| authorised by | the deterministic record; no judge verdict |\n'
  fi
  if [ -n "${V:-}" ]; then
    printf '| risk policy | `%s` |\n' "$(jq -r '.policy_version' <<<"$V")"
    printf '| judge | `%s`, prompt `%s` |\n' "$(jq -r '.model_digest' <<<"$V")" "$(jq -r '.prompt_version' <<<"$V")"
  else
    printf '| risk policy | `%s` |\n' "$(jq -r '.conditions.risk_policy_version // "—"' "$RUN_DIR/run.json" 2>/dev/null || echo '—')"
    printf '| judge | `%s` — ran, reached no verdict |\n' "$(jq -r '.conditions.judge.digest // .conditions.judge.model // "—"' "$RUN_DIR/run.json" 2>/dev/null || echo '—')"
    printf '| developer | `%s` |\n' "$(jq -r '.conditions.developer.digest // .conditions.developer.model // "—"' "$RUN_DIR/run.json" 2>/dev/null || echo '—')"
    printf '| pipeline | `%s` |\n' "$(jq -r '.conditions.pipeline_version // "—"' "$RUN_DIR/run.json" 2>/dev/null || echo '—')"
  fi

  # The documents, by hash.
  #
  # verdict.schema.json says the artifacts array exists "so the PR can prove
  # which version was audited", and audit-check has been stamping it all along —
  # but it stopped there, in a file nobody opens. The two documents linked at the
  # top of this pull request are rendered from Markdown that is not committed
  # anywhere, so without this a reviewer has the judge's word that it audited
  # something, and no way to tell whether it is what they are reading.
  if [ -n "${V:-}" ] && [ "$(jq -r '[.artifacts[]?] | length' <<<"$V")" -gt 0 ]; then
    printf '\n### What was audited, by hash\n\n'
    printf '| document | sha256 |\n|---|---|\n'
    jq -r '.artifacts[]? | "| `\(.path)` | `\(.sha256[0:16])…` |"' <<<"$V"
    printf '\nThese are the bytes the audit saw. The rendered documents linked above are\n'
    printf 'made from them, and `sha256sum` on the run directory will say whether what\n'
    printf 'you are reading is what was judged.\n'
  fi
  [ "$TIER" -ge 3 ] 2>/dev/null && printf '\n> **Tier 3.** Never auto-merged in any merge mode.\n'
  # A run that continued past a verdict it did not satisfy says so here. This is
  # the whole difference between "advisory" and "discarded": the reviewer of this
  # pull request is told which audits did not accept and reads them, instead of
  # the run having quietly decided they did not matter.
  ADV=( "$RUN_DIR"/failed-attempts/*.advisory.* )
  if [ -e "${ADV[0]}" ]; then
    printf '\n## Audits that did not accept\n\n'
    # Two different things end up in this list, and the first version of this
    # paragraph described only one of them. On the run that first reached a pull
    # request, five of the six were the other: the judge produced no judgement at
    # all, and saying it "wrote a judgement the controller stamped" was false
    # about them. Each line below says which; the preamble must not contradict it.
    printf 'This run was made with **advisory audits**, and two different things are\n'
    printf 'listed below. Some are a judge that wrote a judgement the controller stamped\n'
    printf 'into a verdict short of accept. Some are a judge that produced no judgement at\n'
    printf 'all. Each line says which. Every deterministic check stayed blocking throughout.\n\n'
    printf 'Read these before approving:\n\n'
    for a in "${ADV[@]}"; do
      [ -e "$a" ] || continue
      printf -- '- `%s` — %s\n' "$(basename "$a")" \
        "$(grep '^note:' "$a" | head -1 | sed 's/^note: *//')"
    done
    printf '\n'
  fi
} > "$BODY"

TITLE="$BEAN_ID: $BEAN_TITLE"

if [ "$DRY" = 1 ]; then
  printf '\n--- would push %s and open:\n\n' "$BRANCH"
  printf '%s\n\n' "$TITLE"
  cat "$BODY"
  rm -f "$BODY"
  exit 0
fi

# ------------------------------------------------------------ push, then PR --
require_cmd gh
if ! git -C "$ROOT" push -u origin "$BRANCH" 2>&1 | sed 's/^/  /'; then
  rm -f "$BODY"; printf '\nPR FAILED — the push did not succeed\n' >&2; exit 2
fi
ok "push" "$BRANCH -> origin"

DEFAULT_BRANCH="$([ -f "$REPO_CONFIG" ] && "$PIPELINE_DIR/yaml2json.sh" "$REPO_CONFIG" | jq -r '.default_branch // "main"' || echo main)"
URL="$(gh pr create --base "$DEFAULT_BRANCH" --head "$BRANCH" --title "$TITLE" --body-file "$BODY" 2>&1)" || {
  # An existing PR for this branch is not a failure: the run is idempotent and a
  # second attempt must not open a second pull request.
  if printf '%s' "$URL" | grep -qi "already exists"; then
    URL="$(gh pr view "$BRANCH" --json url -q .url 2>/dev/null || printf '%s' "$URL")"
    ok "pr" "already open — not opening a second one"
  else
    rm -f "$BODY"; printf '\nPR FAILED — %s\n' "$URL" >&2; exit 2
  fi
}
rm -f "$BODY"

jq -c --arg url "$URL" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '. + {pr_url: $url, pr_opened_at: $ts, status: "pr_open"}' "$RUN_DIR/run.json" > "$RUN_DIR/run.json.tmp" \
  && mv "$RUN_DIR/run.json.tmp" "$RUN_DIR/run.json"

# The documents themselves, as comments, so a reviewer has them where they are
# reviewing. A failure here does not fail the step: the pull request is open and
# is the deliverable, and a missing comment is visible in a way a missing pull
# request is not.
post_doc() { # post_doc <file> <heading>
  local f="$1" heading="$2" tmp
  [ -f "$f" ] || return 0
  # GitHub caps a comment at 65536 characters. Both documents have run well under
  # that; a longer one is truncated with the fact stated rather than silently.
  tmp="$(mktemp)"
  { printf '## %s\n\n' "$heading"
    if [ "$(wc -c < "$f")" -gt 60000 ]; then
      head -c 60000 "$f"
      printf '\n\n---\n\n*Truncated at 60,000 of %s bytes by GitHub'"'"'s comment limit. The whole\n' "$(wc -c < "$f")"
      printf 'document is `%s` in the run directory.*\n' "$(basename "$f")"
    else
      cat "$f"
    fi
  } > "$tmp"
  if gh pr comment "$URL" --body-file "$tmp" >/dev/null 2>&1; then
    printf '  ok    %-24s posted as a comment (%s bytes)\n' "$(basename "$f")" "$(wc -c < "$f")"
  else
    printf '  warn  %-24s could not be posted; it is in the run directory\n' "$(basename "$f")" >&2
  fi
  rm -f "$tmp"
}
if [ "$DRY" != 1 ]; then
  post_doc "$RUN_DIR/spec.md" "The plan — what this bean set out to do"
  post_doc "$RUN_DIR/impl-detail.md" "What was built — the implementation, explained"
fi

printf '\nPR OPEN  %s\n' "$URL"
printf 'A human merges. This step does not, in any merge mode.\n'
