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

HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
if [ -z "$VERDICT_FILE" ]; then
  bad "verdict" "no package or impl verdict — nothing authorises this PR"
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
TIER="$(jq -r '.effective_risk_tier' <<<"$V")"
BODY="$(mktemp)"
{
  printf '## %s — %s\n\n' "$BEAN_ID" "$BEAN_TITLE"
  jq -r '.intent' <<<"$BEAN_JSON"
  printf '\n\n**Nothing in this pull request was written by a human.** It was planned, built,\n'
  printf 'documented and audited by local models under `factory/`, and audited by a\n'
  printf 'different model family than the one that wrote it. Read the two documents\n'
  printf 'before the diff — they are the point.\n\n'

  printf '### Documents\n\n'
  for pair in "The plan:spec.html" "What was built:impl-detail.html"; do
    label="${pair%%:*}"; f="${pair#*:}"
    [ -f "$RUN_DIR/$f" ] && printf -- '- %s — `%s`\n' "$label" "$(realpath --relative-to="$ROOT" "$RUN_DIR/$f")"
  done
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
  [ "$found" = 0 ] && printf 'Nothing. Every audit was clean.\n'

  printf '\n### Gates\n\n'
  if [ -f "$RUN_DIR/gate.json" ]; then
    jq -r '.gates[]? | "- `\(.id)` \(.status)"' "$RUN_DIR/gate.json"
    jq -r '.acceptance_criteria[]? | "- `\(.id)` \(.status) — \(.command // "")"' "$RUN_DIR/gate.json"
    if [ "$(jq -r '.invariants // "null"' "$RUN_DIR/gate.json")" != "null" ]; then
      printf -- '- independent invariants: %s (`%s`)\n' \
        "$(jq -r '.invariants.status' "$RUN_DIR/gate.json")" "$(jq -r '.invariants.ref' "$RUN_DIR/gate.json")"
    fi
  fi

  printf '\n### Provenance\n\n'
  printf '| | |\n|---|---|\n'
  printf '| base | `%s` |\n' "$(jq -r '.base_sha' <<<"$V")"
  printf '| candidate | `%s` |\n' "$(jq -r '.candidate_sha' <<<"$V")"
  printf '| diff sha256 | `%s` |\n' "$(jq -r '.diff_sha256' <<<"$V")"
  printf '| binding tier | %s |\n' "$TIER"
  printf '| gate image | `%s` |\n' "$(jq -r '.gate_manifest_digest' <<<"$V")"
  printf '| risk policy | `%s` |\n' "$(jq -r '.policy_version' <<<"$V")"
  printf '| judge | `%s`, prompt `%s` |\n' "$(jq -r '.model_digest' <<<"$V")" "$(jq -r '.prompt_version' <<<"$V")"

  # The documents, by hash.
  #
  # verdict.schema.json says the artifacts array exists "so the PR can prove
  # which version was audited", and audit-check has been stamping it all along —
  # but it stopped there, in a file nobody opens. The two documents linked at the
  # top of this pull request are rendered from Markdown that is not committed
  # anywhere, so without this a reviewer has the judge's word that it audited
  # something, and no way to tell whether it is what they are reading.
  if [ "$(jq -r '[.artifacts[]?] | length' <<<"$V")" -gt 0 ]; then
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
    printf 'This run was made with **advisory audits**: the judge ran, wrote a judgement\n'
    printf 'and the controller stamped a verdict from it, but a verdict short of accept\n'
    printf 'did not stop the run. Every deterministic check stayed blocking.\n\n'
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

printf '\nPR OPEN  %s\n' "$URL"
printf 'A human merges. This step does not, in any merge mode.\n'
