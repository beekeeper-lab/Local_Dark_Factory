#!/usr/bin/env bash
# test-preflight.sh — the first gate, which had no tests of its own.
#
# It was exercised only through the full line, where it passes; nothing ever
# asserted that it REFUSES. That is the wrong half to leave untested — a
# preflight that always passes is indistinguishable from one that works, right up
# until the run it should have stopped.
#
# Two of its checks exist because they had already failed silently once: the
# bean.yaml lookup used the wrong variable name and never ran at all, and the
# role-thinking tripwire was guarded by a file test that would have deleted the
# tripwire the day pi moved its catalog. Both are asserted here as refusals.
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
rc_is() {
  if [ "$2" = "$3" ]; then printf '  ok    %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  FAIL  %s — expected exit %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# ---------------------------------------------------------------- fixtures --
ORIGIN="$WORK/origin.git"; git init -q --bare -b main "$ORIGIN"
REPO="$WORK/repo"; git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e.com; git -C "$REPO" config user.name T

mkdir -p "$REPO/factory/beans/bean-001-a-thing"
cat > "$REPO/factory/pipeline-config.json" <<'CFG'
{
  "runs_root": "factory/runs",
  "bean_dir_pattern": "factory/beans/BEAN-NNN-<slug>",
  "bean_index_path": "factory/beans/INDEX.md",
  "branch_pattern": "bean/BEAN-NNN-<slug>"
}
CFG
# The real index's column order, not an invented one: scaffold.sh writes ID
# first and Status fifth, and preflight's awk reads exactly those positions. A
# fixture with an extra leading column made every bean look unapproved, which is
# a test failing for a reason the code does not have.
cat > "$REPO/factory/beans/INDEX.md" <<'IDX'
# Beans — fixture

| ID | Title | Tier | Approved by | Status |
|---|---|---|---|---|
| bean-001 | A thing | full | The Operator | Approved |
| bean-002 | Another | full | The Operator | Draft |
IDX
cat > "$REPO/factory/beans/bean-001-a-thing/bean.yaml" <<'BEAN'
schema_version: bean/2.0.0
id: bean-001
title: A thing
acceptance_criteria:
  - id: ac1
    text: it works
  - id: ac2
    text: it keeps working
definition_of_done:
  - ac1
  - ac2
BEAN
printf 'x\n' > "$REPO/keep.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m init
git -C "$REPO" remote add origin "$ORIGIN" && git -C "$REPO" push -q origin main

# pi's model catalog, and roles.json pointing at it. Both are read by the
# role-thinking tripwire, which must refuse rather than skip when either is off.
cat > "$WORK/pi-models.json" <<'PM'
{"providers": {"ollama": {"models": [
  {"id": "dev-model:latest", "reasoning": true},
  {"id": "judge-model:latest", "reasoning": true},
  {"id": "no-reasoning:latest", "reasoning": false}
]}}}
PM
cat > "$WORK/roles.json" <<'RJ'
{"provider_allowlist": ["ollama"],
 "roles": {
   "developer": {"provider": "ollama", "model": "dev-model:latest", "thinking": "medium"},
   "judge": {"provider": "ollama", "model": "judge-model:latest", "thinking": "high"}}}
RJ

pf() { # <bean-id> [env overrides applied by caller]
  ( cd "$REPO" && PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
    PI_MODELS_JSON="${PI_MODELS_OVERRIDE:-$WORK/pi-models.json}" \
    bash "$PIPELINE_DIR/preflight.sh" "$@" 2>&1 )
}
# roles.json is read from beside preflight.sh, so a fixture roles file means
# running against a copy of the pipeline directory.
#
# Guarded, because a computed path handed to `cp -r` is a loaded weapon. A debug
# copy of this file placed in /tmp made `dirname/..` resolve to `/`, and the copy
# duly recursed into /proc until a 63G tmpfs was full — at which point every
# write on the box started failing with "Unknown system error -122", including
# the live doc session, which looked for all the world like a model failure.
[ -f "$PIPELINE_DIR/preflight.sh" ] && [ -f "$PIPELINE_DIR/roles.json" ] || {
  printf 'FATAL: PIPELINE_DIR is %s, which is not the pipeline. Refusing to copy it.\n' "$PIPELINE_DIR"
  exit 1
}
PIPE_COPY="$WORK/pipeline"; cp -r "$PIPELINE_DIR" "$PIPE_COPY"
cp "$WORK/roles.json" "$PIPE_COPY/roles.json"
pfc() {
  ( cd "$REPO" && PIPELINE_CONFIG="$REPO/factory/pipeline-config.json" \
    PI_MODELS_JSON="${PI_MODELS_OVERRIDE:-$WORK/pi-models.json}" \
    bash "$PIPE_COPY/preflight.sh" "$@" 2>&1 )
}

# --------------------------------------------------------------------------
printf '\n== a repository that is ready ==\n\n'
out="$(pfc bean-001)"; rc=$?
rc_is "it passes"                      "$rc" 0
check "the tree is checked"            "PASS  clean-tree" "$out"
check "the branch is checked"          "PASS  on-main" "$out"
check "currency is checked"            "PASS  up-to-date" "$out"
check "approval is checked"            "PASS  bean-approved" "$out"
check "the definition of done too"     "PASS  definition-of-done" "$out"
check "and no branch exists yet"       "PASS  no-branch" "$out"
check "and every thinking role can think" "PASS  role-thinking" "$out"
check "it says so at the end"          "all checks passed for bean-001" "$out"

# --------------------------------------------------------------------------
printf '\n== every refusal, which is the half that was never tested ==\n\n'

printf 'uncommitted\n' > "$REPO/keep.txt"
out="$(pfc bean-001)"; rc=$?
rc_is "a dirty tree refuses"           "$rc" 1
check "and shows what is dirty"        "keep.txt" "$out"
git -C "$REPO" checkout -q -- keep.txt

git -C "$REPO" checkout -q -b somewhere-else
out="$(pfc bean-001)"; rc=$?
rc_is "being off main refuses"         "$rc" 1
check "and names the branch"           "current branch is 'somewhere-else'" "$out"
git -C "$REPO" checkout -q main && git -C "$REPO" branch -q -D somewhere-else

# Someone lands on main while this repo's copy sits still.
SEED="$WORK/seed"; git clone -q "$ORIGIN" "$SEED"
git -C "$SEED" config user.email t@e.com; git -C "$SEED" config user.name T
printf 'theirs\n' > "$SEED/theirs.txt"
git -C "$SEED" add -A && git -C "$SEED" commit -q -m "someone else" && git -C "$SEED" push -q origin main
out="$(pfc bean-001)"; rc=$?
rc_is "a stale main refuses"           "$rc" 1
check "and counts the commits"         "1 commit(s) behind origin/main" "$out"
git -C "$REPO" pull -q --ff-only origin main

out="$(pfc bean-002)"; rc=$?
rc_is "a bean that is not approved refuses" "$rc" 1
check "and says what status it has"    "status is 'Draft'" "$out"

out="$(pfc bean-404)"; rc=$?
rc_is "a bean not in the index refuses" "$rc" 1
check "and says where it looked"       "INDEX.md" "$out"

out="$(pfc not-a-bean 2>&1)"; rc=$?
rc_is "a malformed id refuses"         "$rc" 1
check "before anything else happens"   "bean id must look like bean-NNN" "$out"

git -C "$REPO" branch -q "bean/bean-001-a-thing"
out="$(pfc bean-001)"; rc=$?
rc_is "an existing bean branch refuses" "$rc" 1
check "and names it"                   "bean/bean-001-a-thing" "$out"
git -C "$REPO" branch -q -D "bean/bean-001-a-thing"

# --------------------------------------------------------------------------
printf '\n== the two checks that had already failed silently once ==\n\n'
#
# The bean.yaml lookup used $ROOT where the file defines $root, so it died on an
# unbound variable and the whole definition-of-done block never ran — a check
# that reports nothing and looks fine. What survives that bug is the explicit
# refusal when no bean.yaml is found, rather than a quietly skipped block.
mv "$REPO/factory/beans/bean-001-a-thing/bean.yaml" "$WORK/bean.yaml.bak"
git -C "$REPO" commit -qam "no bean.yaml"
out="$(pfc bean-001)"; rc=$?
rc_is "a bean with no bean.yaml refuses" "$rc" 1
check "rather than skipping the check"  "its machine-readable form is missing" "$out"
nope  "and does not claim to have run it" "PASS  definition-of-done" "$out"
mv "$WORK/bean.yaml.bak" "$REPO/factory/beans/bean-001-a-thing/bean.yaml"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "bean.yaml back"

printf '\n-- a dangling criterion id in definition_of_done --\n\n'
python3 - "$REPO/factory/beans/bean-001-a-thing/bean.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("  - ac2\n", "  - ac2\n  - ac7\n")
open(p, "w").write(s)
PY
# Commit it. clean-tree runs first and would otherwise shadow every check below
# — which is correct behaviour, and exactly what it did to twenty assertions in
# the first run of this file.
git -C "$REPO" commit -qam "a dangling criterion id"
out="$(pfc bean-001)"; rc=$?
rc_is "it refuses"                     "$rc" 1
check "and names the dangling id"      "ac7" "$out"
check "and calls it what it is"        "dangling reference" "$out"

printf '\n-- but prose in the same field is left alone --\n\n'
#
# The first version of this check treated every entry as an id and would have
# failed all twenty beans in the corpus, which use the field the way the schema
# permits: `items: {type: string}`, no pattern, a sentence inside.
python3 - "$REPO/factory/beans/bean-001-a-thing/bean.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("  - ac7\n", "  - all AC verify pass, gates green, both documents accepted\n")
open(p, "w").write(s)
PY
git -C "$REPO" commit -qam "prose in definition_of_done"
out="$(pfc bean-001)"; rc=$?
rc_is "a prose definition of done passes" "$rc" 0
check "and the check still ran"        "PASS  definition-of-done" "$out"

printf '\n-- the role-thinking tripwire cannot skip itself --\n\n'
#
# An earlier version guarded the whole block with a file test, so a pi upgrade
# that moved the catalog would have made the tripwire vanish while preflight kept
# printing PASS — the exact scenario it was written for.
out="$(PI_MODELS_OVERRIDE="$WORK/nowhere.json" pfc bean-001)"; rc=$?
rc_is "a missing catalog refuses"      "$rc" 1
check "and says the catalog is gone"   "pi model catalog not found" "$out"
check "and what that would hide"       "pi disables thinking silently" "$out"
check "and how to point it elsewhere"  "PI_MODELS_JSON" "$out"

printf '\n-- a role that declares thinking on a model that cannot think --\n\n'
python3 - "$PIPE_COPY/roles.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["roles"]["judge"]["model"] = "no-reasoning:latest"
json.dump(d, open(p, "w"))
PY
out="$(pfc bean-001)"; rc=$?
rc_is "it refuses"                     "$rc" 1
check "it names the role"              "role 'judge'" "$out"
check "and what pi would do"           "silently run it with thinking off" "$out"
check "and why that is worse than nothing" "while the run record claims otherwise" "$out"

printf '\n-- a role on a model pi has never heard of --\n\n'
python3 - "$PIPE_COPY/roles.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["roles"]["judge"]["model"] = "never-heard-of-it:latest"
json.dump(d, open(p, "w"))
PY
out="$(pfc bean-001)"; rc=$?
rc_is "it refuses"                     "$rc" 1
check "and says pi would substitute"   "fall back to a default model" "$out"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
