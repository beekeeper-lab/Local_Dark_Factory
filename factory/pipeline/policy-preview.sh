#!/usr/bin/env bash
# policy-preview.sh — what the risk policy actually does to this repo's beans.
#
# risk-policy.yaml has been waiting on a human read since Phase 0, and it is the
# kind of document that is hard to review by reading: a list of globs and tiers,
# each individually reasonable, whose consequences only appear when a real change
# meets them. The question a reviewer actually wants answered is not "is this glob
# right" but "which of my beans will need a human, and which will not".
#
# So this answers that. Every approved bean, the tier its declared write paths
# land in, and which rule bound it. A policy review becomes reading one table and
# disagreeing with specific rows.
#
# It computes tiers with the same tier.py the gate uses, so this cannot drift into
# describing a policy the line does not apply. The one thing it cannot know is
# what the diff will really touch — a bean's declared paths are an upper bound,
# and the gate recomputes from the actual diff. A bean shown here as tier 1 can
# still come out higher; it can never come out lower.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
policy-preview.sh — the tier every bean lands in, and the rule that put it there.

usage: policy-preview.sh [--policy <file>] [--beans <dir>] [--json]

Defaults to factory/risk-policy.yaml and factory/beans/ in the current repo.
EOF
}

POLICY=""; BEANS=""; AS_JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --policy) POLICY="${2:?}"; shift 2 ;;
    --beans)  BEANS="${2:?}"; shift 2 ;;
    --json)   AS_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

ROOT="$(repo_root)"
[ -n "$POLICY" ] || POLICY="$ROOT/factory/risk-policy.yaml"
[ -n "$BEANS" ]  || BEANS="$ROOT/factory/beans"
[ -f "$POLICY" ] || die "no risk policy at $POLICY"
[ -d "$BEANS" ]  || die "no beans directory at $BEANS"

PY="$(factory_python)"
POLICY_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$POLICY")" || die "cannot read $POLICY"
POLICY_TMP="$(mktemp)"; printf '%s' "$POLICY_JSON" > "$POLICY_TMP"
trap 'rm -f "$POLICY_TMP"' EXIT

ALLOWED="$(jq -c '.repo_allowed_paths // []' <<<"$POLICY_JSON")"
DEFAULT_TIER="$(jq -r '.default_tier // 1' <<<"$POLICY_JSON")"

ROWS='[]'
for d in "$BEANS"/*/; do
  b="$d/bean.yaml"
  [ -f "$b" ] || continue
  bj="$("$PIPELINE_DIR/yaml2json.sh" "$b" 2>/dev/null)" || continue
  id="$(jq -r '.id // empty' <<<"$bj")"
  [ -n "$id" ] || continue
  title="$(jq -r '.title // ""' <<<"$bj")"
  paths="$(jq -c '.allowed_write_paths // []' <<<"$bj")"
  bean_tier="$(jq -r '.suggested_risk_tier // 0' <<<"$bj")"

  # A bean's paths are globs, and tier.py matches concrete paths. Expand each
  # glob to a representative path so the rules see something they can match:
  # "src/**" becomes "src/x", which is what any file under it would look like.
  probe="$(jq -c '[ .[] | sub("\\*\\*/\\*"; "x") | sub("/\\*\\*$"; "/x") | sub("\\*\\*"; "x") | sub("\\*"; "x") ]' <<<"$paths")"

  res="$("$PY" "$PIPELINE_DIR/tier.py" --policy "$POLICY_TMP" --paths "$probe" \
        --bean-tier "$bean_tier" --json 2>/dev/null)" || res='{}'
  final="$(jq -r '.final_tier // empty' <<<"$res")"
  # The reasons come from `.paths[]`, and only from the paths that actually
  # matched a rule — the first version read a `.matched` field tier.py does not
  # emit, so every row said "no rule matched" while showing a tier that a rule
  # had clearly set. And the binding term matters as much as the reason: a bean
  # at tier 2 because it declares `suggested_risk_tier: 2` is a different fact
  # from one the policy put there, and only the second is this policy's doing.
  why="$(jq -r '[.paths[]? | select(.rule != null) | .reason] | unique | join("; ")' <<<"$res" 2>/dev/null)"
  binding="$(jq -r '(.binding_term // []) | join("+")' <<<"$res" 2>/dev/null)"
  if [ -z "$why" ]; then
    if [ "$binding" = "bean_suggested" ]; then
      why="the bean asks for tier $final itself; no policy rule matched"
    else
      why="no rule matched — default_tier $DEFAULT_TIER"
    fi
  elif [ "$binding" != "policy" ]; then
    why="$why  (raised to $final by: $binding)"
  fi

  # Which of the bean's paths fall outside the repo's approved surface? The
  # build loop intersects them, so these are silently unreachable rather than
  # refused, and a bean whose whole surface is outside cannot do anything.
  outside="$(printf '%s\n' "$(jq -r '.[]' <<<"$paths")" \
    | "$PY" "$PIPELINE_DIR/contain.py" --patterns "$ALLOWED" 2>/dev/null | tr '\n' ' ')"

  ROWS="$(jq -c --arg id "$id" --arg t "$title" --argjson tier "${final:-1}" \
    --arg why "$why" --argjson paths "$paths" --arg outside "$outside" \
    --arg binding "$binding" \
    '. + [{bean:$id, title:$t, tier:$tier, bound_by:$why, binding_term:$binding, write_paths:$paths,
           outside_repo_surface:($outside | split(" ") | map(select(. != "")))}]' <<<"$ROWS")"
done

if [ "$AS_JSON" = 1 ]; then
  jq -n --argjson r "$ROWS" --arg policy "$(jq -r '.policy_version // "?"' <<<"$POLICY_JSON")" \
    '{schema:"policy-preview/1.0.0", policy_version:$policy, beans:$r}'
  exit 0
fi

printf '\nrisk policy %s — what it does to %s bean(s)\n\n' \
  "$(jq -r '.policy_version // "?"' <<<"$POLICY_JSON")" "$(jq 'length' <<<"$ROWS")"
# Truncate on a word boundary, and say that you did.
#
# `${why:0:60}` cut the reason a bean got its tier mid-word — "constraint solving
# — wrong answers are silent, not loud  (ra" — on sixteen of twenty rows. This
# table exists to let a person review a risk policy by its consequences, and a
# consequence cut off in the middle of a word is a worse review than a longer
# line. An ellipsis at least says the sentence continues.
elide() { # elide <text> <budget>
  local t="$1" n="$2"
  [ "${#t}" -le "$n" ] && { printf '%s' "$t"; return; }
  local cut="${t:0:$((n - 1))}"
  # Back up to the last space, unless that throws away more than a third of it.
  local trimmed="${cut% *}"
  [ "${#trimmed}" -ge $(((n - 1) * 2 / 3)) ] && cut="$trimmed"
  printf '%s…' "$cut"
}
# Pad by characters, not bytes. printf's %-44s counts bytes, so one multi-byte
# ellipsis short-pads the column by two and the whole table steps left.
pad() { # pad <text> <width>
  local t="$1" n="$2" i=0
  printf '%s' "$t"
  while [ $((${#t} + i)) -lt "$n" ]; do printf ' '; i=$((i + 1)); done
}
printf '%-10s %-5s %-44s %s\n' BEAN TIER TITLE BOUND-BY
# BOUND-BY is not truncated. It is the reason a bean lands where it does, and it
# is the entire thing a person is here to read; a long line that wraps costs
# nothing, and "(raised to…" costs the review.
jq -r '.[] | [.bean, (.tier|tostring), .title, .bound_by] | @tsv' <<<"$ROWS" \
  | while IFS=$'\t' read -r id tier title why; do
      printf '%s %s %s %s\n' "$(pad "$id" 10)" "$(pad "$tier" 5)" "$(pad "$(elide "$title" 42)" 44)" "$why"
    done

printf '\nwho set the tier: '
jq -r 'group_by(.binding_term) | map("\(.[0].binding_term // "default")→\(length)") | join("   ")' <<<"$ROWS"
printf '\nby tier: '
jq -r 'group_by(.tier) | map("\(.[0].tier)→\(length) bean(s)") | join("   ")' <<<"$ROWS"

stray="$(jq -r '[.[] | select((.outside_repo_surface | length) > 0) | "\(.bean): \(.outside_repo_surface | join(", "))"] | .[]' <<<"$ROWS")"
if [ -n "$stray" ]; then
  printf '\nPaths a bean declares that are OUTSIDE repo_allowed_paths. The build loop\n'
  printf 'intersects, so these are unreachable rather than refused — a bean that needs\n'
  printf 'one of them will fail to do its job and the reason will not be obvious:\n\n'
  printf '%s\n' "$stray" | sed 's/^/  /'
fi

# The rules that never fire are as worth seeing as the ones that do: a tier-3
# rule nothing reaches is either correct (this repo has no deploy/) or a rule
# written against paths that do not exist here, and only a person can tell which.
UNUSED="$(jq -r --argjson rows "$ROWS" \
  '[.rules[]?.reason] - ($rows | map(.bound_by))' <<<"$POLICY_JSON" 2>/dev/null \
  | jq -r '.[]?' 2>/dev/null)"
HIGHEST="$(jq -r '[.[].tier] | max' <<<"$ROWS")"
if [ "${HIGHEST:-0}" -lt 3 ]; then
  printf '\nNo bean in this set reaches tier 3, so the never-auto-merged rules — agent\n'
  printf 'control, secrets, infrastructure — never fire for this corpus. That is either\n'
  printf 'correct (no bean writes those paths, and none should) or it means those rules\n'
  printf 'are written against paths this repo does not have. Worth one look.\n'
fi

printf '\nWhat to check, as the human this policy is waiting on:\n'
printf '  · does any tier-1 row describe work you would want to read before it merges?\n'
printf '  · does any tier-3 row describe work so routine that gating it will be ignored?\n'
printf '  · is repo_allowed_paths the surface you meant to open?\n'
printf '\nTiers are an upper bound here: the gate recomputes from the real diff, and a\n'
printf 'bean shown as 1 can come out higher. None can come out lower.\n\n'
