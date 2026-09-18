"""Does the spec's account of the current code match the code?

The spec rubric asks the judge: "Does the spec claim the code does something it
does not? Check 'Current behaviour' against the real files." One of the seeded
defects in bench/judge-fitness.sh is exactly that, and across four runs no judge
ever named it.

It does not need a judge. A spec's Current-behaviour section names files and
symbols, and whether those exist is a question about the filesystem.

Two kinds of claim, treated differently on purpose:

  a path      `src/seating_planner/solver.py` either is there or it is not.
              A spec describing what a file currently does, when the file does
              not exist, is stating a falsehood. That is decidable and it fails.

  a symbol    `solve_seating` might be a function in the codebase, or it might be
              a name the spec is about to introduce, or prose. Grep decides
              whether the string occurs anywhere; absence is worth reporting and
              is not proof of anything, so it is reported and does not fail.

The line between them is drawn conservatively: a backticked token counts as a
path only if it looks unmistakably like one.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# A fenced block is example code, not a claim about what is there now. Specs
# routinely show the code they are about to write inside one, and every
# identifier in it would otherwise be reported as missing.
FENCE = re.compile(r"^```", re.MULTILINE)
BACKTICKED = re.compile(r"`([^`\n]{1,200})`")

PATH_LIKE = re.compile(
    r"""^(?!-)                      # not a flag
        (?=.*[/.])                  # has a separator or an extension
        [\w./@+-]+$                 # and nothing that would make it prose
    """,
    re.VERBOSE,
)
# Extensions we are confident name files. A bare `foo.bar` with an unknown
# extension is left alone: `pytest.ini_options` is a TOML key, not a file.
KNOWN_SUFFIXES = {
    ".py", ".js", ".ts", ".tsx", ".jsx", ".go", ".rs", ".rb", ".java", ".c",
    ".h", ".cpp", ".sh", ".bash", ".yaml", ".yml", ".json", ".toml", ".cfg",
    ".ini", ".md", ".rst", ".txt", ".sql", ".html", ".css", ".lock",
}
SYMBOL_LIKE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{2,}$")

# A Current-behaviour section names absent things as often as present ones, and
# saying so accurately is exactly what a good one does: "There is no
# `src/a.py`." is a true statement about the current behaviour, and flagging it
# as a false claim would punish the specs that describe the starting state most
# carefully. So the sentence around each path is read for negation, and a path
# asserted to be absent is not required to exist.
#
# This is a heuristic over English and it will miss constructions not listed
# here. It errs toward silence: an unrecognised negation means the path is
# checked and, if absent, reported — which a person then reads. The opposite
# error, treating a described-as-missing file as a false claim, would make the
# check untrustworthy on exactly the specs that are written well.
# What counts as a claim that a file exists NOW.
#
# The first three versions of this asked the opposite question — is there a
# negation near the path? — and treated everything else as an assertion that the
# file exists. That was wrong on every real spec it met, three times, always the
# same way: a Current-behaviour section legitimately talks about the future.
#
#   "Both are fixed by this bean creating `tests/` and `src/`."
#   "...a `testpaths` setting in `pyproject.toml` (an allowed write path)"
#   "no `pyproject.toml`, no `src/`, and no `tests/` exist in the repository"
#
# None of those says the file is there, and only the third contains a negation.
# The absence of a negation is not evidence of an assertion, and building a
# failure on it means accusing a well-written section of lying about a file it
# was careful to describe as missing.
#
# So the default flips: a path is only required to exist when the text near it
# says it does. That is a narrower rule, it will miss some real inventions, and
# the trade is deliberate — the seeded defect this exists to catch says "The
# repository ALREADY CONTAINS `src/seating_planner/config.py`", which is exactly
# the shape of a false claim about the present. A spec that invents a file
# without claiming it is there is making a much weaker error.
ASSERTS_EXISTENCE = re.compile(
    r"""\b(
        already | currently | at\s+present | today | now\s+(contains|holds)
        | contains | holds | exists | lives\s+(at|in) | sits\s+(at|in)
        | is\s+(present|there|at|in) | are\s+(present|there|in)
        | ships\s+with | carries | declares | defines | sets\s+up
        | the\s+repository\s+has | we\s+have
    )\b""",
    re.VERBOSE | re.IGNORECASE,
)

# Still read, but only to record that the section calls a path absent — never to
# suppress anything, because suppression is now the default.
#
# Deliberately narrow, and narrower than it was. While assertion was inferred
# from the absence of negation, this had to catch every way of saying "not here",
# including forward-looking ones like "creating" — and that made "this bean
# creating `src/`" read as a claim that src/ is absent, which then read as a
# contradiction once src/ existed. Now that an assertion has to say so, this only
# needs to catch actual statements of absence.
NEGATION = re.compile(
    r"""\b(
        no | not | never | nothing | none | without
        | isn't | aren't | doesn't | don't | won't | cannot | can't
        | absent | missing | empty | lacks? | lacking
        | yet\s+to\s+be | does\s+not | do\s+not
    )\b""",
    re.VERBOSE | re.IGNORECASE,
)

# How far from the path a claim still counts. Deliberately small: English puts
# "already contains" and "does not exist" next to what they are about, and a
# wider window picks up clauses belonging to other nouns. The case that prompted
# it was a sentence-wide window reading "the package does not exist. The entire
# working tree (excluding `factory/`...)" as a denial of `factory/`.
#
# Measured, because the first version of this comment claimed more than the
# numbers deliver: at 48 characters a negation in the *previous sentence* still
# reaches a path that begins immediately after it, and stops reaching once about
# ten more characters separate them. So the window bounds the reach; it does not
# eliminate it, and a denial from a neighbouring clause is still possible.
#
# That is survivable only because of what a denial can do. It suppresses a
# missing-path failure and it is recorded — it never fires one. A stray negation
# therefore costs at worst a check not run on one path, never a false accusation.
# If denials ever start failing runs, these numbers stop being adequate.
BEFORE = 48
AFTER = 32


def around(text: str, index: int, end: int) -> str:
    """The few words either side of the token, and no more."""
    return text[max(0, index - BEFORE):min(len(text), end + AFTER)]

# Words that look like identifiers and are not. Everything here appeared in a
# real spec as prose or as a tool name.
NOT_SYMBOLS = {
    "true", "false", "none", "null", "main", "test", "tests", "src", "todo",
    "python", "pytest", "ruff", "mypy", "git", "bash", "json", "yaml", "toml",
    "int", "str", "bool", "float", "list", "dict", "set", "tuple", "self",
    "and", "or", "not", "if", "else", "for", "while", "return", "import",
}


def section(text: str, heading: str) -> str:
    """The body under a `## heading`, up to the next heading of the same level."""
    pattern = re.compile(
        rf"^##\s+{re.escape(heading)}\s*$(.*?)(?=^##\s|\Z)",
        re.MULTILINE | re.DOTALL | re.IGNORECASE,
    )
    m = pattern.search(text)
    return m.group(1) if m else ""


def strip_fences(text: str) -> str:
    parts = FENCE.split(text)
    # Odd-indexed parts are inside fences.
    return "\n".join(p for i, p in enumerate(parts) if i % 2 == 0)


def claims(body: str) -> tuple[list[str], list[str], list[str], list[str]]:
    """Paths asserted to exist, denied, merely mentioned, and asserted symbols."""
    text = strip_fences(body)
    asserted: list[str] = []
    denied: list[str] = []
    mentioned: list[str] = []
    symbols: list[str] = []
    for m in BACKTICKED.finditer(text):
        tok = m.group(1).strip().rstrip(",.;:")
        if not tok or " " in tok:
            continue
        is_path = PATH_LIKE.match(tok) and (
            "/" in tok or Path(tok).suffix.lower() in KNOWN_SUFFIXES
        )
        context = around(text, m.start(), m.end())
        if is_path:
            if NEGATION.search(context):
                denied.append(tok)
            elif ASSERTS_EXISTENCE.search(context):
                asserted.append(tok)
            else:
                # Mentioned, with no claim either way. Recorded so a reader can
                # see what the section talked about, and required of nothing.
                mentioned.append(tok)
            continue
        if SYMBOL_LIKE.match(tok) and tok.lower() not in NOT_SYMBOLS:
            if ASSERTS_EXISTENCE.search(context):
                symbols.append(tok)
    return sorted(set(asserted)), sorted(set(denied)), sorted(set(mentioned)), sorted(set(symbols))


def grep(root: Path, needle: str) -> bool:
    """Does this string occur anywhere in the tracked tree?"""
    try:
        r = subprocess.run(
            ["git", "grep", "-q", "-F", "--", needle],
            cwd=root, capture_output=True, timeout=30,
        )
        return r.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("spec", help="spec.md")
    ap.add_argument("--root", default=".", help="repository the spec describes")
    ap.add_argument("--section", default="Current behaviour")
    ap.add_argument("--json", dest="as_json", action="store_true")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    text = Path(args.spec).read_text(encoding="utf-8", errors="replace")
    body = section(text, args.section)

    if not body.strip():
        result = {
            "section": args.section,
            "checked": False,
            "why": f"the spec has no '{args.section}' section, so it makes no claims to check",
            "missing_paths": [], "named_paths": [],
            "paths_said_to_be_absent": [], "said_absent_but_present": [],
            "absent_symbols": [], "named_symbols": [],
        }
        print(json.dumps(result, indent=2) if args.as_json else result["why"])
        return 0

    asserted, denied, mentioned, symbols = claims(body)

    # A path denied ANYWHERE in the section is not required to exist, even if it
    # is also mentioned neutrally elsewhere. The first spec a contained worker
    # ever wrote opened with "no `pyproject.toml`, no `src/`, and no `tests/`
    # exist in the repository today" — correct, and exactly what this section is
    # for — and then referred to `pyproject.toml` again forty lines later while
    # describing the change. One denial, one neutral mention, and the neutral one
    # won, so the check called a true sentence a false claim.
    #
    # Denial wins, for the same reason negation is read at all: suppressing a
    # check on a maybe costs a line someone skims, and firing one on a maybe
    # costs the check its credibility.
    denied_set = set(denied)

    def present(rel: str) -> bool:
        """Is this path in the repository — under that name, or as a basename?

        `(root / rel).exists()` alone was wrong on the first spec that met it.
        bean-003's said, correctly:

            and `tests/` contains only `test_scaffold.py` and `tests/domain/`

        `tests/test_scaffold.py` is there. The sentence names the directory once
        and then the file, which is how anyone writes it — and this check looked
        for `./test_scaffold.py`, did not find it, and failed the spec for
        describing a file that is not there. The spec was right and the check
        sent it back.

        So a bare filename — no directory component — is also looked for as a
        basename. Narrow on purpose: it is not a glob, it does not match
        directories, and a path that names a directory is still resolved from
        the root, because `src/config.py` and `config.py` are different claims.
        The seeded defect this check exists to catch says "The repository ALREADY
        CONTAINS `src/seating_planner/config.py`", which has a directory in it
        and is unaffected.
        """
        if (root / rel).exists():
            return True
        if "/" in rel.strip("/"):
            return False
        return any(
            q.is_file() for q in root.rglob(rel)
            if ".git" not in q.parts and "factory" not in q.parts[:1]
        )

    missing = [p for p in asserted if p not in denied_set and not present(p)]
    absent = [s for s in symbols if not grep(root, s)]
    # The reverse check — a path the spec says is absent which is in fact there —
    # was implemented and then removed, and the removal is the point.
    #
    # Negation detection exists to SUPPRESS a check: to stop "there is no `X`"
    # being reported as a false claim about a missing file. Suppression is the
    # forgiving direction, because a missed negation costs one line a person
    # reads and dismisses. Using the same fuzzy signal to FIRE a failure asks far
    # more precision of it than it has, and on the first real spec it met it was
    # wrong twice in one section: "the package does not exist. The entire working
    # tree (excluding `factory/`, ...)" reads as a denial of `factory/`, and
    # "`...py` already exists and imports a module that no bean has created yet"
    # reads as a denial of the file it had just said exists.
    #
    # So denials are recorded and never judged. What they are is a list of things
    # the spec claims are absent, which a reader — or a judge — can weigh.
    denied_and_present = [p for p in denied if present(p)]

    result = {
        "section": args.section,
        "checked": True,
        "paths_said_to_exist": [p for p in asserted if p not in denied_set],
        "paths_only_mentioned": mentioned,
        "missing_paths": missing,
        "paths_said_to_be_absent": denied,
        "said_absent_but_present": denied_and_present,
        "said_absent_but_present_is_not_a_failure": (
            "Recorded, never failed. Deciding which noun a negation attaches to is "
            "not something this can do reliably, and it was wrong twice on the first "
            "real spec it met. Suppressing a check on a maybe is cheap; firing one is "
            "not."
        ),
        "named_symbols": symbols,
        "absent_symbols": absent,
        "note": (
            "A path this section SAYS EXISTS — 'already contains', 'currently', "
            "'is present' — is a claim about the filesystem, and if the file is not "
            "there the section is describing something that is not. A path merely "
            "mentioned, including one the change is about to create, claims nothing "
            "and is required of nothing. "
            "A path it says is ABSENT is also a claim, checked the other way. "
            "Sentences are read for negation so that 'There is no `src/a.py`' — a "
            "true and useful thing for this section to say — is not reported as a "
            "false claim. A symbol is weaker evidence, since it may be prose or a "
            "name the change introduces, so its absence is reported and never fails."
        ),
    }

    if args.as_json:
        print(json.dumps(result, indent=2))
    else:
        for p in missing:
            print(f"missing path: {p}")
        for p in denied_and_present:
            print(f"note: said to be absent, but present: {p}")
        for s in absent:
            print(f"symbol not found anywhere: {s}")

    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
