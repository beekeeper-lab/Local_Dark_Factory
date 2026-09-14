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


def violations(paths: list[str], patterns: list[str]) -> list[str]:
    regexes = [pattern_to_regex(p) for p in patterns if p.strip()]
    bad = []
    for path in paths:
        path = path.strip().lstrip("./")
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
