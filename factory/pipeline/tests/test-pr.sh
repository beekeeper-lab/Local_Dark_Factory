#!/usr/bin/env bash
# test-pr.sh — what has to be true before a pull request exists.
#
# The preconditions are the whole value of this step. A PR opened without them is
# a PR that says "three models agreed" when they did not, and a reviewer has no
# way to tell the difference from the outside.
#
# `gh` is stubbed. The point is not that GitHub works; it is that the controller
# refuses when it should, opens exactly one PR when it should, and never merges.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nocheck() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}

# A gh that records what it was asked to do, so the test can assert on the verbs.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "pr create")
    # Keep the body. Assertions about what a reviewer will actually see need the
    # file, not the flag that named it — and the file is a mktemp that pr.sh
    # removes on its way out.
    for _i in $(seq 1 $#); do
      if [ "${!_i}" = "--body-file" ]; then
        _j=$((_i + 1)); cp "${!_j}" "$GH_BODY" 2>/dev/null || true
      fi
    done
    if [ -f "$GH_EXISTING" ]; then echo "a pull request for branch already exists"; exit 1; fi
    : > "$GH_EXISTING"
    echo "https://github.com/example/x/pull/1"
    ;;
  "pr view") echo "https://github.com/example/x/pull/1" ;;
  "pr comment") : ;;
  *) exit 0 ;;
esac
GH
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
export GH_CALLS="$WORK/gh-calls.txt"
export GH_BODY="$WORK/last-body"
export GH_EXISTING="$WORK/gh-existing"

git init -q --bare "$WORK/origin.git"
REPO="$WORK/repo"; git init -q -b main "$REPO"; cd "$REPO"
git config user.email t@e.com; git config user.name T
git remote add origin "$WORK/origin.git"
mkdir -p factory/beans src factory/runs/R/verdicts
cat > factory/repo.yaml <<'YAML'
schema_version: repo-config/1.0.0
repo: example/x
default_branch: main
host: github
merge_mode: human_required
max_inflight: 1
policy_ref: factory/risk-policy.yaml
gates_ref: factory/gates.lock.yaml
YAML
cat > factory/beans/bean.yaml <<'YAML'
schema_version: bean/2.0.0
id: bean-001
repo: example/x
title: A bean that reached a pull request
intent: Prove the last stage refuses when it should.
status: approved
allowed_write_paths: ["src/**"]
acceptance_criteria:
  - id: ac1
    text: a exists
    verify: { kind: command, run: ["true"] }
definition_of_done: ["ac1"]
YAML
echo readme > README.md
# A scaffolded repo keeps run directories out of the index; the fixture does too,
# or it would be testing a repo the line never produces.
printf 'factory/runs/\n' > .gitignore
git add -A && git commit -q -m init
git push -q -u origin main
git checkout -q -b bean/bean-001
echo 'print(1)' > src/a.py
git add -A && git commit -q -m work
HEAD_SHA="$(git rev-parse HEAD)"
BASE_SHA="$(git rev-parse main)"

R=factory/runs/R
cat > $R/run.json <<JSON
{"run_id":"R","bean":"bean-001","branch":"bean/bean-001","status":"running"}
JSON
cat > $R/gate.json <<'JSON'
{"overall":"pass","gates":[{"id":"lint","status":"pass"}],
 "acceptance_criteria":[{"id":"ac1","status":"pass","command":"true"}],
 "invariants":null}
JSON
verdict() { # verdict <verdict-word> <candidate-sha>
  cat > $R/verdicts/package.attempt-1.json <<JSON
{"schema_version":"verdict/2.0.0","stage":"impl_audit","bean_id":"bean-001",
 "base_sha":"$BASE_SHA","candidate_sha":"$2","diff_sha256":"$(printf a%.0s {1..64})",
 "gate_run_id":"g","gate_manifest_digest":"sha256:$(printf b%.0s {1..64})",
 "invariants_digest":"sha256:$(printf c%.0s {1..64})","policy_version":"p/1",
 "effective_risk_tier":1,"model_digest":"abc","prompt_version":"factory-audit@x",
 "artifacts":[{"kind":"spec","path":"factory/runs/R/spec.md","sha256":"$(printf c%.0s {1..64})"}],
 "criteria":[{"id":"ac1","met":true,"evidence":"e"}],"verdict":"$1"}
JSON
}
cat > $R/verdicts/package.attempt-1.judgement.json <<'JSON'
{"verdict":"accept","findings":[{"severity":"minor","summary":"the scaffold test is thin but real"}]}
JSON
printf '<html>spec</html>' > $R/spec.html
printf '<html>impl</html>' > $R/impl-detail.html
# The Markdown too: it is what gets posted as a comment, and a fixture carrying
# only the rendered HTML made the body silently omit both documents.
printf '# Spec\n\nThe plan, in the form a reviewer reads.\n' > $R/spec.md
printf '# What was built\n\nThe implementation, explained.\n' > $R/impl-detail.md

pr() { bash "$PIPELINE_DIR/pr.sh" factory/runs/R --bean factory/beans/bean.yaml "$@" 2>&1; }

printf '\n== it refuses without an accepting verdict ==\n\n'
verdict revise "$HEAD_SHA"
out="$(pr)"; rc=$?
check "a revise does not open a PR"  "only an accept opens a PR" "$out"
want  "and it exits 1"               "expected 1" test "$rc" -eq 1
want  "nothing was pushed"           "gh must not have been called" test ! -s "$GH_CALLS"

printf '\n== it refuses when the audit judged a different commit ==\n\n'
verdict accept "$(printf '0%.0s' {1..40})"
out="$(pr)"
check "a moved HEAD is caught"       "the audit did not see what would be pushed" "$out"

printf '\n== it refuses on an ungated change, a dirty tree, and open questions ==\n\n'
verdict accept "$HEAD_SHA"
mv $R/gate.json "$WORK/gate.away"
out="$(pr)"
check "no gate.json is refused"      "the change was never gated" "$out"
mv "$WORK/gate.away" $R/gate.json

printf 'stray\n' > src/uncommitted.py
out="$(pr)"
check "a dirty tree is refused"      "uncommitted changes would not be in the PR" "$out"
rm -f src/uncommitted.py

printf '# something asked for a human\n' > $R/QUESTIONS.md
out="$(pr)"
check "an open QUESTIONS.md is refused" "asked for a human and never got one" "$out"
rm -f $R/QUESTIONS.md

printf '\n== advisory audits: no verdict, and a pull request that says so ==\n\n'
#
# The judge is measured as not reproducible on identical input at temperature 0,
# so this line runs with FACTORY_ADVISORY_AUDITS: verdicts recorded, not binding.
# That collides with the rule above — a PR needs an accepting verdict on the exact
# candidate — and in advisory mode there is none to have. The first real run to
# reach this step halted here, at stage ten of ten.
#
# The resolution is not to relax the rule. In advisory mode a DIFFERENT set of
# things authorises the PR, all of them deterministic: the gate passed on this
# candidate, the package record is internally consistent, the document exists, and
# every audit that reached no verdict left a record saying why.
rm -f $R/verdicts/package.attempt-1.json $R/verdicts/impl.attempt-1.json
# The judgement too: with no verdict there is nothing that stamped one, and the
# "what the audits saw" section has to be right about that.
mv $R/verdicts/package.attempt-1.judgement.json "$WORK/judgement.away"
rm -f "$GH_CALLS"

printf -- '-- with nothing recorded, it still refuses --\n\n'
out="$(pr)"; rc=$?
check "no verdict and no reason refuses" "no advisory record explaining the absence" "$out"
want  "and nothing was pushed"           "gh must not have been called" test ! -s "$GH_CALLS"

printf -- '\n-- with the advisory records, it opens one, loudly --\n\n'
mkdir -p $R/failed-attempts
for t in spec impl doc package; do
  printf 'step: audit-%s\nmode: advisory — this did NOT stop the run\nnote: the judge produced no judgement\n' \
    "$t" > "$R/failed-attempts/audit-$t.advisory.1"
done
printf '{"internally_consistent":true}\n' > $R/package-check.json
printf '{"status":"pass"}\n' > $R/doc-check.json
out="$(pr)"; rc=$?
if [ "$rc" -ne 0 ]; then
  printf '  --- pr.sh refused; its output ---\n'
  sed 's/^/  | /' <<<"$out" | tail -25
  printf '  --- end ---\n'
fi
want  "it opens the pull request"        "expected exit 0, got $rc" test "$rc" -eq 0
check "the absent verdict is stated"     "audits ran advisory" "$out"
check "the package record stands in"     "ok    package record" "$out"
check "and so does the document"         "ok    document" "$out"

body="$(cat "$WORK/last-body" 2>/dev/null || true)"
check "the warning leads the body"       "No audit verdict authorises this pull request" "$body"
check "it names which audits"            "reached no verdict for" "$body"
check "and why, without excusing it"     "not reproducible on identical input" "$body"
check "it says what did authorise it"    "What *did* authorise it is deterministic" "$body"
check "and tells the reviewer their job" "Read the two documents and the diff yourself" "$body"
if grep -qF 'Every audit was clean' <<<"$body"; then
  printf '  FAIL  it must not claim a clean audit when none reached a verdict\n'; FAIL=$((FAIL+1))
else
  printf '  ok    it does not claim a clean audit\n'; PASS=$((PASS+1))
fi
check "an absence is called an absence"  "an absence of findings, not a clean bill" "$body"
check "provenance says what authorised"  "the deterministic record; no judge verdict" "$body"
check "and the candidate is still named" "$HEAD_SHA" "$body"

rm -rf $R/failed-attempts $R/package-check.json $R/doc-check.json
mv "$WORK/judgement.away" $R/verdicts/package.attempt-1.judgement.json
verdict accept "$HEAD_SHA"
rm -f "$GH_CALLS"

printf '\n== it refuses to open a PR from main ==\n\n'
# No `git stash -u` here: the run directory is untracked, and stashing would
# sweep it away — the test would then be checking that pr.sh rejects a missing
# run dir, which is a different thing entirely.
git checkout -q main
out="$(pr)"
check "main is refused"              "never from main" "$out"
git checkout -q bean/bean-001

printf '\n== with every precondition met, it opens exactly one PR ==\n\n'
out="$(pr)"; rc=$?
check "the PR is opened"             "PR OPEN" "$out"
want  "and it exits 0"               "expected 0" test "$rc" -eq 0
calls="$(cat "$GH_CALLS")"
check "gh pr create was called"      "pr create" "$calls"
check "against the default branch"   "--base main" "$calls"
nocheck "it never merges"            "pr merge" "$calls"
nocheck "and never auto-merges"      "--auto" "$calls"
check "the run records the PR"       '"status":"pr_open"' "$(tr -d ' ' < $R/run.json)"
# And the two documents went with it. The body names them; these put them where
# the reviewer is. Asserted on a real invocation, not a --dry-run, which posts
# nothing by design.
want  "the plan was posted"          "gh pr comment should have been called for each document" \
      test "$(grep -c 'pr comment' "$GH_CALLS")" -eq 2
check "and the step says so"         "spec.md" "$out"
check "with the other one too"       "impl-detail.md" "$out"

printf '\n== a second run does not open a second PR ==\n\n'
out="$(pr)"
check "an existing PR is recognised" "already open — not opening a second one" "$out"
n="$(grep -c "pr create" "$GH_CALLS")"
want "only one create was attempted per run" "expected 2 attempts, one per invocation" test "$n" -eq 2

printf '\n== the body carries what a reviewer needs ==\n\n'
body="$(bash "$PIPELINE_DIR/pr.sh" factory/runs/R --bean factory/beans/bean.yaml --dry-run 2>&1)"
check "it says no human wrote it"    "Nothing in this pull request was written by a human" "$body"
# The body used to link `factory/runs/<run>/spec.html`, which is gitignored, so
# the links were dead for everyone except someone sitting at the machine that
# built the branch. The documents are posted as comments now, and the body says
# so and names their hashes.
check "it says where the documents are" "Posted as comments on this pull request" "$body"
check "and why not in the diff"         "would change the commit" "$body"
check "the plan is named"               "The plan —" "$body"
check "and the implementation document" "What was built —" "$body"
check "each by hash"                    "sha256" "$body"
check "it tables the verdicts"       "| Stage | Verdict | Tier | Findings |" "$body"
check "it carries non-blocking findings" "the scaffold test is thin but real" "$body"
check "it records the candidate"     "${HEAD_SHA:0:12}" "$body"
check "and the gate image"           "gate image" "$body"
check "and the binding tier"         "binding tier" "$body"
# The schema says the artifacts array exists so the PR can prove which version
# was audited. It was being stamped into the verdict and going no further.
check "it names what was audited"    "What was audited, by hash" "$body"
check "with the artifact hashes"     "sha256" "$body"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
