# Resume here — Phase 1

Phase 0 closed 2026-09-14 (tag `phase-0-complete`). Branch `factory/phase0-prep-and-bean-set-v1`.

## Read this first

Two things are waiting on you, and nothing else in this repository is blocked.
A third, further down, blocks nothing and wants a decision anyway.

1. **Merge https://github.com/beekeeper-lab/seating-planner-py/pull/1**, or say why
   not. The two documents the line wrote are posted as comments on it; reading them
   is the review the pull request asks for. Until it lands, `factory go` has nothing
   to run — see below.
2. **`gh auth refresh --scopes write:packages`**, then the two lines under
   "CI is built and waiting on one command" in Still Open. That publishes the pinned
   gate image, and the next `scaffold.sh` run then installs the workflow by itself.
   It does **not** make `required_checks` enforceable: branch protection is
   unavailable on a private repo without GitHub Pro (HTTP 403, checked 2026-09-16),
   so `gates` will be a visible check and never a gate on this repository. The
   human merge is the gate, which is what `merge_mode: human_required` already
   said.

One more, whenever you like: `factory read <run-dir>` in the target repo records
that a human read the two rendered documents. It is the one Phase-1 exit predicate
a script cannot settle.

And one that blocks nothing but is worth a decision: **this repository's own
PR #2 has been open since 2026-09-14 and now carries 308 commits** — all of Phase
0, all of Phase 1, every measurement above. `main` is still at the Spec v5 merge.
Nothing needs it: the branch is where the work happens and everything is pushed.
But a 308-commit pull request is not reviewable as a pull request, and the longer
it stands the less true it gets. **Recommendation: merge it, and open smaller
ones from here.** The alternative — reviewing it as one change — is not a real
option at this size, and leaving it open is choosing that option by default.

**What changed on 2026-09-16 and the night of the 17th, in the order a reader
needs it:**

1. **The judge accepts about half the seeded defects put in front of it, and always
   did.** Two of six fixtures were not seeding the defects they claimed; on honest
   ones it is 7 to 9 false accepts in 15. Not a regression — the corpus could not
   show it before. *"The judge accepts about half the seeded defects"*.
2. **Changing the model does not help.** `qwen3-coder-next` accepts 15 of 15,
   perfectly reproducibly; `gemma4` cannot be driven under a grammar at all;
   `devstral` cannot hold the schema. gpt-oss:120b is the best available.
3. **The SIZE of the prompt is the only thing that has ever moved the
   false-accept rate.** Three passes at 20,422 and 30,422 bytes rejected a seeded
   defect 3 of 3; at 40,422 the judge accepted it 2 of 3. Nothing else tried this
   week moved it — not the token cap, the thinking level, five grammar
   constraints, a repaired prompt, four other models, or one question per
   criterion. The controller's own measurements were going to the judge as raw
   JSON and are now prose, which took the spec audit from 25,428 to 21,343 bytes
   and the impl audit from 30,514 to 23,763. The doc audit is 36,731 and cannot
   be cut. *"The size of the prompt moves the false-accept rate"*.
4. **Work moved out of the judge instead, and this is the thing that keeps
   working.** **Four of five seeded defects are now decided by a check, with zero
   false alarms**, against one this morning. Two mechanisms: a bean's `non_goals`
   and `constraints` can say *where* (`bean-forbids.sh`), and a task intent can be
   compared against what every other approved bean says it is for
   (`plans-other-beans.sh` — the evidence for `unfinishable-task` was never in the
   documents under audit, it was in the other nineteen beans). Only
   `criterion-not-really-met` is still the judge's.
5. **Hidden tests are built**, bean-001 and bean-002 have suites, and the worker is
   told the rule without the answers. *"Hidden tests"*. Verified **both ways** as
   of 2026-09-17: the gate's control proved a suite can fail, nothing proved it
   can pass, and a suite that can never pass blocks its bean forever while the
   worker sees only a count. `hidden-tests/verify.sh` checks both — bean-001:
   11 of 11 pass on its accepted tree, 9 of 11 fail on an empty one, the other
   two declared absences. bean-002 is HALF CHECKED until it runs, and says so.
6. **Five grammar changes**, each measured, which produced this line's **first
   stamped audit verdict** — and none of which is evidence the judge is right.
   *"Then three changes in an afternoon"*.
7. **`factory reaudit`** answers "did that change anything on a real run", which
   the seeded-defect harnesses cannot.
8. **The corpus had drifted under the scaffold, and nobody could have seen it.**
   `scaffold.sh` copies the control surface into the target repo one way and never
   looks again, so bean-002's annotation — made in the target — was one scaffold
   run from being deleted by the script whose job is keeping the two the same.
   `scaffold.sh --check` now reports DIFFERS/MISSING/EXTRA per file; it found two
   more things nobody knew. *"Nineteen beans are annotated"*.

The one sentence worth carrying out of all of it: **on this model a constraint in
the grammar is a rule and the same constraint in prose is a suggestion** — and
its boundary, measured 2026-09-17: **a grammar constrains the SHAPE of an answer
and cannot constrain its TRUTH.** `minLength` on `quote` is honoured exactly, and
every quote it forced was invented. *"The sixth grammar constraint"*.

## The judge, in one place

Eight sections below carry pieces of this, written as each was measured. This is
the whole of it, in the order a reader needs, with where to look for each.

**What it does.** Given a spec and a bean, it fabricates the evidence for a verdict
it has already reached. On a real run, **six of six answers quoted text that is on
disk nowhere** — not paraphrases, invented requirements: *"`src/pyproject.toml`
must be present"*, *"The repository does not contain a .gitignore file"* (it does).
`evidence/judge-invented-quotes-20260916.md` has the list, including one where it
quoted its own instructions as text from the document under audit.

**How often it is wrong.** 4 false accepts in 15 seeded defects at the best
configuration, 9 before the prompt was fixed. A false accept is the failure the
line exists to prevent. And **the clean control is rejected 3 of 3 in every
configuration measured** — it has never once passed a spec with nothing wrong.

**What has been tried, and what each was worth.**

| | fitness (seeded) | reaudit (real run) |
| --- | --- | --- |
| token cap 12000 → 16000 | cut-offs 4/18 → 0/18 | — |
| `thinking: medium` → `low` | fewer cut-offs | fewer generated tokens at medium |
| five grammar constraints | no change | conformance ~0% → 100%, **first stamped verdict** |
| prompt stopped contradicting itself | **9 → 4 false accepts** | 1 stamped → 0 |
| a quote per criterion, not per judgement | — | 1 stamped → **0 of 12**, and 31% of criteria carry no quote at all |
| a different model | qwen3-coder 15/15; gemma4 cannot run; devstral cannot hold the schema | — |
| one criterion at a time | 0 false accepts and **0 defects named**, control rejected, 4× the cost | — |
| **twice the artifact bytes** | **0 of 3 false accepts → 2 of 3** | — |

**The two numbers are different questions and only one has ever moved.**
`judge-fitness` asks whether it finds a planted flaw. `factory reaudit` asks
whether it produces a verdict the controller will stamp on a real run. The second
has never exceeded **1 in 12**, and as of 2026-09-17 it is **0 in 12** — because
the controller stopped stamping a verdict that rested on criteria nobody had
verified. *"MEASURED: 0 of 12"*.

**What follows, and what the line already does about it.**

1. **Advisory audits are the best-supported decision in this repository**, and not
   a holding position. `merge_mode: human_required` carries the weight.
2. **Move work out of the judge rather than into prompting it.** Done today:
   `bean-forbids.sh` takes `contradicts-non-goal` and `plans-other-beans.sh` takes
   `unfinishable-task` — **4 of 5 seeded defects decided by a check with 0 false
   alarms**, against 1 this morning. Hidden tests measure the build against
   something nobody in the loop can read. Every lever aimed AT the judge has
   produced nothing this week; every piece of work taken away from it has stuck.
3. **Do not weaken the quote check.** It is the instrument catching the
   fabrication, and its refusal rate is the measurement. I nearly redesigned it
   before reading what it had refused.
4. **The one untried lever has been tried and it is dead.** One criterion at a
   time, 6,209 seconds of GPU: six cases, six `revise`, the clean control
   rejected, and **none of the five defects named** against four for the whole
   question. Zero false accepts, which sounds like the goal and is a stuck
   needle. *"The lever was tried, and it is dead"*.

Sections with the detail: *"OPEN and important"*, *"Removing a contradiction"*,
*"Then three changes in an afternoon"*, *"The judge's token cap"*, *"The untried
lever"*, *"Why bean-001 has no binding audit verdict"*, *"The judge has been
running at the one thinking level that does not work"*, *"The judge does not run
as an agent"*.

## The line is blocked on one human action, and correctly

`factory go` runs the approved beans in dependency order. It ran bean-002 this
morning and stopped, because bean-001's work is in an **open pull request**, not
on `main`, and `main` is what the next bean builds against. `merge_mode:
human_required` means that is by design.

```
$ factory queue
bean-001   pr_open   Project scaffold with linting…   pull request open, not merged: …/pull/1
ready: nothing
waiting on a human to merge: bean-001
```

**Merging https://github.com/beekeeper-lab/seating-planner-py/pull/1 unblocks the
whole chain** — bean-002 becomes ready, and `factory go` will work down the
dependency order from there. Read the two documents posted as comments on it
first; that is the review the pull request asks for.

The developer model found this before the queue did: it opened bean-002's tree,
saw no `src/`, cross-checked bean-001's own spec and gate record, and stopped
rather than planning around the missing precondition
(`evidence/bean-002-worker-questions-20260916.md`).


## State: Phase 0 closed. Phase 1 is built end to end, and one real run has now finished — PR #1 is open.

**Test coverage as of 2026-09-16 evening: 1533 assertions across 36 suites, all
green, in about two minutes.** `factory/pipeline/tests/run-all.sh` runs both
directories and leaves the count where the commit-msg hook can check it — several
commit messages here have quoted a number written from memory, and each was a
small false claim in a record whose entire value is that its claims are true.
Nine of those suites are new that evening, written against the scripts that had no
tests at all — the CLI, judge.sh, claims-check.py, preflight.sh, new-run.sh,
policy-preview.sh, telemetry-report.sh, lib.sh and the new sync step. Every one of
them found a live defect in the first hour, which is the argument for writing them:
see "What the untested scripts were hiding" below.

All six `phase_0_exit` predicates hold — and, as of the audit, they are *computed*
rather than asserted (`bench/phase0-audit.sh`), which they were not before:

```yaml
residency_recorded: true      swap_time_measured: true     harmony_conformance: pass
pi_drives_both_models: pass   regime_decision: "serial"    figures_have_provenance: true
```

The audit found 10 things (2 blocker, 5 major, 3 minor); all were corrected and the
re-run is green. Report: `audits/PHASE-0-AUDIT-20260914.md`. The two that matter most
for anything downstream:

- **Evidence is now committed.** `bench/results/` was gitignored, so every Phase-0
  figure lived only on Forge's disk. The cited artifacts are tracked by name now.
- **Run conditions are observed, not declared.** `run-step.sh` used to stamp
  `conditions.num_ctx` and `conditions.thinking` from `roles.json`. pi has no
  `num_ctx` flag at all, so that number was fiction whenever the server disagreed.
  Both are now read back (pi's session file, ollama `/api/ps`), with the declared
  value kept beside the observed one and a `declared_matches_observed` flag.

Marker convention, set here and binding on every later phase: a commit whose subject
begins `PHASE-N-COMPLETE`, plus an annotated tag `phase-N-complete`. Tags are local until
pushed.

**All 20 seating-planner beans are `status: approved`** (2026-09-14, bulk approval delegated
by the owner — recorded as such in `bean-sets/v1/manifest.json`, because a set-level
approval is not the per-bean human read §04 describes). Run order is bean id order, which
is a checked topological order.

## Sandbox — what is contained

`factory/pipeline/sandbox.sh` implements the §08 contract for verification and refuses
rather than degrades. Proven by attempting each escape (`tests/test-sandbox.sh`, 36 cases):
read-only outside the one writable tree, no network, no capabilities, no host environment,
no container socket, no SSH agent, limits on memory/cpu/pids/wall-clock/output, image pinned
by digest and checked against it, no git binary in the image, no `.git` in the tree.

**The worker is contained too, as of 2026-09-15.** `factory/worker-image/` (node pinned by
digest, pi pinned by version) + `worker-sandbox.sh` + `model-gateway.sh` + `model-bridge.py`,
pinned in `factory/worker.lock.yaml`.

The network story was the easy half once looked at properly. There is no route:
`--network=none` removes every one, and the model arrives on a unix socket bridged on the
host to exactly one address and port. Stronger than an allow-list, because there is no
interface to widen. Two things worth keeping in mind:

- The bridge runs under `runcon -t container_t`. SELinux checks a unix socket connection
  against the peer *process's* context, not the file's label, so a container may not connect
  to a socket held by an ordinary user process however the file is relabelled. This took
  three attempts to see; `factory doctor` now checks `runcon` is present.
- `.git` is masked with an empty read-only mount rather than removed, so edits land in the
  real tree where the change scan reads them, while `git` inside reports "not a git
  repository". The controller makes every commit.

**Everything that can quietly stop containing now says so.** Not decoration: a pipeline
snapshot silently turned worker containment off for a whole run, found only by noticing a
session file path in a log. Every uncontained developer session now prints why,
`FACTORY_VERIFY_SANDBOX` governs every verification sandbox in one place, and the snapshot
refuses to start if it is missing anything the line resolves paths against.

## Nine ways a check goes wrong, found on 2026-09-15, 16

**(9) The right check at the wrong resolution — and the coarse answer is TRUE,
which is why nobody sees it.** Three separate instances on 2026-09-16, all found
in one evening once the shape was recognised, and none of them a bug in the sense
of code doing what it was not told to:

- **The quote check counted verified quotes, not verified criteria.** A judgement
  with four criteria — one quoting 300 real characters and three quoting "the
  test" — printed *"1 quote(s) verified against the artifacts"* and passed. The
  sentence was true. Three criteria nobody could check rode along on the fourth.
- **The hidden-test control required the SUITE to fail against an empty tree.** A
  suite fails if one test does, so three real hidden tests were passing against
  nothing underneath a control that read green. The judge is handed a count, so a
  test that cannot fail inflates the number permanently and invisibly.
- **test-integrity required the whole test command to fail on revert.** Five new
  tests where one pins the change and four assert what was already true got the
  same "yes" as five that all pin it — and weakened assertions are the defect the
  impl rubric calls a blocker and the one a developer model produces most often.

The pattern: a check answers a question about a COLLECTION when the thing it is
protecting against lives in an ITEM. It never fires falsely, it reports
truthfully, and it is wrong in exactly the cases it was built for. **Ask of any
check: if nine of the ten things under it were broken and one was fine, would it
still say what it says now?**

All three are fixed and all three fixes have the same shape — resolve per item,
and make the legitimate exceptions declared rather than inferred: `absent-by-design.txt`
lists the hidden tests that are supposed to pass against nothing, because an
assertion about an ABSENCE is true of an empty directory and cannot be told from
a vacuous one by looking.

**(8) Two causes, one symptom, and the message names the likelier.** ollama returns
200 with a zero-valued struct both when a runner is killed for memory and when the
grammar rejects a token the model emitted. judge.sh said "free VRAM and retry" —
true half the time, and the half it was wrong about cost a measurement cycle on an
idle GPU. A diagnostic that names one of two indistinguishable causes has to name
both, say which is fixable by retrying, and say where the difference is visible.


Every one of these was in code written here, most of it written the same day, and
each was found by a real run rather than by a test. They are listed because the
next check written will be able to have one of them.

Three of the six, the model being checked said so in its own report, and was
right.

**1. Measuring something other than what it claims.** doclint reported a
three-thousand-character section as empty: it started a new section at every
heading, including deeper ones, so a `## Proposed change` written as `### task-N`
subsections measured only the empty gap before the first. The comment above the
code described the correct rule; the code did something else. doc-check had the
same bug in its walkthrough coverage. Both were refusing the shape the authoring
skill explicitly asks for, so the only document that could pass was one nothing
asks for. **The model said so in its own retry report and was right.**

**2. Failing open.** The recurring shape, named because it keeps coming back in new
code: **a loop that skips what it cannot read reports on a subset it never names.**
`queue.sh` did `|| continue` on a bean.yaml that would not parse, so a malformed bean
vanished from the queue — twenty beans in the directory, nineteen in the queue, and the
difference visible only to someone who thought to count both. The same shape is below in
preflight's bean lookup. A skipped input needs a row saying it was skipped, or the output
is a confident answer about a question that was quietly narrowed.

`contain.py || true` swallowed exit 2 — "I could not run" —
alongside exit 1. Fixed in `gate.sh` on 2026-09-15 **and not in `build-loop.sh`,
where the same two lines sat until 2026-09-16.** The gate is the second line of
defence; the build loop is the first, and it runs once per attempt. A taxonomy
entry that names one call site is an entry that leaves the others — grep for the
pattern, not the file. The loop's startup check had a third variant: `! cmd`
treats "outside the paths" and "could not run" alike, so an unreadable pattern
list made every task look out of bounds, which is a refusal for the wrong reason
and sends the next person to edit the bean.

The original, for the record:
alongside exit 1 — "violations found". Both print nothing, so a crashed
containment check reported a clean diff and the gate recorded `contained: true`.
Also: spec-check skipping schema validation with a `note`, preflight's bean lookup
finding nothing and reporting nothing, sync-tree asserting its no-.git guarantee
only at the top level. **A check that can decline to run must say so in a way that
fails, because silence is indistinguishable from a pass and will be read as one.**

**3. Truncating before measuring.** The secret scan's `head -20` sat inside the
pipeline that produced the match list, so fifty leaked credentials reported as
twenty. audit-check's quote haystack was `-maxdepth 2`, so a quote from an attempt
log four levels down was refused as invented — the one accusation that script must
never make wrongly.

**4. Overruling the thing being measured.** A `definition_of_done` check I wrote
would have failed all twenty beans for using the field the way the schema
permits — prose rather than criterion ids. Caught before commit only because the
corpus was checked first. The claims check went through three versions of this,
each firing wrongly on a real spec, before the rule was inverted to require
positive evidence of a claim rather than inferring one from the absence of a
denial.

A fifth, adjacent: **a diagnostic that points at the wrong cause.** "child exit 1"
for a doc step that wrote nothing, and a "terminated" line from the container's
own forwarder that read like an external kill and cost a real diagnosis session
looking for a signal nobody sent.

**5b. Reading a string with `jq -e` and calling it a check.** In jq only `null` and
`false` are falsy — **`""` is true.** So `jq -e '.provenance.ollama_version and ...'`
passed for a figure whose ollama_version was the empty string, and the Phase-0 audit
reported "every results JSON carries kernel + ollama version" about a field with
nothing in it. `provenance_block` fills that field from `ollama --version`, which
produces nothing on a box without ollama — the exact machine someone would re-run
these harnesses on. The same shape was in `harmony-conformance.sh`, deciding whether
the OpenAI endpoint accepts a `developer` role. **Grep for `jq -e '.field'` whenever
a check reads a string it did not write itself**; the fix is `(.field // "") != ""`.

**6. Asking whether a thing exists when the question is who made it.** Added
2026-09-15 evening, and it is category 1 wearing a different hat. run-step
reported "its output IS present, so this is a failure after the work" for a doc
attempt that wrote nothing — the file on disk was byte-for-byte a previous
attempt's, four hours old. Orchestrate's doc retry had the same test
(`[ ! -s impl-detail.md ]`), which on any resumed run is always false, so the
retry that exists precisely for this failure never fired and the run halted for a
human. Both now hash the file before the session and after. **Existence is not
authorship, and on a resumed run every output of every earlier attempt is sitting
right there to be mistaken for this one's.**

## Deterministic checks — what used to be the judge's job

Four rubric items moved out of the judge into the controller, each with tests. A deliberate
response to measuring the judge, not a tidying exercise:

| check | settles | was |
|---|---|---|
| `spec-check.sh` verify precheck | a task whose every check already passes cannot be demonstrated | spec rubric |
| `claims-check.py` | files the spec says exist, against the filesystem | spec rubric |
| `test-integrity.sh` | do the tests fail with the source reverted | impl rubric |
| `package-check.sh` | every arithmetic bullet — pairs, status, naming, tier | the whole package rubric |

`bench/controller-fitness.sh` runs the judge's own six seeded cases through these.
**Re-measured 2026-09-16 against a clean base** (`controller-fitness-20260916T003558Z.json`):
the clean control passes, **1 of 5** caught by name, 0 false alarms, ~6 seconds a case, no
variance. The other 4 are the judge's actual job.

The earlier figure of 2 of 5 was measured with the target repo on a bean branch — the work
already committed, so every verify already passed and the clean control failed. The harness
refuses that state now. **1 of 5 was the honest number then**, and the drop was a
measurement improving, not a check regressing. It is **4 of 5** now — two checks
later, both measured the same way and both against a pinned fixture rather than a
live bean: *"What annotating buys"* and *"The fourth of five seeded defects"*.

The one that moved is worth naming, because the claim in the table above is narrower than it
reads. The `tautological-verify` case replaces *one* of task-1's verifies with `test -d .`.
verify-precheck names it — *"each task has a check that fails first; these do not, which may
be fine: task-1[0] …"* — and passes, because its rule is that each task needs **at least one**
check that can fail, and task-1 still has three. That rule is right: a task legitimately
carries always-passing checks (`ruff check .` passes on a clean tree), and failing on them
would make the check untrustworthy on good specs. So the precheck **surfaces** a single
tautological verify and does not **catch** it. Whether one planted among several real ones
should fail the spec is a judgement call, which is the definition of the judge's job.

Three lessons are baked into those checks and are worth not relearning:

- **A one-sided check is unsound.** test-integrity first ran the tests only on the reverted
  tree and called any failure "the tests pin the change" — so a missing binary read as
  success. It now requires a control run on the unreverted tree first.
- **A fuzzy signal belongs on the forgiving side.** claims-check reads English negation so
  "there is no `src/a.py`" is not reported as a false claim. Using the same signal to *fire*
  a failure was wrong twice in one section of the first real spec it met. Suppress on a
  maybe; never accuse on one.
- **Only fail on what is decidable.** test-integrity exits 2 — undecided — for "no tests
  written" and "the tests do not pass to begin with", because a change with no tests may be
  a config bump. A check that fails runs on judgement calls gets switched off, and takes the
  decidable one with it.

## The three ranked gaps in the forked pipeline are closed

1. ~~No task loop~~ — `build-loop.sh`, 83 assertions.
2. ~~Sandbox — half~~ — the worker is contained as of 2026-09-15; see above.
3. ~~The model declares its own tier~~ — `tier.py` + `gate.sh`. The tier comes from the
   paths the diff touched; bean and judge can only raise it.

## The stages, as they stand

| Stage | Model half | Controller half | Tested |
|---|---|---|---|
| preflight | — | `preflight.sh` | via full-line |
| specify | `factory-spec` writes `spec.md` + `tasks.yaml` | `spec-check.sh`: sections, schema, paths, claimed criteria, budget, **verify precheck, current-behaviour claims, byte budget**, renders HTML | 31 |
| spec audit | `factory-audit` writes a *judgement* | `audit-check.sh` stamps provenance, validates, amends the step | 48 |
| build | `factory-build-task`, one task per session, **contained** | `build-loop.sh`: contain → reject+reset → verify in the sandbox → commit | 83 |
| gate | — | `gate.sh`: whole-diff containment, tier, budget, secrets, gates, ACs, invariants, **test integrity** | 44 |
| document | `factory-doc` | `doc-check.sh` + `doclint.sh`: sections, diff coverage both ways, renders HTML | 13 + 33 |
| pre-PR audit | `factory-audit` | **`package-check.sh`** settles the whole arithmetic rubric first | 24 |
| sync | — | **`sync.sh`**: rebases a branch the base has moved past, files the now-stale results, and sends the line back to the gate | 48 |
| PR | — | `pr.sh`: refuses without an accepting verdict, a clean tree, a gated diff, a base that has not moved | 25 |

`sync` is the only step that can run the line backwards. It writes `rewind.json`,
the orchestrator's loop reads it at the top of each iteration, and gate,
audit-impl and audit-package run again against the new candidate. The spec audit
does not: it judged the plan, and a rebase does not change the plan.

Supporting: `sandbox.sh` (36), `test-integrity.sh` (22), invariants (9), role routing (38).

**`tests/run-all.sh` runs every suite** — 455 assertions, ~64s; `--fast` skips the
end-to-end ones. `tests/test-full-line.sh` drives preflight → pull request with pi, the
judge and gh stubbed, in about twenty seconds. It exists because the two worst bugs this
project has had both lived past `build` and neither needed a model to reproduce.

## OPEN: the judge is measured, and the measurement is that it is not reproducible

This section previously said the judge "works in principle" and laid out a hypothesis about
schema complexity. The hypothesis was never the problem. **Ask the same question five times
with identical input at temperature 0 and you get two different verdicts.**

`bench/judge-variance.sh`, gpt-oss:120b, one seeded defect, byte-identical input each run:

```
revise   9 findings   confidence 0.99   232s
revise   1 finding    confidence 0.90   168s
revise   1 finding    confidence 0.95   137s
none     —            —                 449s
revise   4 findings   confidence 0.95   197s
```

The defect was named in an earlier fitness run and in none of these five.

**Re-measured 2026-09-16, and the verdict half changed.** Same case, same harness,
after the token cap went to 16000 and `met` was given a per-target meaning
(`judge-variance-20260916T142555Z.json`, `evidence/judge-variance-16k-met-20260916.log`):

```
revise   4 findings   confidence 0.92   382s
revise   0 findings   confidence 0.50   180s     ← a revise with nothing to revise
revise   4 findings   confidence 0.99   194s
revise   3 findings   confidence 0.85   443s
revise   1 finding    confidence 0.90   206s
```

**One verdict across five identical runs**, where the earlier run gave two. That is
the first time this judge has been reproducible on anything.

It does **not** reopen the advisory-audits decision, for three reasons stated
plainly so nobody has to reconstruct them:

1. One case. The finding above is at case level across six.
2. Three variables changed at once — cap, prompt, thinking level — so nothing here
   attributes the change to any of them.
3. **The content is still random.** Findings 4/0/4/3/1, confidence 0.5 to 0.99, and
   the seeded defect named in none of the five. A verdict that is stable while its
   reasoning is not is a coin that has landed the same way five times.

Run 2 is why `audit-check.sh` now refuses a `revise` or `block` carrying zero
findings: orchestrate routes a failed audit back into the authoring step *with the
findings*, and with none attached the step is asked the identical question again,
burns an attempt, and halts the run for a human whose only information is "the
judge said revise".

The honest next step is a repeat of the **case-level** measurement at the new cap
and prompt — `judge-fitness.sh --repeat 3`, about 75 minutes — which is what would
actually bear on the decision.

**Confirmed at case level, 2026-09-16** (`judge-fitness-20260916T001225Z.json`,
`--repeat 3`: the same six cases, three times, byte-identical input, temperature 0):

```
clean                       revise   revise   abstain     ← never once passed a clean spec
contradicts-non-goal        revise   revise   revise
criterion-not-really-met    revise   ACCEPT   revise      ← false accept on identical input
invented-current-behaviour  revise   cut off  cut off
tautological-verify         revise   revise   ACCEPT      ← false accept on identical input
unfinishable-task           revise   revise   revise

15 seeded defects: rejected 11 · NAMED the actual defect 2 · false accepts 2 · cut off 2
```

Three things, and the third is the one that decides the question:

1. **The clean control is rejected every time.** Not variance — a consistent false
   rejection. In one pass it named the defect; in three passes it has never once said a
   clean spec is clean.
2. **It rejects for the wrong reason.** 11 rejections, 2 of which named the seeded defect.
   A verdict that is right by accident is not a check.
3. **Two cases flipped to `accept` on identical input.** The same bytes, the same
   temperature, and a seeded defect passed. That is the failure the line exists to prevent,
   and it is invisible from the outside — a `revise` costs a retry, an `accept` costs
   everything after it.

A judge that rejects what is good, rejects what is bad for reasons that are not the reason,
and sometimes accepts what is bad, cannot be a gate. The advisory decision stands on
measurement, not caution.

**The consequence lands on this project's own conclusions.** Every judge finding here came
from comparing single runs: fenced artifacts against unfenced, one message per artifact
against one blob, gpt-oss against gemma4, 4000 tokens against 12000. One sample per arm
against a spread at least this wide. Those comparisons are withdrawn.

What survives on other evidence:

- The format fixation was real — "the document is not valid JSON" in several logs across
  runs. **One message per artifact stopped it appearing at all**, which is a different kind
  of evidence from a rate moving.
- **gemma4 is a rubber stamp**: three false accepts in the three cases it judged, 17s each.
  Strong even at n=1 per case. gpt-oss:120b stays.
- Two of the five seeded defects in `bench/judge-fitness.sh` were **not the defects they
  claimed to be** until 2026-09-15. `tautological-verify` mutated the task list with a regex
  that stopped at a `]` inside a Python string, leaving a syntax error. The judge read it,
  reported a syntax error, and was scored as having missed the defect — three times. Part of
  the "format fixation" it was accused of was, on that case, the judge being right.

## The judge has been running at the one thinking level that does not work

Measured 2026-09-16 (`format-support-20260916T111754Z.json`), under a **real 18KB
payload** rather than a short probe — the distinction the harness exists for:

```
gpt-oss:120b      thinking=low      HOLDS the schema   110s
gpt-oss:120b      thinking=medium   spends the whole budget thinking, writes nothing
gpt-oss:120b      thinking=high     spends the whole budget thinking, writes nothing
gpt-oss:20b       every level       empty content, 3s — it simply fails
gemma4:26b        thinking=false    holds — and is the measured rubber stamp
devstral:24b      —                 does not support thinking; non-JSON with it off
```

**The only eligible judge configuration on this box is `gpt-oss:120b` at
`thinking=low`, and `roles.json` says `medium`.** That is very likely most of what
"the judge produced no judgement" has meant all along: five of bean-001's audits
ended that way, and "spent the whole budget thinking and wrote nothing" is exactly
the shape.

roles.json's own note already carried the revisit condition — *"Revisit if the
judge's catch rate on bench/judge-fitness.sh is poor at medium"* — and it is poor.
A fitness run at `low`, three passes, is the comparison; `judge-fitness.sh
--thinking low` exists for it and stamps the level into the artifact.

**So the judge is advisory for now.** `--advisory-audits` lets it run, write a judgement and
have a verdict stamped, without a verdict short of accept stopping the run. Only the model's
opinion is softened; every deterministic check stays blocking. The advisory is written into
`failed-attempts/` with its reason and `pr.sh` lists it in the pull request, so "advisory"
cannot quietly become "ignored".

**The productive direction is not prompting.** It is moving what is decidable into the
controller — see the deterministic checks section above — and leaving the judge the part
counting cannot reach. `bench/judge-fitness.sh --repeat N` exists now; anything you intend
to compare against another number needs it, and the harness says so in its own output.

Also settled today: `repeat_penalty` 1.1. Two audits in a row hit the token cap, and neither
was thinking hard — one spent its last few hundred tokens repeating a single sentence inside
a string it never closed. temperature 0 makes that worse, not better: with no sampling noise
a model that starts a loop has nothing to break it.

## The judge does not run as an agent

`audit-*` does not go through `run-step.sh`. gpt-oss:120b under pi calls a
`repo_browser.*` tool namespace that does not exist here — twelve calls, empty
arguments, no result, and then a confident audit of a document it never read.
`judge.sh` puts the artifacts in the question instead, constrains the answer,
and writes the file itself. A system message denying tools is load-bearing:
without it the model emits those tool calls even against the raw API with the
documents already in the prompt.

It is also the only place in the line where the declared context is the served
context, because `/api/chat` takes `options.num_ctx` and pi does not.

## The worker's harness surface is closed

`run-step.sh` passed pi `--model`, `--thinking`, `--skill` and nothing else, so pi
discovered the rest on its own: every file in `~/.pi/agent/extensions/` — 24 on this
box, among them `github-mcp.ts`, `trello.ts`, `obsidian.ts`, `team-lead.ts` and two
`posttooluse-edit-write` hooks — plus the prompt-template directory, plus any
`AGENTS.md`/`CLAUDE.md` in the target repo, prepended silently. None of it was in the
run record. That is the skill collision one directory over, on a line whose invariant
is "no credential near a model".

Now: `--no-extensions --no-prompt-templates --no-context-files --tools read,write,edit,bash`,
and `conditions.harness` records the flag set and the four tool names, so two runs
with different surfaces are not mistaken for comparable. `factory-spec` still tells
the worker to *read* the repo's context files if present — a recorded act — which is
why turning off the silent injection loses nothing.

Not done, and why: `--no-skills` alongside the explicit `--skill` would make the
global-skill collision impossible rather than alarmed, but whether pi 0.85.1 still
honours `--skill` under `--no-skills` needs a live smoke step to prove; the stub
cannot. The collision check stays as the defence until then.

- **The next judge measurement is not comparable with the ones before it.**
  `met` now carries a per-target meaning (judge.sh, 2026-09-16). Every fitness and
  variance figure taken before this asked the judge a question with an undefined
  field in it; a spec audit answering `met: false, evidence: "No source files were
  provided for analysis"` was the model reading `met` as "the code satisfies this"
  and saying, correctly, that there is no code. Re-measure before comparing.

## The judge's token cap is 16000, and that is the only number this measurement earned

`JUDGE_NUM_PREDICT` went 12000 → 16000 on 2026-09-16, in `judge.sh` and in the two
bench harnesses that record it (test-judge.sh asserts the three agree — three copies
of a number is two copies that will eventually be wrong, silently, in an artifact
nobody can check afterwards).

Everything else judge-fitness reports is a verdict, and this judge gives different
verdicts to the same question at temperature 0. So a catch rate at one cap against a
catch rate at another measures the weather. **"Was the answer truncated by the token
cap" is not a verdict** — `done_reason` says `length` or it does not — and that is the
one comparison the non-reproducibility does not poison:

```
              cut off   false accepts   named   abstained   no answer
12000, low     4 / 18         1           4         0           ?
16000, low     0 / 18         0           2         4           2
```

Only the first column is a claim. The others are in the table because leaving them
out would be picking the column that moved.

What 16000 did **not** fix: two cases still return no judgement at all
(`criterion-not-really-met`, `tautological-verify`), now with `done_reason=stop`
rather than `length`. That is a different failure, and the diagnostics added the same
day — the whole answer kept at `verdicts/<target>.unparseable.json`, with jq's own
parse error and the real `done_reason` — say which one it is next time. Both are
reported as `unmeasurable_cases`, so the run is an incomplete measurement and says so.

Evidence: `evidence/judge-fitness-low-16k-20260916.log` beside
`evidence/judge-fitness-low-20260916.log`, and
`bench/results/judge-fitness-20260916T130042Z.json`.

## Why bean-001 has no binding audit verdict, specifically

`bench/phase1-audit.sh` reports `three_verdicts_schema_valid: not_exercised` —
"6 audits ran advisory and reached none". That is true and it does not say what
happened, and what happened is now known per audit:

- **spec** produced a judgement: `accept`, and `confidence: 100` against a
  contract of 0..1. `audit-check.sh` refuses it, correctly — "certain" and
  "percent" cannot be told apart afterwards and guessing which was meant would
  invent a claim the model did not make.
- **doc** produced a judgement: `accept`, **0 findings and 0 criteria**, for a
  bean with four acceptance criteria. A judgement that reports on none of them is
  not a judgement.
- **impl, package** produced no judgement file at all. At the 12000 cap that is
  most likely the token cut-off; it could also be the unparseable-answer path,
  which until 2026-09-16 kept nothing and so cannot be told apart retrospectively.

All three causes have had work done on them since: the cap is 16000 (0 of 18 cut
off, where 12000 gave 4 of 18), `met` now says what it means per target, and the
unparseable path keeps the whole answer with `done_reason` and jq's own error.

**Run 2026-09-16** against a copy of that run directory, at the new cap with the
new prompt (`evidence/reaudit-bean-001-20260916.log`):

```
TARGET    JUDGE-RC  VERDICT   STAMPED   why not
spec      1         -         no        reasoned 20,417 chars, ended its turn without an answer
impl      1         -         no        tried to call repo_browser.open_file
doc       0         accept    no        reported on 2 of the bean's 4 criteria
package   0         accept    no        reported on 2 of the bean's 4 criteria
```

**Two of four now produce a well-formed judgement, where none did before.** That
is real progress and it is not enough: none of the four is stampable.

Three things worth keeping from it:

1. **The criteria-coverage check earned its place on day one.** doc and package
   both returned `accept` at confidence **0.99** over half the bean's criteria.
   Without that check both would have been stamped.
2. **Size is not the variable.** The largest payload is the one that worked (doc,
   36,731 bytes over 3 artifacts); the failures were 25,428 and 30,514. The
   obvious hypothesis is dead and does not need measuring.
3. **What the two failures share** is the bean and the task list — the two
   artifacts written in the imperative and addressed to a different model, which
   the preamble already warns about once, thousands of tokens earlier. The spec
   judge's reasoning trace is the evidence: it read `claims-check.json` as a
   confusing set of statements about its own task, invented a response shape
   (`{"verdict": false, "reasons": [...]}`), and finished with *"Could you clarify
   what exactly you'd like me to do?"*.

   `judge.sh` now puts a `read as:` line on each artifact header — "written in the
   imperative and addressed to a DIFFERENT model", "a measurement the controller
   already took... not a question for you" — rather than saying it once in the
   preamble.

**Measured, three passes × four targets** (`evidence/reaudit-bean-001-3pass-20260916.log`).
The `read as:` change cannot be called either way — which targets answer moves
between passes, spec going 0/1 → 3/3 and doc going 1/1 → 0/3 — and that movement
is itself the more important result.

**Twelve real audits of a real run at the best configuration this project knows,
and not one produced a verdict the controller will stamp.**

```
 6  no judgement at all   tool calls into a repo_browser namespace that does not
                          exist (×3), reasoned then stopped (×2), unparseable (×1)
 4  wrong criteria        see below
 2  revise, zero findings
```

The criteria column is the finding. What it put in `criteria`:

```
task-1, task-2                          the task list's ids
artifact-1 .. artifact-5                the numbering of the prompt's own delimiters
test_files_presented                    invented
importable-modules, module-docstrings   invented
```

One answer of six used a real id, and only one of the bean's four. The prompt has
said, in bold, *"the criteria you report on are these, and only these — using
exactly these ids"*, followed by the list, since the day the judge first invented
`C001`. The model is not defying the instruction so much as filling the field from
whatever enumerable thing is nearest, and prose cannot stop that.

**So the ids are in the grammar.** `criteria[].id` carries an enum of the bean's
ids and `minItems` is their count, built from the same jq that builds the prose
list so the two cannot drift. Constrained decoding makes `task-1` unemittable
rather than discouraged — and `bench/format-support.sh` already measured that this
model holds a schema at `low`. A re-measurement against the baseline of zero is
the next thing to do here.

**What this meant for the decision, as of that measurement**: advisory audits were
not a temporary accommodation while the judge was tuned. The audit stage did not
produce a binding verdict on this line's artifacts at all.

## Removing a contradiction halved the false accepts — and changed nothing on a real run

`factory/skills/factory-audit/SKILL.md` is spliced into the judge's prompt
verbatim. It said **"Open the files named below"** and **"Re-read the files"** —
written when the audit was a pi session — in a prompt whose preamble says *"You
have NO tools: no file system, no repo_browser, no way to open, search or list
anything."*

Same model, same grammar, same token cap, same fixtures, that one change
(`evidence/judge-fitness-rubricfix-20260916.log`):

```
                        contradictory prompt      rubric fixed
false accepts                 9 / 15                 4 / 15
rejected                      5                     11
NAMED the defect              2                      4
no answer                     1                      0
control rejected            3 of 3                 3 of 3
seconds per case             21–56                 68–437
```

**False accepts more than halved.** And the part that is *not* explained by "it
just rejects more": the defect was **named** four times against two. You cannot
name a seeded defect by lowering a threshold.

Three things to hold onto with it:

- **The control is still rejected 3 of 3.** This judge has never once passed a
  clean spec, in any configuration measured today. That is the most damning single
  fact about it and this change did not touch it.
- **It costs 5 to 10x the time.** The judge stopped reaching for a tool, failing,
  and answering quickly from nothing; it now thinks for four to seven minutes.
  That is a fair price for an audit stage and it is a real change to per-bean cost.
- **n is 15, and this judge is not reproducible.** The direction is consistent
  across all four columns and three cases went from mixed verdicts to `revise×3`,
  which is more than the spread would give — but it is one run.

### And it did not transfer to a real run

The same fix, measured the other way — `factory reaudit --passes 3` against
bean-001's own run directory (`evidence/reaudit-bean-001-rubricfix-20260916.log`):

```
                    before      after
stamped              1 / 12     0 / 12
answered             8 / 12     6 / 12
all four criteria    8 of 8     6 of 6
refused on the quote 5 of 7     6 of 6
```

Every answered audit fails on an invented quote, and they are not near-misses —
they are requirements the judge made up: *"`src/pyproject.toml` must be present"*,
*"The repository does not contain a .gitignore file"* (it does), *"All tests pass.
This is a valid package."*

**Two harnesses, two questions, and only one of them moved.** `judge-fitness` asks
whether the judge can find a planted flaw in a mutated spec. `factory reaudit`
asks whether it can produce a verdict a controller will stamp on a real run.
Nothing measured today has moved the second above **1 in 12**, and the reason is
always the same: the judge fabricates the evidence for a verdict it has already
reached, and the quote check catches it every time. *(2026-09-17: it is 0 in 12
now. Not a regression — a criterion whose quote was too short to check used to
ride along on one that was checked, and 4 of the 12 refusals are exactly that.)*

Do not report the fitness number without this one beside it.

**The lesson generalises past the judge.** Nobody had read the prompt as one
document. judge.sh's preamble and the rubric it splices in were written months
apart, edited separately, and contradicted each other in the one place that
mattered — and the project spent two days treating the resulting `repo_browser`
calls as a quirk of the model. The two files now say so in their own headers, and
test-judge.sh asserts they agree.

## OPEN and important: the judge accepts about half the seeded defects, and always did

`bench/judge-fitness.sh --repeat 3`, 2026-09-16 evening, on fixtures that are
actually seeding their defects for the first time
(`evidence/judge-fitness-grammar-20260916.log`):

```
of 15 seeded defects: rejected 5, NAMED the actual defect 2
false accepts 9 · abstentions 0 · no answer 1

clean                        revise ×3          ← the control, rejected every time
tautological-verify          accept ×3
contradicts-non-goal         accept ×2 revise ×1
invented-current-behaviour   accept ×1 revise ×2
unfinishable-task            accept ×2 revise ×1
criterion-not-really-met     accept ×1 none ×1 revise ×1
```

**Nine false accepts in fifteen, and the clean control rejected three times out of
three.** That is not noise around the truth, it is anti-correlated with it.

**It is not a measured regression, and saying so would be the same mistake this
project keeps writing down.** Two things changed at once: the response grammar,
and two of the six fixtures — which were not seeding the defects they claimed, so
no earlier fitness figure was measured against these cases at all. The honest
statement is that this is a **new baseline** and that every number before it is
uncomparable.

What it does say on its own terms:

- **Conformance and judgement are not the same thing.** Every case that answered
  carried all four criterion ids, in the right shape, with a valid confidence. The
  grammar work did exactly what it was measured to do and none of it is evidence
  about whether the judge is right.
- Answers are much faster — 21 to 56 seconds, against 100 to 700 before. A judge
  that used to spend minutes now answers in half a minute and accepts broken
  plans.
- **Advisory audits are more justified than before, not less.**

**The caps were measured and are not the cause** (`JUDGE_FIELD_MAXLEN=0`,
`evidence/judge-fitness-nocap-20260916.log`, everything else identical):

```
                 field_maxlen 600    field_maxlen 0
false accepts          9                  7
named                  2                  3
rejected               5                  8
no answer              1                  0
```

Better on every axis without them, and not significantly: a judge that gives
different verdicts to byte-identical input does not distinguish 9 from 7 in
fifteen trials.

**Which leaves the uncomfortable conclusion.** This judge accepts about half the
seeded defects put in front of it, in either configuration, and the earlier
figures of zero to two false accepts were flattered by two fixtures that were not
seeding their defects. **It was always this bad**; today is the first time the
corpus was capable of showing it.

One real signal in the pair: `criterion-not-really-met` is named 3 of 3 without
the caps and 1 of 3 with — the only case this judge ever names. That is an
argument for **raising** 600 rather than removing it, and n is 3. The caps stay at
600, which is the configuration everything else today was measured at; raising
them is a candidate with a measurement attached, not a tidy-up.

**Do not take the grammar changes as settled improvements.** They are settled
improvements to *conformance* — which is what the controller needs to stamp
anything at all, and is why the line produced its first verdict today — and they
are not evidence about whether the judge is right. `tools: []` remains untested as
a cause and is the next thing to vary if anyone wants to keep pulling this thread.

## Then three changes in an afternoon, and they are all the same change

**The first stamped audit verdict this line has produced**:
`evidence/first-stamped-verdict-20260916.json` — an impl audit of bean-001,
`accept` at confidence 0.9, all four criteria, two quotes verified against the
artifacts, the controller's measured `test_integrity`, tier 2.

```
enum on criteria[].id    criterion compliance: 1 of 6 answers partly right
                         → 5 of 5 answers exactly right
tools: []                the field was ABSENT, not empty. The system prompt has
                         said "you have NO tools" for days; the model called
                         repo_browser.open_file 9 times out of 9. With an empty
                         list declared: 0 out of 8
maxLength on free text   `evidence` was arriving with a unified diff and a whole
                         Python module in it, or the model's own reasoning
                         followed by a nested ```json answer. It fills the field
                         with everything it would otherwise have said, runs long,
                         and the string never closes
```

**On this model a constraint in the grammar is a rule and the same constraint in
prose is a suggestion.** Three for three, against a 12-attempt baseline of zero.
That is the transferable finding; the three fixes are the illustration.

Two things made it findable rather than guessable:

- `prompt_eval_count` and `eval_count`, read off the response for the first time.
  "It stopped without finishing" was a choice between the token cap, the context
  window and the model simply stopping, and `35% of 32768 with 84 generated
  tokens` rules out two of them in one line. Every judge call logs it now, and a
  request that fills the window says which knob is not the lever.
- `verdicts/<target>.unparseable.json`, which keeps the whole answer. The
  `evidence`-contains-a-Python-module finding is unavailable without it.

And a contract that could not be satisfied: `verdict.schema.json` REQUIRES
`test_integrity` on an impl audit, and judge.sh's response schema does not contain
the field — so the judge was never asked for it and an impl verdict could never
validate. `audit-check.sh` fills it from `test-integrity.json`: the controller
measured it, the verdict is the controller's document, and the judge should never
have been asked to restate a number it was handed.

**Still true**: one stamped verdict in three passes is not a working audit stage,
and the other two refusals were right (one quoted nothing long enough to prove
anything; one quoted a `SeatingPlanner` import and a poetry dev-dependencies block
that exist in neither file — the quote check catching invented evidence, which is
what it is for). `merge_mode: human_required` still carries the weight. What has
changed is that the failures are now specific and the lever that moves them is
known.

`factory reaudit <run-dir>` is the harness for all of this: a finished run's
audits, N times, against a copy, never writing to the run.

## OPEN: the snapshot launcher died on its own last line, after succeeding

That 75-minute run finished, printed its whole summary, wrote its results file, and
then `bench/snapshot.sh` exited 2 with

```
bench/snapshot.sh: line 61: unexpected EOF while looking for matching `"'
```

on a file that is sixty lines long and passes `bash -n`. bash reads a script by byte
offset as it executes — the reason the launcher exists — and something rewrote the
bytes between the read that started the harness and the read that should have
followed it. **Nothing in that session edited this file**, and a short probe harness
does not reproduce it. Cause not identified.

The consequence is closed: everything after the harness call is now on one line, so
bash has already read it before running the first command on it and there is nothing
left to read afterwards. A successful measurement can no longer be reported as a
failed launcher. If this recurs, the thing to catch is what is writing to
`bench/snapshot.sh` — `inotifywait -m bench/snapshot.sh` during a long run.

- ~~**`minLength` on `quote`.**~~ **Measured 2026-09-17 and the answer is no**;
  see *"The sixth grammar constraint"*. It is honoured — at 200 every quote came
  back over 200 characters — and it made the answers worse: 0 of 4 quotes were
  real, against 1 of 4 at 12. Forcing a longer quote makes the model write more
  prose and call it a quote. `JUDGE_QUOTE_MINLEN` exists and stays at 0.

- **Re-run `bench/size-sweep.sh` now that `tools: []` is declared.** Its standing
  finding is that at exactly 10,000 bytes of padding the judge produces no
  judgement, reproducibly, answering `{"path": "", "depth": 3}`. That is a
  file-browsing tool call leaking into content, and the same shape as the
  `repo_browser.open_file` calls that stopped when the empty tool list was
  declared. The sweep may now measure something different, or nothing at all.

- ~~**Re-run `bench/judge-fitness.sh --repeat 3`.**~~ **Done — it is
  `judge-fitness-rubricfix-20260916T211029Z.json`**, three passes, measured
  22:26Z on 2026-09-16 with the enum, the empty tool list, the 600-character
  field caps, the keyed criteria and the confidence enum all in place, and on the
  repaired fixtures. **4 false accepts in 15**, and that is the figure the
  advisory-audits decision rests on. Nothing has changed the judge since except a
  retry on a tool-call answer, which only affects cases that previously produced
  nothing at all.

- ~~**`confidence` as an enum**~~ — **done 2026-09-16.** The keyword finding stands
  and is the transferable part: the schema carried `{"minimum":0,"maximum":1}` for
  days and the judge returned **100**. llama.cpp's grammar conversion honours
  `enum` and `maxLength` and does **not** honour numeric bounds — worth knowing
  before reaching for any other numeric constraint. It is `[0, 0.1, … 1]` now, and
  one decimal place is the honest precision for a number a model produces by feel.
  **Unmeasured**; the next `factory reaudit --passes 3` says whether it took.

- ~~**The quote is the remaining blocker**~~ — **read the quotes first.** This was
  queued as "redesign the field so an invented quote is unrepresentable: number the
  artifact lines, ask for an artifact+line reference, let the controller resolve
  it". Then I read what the judge had actually put in that field
  (`evidence/judge-invented-quotes-20260916.md`):

  ```
  [tool.poetry] name = "seating-planner"        ← the project uses setuptools
  [tool.ruff] line-length = 120 select = [...]  ← the real file says 100, and different rules
  from .planner import SeatingPlanner            ← no such module; this bean is a scaffold
  Your answer must be a JSON object with ...     ← its own instructions, cited as the artifact
  ```

  **The quote check is not the blocker. It is the detector.** Five refusals in
  seven answers is a measurement of how often this judge invents the evidence for a
  verdict it has already reached, and the redesign would have replaced the one
  instrument that is telling the truth with one that cannot: a line reference
  resolves to real text whether or not the judge read anything, so the guarantee
  drops to nothing precisely where it is doing the most work.

  Do not weaken it. If anything, the number to watch is the refusal rate, and it
  belongs in the reaudit record beside the false-accept rate.

## The tautological-verify fixture was not seeding the defect, for the second time

`bench/controller-fitness.sh` has reported "1 of 5 seeded defects named by a
check, 4 not decidable" and closed with *"the ones marked not decidable are the
judge's actual job"*. One of those four was not.

The mutation is supposed to replace the first task's whole `verify:` block with a
check that cannot fail. It skipped the existing items with

```
while lines[i].strip().startswith("-"): i += 1
```

and the line after the first item in this task list is a **comment**. So it
skipped nothing: the mutation *prepended* one tautological verify to four real
ones, which is not a tautological task — it is the case `spec-check` documents as
legitimate ("a lint that is green on an empty directory"). The controller
correctly did not flag it, and was scored as having missed a defect that was never
seeded.

That is the second time this one mutation has been silently wrong in a different
way; the first, a regex that stopped at a `]` inside a Python string, ran for
months. Both times the number it produced looked exactly like a measurement.

Fixed by skipping on **indentation** rather than on a leading `-`, and the
mutation now **asserts its own post-condition** — the first task has exactly one
verify and it is the tautological one. A mutation that has been wrong twice does
not get a third chance to be wrong quietly.

**What it changes**: `tautological-verify` is decided by `spec-check`'s verify
precheck and always was. Controller fitness was **2 of 5 named by a check, 3 not
decidable, 0 false alarms** at that point (`controller-fitness-20260916T171328Z.json`);
it is **4 of 5, 1 not decidable, 0 false alarms** as of 2026-09-17, after
`bean-forbids` took `contradicts-non-goal` and `plans-other-beans` took
`unfinishable-task`.

**And what it invalidates**: every `judge-fitness` figure involving this case
scored the judge against a fixture that was not the defect. That is one of six
cases in every run since the rewrite.

**A second one was wrong too**, found by applying every other mutation and reading
what came out. `contradicts-non-goal` spliced a block list item after
`write_paths:`, which in this task list is followed by an inline flow list on the
same line:

```yaml
write_paths:
  - src/seating_planner/solver/** [pyproject.toml, .gitignore]
```

One nonsense string, with the two real paths swallowed into it. Parsed and
rewritten with yaml now.

**Every mutation asserts its own post-condition**, and one assertion holds for all
of them: a non-control mutation that changed nothing is an error. Driven against a
renamed heading to prove they bite. This one fixture has been silently wrong three
times in three different ways and the assertions are the only thing that makes a
fourth different from the first three.

## What a bean forbids, decided by running something

`non_goals` was a list of English sentences, checked by asking the judge. That
judge accepts about half the seeded defects put in front of it, and
`contradicts-non-goal` — a spec planning work its own bean forbids — is one of the
cases it misses; `bench/controller-fitness.sh` had it as *"not decidable from the
documents, needs a judge"*.

**Half of it is decidable.** A non-goal about a PLACE is a statement about paths
and imports, and those are countable:

```yaml
non_goals:
  - no seat-level positions          # a concept. Still the audit's.
  - text: no rule model (bean-003)
    forbidden_paths: ["src/seating_planner/domain/rule*.py", …]
  - text: no database
    forbidden_imports: [sqlite3, sqlalchemy, psycopg, pymongo, redis, shelve]
```

`factory/pipeline/bean-forbids.sh`, 33 assertions. Checked twice, in two places that
ask different questions:

- **spec-check**, over every task's `write_paths` — *before a model writes a line
  of it*. This is the cheapest possible place to catch `contradicts-non-goal`.
- **the gate**, over the diff — because a task can stay inside its declared write
  paths and still add an import the bean forbids. The plan is a promise; the diff
  is the change.

Everything is optional and nothing about an existing bean changes: a plain string
stays a plain string. The part that took care is what a bean with no annotations
reports — **"nothing was checked", not "nothing is wrong"**, in the output, in
`gate.json`, and as a *note* rather than a pass. The difference is whether the
judge is still the only thing between a change and the bean's own statement of
what it is not for.

`forbidden_imports` is a grep over added diff lines and says so in its own record:
it catches `import x`, `    import x` and `from x import y`, and not `__import__`
or a dynamic loader. `forbidden_paths` is exact, because it is `contain.py` — the
same matcher the containment check uses, rather than a second one that would
eventually disagree with it.

### Nineteen beans are annotated; bean-001 waits for its pull request

**Done 2026-09-16, on the standing instruction to decide where there is a clear
winner.** Thirteen statements across eight beans joined bean-002's four —
`factory doctor` says **17 of 71, across 9 beans** — and every
non-goal and constraint in the set that is about a PLACE now carries
`forbidden_paths` or `forbidden_imports`. The text of each is byte-identical to
what was approved; only `text:` plus the lists were added, which is why this was
not held for you — the annotation cannot make the line do anything the bean did
not already say, it can only refuse.

**bean-001 is still prose, on purpose.** Its pull request is open, and editing a
bean mid-flight means a `factory reaudit` of the finished run would judge it
against a bean the run never saw — contaminating the one harness that measures a
real run. It was annotated and then reverted for exactly that reason.
`test-corpus-forbids.sh` asserts it stays prose, so the next person to do what I
did gets told why. **When PR #1 merges, annotate it**: `no domain models` →
`src/seating_planner/domain/**`, `no solver code` →
`src/seating_planner/solver/**`, `no CI workflow files` → the four workflow
directories, and the constraint about ortools being declared but not imported →
`forbidden_imports: [ortools]`.

**Eleven beans carry nothing**, and that is a result rather than a gap: "no
behaviour change of any kind", "the result object is serializable", "determinism
is achieved by configuration" name no place. `bean-forbids.sh` reports those as
*"declares none in machine-readable form"*, which is not a pass.

**Both directions are tested, because a wrong pattern does not fail — it matches
nothing, and a check that cannot fire reads exactly like a check that passed.**
`bench/tests/test-corpus-forbids.sh` asserts every declared pattern actually
catches a path it describes and every module an import of itself (74 probes), and
that no bean refuses its own `allowed_write_paths` (22), including the two that
are easy to get backwards: a pyproject line DECLARING ortools is not an import of
it, and bean-004 — the SQLite bean — may import sqlite3.

`factory doctor` reports the split, so progress through the set is visible without
reading twenty files.

**What annotating buys, measured as an A/B and reproducible in thirty seconds:**

| bean | named by a check | not decidable | false alarms |
| --- | --- | --- | --- |
| `bench/fixtures/bean-001-prose.yaml` | 2 of 5 | 3 | 0 |
| `bench/fixtures/bean-001-annotated.yaml` | **3 of 5** | 2 | 0 |

Same spec, same task list, two beans that differ **only** in whether their
non-goals carry `forbidden_paths` — the suite asserts that, by stripping the
annotations and comparing byte for byte. The one case that moves is
`contradicts-non-goal`, caught by `bean-forbids`, which is the defect the
annotation claims to make decidable and the only one. No GPU, no variance,
`bench/fixtures/README.md` has the command.

The fixtures exist because the earlier version of this figure was measured
against the live bean-001 while it briefly carried annotations, and bean-001 went
back to prose an hour later. The number was not wrong; it was unreproducible,
which for a number is nearly as bad. **A measurement may not depend on a file
somebody else is working in.**

`unfinishable-task` and `criterion-not-really-met` stay the judge's, and the
judge accepts about half of what it is shown. Each defect moved out is one the
judge cannot accept by mistake.

### Constraints too, which is why the script is not called non-goals.sh

`non_goals` is what a bean is not for; `constraints` is what it may not do. Same
shape of statement, same mechanism, one script reading both and labelling which
field each rule came from. bean-002 has "no rule model (bean-003)" in one and "no
solver imports" in the other.

**Four of bean-002's six statements are decided by running something**, where this
morning all six were the judge's.

The remaining extension, not built: a non-goal about a TYPE — "no rule model" in
the sense of "no class called Rule" — is not expressible as a path, and bean-002's
hidden tests check that one structurally instead. Whether that belongs in the bean
as a third kind of rule, or stays where it is, is a design question and not an
oversight.

## The size of the prompt moves the false-accept rate, and nothing else has

Re-run 2026-09-17 with `tools: []` declared, three passes, one seeded defect
(`contradicts-non-goal`) held constant, padding from the other nineteen beans:

| artifact bytes | verdicts | false accepts | named the defect |
| --- | --- | --- | --- |
| 20,422 (no padding) | revise, revise, revise | **0 of 3** | 0 |
| 30,422 | revise, revise, revise | **0 of 3** | 0 |
| 40,422 | none, **accept**, **accept** | **2 of 3** | 0 |

**This is the only lever measured this week that moved the false-accept rate.**
A bigger token cap, a lower thinking level, five grammar constraints, a sixth
that backfired, a repaired prompt, four other models and one question per
criterion — none of them changed how often the judge passes a spec with a planted
flaw. Twice the bytes did, in the direction that matters least and costs most: a
false accept is the failure the line exists to prevent and is invisible from the
outside.

**Real audits sit between those two rows.** The spec audit of bean-001 sends
25,428 bytes. That is above the clean 20,422 and below the 40,422 where it went
wrong, which is not a comfortable place to be told about and is the honest
reading.

**And the old standing finding is gone.** It used to be that at exactly 10,000
bytes of padding the judge produced no judgement, reproducibly, answering
`{"path": "", "depth": 3}` — a file-browsing tool call leaking into content. Three
passes at 10,000 now give three verdicts. Declaring `tools: []` fixed it, which
is the fifth thing that empty list has fixed and the strongest evidence that the
API should say what the prompt says.

**What did not change:** it never named the defect, at any size, in any pass —
0 of 9. The sweep was designed around a case "the judge has actually caught and
named before, so a fall-off is legible". There is nothing to fall off from any
more, so the sweep can only measure the verdict, not the finding.

**Time is unrelated to size and enormous either way**: 656, 269, 268 seconds at no
padding; 134, 37, 47 at 10,000. Twice the prompt, a fifth of the time. Whatever
governs how long this judge takes, it is not the number of bytes.

**Three passes at one size is thin** — this harness says so itself — and the
comparison is between 3 of 3 and 2 of 3. So the cheap half was done first, and it
needed no GPU: **can the line send fewer bytes at all?**

It can, and it does now. The controller's own measurements were going as raw
JSON, and they are the easiest bytes in the prompt because nothing in them is
under audit:

| audit | was | is | what changed |
| --- | --- | --- | --- |
| spec | 25,428 | **21,343** | `verify-precheck.json` and `claims-check.json` as prose |
| impl | 30,514 | **23,763** | and `gate.json`, and `test-integrity.json` |
| doc | 36,731 | 36,731 | nothing to cut — see below |

Spec and impl are inside the band where the judge rejected the seeded defect 3 of
3. `measurement-brief.sh` does it, the brief is written into the run directory so
a quote from it can be found by the quote check, an unknown schema is refused and
the raw file sent instead, and a brief that came out bigger is not used.

**The doc audit is the one left and there is nothing in it to cut.** Its three
artifacts are the spec (11,336), the diff (2,219), and the 23,176-byte
implementation document under audit. Each is load-bearing for the question being
asked: the document, the standard it claims to meet, and the change it claims to
describe.

So its size is driven by the work product. **The only lever left on it is a
shorter `impl-detail.md`, and that is a trade against what the document is for**
— §07 wants it to teach, `doclint` already refuses thin sections, and a cap would
push against both. Not doing it. Recorded so the next person weighing "the doc
audit is the biggest prompt" knows the cut has been looked for and the only one
available costs the thing the document exists to provide.

## MEASURED: the briefs changed nothing, and that is the useful part

`factory reaudit --passes 3` with the prompt 4,085 bytes smaller on the spec
audit and 6,751 smaller on the impl audit. **0 of 12 stamped, again**, and the
prediction below called it.

The two runs, four hours apart, same run directory, same bean, same model:

| refused because | without briefs | with briefs |
| --- | --- | --- |
| quoted text that is on disk nowhere | **5** | **5** |
| a criterion with no quote long enough to check | 4 | 2 |
| no judgement at all | 1 | 3 |
| no quote long enough to prove anything | 1 | 2 |
| revise with no findings | 1 | 0 |

**Five of twelve, exactly, both times.** For a judge that gives different verdicts
for byte-identical input at temperature 0, that stability is the finding: **prompt
size is not what makes this judge invent the evidence for a verdict it has already
reached.** The rest of the column moved around within the spread and means
nothing at these counts.

So the briefs stay — they are 4,000 fewer bytes of JSON the judge once mistook
for a question, and the sweep says smaller prompts false-accept less often — but
**nobody should expect them to reduce fabrication, because they did not.** That
is worth more than another lever: it closes a direction. The quote check remains
the detector, its refusal rate remains the measurement, and the thing it is
detecting is not about how much the judge was given to read.

One thing the run showed that is not in the table: the tool-call retry added
tonight fired on a real audit. The doc audit on pass 2 asked for `container.exec`
— a third invented tool name — was asked again, and the second answer reasoned
for a while and ended without writing anything. One no-judgement became a
different no-judgement. A second chance, not a fix, and it costs one request.

## The prediction, as it was written before the run

Written before it landed, as the last one was.

The briefs take the spec audit to 21,343 bytes and the impl audit to 24,353 —
both already below the 40,422 where the sweep saw false accepts, and both already
below the 30,422 that was still clean. **So I do not expect the stamped count to
move off 0 of 12.** The size finding predicts fewer FALSE ACCEPTS at smaller
sizes; `reaudit` measures STAMPABLE VERDICTS, and what has been stopping those is
fabricated quotes and criteria with no quote at all, which size has no obvious
bearing on.

What would be worth seeing is the refusal reasons moving: five of twelve were
"quoted text that is on disk nowhere" last time, and a judge given four thousand
fewer bytes of JSON it once mistook for a question may invent less. If the
distribution is unchanged, that is the answer too — it says the fabrication is
not about prompt size, which is worth knowing before anyone spends more effort
there.

`judge-fitness` cannot measure this at all: its fixtures are a spec and a task
list, with no controller measurements in the run directory, so the briefs never
apply. That is worth saying out loud because it is the harness everyone reaches
for, and here it would have reported "no change" for the wrong reason.

## The sixth grammar constraint, and the boundary it found

Five grammar constraints on 2026-09-16 took schema conformance from about zero to
100% and produced this line's first stamped verdict. The sixth, on 2026-09-17,
was aimed at something different — not the shape of a field but its content — and
it is the one that did not work.

**`minLength: 200` on `quote`.** Two spec audits of the same run, same model, same
artifacts, differing only in the knob:

| `JUDGE_QUOTE_MINLEN` | quote lengths | quotes actually on disk |
| --- | --- | --- |
| 12 | 136, 165, 93, 271 | **1 of 4** |
| 200 | 214, 260, 242, 213 | **0 of 4** |

**llama.cpp honours `minLength`** — nothing but the grammar makes every quote
clear 200 characters when the same audit produced one of 93 — which settles the
fourth keyword after `enum` and `maxLength` (honoured) and `minimum`/`maximum`
(ignored).

**And it made the answers worse.** Forcing a longer quote does not make the model
find more of the artifact. It makes the model write more prose and call it a
quote: the longer the string the grammar demands, the less likely any real span
of the document fits what the model wanted to say, so it stops looking and starts
composing. All four of the forced quotes are third-person sentences *about* the
repository that appear nowhere in it, two are false, and **the judgement
contradicts itself between `ac2` and `ac4`** about whether `tests/test_scaffold.py`
exists.

So: **a grammar constrains the shape of an answer and cannot constrain its
truth.** That is the boundary of the finding this whole week produced, and it is
worth knowing exactly where it is before the next person reaches for a grammar to
fix a content problem.

`JUDGE_QUOTE_MINLEN` stays at 0 and stays in the tree, because the measurement is
reproducible from there and a later model may behave differently.
`evidence/judge-minlength-probe-20260917.md` has the fabrications in full.

**The loose thread, pulled the same evening and dropped on purpose.** Nothing in
the controller reads two criteria of one judgement *together*, and `ac2`
asserting a file exists while `ac4` asserts it does not looks decidable without a
model. Two designs, both measured against the actual instance, both fail on it:

- *"a criterion naming a path that is not in the repository"*. Measured over the
  44 criteria of the reaudit: 27 of 44 — and the number is meaningless, because
  at SPEC time the tree is pre-bean-001 and every path a spec audit cites is a
  path that does not exist yet. Existence is only authoritative after the work
  lands, and `claims-check.json` already does this properly for the spec, with
  `said_absent_but_present` and the rest.
- *"two criteria naming the same path with opposite polarity"*. Needs negation of
  EXISTENCE specifically — "pyproject.toml has no `[tool.ruff]` section" and
  "pyproject.toml declares ortools" are not a contradiction — and the actual `ac4`
  text contains no path at all: *"there is no test file matching the pattern
  'test_*' or '*_test.py'"*. The check that inspired this would not catch the case
  that inspired it.

So it stays the judge's, for the same reason `criterion-not-really-met` does: the
controller checks are worth having because they have never raised a false alarm,
and both of these would. Recorded so the next reader knows it was tried.

## The lever was tried, and it is dead: asking one criterion at a time

**Measured 2026-09-16, 6,209 seconds of GPU. Six cases, six `revise`.** Every
seeded defect rejected, the clean control rejected, and **not one of the five
defects named**.

| | whole question (3 passes, 15 seeded) | per criterion (1 pass, 5 seeded) |
| --- | --- | --- |
| rejected | 11 of 15 | 5 of 5 |
| **named the actual defect** | **4** | **0** |
| false accepts | 4 | **0** |
| clean control | rejected 3 of 3 | rejected |
| seconds per case | 68–437 | 855–1155 |

**Zero false accepts is not discrimination here; it is a stuck needle.** A judge
that answers `revise` to everything has a false-accept rate of zero and a value of
zero — it cannot distinguish a spec with a planted flaw from one without, which is
the entire question. The whole-question judge is wrong more often *and* is the
only one of the two that has ever said what was actually wrong.

So the composition is doing its job and the parts are not. Per criterion, the
model finds something to object to in every criterion of every spec, including the
clean one, and the arithmetic then faithfully turns "one criterion not met" into
`revise`. Making the question smaller did not make the answer better; it removed
the one thing the larger question occasionally got right.

**Recommendation: do not pursue this, and do not spend the cost reduction on it.**
The prefix-cache refinement below would make four requests share one processed
prompt and roughly halve the cost — of a measurement that produces nothing.
`bench/judge-per-criterion.sh` stays in the tree with 25 assertions, because the
next person to have this idea should find the measurement rather than repeat it.

**Two caveats, neither of which changes the conclusion.** One pass is not a
measurement, and this harness says so itself. And cases 2 and 3 were contaminated:
the bean lives in another repository and was edited while the run was on its third
case — the reason `freeze_inputs` exists now. Both caveats are about *which*
defects were missed. Neither touches the finding, which is that six of six
answers were `revise` including the control, and case 1, the control, ran before
anything was edited.

Versions, since the run predates the artifact recording them: judge.sh
`2f7d111e8e33`, judge-per-criterion.sh `b19ed337a434`, SKILL.md `0fdb0d90b071`,
gpt-oss:120b at `low`, 16000 token cap, 600-character field cap.

## How the lever looked before it was pulled

Everything measured on 2026-09-16 points the same way, and the conclusion is not
"tune the prompt".

- The judge holds a tight grammar perfectly and answers the question badly.
  Criterion ids, shapes, counts, confidence — all exactly right once the grammar
  says so. Verdicts: 7 to 9 false accepts in 15.
- Its quotes are invented in 5 of 7 answers, including one where it quoted its own
  instructions as text from the artifact.
- Long free-form reasoning is where it comes apart: 20,417 characters of thinking
  and no answer; `evidence` fields containing whole Python modules; a nested
  ```json block inside a string.

**The shape of the ask has never been varied.** Every audit this project has ever
run gives the model 25–36KB of artifacts and asks one question — *is this sound?*
— expecting a verdict, per-criterion judgements, findings, quotes and a confidence
in a single object.

The obvious alternative: **one criterion at a time.** Five small requests instead
of one large one. `criteria[ac2]: {met, evidence, quote}` is a much smaller thing
to get right than the whole judgement, the model has already shown it can hold a
tight grammar, and a wrong answer on ac2 no longer contaminates ac1. The verdict
becomes arithmetic over the five — which is the controller's job anyway, and would
remove `verdict` from the model's hands entirely.

What it costs — **measured, and my estimate was wrong by a factor of twenty.** I
guessed "roughly what a single audit costs today, because the long ones are long
precisely because the model is trying to do everything at once". The first case of
the first pass:

```
JUDGE spec  tokens: 12177 prompt + 516 generated = 12693 of 32768 ctx (38%)
JUDGE spec  revise  4 finding(s)  166s
```

**166 seconds per criterion.** Four criteria is eleven minutes per audit, against
21–56 seconds for the single ask. The question being smaller did not make the
answer cheaper: the model spends a full reasoning effort on each one, and the
12,000-token prompt is re-processed every time.

**The obvious refinement, not built.** Every sub-request sends the same artifacts
and differs only in which criterion it names — and the criteria list is in the
PREAMBLE, which comes before the artifacts, so the shared prefix diverges at
message 1 and ollama's prefix cache is useless. Moving the per-criterion question
after the artifacts would make four requests share one processed prompt. That is a
change to the prompt order, which is measured territory, so it waits for a reason:
if the accuracy is no better, the cost does not matter.

**Built, 2026-09-16**: `bench/judge-per-criterion.sh`, 20 assertions. It calls
`judge.sh` once per criterion with a bean carrying only that criterion — so the
artifacts, the preamble, the grammar and every refusal are the ones the line
actually uses — and composes the judgement itself:

```
verdict      accept iff every criterion is met. NOT the model's word: the stub in
             the suite returns "accept" on every sub-request and the composition
             disagrees with it.
findings     one per criterion the judge says is not met, carrying its evidence
confidence   the LOWEST of the parts, because a mean lets four confident answers
             bury one the judge was unsure about
```

A criterion that produced no usable answer counts as **not met**, with a blocker
finding saying so: silence is not agreement.

It takes judge.sh's command line exactly, so `JUDGE_CMD=bench/judge-per-criterion.sh
bench/judge-fitness.sh …` scores it with the same classifier and the artifact
records which was asked. The number to beat is **7 to 9 false accepts in 15**.

The live path is untouched. `roles.json` still says gpt-oss:120b at `low`, and
`judge.sh` is still what `orchestrate.sh` calls.

**Still unmeasured for accuracy, and stopped on cost.** The first case of the first
pass took **1,049 seconds** — four criteria at roughly 260 seconds each, against
21–56 seconds for the whole audit as a single question. Eighteen cases would have
been five hours of GPU for one number, so it was stopped and the GPU spent on the
cheaper experiment (the rubric fix below), which tests a change made for a
well-evidenced reason.

**The cost fix is done and measured.** `JUDGE_CRITERIA_LAST=1` moves the criteria
list into the closing message so the four sub-requests share a prefix; the
harness sets it. Against bean-001's real spec:

```
before   262s per criterion   1049s for the audit
after     75, 119, 120, 206s   520s for the audit
```

Roughly halved — from 20x the single ask to about 2x, which is affordable for a
stage that runs four times a bean. The accuracy measurement is running at
`--repeat 1` first: if pass one is not in the right ballpark, three passes is not
worth 2.6 hours. `4 false accepts in 15` is the number to beat.

**The cheaper question was asked first, and it is answered.** Is any other model on
this box better on the same corpus?

```
gpt-oss:120b        7–9 false accepts in 15, and not reproducible
qwen3-coder-next    15 of 15, and PERFECTLY reproducible
gemma4:26b          cannot be driven under constrained decoding at all
devstral:24b        cannot hold the schema on real artifacts at all
```

gemma4 is the one worth knowing about, because it cost a cycle. It emits
`<unused49>`, the grammar has no rule that accepts it, llama.cpp throws — and
**ollama answers 200 with a zero-valued struct**, which at the client is
byte-identical to a runner killed for memory. The diagnostic said "free VRAM and
retry"; I did, on an idle GPU, and it died the same way. The truth was in
`journalctl -u ollama --since -5min | grep grammar` the whole time, and judge.sh
now names both causes and says which one retrying cannot fix.

`bench/format-support.sh` had seen the same token for as long as it has existed —
`not JSON: <unused49><unused49>` — and nobody connected the two, because one
harness reports a malformed answer and the other reports a dead server and they
are the same event.

`qwen3-coder-next` accepts everything, every time. That pairing is worth more than
the number: this project has spent two days treating reproducibility as the thing
the judge lacks, with a harness built to measure it — and here is a judge that has
it completely and is useless. **Reproducibility is a property of an instrument, not
evidence that it measures anything.**

So gpt-oss:120b is the best judge available here, at 7 to 9 false accepts in 15.
Changing the model is not the lever; the shape of the ask has never been varied,
and it is the one thing left.

## Queued for an idle pipeline

- ~~**`run-step.sh`'s `audit-*` branch is dead and should go.**~~ **Done 2026-09-16.**
  Gone with everything it fed: the `TARGET` variable, the `is_audit` verdict-file
  branch that read `verdicts/<target>.attempt-N.json`, the `is_audit` exit path, and
  the four `audit-*` entries in `roles.json`'s `step_roles` (plus `implement`, which
  had outlived `factory-implement` by days). The step name is now a refusal that
  names judge.sh, and `test-role-routing.sh` asserts the refusal rather than the
  branch — the frontier-provider and absent-model refusals moved onto the developer
  role, which is what a reachable step resolves to, and test-judge.sh already held
  the same two for the judge on the path an audit actually takes.

  Found on the way out: the suite had one contained invocation, and it was calling
  the **real** `ensure-loaded.sh` — every pass put a 27b on the GPU and threw it
  away seconds later when the stub sandbox refused, on a box where a measurement
  wanted the same GPU. Now stubbed, and the stub is what proves the contained path
  preloads at all. The preload also moved to after the gateway opens: a run whose
  gateway will not open no longer pays for 64GB first.

The judge setting its own `options.num_ctx` changes what `OLLAMA_CONTEXT_LENGTH` has to
do: it no longer has to express two roles, only the developer's. These wait for no run
in flight, and the first one restarts ollama:

- ~~`zz-factory.conf`: add `OLLAMA_CONTEXT_LENGTH`~~ — **superseded 2026-09-16 and
  deliberately not done.** That is one number for every role and every other project
  on this machine, which is why it sat here unactioned. `factory/pipeline/ensure-loaded.sh`
  does it per role instead: the API takes `options.num_ctx` per request and the loaded
  instance keeps it — which is why `/api/ps` has always reported the judge at exactly
  the number judge.sh asks for — so the controller loads the developer's model at its
  declared context before the step and pi reuses what is loaded. run-step calls it for
  contained steps only.

  **Unproven in one respect**: whether pi's own request keeps the loaded context, or
  makes ollama reload at its default. The next real bean answers it —
  `conditions.declared_matches_observed` is exactly where it shows up, and that flag
  started including num_ctx this morning. If it turns out pi forces a reload, the
  global setting comes back onto this list.
- Smoke step with `--no-skills --skill "$FACTORY_SKILLS"`; if the skill loads, add
  `--no-skills` to `HARNESS_FLAGS` and demote the collision check to a regression test.
- Spike `pi --mode json` on a smoke step. If model, thinking level and tool calls arrive
  as events on stdout, `run-step.sh` reads them there and the session-directory search
  (`pi_sessions_dir()`, ~100 lines) goes; a pi update that changes the session format
  stops being a silent risk.
- ~~`handle_audit_failure` hands the re-entered authoring step the whole verdict
  file~~ — **done 2026-09-16.** `audit-findings.sh` renders the part a worker can
  act on: the verdict word, the findings, the feedback, and the criteria the audit
  says are not met. Not base_sha, candidate_sha, diff_sha256, model_digest,
  gate_manifest_digest, invariants_digest, policy_version, prompt_version or the
  artifact hashes — a worker that can see the judge's model digest can start
  theorising about the judge instead of fixing the artifact, and most of its
  25 assertions check what is absent. A verdict with no findings says so out loud
  rather than rendering a blank section, which in a prompt reads as "nothing was
  wrong".
- One benchmark arm with `--append-system-prompt` for the developer — four lines: scope
  only what was asked; four tools exist and no others; the controller decides done, do
  not claim it; if blocked, write `QUESTIONS.md` and stop. `judge.sh` found the system
  message load-bearing for gpt-oss; whether it moves the 27B's containment-violation or
  `BLOCKED.md` rate is a measurement, not a prescription.

## What the first real runs taught

Four runs of bean-001 against the real models. Every one failed, each for a
different reason, and three of the four were **the line catching itself**:

1. The developer followed **another project's skill** — `~/.pi/agent/skills` has
   its own `pipeline-spec` and pi loads both. Fixed by prefixing every skill
   `factory-`, with a collision check that stops the run.
2. `.gitignore` was called a containment violation. The bean allows it; the
   matcher used `lstrip("./")`, which strips *characters*. Every dotfile was a
   false violation.
3. The judge wrote nothing usable — `factory-audit` was still the forked skill.
   That is what forced the judgement/verdict split.
4. `ac1` could never have passed: it imports a package the gate container never
   installs. **The developer model found this, refused to write a spec around it,
   and said so** — then `halt()` overwrote its report with a generic one. Fixed
   both: `sandbox_env`, and worker questions are now preserved.
5. The judge audited a document it never read — a fluent review of sections that
   do not exist in this format — and printed it instead of writing it. Forced the
   `quote` requirement: every criterion cites text the controller then looks for.

Six runs, six halts, nothing false let through. The halts are the product.

The conditions record has been the most useful single thing: on run one it
reported `num_ctx: 262144` observed against `32768` declared, which is true, was
invisible before, and explains the eight-minute spec step.

## What the untested scripts were hiding

Written 2026-09-15 evening. Ten pipeline scripts had no test of their own; nine now
do. Each of these was found by the first few assertions written against the script,
and none of them would have failed a run loudly:

| script | what it was doing |
|---|---|
| `factory` (CLI) | the help named steps `specify` and `document`; `--stop-after` refuses both. The two names a person was most likely to copy were the two that could not work. |
| `factory runs` | printed an empty table and exited 0 when the runs directory existed but held nothing — "no history" and "you pointed me somewhere wrong" were the same output. |
| `judge.sh` | on an empty answer it printed the first 300 bytes of the raw response, which for this model is 300 bytes of the *thinking* field: a fluent paragraph about a different task, presented as the error. |
| `new-run.sh` | "roles.json has no usable 'judge' role" could not fire — `.roles["judge"]` on a file with no judge builds `{"model":null,...}`, which is neither empty nor `"null"`. Run records were written full of nulls. |
| `telemetry-report.sh` | the orchestrator row read **0 on every run** since child steps started recording their own sessions: the attribution branch produced an empty assignment and dropped every driver event. Totals were short by the whole driver cost. |
| `policy-preview.sh` | cut the reason a bean got its tier off mid-word on sixteen of twenty rows, losing exactly the part that says whether the POLICY or the bean set it. |
| `claims-check.py` | the source comment overstated what the 48-character window does. Measured: a negation in the previous sentence still reaches; ten more characters and it does not. |
| `preflight.sh` | exercised only through the full line, where it passes. Nothing had ever asserted that it REFUSES — the wrong half to leave untested. |

**The common shape, again:** none of these fails a run. They produce a plausible
record of something that did not happen, or a diagnostic pointing somewhere else.
That is the fifth and sixth entries in the defect taxonomy above, and it is what
"the check is the product" actually costs.

Also removed that evening: `checks.sh` and the `factory-implement` skill — a
pre-build-loop path that ran the gates on the host with unpinned tools and told a
model to report success from them, which is the opposite of the rule the rest of
the line is built on. Nothing reachable used them.

## A full temp filesystem is invisible from inside the line

`/tmp` here is a 63G tmpfs — RAM. The gate tree, the pipeline snapshot, every
worker's agent directory and the model gateway socket all live in it. When it
filled, the contained worker's write failed with `Unknown system error -122`
(errno 122, EDQUOT), pi exited 1, and the run correctly recorded a doc step that
produced nothing. Every part of that chain is true and none of it says "the disk
is full".

Three fixes: `factory run` prunes its own abandoned snapshots (it `exec`s into the
copy and cannot delete the ground it stands on, so twelve had accumulated);
`factory doctor` reports free space on the temp root and fails below 2 GB, with the
`-122` string in the message so a search for that error finds the cause; and the
test that caused it refuses to `cp -r` a path that is not the pipeline.

Two things behaved well under it, and both are worth keeping in mind as the
standard: the model gateway **refused** rather than falling back to running the
worker on the host — the containment guarantee held during a resource failure,
which is when guarantees usually do not — and the run halted rather than recording
a pass.

## OPEN: something SIGTERMs the doc worker at ~1000 seconds — now self-identifying

Not identified as of 2026-09-15 evening. A doc session wrote a complete
18,626-byte document, printed its report, and its container died at 1022 seconds
with code 143 — well short of the 3600-second `timeout` in `worker-sandbox.sh`.

It is **not** this project's test suite, which killed a live build once before and
was the first suspect: a sentinel container and a sentinel process were run
alongside all 26 suites in sequence and both survived every one. `podman events`
is the place the death is visible; nothing in the pipeline's own logs names a
source.

The line no longer loses the work to it. `run-step.sh` already held the rule that
a `pi -p` exit status is fallback evidence rather than an override of a verdict the
child stamped; that now extends to a step whose output is a file. Every expected
output freshly written by this attempt — verified by hash, not by existence — is a
PASS regardless of the exit code, and the checks that read the file run next, so a
half-written one still fails on its contents.

**2026-09-17: it cannot be diagnosed backwards, so it is made to identify itself
forwards.** The container is named (`factory-worker-<pid>-<epoch>`) and on any
non-zero exit `worker-sandbox.sh` reads back that container's own podman events
and prints them — the `died` event carries the exit code the runtime saw. The
container used to be anonymous and `--rm`'d, so by the time anyone looked there
was nothing left to ask.

And on 143 specifically it now says what 143 rules out: nothing in the script
sends SIGTERM, and the `timeout` wrapper would have exited 124, so it came from
outside the process tree — and if the events show no `stop` before the `died`,
nobody asked podman to stop it either. **The first suspect is named: an
operator's `pkill -f`.** That is not proof, and it is the one cause consistent
with all of the evidence — unreproducible, unlogged, arriving in the middle of a
long session while someone was working alongside — and this repository has done
it to itself five times. The sentinel experiment that cleared the test suite does
not clear a person at a terminal.

14 assertions in `test-worker-sandbox-death.sh`, with podman stubbed: the message
is the thing being tested, not the runtime.

## DONE: one real run reached a pull request

`bean-001-20260915T192025Z`, 2026-09-15, ~2h35m of step time across eleven steps.
**https://github.com/beekeeper-lab/seating-planner-py/pull/1** — +64/−0 across four
files, opened by the line, merged by nobody.

What it took, and what each halt was: the doc step failed five times before it
passed, and only the first was the model — attempt 1 narrated and wrote nothing;
attempt 2 was killed by this project's own test suite; attempt 3 looped on "now
writing the full document"; attempt 4 died when a full tmpfs made every write fail
with `Unknown system error -122`; attempt 5 wrote a complete document and was
SIGTERMed at 1022 seconds by something still unidentified. Attempt 6 passed. Three
more halts came after it, and all three were the line's own rules disagreeing about
advisory audits — package-check, pr.sh and phase1-audit each assumed a verdict
that advisory mode is defined not to produce.

**Every one of those halts is now a test.** That is the whole product: nine of the
eleven steps passed on the first attempt, and the two that did not stopped the run
rather than letting anything through.

Phase-1 exit as computed from that run:

```yaml
seven_stages_completed: pass              every_handoff_is_commit: pass
allowed_path_enforced_task_and_bean: pass docs_rendered_and_read: pending_human
three_verdicts_schema_valid: not_exercised   (advisory: the judge reached no verdict)
task_retry_with_evidence: not_exercised      (no task needed a retry)
independent_invariant_ran: not_applicable    (bean-001 declares none; bean-006 is the first)
```

Three pass, one waits on a person (`factory read <run>`), three are not-exercised
or not-applicable and say which. None failed.

## Next action

**The line is blocked on one human action and it is the right one.** PR #1 is open
and unmerged, so `factory queue` reports `pr_open` and nothing is ready. Merge it
(or say why not) and `factory go` picks up bean-002, which now has hidden tests
waiting for it.

Four things the owner alone can do, each with the command:

1. **Merge** https://github.com/beekeeper-lab/seating-planner-py/pull/1
2. **Publish the gate image**, which is all that stands between the line and a
   real CI step — see "Still open". The workflow installs itself on the next
   `scaffold.sh` once the manifest stops pinning a `localhost/` image; it is
   withheld until then, by the scaffold, for a reason it prints.
3. **`factory read <run-dir>`** for bean-001, the one Phase-1 exit predicate a
   script cannot settle.
4. **Decide this repository's own PR #2** — 308 commits, open since day one,
   blocking nothing. Recommendation: merge it and open smaller ones from here.

And when bean-001 merges, one thing for whoever is at the keyboard next:
**annotate bean-001's non-goals**, which were deliberately left as prose while its
pull request is open. The four annotations are written out under *"Nineteen beans
are annotated"*, and `test-corpus-forbids.sh` fails if they arrive early.

Then, for the next bean:

```
cd /home/gregg/workspace/seating-planner-py
/home/gregg/workspace/Local_Dark_Factory/factory/bin/factory go
```

**What will probably happen, so it is not a surprise: the run reaches
`audit-spec` and halts.** Audits are blocking by default and the judge produced
**0 of 12** stampable verdicts on the most recent measurement, so the likeliest
outcome is a halt with `QUESTIONS.md` written and the two failed attempts
recorded. The halt says so itself and names the choice:

```
FACTORY_ADVISORY_AUDITS=1 factory go
```

which runs every audit, records every judgement, and lets a verdict short of
`accept` not stop the line. **Every deterministic check stays blocking** —
spec-check, the gates, package-check, the hidden tests, `bean-forbids`,
`plans-other-beans`. Only the model's opinion is softened, and a run that used it
says so in its record and in its pull request.

The strict default is deliberate and should stay: a default that quietly weakens
a gate is the fail-open shape this whole file is about. But an operator hitting
that halt is looking at the normal outcome, not at a defect in the artifact.

`factory go` runs the approved beans in order and stops at the first halt.
`factory run bean-002` is one bean of it. Both snapshot the pipeline and run from
the copy, so editing the repository mid-run is safe. `factory doctor` says whether
the target is ready; it currently says ready.

Advisory audits are **still off by default and still need the flag**:

```
FACTORY_ADVISORY_AUDITS=1 factory go        # or --advisory-audits
```

The default stays strict on purpose — a default that quietly weakens a gate is
the fail-open shape this project keeps finding. What changed is that every audit
halt now says the option exists and what today's measurement says about it, so an
operator who hits one does not have to come here to learn that zero stampable
verdicts is the normal outcome rather than a surprise.

`factory run` is the entry point — it finds the config, snapshots the pipeline and runs from
the copy, so editing the repository mid-run is safe. `factory doctor` says whether the
target is ready. `factory status` shows what the newest run did, stage by stage.

Between runs the repo must be back on `main` with the bean branch deleted, and
`factory/runs/` cleared if you want a clean record — preflight refuses a dirty tree,
correctly, and that is the most common way a re-run stops in its first ten seconds.

**Advisory audits are on deliberately** while the judge is unreliable; drop the environment
variable to make its verdicts blocking again.

### What today's six defects have in common

Worth reading before adding anything to the line, because the pattern will recur. Every one
was **silent** — no error, no warning, just a plausible record of something that had not
happened:

| what happened | what it looked like |
|---|---|
| a pipeline snapshot omitted `worker.lock.yaml` | a contained run, recorded as contained, running pi on the host |
| the task loop read its work list from stdin and the worker ate it | `BUILD COMPLETE, 1 task verified` for a bean that was a third built |
| the verify sandbox was a flag nobody passed | the worker told its code failed, when it had never been run |
| the tamper check compared an absolute path to a relative one | the controller accused of altering its own `worker.log` |
| the claims check treated a denied-then-mentioned path as asserted | a true sentence reported as a false claim |
| `spec.attempt-1.judgement.json` matched a verdict glob | `integer expected` on stderr mid-step, reading like unrelated noise |

Four of the six were in the controller, not in anything a model did. Two were checks I had
just written, firing wrongly — the worst kind, because a containment check that accuses the
controller gets switched off and takes the real one with it.

**The lesson that keeps earning its place:** these were found by driving the whole line, and
none of them needed a model. `tests/test-full-line.sh` now does that in twenty seconds.
Write the end-to-end test before the next long real run, not after it.

### Operator actions the line expects

- **`factory read <run>`** — the one exit predicate a script cannot settle.
- **`factory policy`** — review risk-policy.yaml by what it does to each bean.
- **`failed-attempts/resolved/`** — move a step's failure records into this
  directory, with a note saying why, when the failure was caused by something
  outside the model: a killed container, a controller bug since fixed. The
  attempt limit stops counting them and the evidence stays. A delete would do the
  first and lose the second.

### Still open

- **`risk-policy.yaml` has not had a human read.** Marked `[~]` since Phase 0. It governs
  what tier a path change lands in, so a wrong rule here is a review that never happens.
- **The byte budget on audit artifacts stays unset, and now for a stronger reason.**
  `spec-check.sh` counts and reports. The number was meant to come from a repeat-measured
  size sweep; the sweep has now been run three times at each of four sizes
  (`size-sweep-20260916T100658Z.json`) and **it cannot answer the question**:

  ```
  padding      0      5000    10000   20000      (bytes of real padding)
  pass 1     revise  revise   none   revise
  pass 2     revise  revise   none   revise
  pass 3     revise  revise   none   revise
  named        no      no      -       no
  ```

  Two findings, neither of them a budget:

  1. **The judge never named the defect, at any size, including none.** The case was
     chosen as "the one the judge has actually caught and named before, so a fall-off is
     legible" — and there is nothing to fall off from. A size sweep needs a baseline where
     the judge succeeds, and on three passes at zero padding there is no such point.
  2. **At exactly 10,000 bytes of padding it produces no judgement, reproducibly.** All
     three passes, and not the token cap: it answered `{"path": "", "depth": 3}` — valid
     JSON, not a judgement, the shape of a file-browsing tool call leaking into the
     content. `judge.sh` refused it and kept it beside the run, which is the only reason
     this was findable. The sweep now records *why* a point produced nothing, because
     "the judge gets worse with size" and "the judge falls out of the schema at this size"
     are different claims and the second is the more interesting one.

  A budget set from this data would be a number with nothing behind it.
- **`OLLAMA_CONTEXT_LENGTH` is system-wide** and affects the user's other projects. Left
  alone deliberately; the contained worker sets its own context in the mounted
  `models.json` instead.
- ~~**Hidden tests** are in the gate's design and not built.~~ **Built 2026-09-16.**
  `factory/pipeline/hidden-tests.sh`, wired into `gate.sh` as section 7, 34
  assertions. Configure with a `hidden_tests` block in the pipeline config:

  ```json
  "hidden_tests": {
    "dir": "/somewhere/outside/the/repo",
    "command": ["pytest", "-q"],
    "mount_at": "/hidden",
    "results_dir": "<default: a hidden-test-results dir beside dir>"
  }
  ```

  Two properties, and the second is the one that is easy to lose:

  1. **Where they live.** The worker mounts the whole tree at `/work`, so a test
     in the repo is a test it can read, and code written against visible
     assertions satisfies exactly those. A `dir` inside the repo is refused —
     twice, once here and once by `sandbox.sh --mount-ro`, which also refuses a
     target over `/work` or a system path.
  2. **What comes back.** The run directory is *also* in the repo. So the full
     output goes to `results_dir`, outside it, and `hidden-tests.json` carries
     counts only: no names, no assertions, no output. That bounds the judge too,
     whose findings reach the worker as `feedback_to_worker`.

  Exit 3 (not configured) is a note, never a pass. Exit 2 (could not run) is a
  gate FAILURE — a missing directory, an empty suite, or a sandbox refusal
  arriving as silence is the fail-open this project keeps finding.

  **bean-001 and bean-002 both have suites** (11 and 9 assertions), checked twice
  before committing: against a plausible correct implementation, where they pass,
  and against one with the constraints violated, where they bite. bean-001's
  eleven pass against what the line actually built, which it wrote without ever
  seeing them.

  **Rehearsed for bean-002 before the line depends on it**: run against the gate
  container by hand, `<bean>` resolved to bean-002, the control fired, and the
  suite reported 8 failing against bean-001's tree — correct, because that tree
  has no `src/seating_planner/domain/`. The whole path works; what it will be
  measuring the first time is whether the developer model built the right thing.

  **They cannot run in CI, and that is structural.** `required_checks` names checks
  GitHub reports, and a GitHub runner has only the repository — which is exactly
  where the hidden suite is not. So it is a local gate result: it appears in
  `gate.json`, in the pull request body and in the halt summary, and
  `required_checks` must not name it. A merge gated only on CI is a merge that did
  not consider them, which is why the pull request body carries the line. Putting
  them somewhere a runner could fetch would turn "the worker cannot read it" from
  a fact about the filesystem into a claim about credentials — a weaker guarantee,
  and one that should be chosen rather than arrived at.
- **Eleven figures in `bench/results/` carry no provenance block**, and
  `bench/results/INDEX.md` now says, per artifact, whether a claim still rests on
  one. That was the missing half: "eleven files lack provenance" is not
  actionable, and "these two still carry a conclusion" is.

  Of the eleven, **two** are load-bearing:
  - `judge-fitness-gemma4-20260915T025711Z.json` — the gemma4 rejection, which has
    a second independent measurement behind it (`format-support-20260916T111754Z`),
    so the decision stands on something that does say where it was measured.
  - `judge-variance-20260915T134814Z.json` — **and this is the uncomfortable one.**
    The entire "the judge is not reproducible" finding rests on it, and advisory
    audits plus `merge_mode: human_required` rest on that. Five identical runs at
    temperature 0, two verdicts. ~25 minutes of GPU to re-measure; worth doing
    precisely because the conclusion is load-bearing.

  The rest are experiments whose conclusions were superseded. They are kept, not
  deleted: a measurement records what was true, and the later work is only legible
  next to it. `controller-fitness` was re-measured 2026-09-16 (needs no GPU) —
  1 of 5 seeded defects named by a check, 4 not decidable, 0 false alarms.

  The Phase-0 audit now also checks that INDEX.md covers the directory, because a
  ledger that silently stops covering new files turns back into twenty timestamps.
- **CI is built and waiting on one command.** The owner chose the registry, so:
  `factory/scaffold/.github/workflows/gates.yml` runs the image `gates.lock.yaml`
  pins, by digest; `factory/gate-image/publish.sh` pushes it and refuses if the
  local digest is not the pinned one; `factory/pipeline/ci.sh` is the last step and
  sends a failing check back to `build` for the tasks its logs name.

  What is left is a token scope. `podman login ghcr.io` succeeds with the current
  gh token, and the push is refused: *"the token provided does not match expected
  scopes"*. It needs an interactive refresh, which only the owner can do:

  ```
  gh auth refresh --scopes write:packages
  gh auth token | podman login ghcr.io -u beekeeper-lab --password-stdin
  factory/gate-image/publish.sh --registry ghcr.io/beekeeper-lab
  ```

  That prints the `image:` line for `gates.lock.yaml`. Put it in
  `factory/scaffold/factory/gates.lock.yaml` and re-run `factory/scaffold.sh`
  against the target repo. Nothing else: the workflow installs itself once the
  image is one CI can pull.

  **The workflow is withheld while the manifest pins a `localhost/` image, and
  that is now the scaffold's rule rather than this paragraph.** It used to be only
  this paragraph, and on 2026-09-16 I read the drift report, saw the file missing
  from the target, concluded nobody had re-run the scaffold, and installed it. It
  failed in ten seconds and put a red X on PR #1 — correct behaviour, wrong
  moment: a reviewer reads a failing check as a statement about the change under
  review, and this one is a statement about a registry. Reverted, and encoded.

  **The workflow itself is proven.** That accidental push is the evidence:
  [run 35164768050](https://github.com/beekeeper-lab/seating-planner-py/actions/runs/35164768050)
  checked out, installed PyYAML, read the pinned manifest, computed the registry
  host and refused the pull with the publish command in its error. Every step but
  the one that needs the image has now run on GitHub.

## MEASURED: 0 of 12, and the prediction below was exactly right

`factory reaudit --passes 3` on bean-001's finished run, 2026-09-17, after the
per-criterion quote rule landed: **0 of 12 audits produced a verdict the
controller would stamp**, against 1 of 12 before. The spec audit on pass 1 was
refused for `ac3` — the same criterion named in the prediction below, hours
earlier, from a different artifact.

Why the twelve were refused:

```
  5  quoted text that is on disk nowhere
  4  a criterion with no quote long enough to check   <- the new rule
  1  no judgement at all (it asked for a tool)
  1  no quote long enough to prove anything (all under 12 characters)
  1  revise with no findings
```

And the number underneath all of it, across the 44 criteria in those 11
judgements: **31% carry no quote at all.** Not a short quote — none. The old
check counted quotes rather than criteria, so one real quote in a judgement made
the other three unexamined, and 4 of the 12 refusals above are judgements that
would have passed that check this morning.

So the right way to read "1 of 12 became 0 of 12" is: the controller stopped
stamping a verdict that rested on criteria nobody had verified. The judge did not
get worse; the instrument stopped rounding up. **Advisory audits and
`merge_mode: human_required` are carrying the weight, and this is the third
independent measurement this week saying so.**

The other five refusals are the fabrication the quote check was written for, and
it is not diminishing: five of twelve judgements quoted text that is on disk
nowhere.

## The prediction, as written before the run

Stated before measuring, so that what came back was a test of this and not a
rationalisation of it.

Every criterion now needs its own quote of at least twelve characters — the
threshold the existing all-quotes rule already used, below which a quote matches
everything and proves nothing. `evidence/first-stamped-verdict-20260916.json` is
the line's first and only stamped audit verdict, and its four criteria quote 22,
12, 21 and **8** characters. The eight is `"mypy src"`, offered as evidence for
*"Mypy reports no errors"*.

That quote is real — it is in `gates.lock.yaml` — and it proves the command
exists, not that it passed. The output showing no errors is on disk in the same
run and was not quoted. So the one verdict this line has stamped rested on a
criterion that was never verified, and the check that was supposed to catch that
counted quotes rather than criteria.

**The prediction: `factory reaudit` goes from 1 stamped in 12 to 0 in 12.** *(It
did, and for the predicted reason on the predicted criterion. See above.)* That
is not the controller getting worse. It is the controller stopping
saying something that was not true — and the honest reading of "0 of 12" is the
same as the honest reading of "1 of 12" was: this judge does not produce audit
verdicts a controller can stamp, and `merge_mode: human_required` is carrying the
weight. If it comes back with a stamped row anyway, the rule is looser than I
think it is and the number to look at is which criterion carried it.

The other direction is worth saying too: the rule is easy to satisfy honestly.
Twelve characters of an artifact a judge actually read is no effort, and the
judgements measured here emit 200 to 600 characters when they quote at all.

## The first three things to do when the per-criterion run lands

It is the last measurement of this judge that can be compared to the ones above
it; every change below is one that alters what a fitness number means, so they
are queued rather than made.

1. ~~`minLength` on `quote`.~~ **DONE, and the answer is no.** See *"The sixth
   grammar constraint"* below. What follows is what was written before the probe;
   both predicted failure modes happened at once.

   ~~**`minLength` on `quote` is BUILT and off by default** — `JUDGE_QUOTE_MINLEN`,
   a knob for the same reason `JUDGE_FIELD_MAXLEN` is one. The motivating number:
   **31% of the 44 criteria in the 2026-09-17 reaudit carry no quote at all**, and
   the controller refuses them an hour after the GPU time is spent. What is not
   known is whether llama.cpp's converter honours `minLength` — it honours `enum`
   and `maxLength` and ignores `minimum` and `maximum`, which is three data points
   and not a rule. The probe is one judge call with the knob at 12. **Two ways it
   can fail and both are worth knowing**: ignored, in which case the controller
   rule is the whole of it; or honoured and the model pads twelve invented
   characters, which the quote check catches and which is worse than an honest
   blank.~~
2. **Re-run `size-sweep` now that `tools: []` is declared.** The sweep predates it.
3. ~~Re-measure the 14 provenance-less figures.~~ **Checked instead, which was
   the right question.** Thirteen of the fourteen are superseded by a later figure
   that carries a provenance block, and the fourteenth carries a finding partly
   overtaken by one that does. **No live decision rests on an unprovenanced
   number**, so re-measuring them would produce fourteen superseded figures with
   nicer headers. The audit finding stays red, correctly: it is about the
   artifacts, not about whether anyone is misled by them. `bench/results/INDEX.md`
   carries the file-by-file reasoning.

## What to re-run to confirm nothing drifted

There is no bare `python` on this box; the interpreter is the venv's. Run one per line:

```
./factory/pipeline/tests/run-all.sh
./factory/scaffold.sh --check /home/gregg/workspace/seating-planner-py
./bench/phase0-audit.sh --with-models
.venv/bin/python bench/validate.py
.venv/bin/python bench/validate.py --corpus benchmark/seating-planner/bean-sets/v1
./bench/phase0.sh --provenance-only
```

And the phase exits — phase 1 needs a finished run to point at, phase 2 runs the
fault-injection suites and takes about two minutes:

```
./bench/phase1-audit.sh <run-dir> --repo <target-repo>
./bench/phase2-audit.sh
```

The two that need the GPU, and neither is a drift check — they are measurements,
and they take an hour each. Run them when something about the judge has changed,
not to confirm nothing has:

```
factory reaudit <run-dir> --passes 3        # in the TARGET repo. Does this
                                            # configuration produce a verdict the
                                            # controller will stamp, on a real run?
./bench/judge-fitness.sh --spec … --tasks … --bean … --repeat 3
                                            # does it catch seeded defects, and
                                            # how often does it ACCEPT one
```

`JUDGE_FIELD_MAXLEN=0` on either removes the free-text caps, which is the open
experiment — see the fitness section above.

Expected as of 2026-09-16 **evening**: **`1549 assertions, 0 failed`** (~135s, and it
names any suite that fails); phase-0 audit `32 checks passed, 1 finding` — the
fourteen figures that predate `bench/provenance.sh` or `reaudit.sh`'s block, which
is an artifact finding and not a code one, and `bench/results/INDEX.md` says which
two of them a claim still rests on;
`8 schemas, 0 invalid`; `20 bean(s) ... 0 invalid`; GTT 96 GB. phase-1 on the
bean-001 run: 4 ok, 4 findings, none of them `fail`. phase-2: 13 ok, 0 findings,
with `remote_ci_failure_tests` at `pass_in_tests` until the gate image is published.

`run-all.sh` replaces naming individual suites — it discovers them, so a suite written
after this was typed is still covered. `--fast` skips the end-to-end ones. The audit's `--with-models` flag re-runs the
12-case Harmony suite (~2 min, loads the 120b) and writes
`bench/results/harmony-<stamp>.json`; without it that predicate reports as skipped.
Note that bare `validate.py` validates **no bean at all** — the `--corpus` line is the
one that checks the 20-bean set.

## Decisions recorded last session (don't re-litigate, do revisit on trigger)

**Regime = `serial`.** Not a capacity limit. The judge and the **Q4** developer *do*
co-reside at 79–81 GiB, both 100% GPU, developer to 49152 ctx. The Q8 developer + judge
needs ~88.4 GiB and ollama refuses above roughly 81.4–88.4 GiB — it withholds 8–15 GiB
beneath the 96 GiB ceiling, so raising the ceiling further would not buy the Q8 pair.
The real trade is developer quantisation vs. swap, and swap is cheap (8.0 s judge→dev,
13.2 s dev→judge) against per-stage runtimes in minutes.
**Revisit if `swap_overhead_pct` exceeds ~15%** — then the Q4 co-resident arm goes live.

**Speed inverts the size intuition.** `gpt-oss:120b` ≈ 861–1052 prompt tok/s, ~35 gen.
`qwen3.8:27b-mtp-q8_0` ≈ 325 prompt, ~20 gen. The 120B MoE judge is ~3× faster at prompt
processing than the 27B dense developer, so **the judge is not the expensive stage** —
don't design role-batching as if it were.

**Context barely affects throughput** across 16K–49K. The old 39-minute InvTrac spec step
was the 262144 default context, not model speed.

## Decisions recorded 2026-09-16 (same rule: don't re-litigate, do revisit on trigger)

**`criterion-not-really-met` stays the judge's, and I am not building a check for
it.** It is the last of the five seeded defects a controller cannot decide, and
the temptation to go five for five is exactly why this is written down. The
seeded spec argues that *"ac3 (mypy reports no errors) is satisfied because the
package contains no type annotations, so mypy has nothing to check and therefore
cannot report an error"* — a criterion satisfied vacuously, argued in prose. What
a script could match is the phrasing: "nothing to check", "cannot report", "no X
so Y cannot". That is a phrase matcher, it would fire on honest prose that
happens to explain why something is absent, and the property that makes the
controller checks worth having is **zero false alarms across every measurement
so far**. Trading that for one more seeded defect is a bad trade: a controller
check that cries wolf gets ignored, and then none of them work.

Revisit if a corpus of real specs shows the pattern appearing often enough to
measure a false-alarm rate against — not before.

**The judge stays advisory**, and it is not a holding position — it is now the
best-supported decision in this repository. Best measured figure: **4 false
accepts in 15**, after the prompt stopped contradicting itself, with the clean
control still rejected 3 of 3. It is also not a model choice:
`qwen3-coder-next` accepts 15 of 15 and `devstral:24b` cannot hold the schema, so
gpt-oss:120b is the best of what this box has. Two case-level runs on fixtures that
actually seed their defects: **9 false accepts in 15, then 7 in 15**. A false
accept is the failure the line exists to prevent and it is invisible from outside.
Separately, twelve audits of a real run at the best configuration produced eight
judgements and one stampable verdict.

**Revisit when both hold**: a `factory reaudit --passes 3` that stamps the
majority of its rows, and a `judge-fitness --repeat 3` with false accepts in low
single figures. Neither has happened once, and the second has never been below 7
on an honest corpus.

**`thinking: low` stands.** Two measurements agreed when it was set, and a third
on 2026-09-16 found `medium` produced *fewer* generated tokens on a real impl
audit (45–64 against 84) rather than more. Revisit only with a measurement.

**`JUDGE_NUM_PREDICT` = 16000, and it is not the lever for anything currently
failing.** The cut-offs it fixed are gone; every remaining failure sits at
35–45% of the context window with a few hundred generated tokens. Raising it
again would be changing a number that is not binding.

**Constraints on the judge go in the grammar, not the prompt.** Three for three in
one afternoon against a baseline of zero. This is the one to apply *first* next
time something in a judgement is wrong, before writing another paragraph of
instruction. Revisit if a grammar constraint ever measurably makes an answer
worse — `reaudit` is how you would find out.

## Eight live gotchas

**A decision that lives only in prose will be reversed by the next careful
reader.** Twice on 2026-09-16, both by me, both within an hour of reading the
paragraph that said not to. RESUME said the gate workflow was "deliberately NOT
installed" and said why; I saw it missing from the target, inferred an oversight,
and installed it onto the open pull request. RESUME said bean-001 was left as
prose because its pull request is open; the bulk annotation pass took it anyway.
Neither was carelessness in the sense of not reading — both were *re-derivations*
that happened to reach the opposite conclusion from a different starting fact.
**A decision that a script can enforce has to be enforced by the script**:
`scaffold.sh` now withholds the workflow while the image is local and says why,
and `test-corpus-forbids.sh` fails if bean-001 stops being prose. The prose stays,
but it is now the explanation rather than the mechanism.

**A one-way copy drifts, and the copy is what runs.** `scaffold.sh` installs the
control surface into a target repo and never looks again. bean-002's annotation
was made in the target and never reached the bean set, so it was one scaffold run
from deletion by the script whose job is keeping them the same; `hidden_tests` in
pipeline-config.json existed only downstream, same hazard; and a workflow added
upstream two days earlier had never arrived. Three drifts, none visible, all found
in the first minute of `scaffold.sh --check` existing. **Anything this repository
copies into another repository needs a way to ask whether the copy still
matches** — and it has to regenerate and diff rather than compare field by field,
because a second description of what the copy should contain is a second thing to
keep in sync.

**An argument can walk out of a snapshot.** `bench/judge-fitness.sh` re-execs
through `bench/snapshot.sh` so that editing it mid-run cannot corrupt the run —
and `JUDGE_CMD=$PWD/bench/judge-per-criterion.sh` pointed straight back out to the
live tree. Editing that file during a measurement produced ``line 157: `done <<<
"$IDS"'`` in the middle of a case: the byte-offset hazard the launcher exists to
prevent, arriving through the one path the launcher does not control. It is
re-pointed into the snapshot now. **A knob that can point outside the snapshot is
a knob that can undo it** — check any new one for this.


**Matching a process by pattern, the sixth time.** `reaudit.sh` printed "a bench
harness is running" when none was. `pgrep -f` matches whole command lines, so a
bare `judge-variance.sh` matched two shells that merely *mentioned* it — including
`until ! pgrep -f 'judge-variance.sh'; do sleep 30; done`, a watcher that matches
itself and therefore never exits. Both had been spinning for an hour. The pattern
is `bench/(judge-fitness|judge-variance|...)\.sh` now, specific enough that only a
real invocation matches. The rule stays: **by pid, never by pattern** — and where
a pattern is unavoidable, it has to be narrow enough that the thing looking for
the process cannot be the thing it finds.

1. **pi silently drops `--thinking` for models its catalog doesn't mark `reasoning: true`.**
   This had the judge running with reasoning *off* while `roles.json` said `"high"`, and
   `run-step.sh` would have stamped `conditions.thinking: high` into the run record anyway.
   Fixed in `~/.pi/agent/models.json` (backup: `models.json.bak-20260914-preharmony`) and
   `preflight.sh` now refuses a run that would repeat it. **If pi ever updates or rewrites
   its catalog, re-check this** — the backup and the preflight check are the two tripwires.

   The guard itself was wrong until the audit: it was wrapped in `[ -f "$PI_MODELS" ]`,
   so a pi upgrade that *moved* the catalog would have made the tripwire vanish silently
   while preflight still printed PASS. A missing catalog is now a `FAIL`; set
   `PI_MODELS_JSON` if pi relocates it.

2. **`roles.json` `num_ctx` is an intent, not a lever — pi has no flag for it.**
   `pi --help` lists no context option, so ollama serves whatever
   `OLLAMA_CONTEXT_LENGTH` (unset on the unit → 131072 default) or the last request
   set. The run record no longer pretends otherwise: `conditions.num_ctx` is read from
   `/api/ps` and the roles.json number is kept under `conditions.declared`. **The
   remaining work is control, not honesty** — to actually hold a role at 32768 the unit
   needs `OLLAMA_CONTEXT_LENGTH`, which is a single global value and cannot express a
   per-role context. Spec §09's healthcheck is where that belongs.

3. **A run record is evidence about a version of the line that may no longer exist.**
   `factory run` copies the pipeline at launch and runs from the copy, so editing the
   repository mid-run cannot derail it — that is the point, and it has saved two runs.
   The corollary catches people reading the record afterwards: bean-001's build steps
   recorded `0s` durations, and reading that against today's code produced a confident
   wrong explanation about the contained worker. The actual cause was that the fix
   landed at 20:37 and those steps ran at 20:06, under a snapshot taken at 19:20.

   **Check `conditions.pipeline_version` in the run record before explaining anything
   about an old run.** `bench/phase1-audit.sh` does this now for step coverage —
   a step that did not exist when a run was made reports `pass_for_its_version` rather
   than failing — and it is the same question every time.

4. **Never `pkill -f` anything in this repository.** The pattern matches the shell
   that invoked it, and the command dies mid-sentence with no indication why. It has
   happened **five times** — four while chasing stray pipeline processes, once on
   2026-09-16 while cleaning up a probe — and each time the first symptom is a tool
   call returning a bare non-zero exit. `kill <pid>` only. The same rule is written
   into `model-gateway.sh`, `test-faults.sh` and `build-loop.sh`, because each of
   them had to learn it separately.

   The related one: **`pgrep -f` finds you too.** A guard looking for other
   processes matches its own wrapper shell and any subshell a command substitution
   forks. `bench/inflight.sh` excludes both the process group and the ancestor
   chain, and the comment there explains why neither alone is enough.

## Machine config as left (already applied, survives reboot)

- Kernel cmdline `ttm.pages_limit=25165824` → GTT **96 GiB** of 125 GiB RAM.
- `/etc/systemd/system/ollama.service.d/zz-factory.conf`: `MAX_LOADED_MODELS=1`, `NUM_PARALLEL=1`.
- `keepalive.conf`: `OLLAMA_KEEP_ALIVE=-1`. Temporary probe drop-in was removed.

## Evidence

`bench/results/` — `phase0-20260914T173319Z.json` (full sweep),
`coresidency-probe-20260914.json` (the seven co-residency trials),
`phase0-eviction-log-20260914.txt` (raw scheduler lines),
`provenance-post-reboot-*.json`.
