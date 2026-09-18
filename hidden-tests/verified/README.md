# verified/ — which hidden suites have been checked both ways, and against what

`verify.sh` writes one record per suite here. It exists because that check was
the one thing in the line that ran and wrote nothing down.

What is at stake is in verify.sh's own header: a hidden suite that can never
pass **blocks every attempt of its bean forever**, and the worker is told only a
count — so it cannot tell a wrong test from its own wrong code. Whether that had
been ruled out for a given bean lived in whoever last ran the command and
remembered.

Each record carries:

- `outcome` — `ok` (both directions), `half_checked` (can fail; never seen a
  real tree), or `not_verified`.
- `suite_sha256` — the suite's files and its `absent-by-design.txt`, hashed.
  **This is the useful half.** A suite edited since it was verified is back to
  unknown, and editing a hidden test is exactly what happens when one of them
  turns out to be wrong — bean-002's was edited the same day it was verified,
  because it failed a correct implementation on a capital letter.
- `checked_against` and `tree_sha` — the ref the "does it pass" half ran on.

`factory doctor` reads these and says how many suites are verified, how many
have been edited since, and how many have never been checked. A note, not a
failure: a repository can be perfectly runnable with an unverified suite, right
up until the bean it belongs to runs.
