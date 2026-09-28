#!/usr/bin/env python3
"""red-test.py — is this test red for the right reason?

A task that writes tests before the fix ("red tests") used to be verified with
`! pytest -q <file>`, which passes on ANY failure. bean-021's task-1 wrote a test
that built a soft rule with weight 120, outside the rules model's 1..100, so the
test failed in its own setup with a ValueError, never reaching the defect. The
negated pytest called that red, task-1 was verified, and task-2, which may only
write the solver, spent three attempts against a test it could not repair.

usage: python factory/tools/red-test.py --fixes <glob> [--fixes <glob>...] <test path>...

  --fixes   the paths the fix may change (the bean's allowed source paths,
            e.g. 'src/seating_planner/solver/**'). Required.

Red for the right reason means: pytest ran, collected, and at least one test
FAILED, and every failure is one the fix could turn green:

  * an assertion (`assert ...`, AssertionError), or pytest.fail / DID NOT RAISE
  * an exception whose innermost frame is inside --fixes: the defect itself
    raising, as bean-004's SQL syntax error did from the store it was fixing

Anything else is a broken test, and this exits non-zero saying which and why:
a collection or setup error, an exception raised in the test file itself or in
code outside --fixes (nothing the fix does can make that pass), or no failure at
all (a red test that passes does not show the defect).

Exit: 0 red for the right reason · 1 not red, or red for the wrong reason · 2 usage
"""

from __future__ import annotations

import argparse
import fnmatch
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

FRAME = re.compile(r"^(?P<path>[^\s:][^:]*\.py):(?P<line>\d+): (?P<exc>[A-Za-z_][\w.]*)\s*$", re.M)
ASSERTISH = ("assert", "AssertionError", "Failed:", "Failed ")


def matches(path: str, globs: list[str]) -> bool:
    path = path.lstrip("./")
    for g in globs:
        g = g.lstrip("./")
        rx = re.escape(g).replace(r"\*\*/", "(?:.*/)?").replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
        if re.fullmatch(rx, path) or fnmatch.fnmatch(path, g):
            return True
    return False


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True, description="Is this test red for the right reason?")
    ap.add_argument("--fixes", action="append", default=[], required=True)
    ap.add_argument("tests", nargs="+")
    a = ap.parse_args(argv)

    with tempfile.TemporaryDirectory() as tmp:
        junit = os.path.join(tmp, "j.xml")
        proc = subprocess.run(
            [sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", "--tb=long",
             f"--junitxml={junit}", *a.tests],
            capture_output=True, text=True,
        )
        if proc.returncode == 0:
            print("red-test: NOT RED — every test passed, so none of them shows the defect")
            return 1
        if not os.path.exists(junit):
            print(f"red-test: BROKEN — pytest exited {proc.returncode} and reported nothing")
            print(proc.stdout[-1500:] + proc.stderr[-500:])
            return 1
        root = ET.parse(junit).getroot()

    right, wrong = [], []
    for tc in root.iter("testcase"):
        name = f"{tc.get('classname') or ''}::{tc.get('name') or ''}".strip(":")
        for ch in tc:
            if ch.tag == "error":
                wrong.append(f"{name}: an error outside the test body ({(ch.get('message') or '').strip()[:120]})")
            elif ch.tag == "failure":
                msg = (ch.get("message") or "").strip()
                if msg.startswith(ASSERTISH):
                    right.append(f"{name}: {msg.splitlines()[0][:100]}")
                    continue
                frames = list(FRAME.finditer(ch.text or ""))
                last = frames[-1] if frames else None
                if last and matches(last.group("path"), a.fixes):
                    right.append(f"{name}: {last.group('exc')} raised in {last.group('path')}:{last.group('line')}, inside what the fix may change")
                else:
                    where = f"{last.group('path')}:{last.group('line')}" if last else "an unknown place"
                    wrong.append(f"{name}: {msg.splitlines()[0][:120] if msg else 'an exception'}, raised in {where}, outside what the fix may change ({', '.join(a.fixes)})")

    if proc.returncode not in (0, 1) and not wrong:
        wrong.append(f"pytest exited {proc.returncode}: the run was interrupted or collected nothing")
    if wrong:
        print("red-test: BROKEN — these tests fail for a reason the fix cannot address:")
        for w in wrong:
            print(f"  - {w}")
        print("  A red test must fail by assertion, or by the defect raising inside the code being fixed.")
        return 1
    if not right:
        print("red-test: NOT RED — nothing failed")
        return 1
    print(f"red-test: red for the right reason — {len(right)} failure(s), each one the fix can turn green:")
    for r in right:
        print(f"  - {r}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
