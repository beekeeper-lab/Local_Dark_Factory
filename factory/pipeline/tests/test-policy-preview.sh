#!/usr/bin/env bash
# test-policy-preview.sh — the tool a risk-policy review happens through.
#
# risk-policy.yaml is a list of globs and tiers, each individually reasonable,
# whose consequences only appear when a real change meets them. Nobody can review
# that by reading it. This table is what a review actually is, so being wrong
# here is worse than being wrong in most places: it does not fail a run, it
# quietly gives a person a false picture of what they are approving.
#
# It has been wrong that way twice. It read a `.matched` field tier.py does not
# emit, so every row said "no rule matched" while showing a tier a rule had
# plainly set; and it cut the reason off mid-word on sixteen of twenty rows.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
eq() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected "%s", got "%s"\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

REPO="$WORK/repo"; git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e.com; git -C "$REPO" config user.name T
mkdir -p "$REPO/factory/beans"
cat > "$REPO/factory/risk-policy.yaml" <<'RP'
schema_version: risk-policy/1.0.0
policy_version: test/2026-09-15
default_tier: 1
repo_allowed_paths:
  - "src/**"
  - "tests/**"
  - "pyproject.toml"
rules:
  - match: "{pyproject.toml,*.lock,requirements*.txt}"
    min_tier: 2
    reason: dependencies change what the gates are running, which is the one change that can make every other check mean less than it looks
  - match: "src/**/solver/**"
    min_tier: 2
    reason: constraint solving — wrong answers are silent, not loud
  - match: ".github/**"
    min_tier: 3
    reason: agent control
RP
bean() { # <id> <title> <suggested-tier> <paths json>
  local d="$REPO/factory/beans/$1-x"; mkdir -p "$d"
  { printf 'schema_version: bean/2.0.0\nid: %s\ntitle: %s\n' "$1" "$2"
    [ "$3" != 0 ] && printf 'suggested_risk_tier: %s\n' "$3"
    printf 'allowed_write_paths:\n'
    printf '%s\n' "$4" | jq -r '.[] | "  - \"" + . + "\""'
  } > "$d/bean.yaml"
}
bean bean-001 "Something quite ordinary that only touches the tests directory" 0 '["tests/**"]'
bean bean-002 "Project scaffold with linting, typing and test gates all at once" 0 '["pyproject.toml","src/**"]'
bean bean-003 "CP-SAT table assignment satisfying every hard constraint there is" 2 '["src/planner/solver/**"]'
bean bean-004 "A bean that asks for more than the policy would give it" 2 '["tests/**"]'
bean bean-005 "A bean reaching outside the repo surface entirely" 0 '["tests/**","infra/deploy.tf"]'
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init

pp() { ( cd "$REPO" && bash "$PIPELINE_DIR/policy-preview.sh" "$@" 2>&1 ); }

# --------------------------------------------------------------------------
printf '\n== every bean, its tier, and the rule that put it there ==\n\n'
out="$(pp)"; rc=$?
rc_is "it succeeds"                    "$rc" 0
check "it names the policy version"    "test/2026-09-15" "$out"
check "and counts the beans"           "5 bean(s)" "$out"

J="$(pp --json)"
eq "an ordinary bean is tier 1"        "1" "$(jq -r '.beans[] | select(.bean=="bean-001") | .tier' <<<"$J")"
eq "a dependency change is tier 2"     "2" "$(jq -r '.beans[] | select(.bean=="bean-002") | .tier' <<<"$J")"
eq "the solver is tier 2"              "2" "$(jq -r '.beans[] | select(.bean=="bean-003") | .tier' <<<"$J")"

printf '\n-- which is not the same question as who decided --\n\n'
#
# A bean at tier 2 because it declares `suggested_risk_tier: 2` is a different
# fact from one the policy put there, and only the second is this policy's doing.
# The whole point of the review is to see what the POLICY does.
eq "the policy bound bean-002"         "policy" \
   "$(jq -r '.beans[] | select(.bean=="bean-002") | .binding_term' <<<"$J")"
eq "the bean bound bean-004 itself"    "bean_suggested" \
   "$(jq -r '.beans[] | select(.bean=="bean-004") | .binding_term' <<<"$J")"
check "and the row says so in words"   "the bean asks for tier 2 itself" "$out"
check "a bean nothing matched says so" "no rule matched — default_tier 1" "$out"

printf '\n-- the reason, which is the thing a reviewer is here to read --\n\n'
#
# It read a `.matched` field tier.py does not emit, so every row said "no rule
# matched" while showing a tier a rule had plainly set. That is the failure mode
# this tool cannot have: a confident table that describes a different policy.
check "the real reason appears"        "dependencies change what the gates are running" "$out"
nope  "not 'no rule matched' for it"   "bean-002   2     Project scaffold with linting, typing and test gates all at once no rule matched" "$out"
eq "and in the JSON too"               "constraint solving — wrong answers are silent, not loud" \
   "$(jq -r '.beans[] | select(.bean=="bean-003") | .bound_by' <<<"$J" | sed 's/  (raised.*//')"

printf '\n-- and it is not cut off mid-word --\n\n'
#
# `${why:0:60}` produced "...are silent, not loud  (ra" on sixteen of twenty real
# rows. A consequence cut off in the middle of a word is a worse review than a
# line that wraps.
check "the long reason is whole"       "which is the one change that can make every other check mean less than it looks" "$out"
# "(ra" is a substring of the correct output too, so the assertion has to be
# that the phrase COMPLETES — which is the thing truncation destroys.
check "and the raised-by note completes" "(raised to 2 by: policy+bean_suggested)" "$out"
# The title is elided, and when it is, on a word boundary with a mark that says so.
check "a long title is elided"         "…" "$out"
nope  "and not mid-word"               "typin…" "$out"

printf '\n-- the columns line up even when a row carries a multi-byte ellipsis --\n\n'
#
# printf's %-44s pads by bytes; one three-byte ellipsis short-padded the column
# by two and stepped the whole table left from that row down.
widths="$(printf '%s\n' "$out" | awk '/^bean-[0-9]/ {print index($0, $3)}' | sort -u | wc -l)"
eq "every row starts its title at the same column" "1" "$widths"

# --------------------------------------------------------------------------
printf '\n== paths outside the repo surface are unreachable, not refused ==\n\n'
#
# The build loop intersects a bean's paths with repo_allowed_paths, so a path
# outside it is silently dropped: the bean fails to do its job and the reason is
# not in any error message. This is the only place it is visible before a run.
check "the stray path is reported"     "infra/deploy.tf" "$out"
check "and what it means is explained" "unreachable rather than refused" "$out"
eq "the JSON carries it too"           "infra/deploy.tf" \
   "$(jq -r '.beans[] | select(.bean=="bean-005") | .outside_repo_surface[0]' <<<"$J")"

# --------------------------------------------------------------------------
printf '\n== what the tiers add up to ==\n\n'
check "the tier histogram is shown"    "by tier:" "$out"
check "and who set them"               "who set the tier:" "$out"
# No bean here reaches tier 3, and the tool is supposed to say so rather than let
# a reader assume the tier-3 rules were exercised.
check "an unreached tier 3 is called out" "never fire for this corpus" "$out"
check "with the doubt named"           "written against paths this repo does not have" "$out"

printf '\n-- and the caveat that makes the numbers honest --\n\n'
check "the upper bound is stated"      "Tiers are an upper bound here" "$out"
check "and its direction"              "None can come out lower" "$out"

# --------------------------------------------------------------------------
printf '\n== refusals ==\n\n'
out="$(pp --policy "$WORK/nope.yaml")"; rc=$?
rc_is "a missing policy refuses"       "$rc" 1
check "and says where it looked"       "no risk policy at" "$out"
out="$(pp --beans "$WORK/nope")"; rc=$?
rc_is "a missing beans dir refuses"    "$rc" 1
check "and says so"                    "no beans directory at" "$out"
out="$(pp --nonsense 2>&1)"; rc=$?
rc_is "an unknown flag refuses"        "$rc" 1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
