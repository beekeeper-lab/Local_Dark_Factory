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
NEGATION = re.compile(
    r"""\b(
        no | not | never | nothing | none | without
        | isn't | aren't | doesn't | don't | won't | cannot | can't
        | absent | missing | empty | lacks? | lacking
        | yet\s+to\s+be | does\s+not | do\s+not | will\s+be\s+(created|added|written)
        | (to|will|shall)\s+be\s+(created|added|introduced)
        | currently\s+(has|have)\s+no
    )\b""",
    re.VERBOSE | re.IGNORECASE,
)


# How far from the path a negation still counts. Deliberately small.
#
# The first version read the whole sentence, and a sentence is far too much: the
# real spec this line builds contains "`factory/invariants/...py` already exists
# and imports a module that no bean has created yet". The "no" belongs to "bean",
# thirty words away from the path, and the check duly reported that the spec
# denied the existence of a file it had just said already exists.
#
# English puts negation next to what it negates — "there is no `X`", "`X` does
# not exist" — so a narrow window either side catches the real constructions and
# leaves other clauses alone.
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


def claims(body: str) -> tuple[list[str], list[str], list[str]]:
    """Paths asserted to exist, paths asserted to be absent, and symbols."""
    text = strip_fences(body)
    asserted: list[str] = []
    denied: list[str] = []
    symbols: list[str] = []
    for m in BACKTICKED.finditer(text):
        tok = m.group(1).strip().rstrip(",.;:")
        if not tok or " " in tok:
            continue
        is_path = PATH_LIKE.match(tok) and (
            "/" in tok or Path(tok).suffix.lower() in KNOWN_SUFFIXES
        )
        if is_path:
            if NEGATION.search(around(text, m.start(), m.end())):
                denied.append(tok)
            else:
                asserted.append(tok)
            continue
        if SYMBOL_LIKE.match(tok) and tok.lower() not in NOT_SYMBOLS:
            if not NEGATION.search(around(text, m.start(), m.end())):
                symbols.append(tok)
    return sorted(set(asserted)), sorted(set(denied)), sorted(set(symbols))


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

    asserted, denied, symbols = claims(body)
    missing = [p for p in asserted if not (root / p).exists()]
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
    denied_and_present = [p for p in denied if (root / p).exists()]

    result = {
        "section": args.section,
        "checked": True,
        "named_paths": asserted,
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
            "A path this section says exists is a claim about the filesystem, and if "
            "the file is not there the section is describing something that is not. "
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
