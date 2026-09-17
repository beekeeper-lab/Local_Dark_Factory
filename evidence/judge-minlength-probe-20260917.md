# `minLength` on `quote` — honoured exactly, and every quote it forced was invented

2026-09-17. Two spec audits of bean-001's finished run, same artifacts, same
model (gpt-oss:120b, `low`, 16000 cap), differing only in `JUDGE_QUOTE_MINLEN`.

## Does llama.cpp's schema-to-grammar converter honour `minLength`?

**Yes.** It honours `enum` and `maxLength`, ignores `minimum` and `maximum`, and
this settles the fourth: at `minLength: 200` every quote came back between 213 and
260 characters, where the same audit at 12 produced one of 93. Nothing but the
grammar could have done that.

## Did it make the answers better?

**No — it made them worse, and the direction is the point.** Every quote was
checked against the artifacts on disk, normalised for whitespace, the same way
`audit-check.sh` checks them:

| `JUDGE_QUOTE_MINLEN` | quote lengths | real | invented |
| --- | --- | --- | --- |
| 12 | 136, 165, 93, 271 | **1 of 4** | 3 |
| 200 | 214, 260, 242, 213 | **0 of 4** | 4 |

Forcing a longer quote does not make the model find more of the artifact. It
makes the model write more prose and call it a quote. The longer the string the
grammar demands, the less likely any real span of the document fits what the
model wanted to say — so it stops looking and starts composing.

## What it composed

At 200 characters, all four:

- `ac1` — 214 chars

  > The repository has a pyproject.toml file with a version field set to 0.1.0 and a tests/test_scaffold.py that imports seating_planner and asserts __version__ equals "0.1.0". Therefore, the spec's conditions are met.

- `ac2` — 260 chars

  > The repository has a pyproject.toml file with a version field set to 0.1.0, and there is a test file tests/test_scaffold.py that imports seating_planner and asserts `seating_planner.__version__ == "0.1.0"`. This confirms the presence of both required elements.

- `ac3` — 242 chars

  > There is no `requirements.txt` file in the repository as required by the spec. This violates the requirement that the repository must contain a 'requirements.txt' file with appropriate content. Therefore, this part of the specification fails.

- `ac4` — 213 chars

  > There is no test file matching the pattern 'test_*' or '*_test.py' in the repository. This violates the requirement that there must be a test file for the function being checked. Hence this part of the spec fails.

Every one is a sentence *about* the repository, in the third person, of a kind
that appears nowhere in any artifact. Two are also false: `tests/test_scaffold.py`
is in the repository, and no part of the spec asks for a `requirements.txt`.

**And the judgement contradicts itself between two of its own criteria.** `ac2`
says *"there is a test file tests/test_scaffold.py that imports seating_planner"*;
`ac4` says *"there is no test file matching the pattern 'test_*' or '*_test.py' in
the repository"*. Same document, same model, same request. Nothing downstream
caught that, because nothing looks for it — the criteria are checked against the
bean's list and each quote against the disk, and neither check reads two criteria
together. That is a candidate for the controller and it is cheap: two criteria of
one judgement asserting the presence and the absence of the same file is
decidable without a model.

For comparison, at 12 characters, the one that was real:

- `ac1` — 136 chars: `There is a file named .gitignore that contains the string 'factory' and 'ruff', but not a single lin`
- `ac2` — 165 chars: `The repository does contain a test file (tests/test_scaffold.py) that imports the package and checks`
- `ac3` — 93 chars: `- kind: command
        run: ["pytest", "-q", "tests/test_scaffold.py::test_package_imports"]`
- `ac4` — 271 chars: `The repository does not contain a file named 'factory/pipeline-config.json' as required by the test.`

## What this settles

**A grammar constrains the shape of an answer. It cannot constrain its truth.**

That is the boundary of this project's one transferable finding — *on this model
a constraint in the grammar is a rule and the same constraint in prose is a
suggestion* — and it is where the finding stops being useful. Five grammar
constraints took schema conformance from about zero to 100% and produced the
line's first stamped verdict. A sixth, aimed at the content of a field rather
than its shape, produced four fabrications.

**`JUDGE_QUOTE_MINLEN` stays at 0.** The controller's per-criterion quote rule is
the whole of it: it refuses a criterion whose quote is too short to check, and
the quote check refuses one that is not on disk. Both refuse *after* the answer
exists, which is the cost, and both are refusing something real.
