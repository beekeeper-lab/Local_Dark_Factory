# State of the line — 2026-09-18, judge section updated 2026-09-21

Where this is, what is wrong with it, and what I would do next. Written to be
picked up cold; `RESUME.md` is the long version with the measurements attached.

---

## What works

**The line runs end to end and has merged two pull requests written entirely by
local models.**

| | |
| --- | --- |
| bean-001 | project scaffold, merged 2026-09-17 |
| bean-002 | domain models — 336 lines, 5 files, merged 2026-09-18 |
| bean-003 | gate green 2026-09-21 after the budget went 400 → 450; audits advisory, doc step running |
| remaining | 17 of 20 beans |

Eleven stages: preflight → spec → audit-spec → build → gate → audit-impl → doc
→ audit-doc → audit-package → sync → pr → ci. The controller is deterministic
shell and Python; the models write the spec, the code and the documents; a human
merges. **2,230 assertions across 40-odd suites, all green.**

What the line catches by itself, without asking a model anything: a spec that
describes files that do not exist, a verify command that already passes before
the change, a task that plans another bean's work, a diff outside the bean's
declared paths, a test suite that still passes with the change reverted, a
document that does not cover every file it changed, a judgement quoting text
that is in no artifact, a required CI check that went red without running a
single gate.

---

## The central problem: the judge is not accurate, and no configuration fixes it

**The model is `gpt-oss:120b` and it is the best available on this box.**
Measured alternatives: `qwen3-coder-next` accepts 15 of 15 seeded defects — a
rubber stamp; `gemma4:26b` cannot be driven under a response grammar at all (it
emits a token the constrained decode has no rule for, llama.cpp throws, and
ollama answers 200 with an empty struct); `devstral:24b` cannot hold the schema.

**Configuration was wrong and is now right, and it bought conformance rather
than accuracy.** `thinking: medium` was the one level that does not work —
measured under a real 18KB payload, medium and high spend the entire token
budget reasoning and write nothing. Now `low`. The token cap went 12000 → 16000
and cut-offs went 4/18 → 0/18. `repeat_penalty 1.1` stopped a model that spent
its last few hundred tokens repeating one sentence inside a string it never
closed. Five grammar constraints took schema conformance from ~0% to 100%.
Every one of those worked. **None of them moved accuracy.** The judge now
reliably produces perfectly-shaped JSON that is wrong.

**The number that decides it is not the false-accept rate.** It is this:

> The clean control — a spec with nothing wrong with it — has been **rejected
> 3 of 3 in every configuration ever measured.** It has never once passed.

False accepts sit at a fifth to a quarter (4 of 15 seeded defects; 2 of 10 on a
clean size sweep — two harnesses, different case mixes, different days). A judge
that accepts a quarter of planted defects *and* rejects every correct spec is
not noisy around the truth; on this task its output is close to uncorrelated
with it. There is no threshold that makes it a gate: tightening it blocks good
work as fast as it catches bad.

**One change ever moved the number**, and it was not a model or a parameter:
removing a contradiction from the prompt, which told the judge to "open the
files named below" in a prompt whose preamble says it has no tools. 9 → 4 false
accepts in 15. Prompt size, measurement briefs, asking one criterion at a time,
quote-length rules, a different model: nothing, and the prompt-size finding was
**retracted in full** when the harness behind it turned out to be reporting its
first pass five times.

### So: model, configuration, or use?

**Use.** Most of what the audits were being asked is decidable by running
something, and that work has moved to the controller, which now decides 4 of 5
seeded defects. The line got substantially more reliable this week and the
judge's accuracy never moved at all. The remaining question is what an LLM is
*for* here, and the answer this repository has arrived at is: the part counting
cannot reach, advisory, never blocking.

### What is genuinely still open on the judge

Refusal records (added 2026-09-17) made the failure modes countable for the
first time, and they are **not all the same failure**:

```
by stage                                          (as of 2026-09-21)
  impl      3   criterion-quote-too-short, tool-calls-instead-of-answer
  spec      2   budget-spent-thinking, quote-not-on-disk
  doc       1   budget-spent-thinking
  package   1   verdict-without-findings

  7 of 7 audit(s) reached no verdict; 0 were stamped
```

That count was 6 an hour before it was 7, and the difference is a controller
defect rather than an audit: the attempt number was derived from judgement files
only, so a target that never produced one wrote every refusal as `attempt-1` and
each refusal **deleted the one before it**. A run that failed twice kept the
second. It is fixed, and the arithmetic it was corrupting is the arithmetic this
section is made of.

Two of five are `budget-spent-thinking` — the model used all 16,000 tokens
reasoning and wrote nothing. That looked like our cap rather than its failure,
and it was called the one configuration lever with fresh evidence behind it.

**Measured 2026-09-21, and it was not the lever.** bean-003's impl audit refused
the same way; the numbers behind it are now in the refusal record rather than in
terminal scrollback:

```
prompt_tokens         12355
generated_tokens         49
num_ctx               32768
headroom_for_answer   20413     ← num_ctx − prompt_tokens
context_was_the_limit  false
```

There were **20,413 tokens of room** and the cap was 16,000, so it was never
binding on the window. And the premise underneath the recommendation was wrong:
the spec prompt is not two to three times the impl prompt, it is the same size.
Measured across two runs, in bytes sent — `doc.request.json` and friends record
this per audit:

| target | artifacts | bytes | against impl |
| --- | --- | --- | --- |
| doc | 3 | 61,392 | 1.8× |
| impl | 6 | 34,585 | — |
| spec | 5 | 34,422 | 1.0× |
| package | 6 | 18,689 | 0.5× |

Only `doc` is meaningfully larger, and it is larger in the direction that makes
raising the cap **useless**: at roughly 2.8 bytes per token, 61KB is near 22,000
prompt tokens, which leaves about 10,900 of a 32,768 window — *less* than the
16,000 cap it already has. A doc audit that tried to spend its budget would hit
the context window first. That last figure is an estimate from one sample's
bytes-per-token and not a measurement; the next doc refusal will carry the real
numbers, because refusals now record them.

**What the trace says the failure actually was.** The 66KB of reasoning is kept
at `evidence/bean-003-judge-built-the-bean-20260921.txt`. It opens *"We need to
determine if the implementation (the code we wrote)"* — the builder's voice, for
work the preamble tells it it did not see produced — and continues with 24 ×
"we need to implement", 10 × "Let's open", 23 × "guess", ending mid-sentence
drafting a test function it invented. It was not short of room. It was carrying
out the bean.

The first thing it quotes is the fix: *"Create
src/seating_planner/rules/template.py and nothing else"*, from the spec — the
one imperative artifact on an impl audit that did not carry the sentence saying
it is addressed to a different model and is not a task for the judge to carry
out. The bean and the task list had it. The spec did not, on the impl and doc
targets where it is context rather than the thing under audit. It does now.

**What that bought, and what it did not.** Two attempts after the change, both
refused identically: 49 and 60 generated tokens, each asking to call
`repo_browser.print_tree` — a tool from some other harness, in a prompt that
says there are no tools — twice, refused as `tool-calls-instead-of-answer`. So
the change moved a 16,000-token failure to a 50-token one, reproducibly, and
**still produced no verdict**. It is a cheaper failure and a clearer one. It is
not a judge.

This does not change the conclusion above; it removes the one lever that looked
untried. `factory reaudit` is where a real number for it comes from — n is 2
here, on a model measured as not reproducible on identical input.

---

## The other open problems

**1. Phase 1 cannot close, and one of the two reasons is deliberate.**
`three_verdicts_schema_valid` requires a verdict the controller will stamp, and
the judge has produced zero in twelve measured audits. Refusal records now make
the better question — *did every audit reach a recorded decision?* — satisfiable,
and rewriting the predicate to ask it would be moving the goalpost with the file
open. It stays unmet. `docs_rendered_and_read` needs a person to run
`factory read <run-dir>` once; an agent can only record a weaker fact, and all
three readers of that file distinguish the two.

**2. CI is red for a reason that has nothing to do with any change.** The gate
image is published to a private GHCR package linked to no repository, so the
workflow's `GITHUB_TOKEN` cannot see it and GHCR answers `manifest unknown` —
the same answer it gives for an image that is not there. One settings toggle
fixes it (make the package public, or grant the repo access); there is no REST
endpoint for container visibility. The line classifies this correctly on its own
now: no gate ran, so the red says nothing about the change, and it halts rather
than sending a worker to fix code nothing executed.

**3. The controller's own bookkeeping is where the defects are.** Fourteen were
found in one evening, every one of them by a bean actually running, and all but
two were in the controller rather than in any model: a container entrypoint that
turned every worker exit into 143; a freshness rule that scored a correct
minimal edit as "wrote nothing"; a halt a resume walked straight past; a killed
process orphaning an attempt so every later resume lost the step; `jq -s`
without `-c` quietly turning the step log into not-JSONL; three separate readers
of one directory each mis-reading it in front of a real run; two instructions the
environment made impossible, which workers dutifully worked around and
apologised for in their reports.

**4. Two false alarms, the first this project has had.** Both fired on bean-003
and both sent a correct spec back. `current behaviour` failed a spec for saying
"`tests/` contains only `test_scaffold.py`" because it resolved the bare
filename from the repo root. `plans-other-beans` reported that a task planned
another bean's work on the terms `construction` and `module` — two generic
English words that happened to satisfy every condition. Both fixed, the second
by requiring an *adjacent* distinctive pair rather than two scattered words: a
subject is a phrase. The worth of these checks is that they have no false
alarms, so each one is a serious event.

**5. Speed.** A bean costs two to four hours. The doc step alone runs 30–60
minutes and is the slowest thing in the line. Nothing has been done about this
and nothing should be until the line is right.

---

## Where I would go from here

**1. Run beans.** This is the whole recommendation. A week aimed at the judge
moved the false-accept rate by nothing; one evening of a real bean walking the
line moved reliability more than all of it — because a real run is the only
thing that exercises resume, halt, retry, and the parts of the record nothing
else writes. 2,214 passing assertions caught none of those fourteen defects,
because they live in the seams the tests stub out.

**2. Unblock bean-003** by raising its size budget from 400 to about 450. The
bean asks for four rule types, validation, serialization round-trip and a
seven-category template; 400 was a guess and the work came in at 404.

**3. Keep moving decidable work to the controller**, and keep the judge
advisory. That is the best-supported decision in this repository.

**4. ~~Raise `JUDGE_NUM_PREDICT` for the spec and doc targets specifically.~~**
Measured 2026-09-21 and withdrawn. The impl audit had 20,413 tokens of headroom
against a 16,000 cap, so the cap was never binding; the spec prompt turns out to
be the same size as the impl prompt rather than two to three times it; and the
doc prompt is large enough that its headroom is *below* the cap it already has,
which makes `num_ctx` the lever there if anything is. The real failure was a
prompt contradiction, and fixing it moved a 16,000-token failure to a 50-token
one without producing a verdict. See the judge section above.

**5. Write hidden suites ahead of the line.** bean-003's and bean-004's were
written before their code existed, which is the only way "write them from the
bean, not from the diff" can be relied on rather than promised — and bean-003's
passed on the first tree it ever saw. Two rules earned the hard way: never
restate a constraint that is already machine-readable in `bean.yaml`, and match
loosely enough that a correct implementation cannot fail on a capital letter.

**6. The one decision that is not mine.** The obvious fix for the judge — a
frontier model for the audit step — is blocked by design rather than by effort:
`judge.sh` enforces a provider allow-list and the project's defining constraint
is *no frontier model at runtime*. If that constraint is absolute, the question
is settled and the judge stays advisory permanently, with the controller and the
human merge as the gate. That is a coherent design and I would keep it.

---

## What to read, in order

1. `README.md` — what the line is and how to run it.
2. This file.
3. `RESUME.md` — the long ledger: every measurement, every retraction, and
   **fourteen ways a check goes wrong**, which is the most portable thing here.
4. `git log` — the reasoning lives in the commit messages, deliberately.
