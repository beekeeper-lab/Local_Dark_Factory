#!/usr/bin/env python3
"""contain.py — which of these changed paths fall outside the allowed patterns?

Separate from the loop, and small enough to read in one sitting, because this is
the check that decides whether a model's edit is accepted or thrown away. Spec
§08 requires an out-of-scope edit to be **rejected, not stripped**: the whole
attempt is discarded. A matcher that is too permissive turns that guarantee into
a formality, so the failure mode chosen here is always "too strict" — an
unmatched path is a violation.

Why not bash's `[[ path == pattern ]]`: inside `[[ ]]` a `*` matches `/` as
well, so `src/*.py` would happily match `src/deep/nested/evil.py`. The patterns
in bean and task write_paths are gitignore-shaped, where `*` stops at a slash
and `**` does not. The difference is the whole point of the check.

usage:
  contain.py --patterns <json-array> [--paths-from <file>|-]
  echo "src/a.py" | contain.py --patterns '["src/**"]'

Prints one violating path per line. Exit 0 when every path is allowed, 1 when
any is not, 2 on bad usage.
"""
from __future__ import annotations

import argparse
import json
import re
import sys


def expand_braces(pattern: str) -> list[str]:
    """`{a,b}/x` -> ['a/x', 'b/x'].

    The risk policy's own schema uses brace alternatives
    (`{factory/repo.yaml,factory/risk-policy.yaml,...}`), so a matcher that did
    not expand them would silently match nothing and every agent-control file
    would classify as tier 1. Silent under-matching is the dangerous direction
    here, which is why this exists rather than being left to the caller.
    """
    start = pattern.find("{")
    if start == -1:
        return [pattern]
    depth = 0
    for i in range(start, len(pattern)):
        if pattern[i] == "{":
            depth += 1
        elif pattern[i] == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
    else:
        return [pattern]  # unbalanced: treat literally rather than guess

    head, body, tail = pattern[:start], pattern[start + 1:end], pattern[end + 1:]
    parts, depth, cur = [], 0, ""
    for ch in body:
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        cur += ch
    parts.append(cur)

    out = []
    for part in parts:
        out.extend(expand_braces(head + part + tail))
    return out


def pattern_to_regex(pattern: str) -> re.Pattern[str]:
    """Translate a gitignore-ish path pattern into an anchored regex.

    `**` crosses directory separators; `*` and `?` do not. A trailing `/`, or a
    bare `**` suffix, means "this directory and everything under it".
    """
    p = pattern.strip()
    if not p:
        raise ValueError("empty pattern")
    p = p.lstrip("/")
    if p.endswith("/"):
        p += "**"

    out: list[str] = []
    i = 0
    while i < len(p):
        c = p[i]
        if c == "*":
            if p.startswith("**", i):
                # `**/` consumes the separator so `a/**/b` also matches `a/b`.
                if p.startswith("**/", i):
                    out.append("(?:.*/)?")
                    i += 3
                    continue
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
            i += 1
            continue
        if c == "?":
            out.append("[^/]")
            i += 1
            continue
        out.append(re.escape(c))
        i += 1
    return re.compile("".join(out) + r"\Z")


def compile_patterns(patterns: list[str]) -> list[re.Pattern[str]]:
    out = []
    for pattern in patterns:
        if not pattern.strip():
            continue
        for expanded in expand_braces(pattern):
            out.append(pattern_to_regex(expanded))
    return out


def normalise(path: str) -> str:
    """Strip a leading './' — as a PREFIX, not as a set of characters.

    `str.lstrip("./")` removes any leading run of '.' or '/', which turns
    `.gitignore` into `gitignore` and `.github/workflows/ci.yml` into
    `github/workflows/ci.yml`. Every dotfile then fails to match its own pattern
    and reads as a containment violation. Found on the first real run of the
    line: the developer model correctly listed `.gitignore`, which the bean
    explicitly allows, and the controller called it an escape.
    """
    path = path.strip()
    while path.startswith("./"):
        path = path[2:]
    return path


def matches(path: str, pattern: str) -> bool:
    """Does one path match one (possibly brace-containing) pattern?"""
    return any(r.match(normalise(path)) for r in compile_patterns([pattern]))


def violations(paths: list[str], patterns: list[str]) -> list[str]:
    regexes = compile_patterns(patterns)
    bad = []
    for path in paths:
        path = normalise(path)
        if not path:
            continue
        if not any(r.match(path) for r in regexes):
            bad.append(path)
    return bad


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--patterns", required=True,
                    help="JSON array of allowed path patterns")
    ap.add_argument("--paths-from", default="-",
                    help="file of changed paths, one per line ('-' for stdin)")
    ap.add_argument("--paths", default=None,
                    help="JSON array of changed paths (instead of --paths-from)")
    args = ap.parse_args()

    try:
        patterns = json.loads(args.patterns)
    except json.JSONDecodeError as exc:
        print(f"contain: --patterns is not valid JSON: {exc}", file=sys.stderr)
        return 2
    if not isinstance(patterns, list) or not patterns:
        print("contain: --patterns must be a non-empty JSON array", file=sys.stderr)
        return 2

    if args.paths is not None:
        paths = json.loads(args.paths)
    elif args.paths_from == "-":
        paths = sys.stdin.read().splitlines()
    else:
        with open(args.paths_from) as fh:
            paths = fh.read().splitlines()

    bad = violations(paths, patterns)
    for path in bad:
        print(path)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
