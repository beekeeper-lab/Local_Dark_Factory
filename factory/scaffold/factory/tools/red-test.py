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

An assertion is also broken when nothing it reads comes from the project. In
bean-021's second run, task-1's guard `assert len(set(scores)) >= 2` counted the
scores of charts the test enumerated itself; its scenario forced every chart to
one score, so it failed on every solver, the fixed one included. The failing
assert's inputs are traced back through the test function, and through helpers
in the test file, and if none reaches a project import, a fixture or an
unknown module, no fix can turn it green.

Exit: 0 red for the right reason · 1 not red, or red for the wrong reason · 2 usage
"""

from __future__ import annotations

import argparse
import ast
import builtins
import fnmatch
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

FRAME = re.compile(r"^(?P<path>[^\s:][^:\n]*\.py):(?P<line>\d+): (?P<exc>[A-Za-z_][\w.]*)\s*$", re.M)
ASSERTISH = ("assert", "AssertionError", "Failed:", "Failed ")


def matches(path: str, globs: list[str]) -> bool:
    path = path.lstrip("./")
    for g in globs:
        g = g.lstrip("./")
        rx = re.escape(g).replace(r"\*\*/", "(?:.*/)?").replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
        if re.fullmatch(rx, path) or fnmatch.fnmatch(path, g):
            return True
    return False


# What an assertion may read and still be blind: pure builtins, pure standard
# modules, literals, and the test's own locals and nested functions. Anything
# else (a project import, a fixture, a module-level constant, a file, an unknown
# name) might carry the project's behaviour, and the assertion is left alone.
IMPURE_BUILTINS = {"open", "input", "__import__", "exec", "eval", "compile", "globals", "locals", "vars"}
PURE_BUILTINS = set(dir(builtins)) - IMPURE_BUILTINS
PURE_MODULES = {"itertools", "math", "collections", "functools", "operator", "re", "string", "typing",
                "dataclasses", "enum", "fractions", "decimal", "statistics", "random", "copy", "__future__",
                "pytest"}
FUNCS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)


def loaded(node: ast.AST) -> set[str]:
    return {n.id for n in ast.walk(node) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load)}


def bound(target: ast.AST) -> set[str]:
    """The local names an assignment target rebinds or mutates (x in `x.y = ...`; a, b in `a, b = ...`)."""
    return {n.id for n in ast.walk(target) if isinstance(n, ast.Name)}


def import_kinds(st: ast.stmt) -> dict[str, str]:
    out = {}
    for al in st.names:
        mod = (st.module or "") if isinstance(st, ast.ImportFrom) else al.name
        pure = getattr(st, "level", 0) == 0 and mod.split(".")[0] in PURE_MODULES
        out[(al.asname or al.name).split(".")[0]] = "pure" if pure else "proj"
    return out


def module_env(tree: ast.Module) -> dict[str, object]:
    env: dict[str, object] = {}
    for st in tree.body:
        if isinstance(st, (ast.Import, ast.ImportFrom)):
            env.update(import_kinds(st))
        elif isinstance(st, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            env[st.name] = st
        else:  # a module-level constant: a path, an environment read, a table. Not provably pure.
            for n in ast.walk(st):
                if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
                    env[n.id] = "proj"
    return env


def own_nodes(fn: ast.AST):
    """fn's nodes, not descending into nested functions or classes (they are scopes of their own)."""
    todo = list(ast.iter_child_nodes(fn))
    while todo:
        n = todo.pop()
        yield n
        if not isinstance(n, (*FUNCS, ast.ClassDef)):
            todo.extend(ast.iter_child_nodes(n))


def scope(fn: ast.AST) -> tuple[dict[str, set[str]], set[str], dict[str, object], set[str]]:
    """(edges, binds, nested, params): name -> every name its value could come from, control flow
    included (over-approximate); the names fn itself binds (a name only mutated here, like a module
    object handed to a call, is still resolved outside); the nested functions, imports and classes
    fn defines; its parameters."""
    edges: dict[str, set[str]] = {}
    nested: dict[str, object] = {}
    params = {x.arg for x in ast.walk(fn.args) if isinstance(x, ast.arg)} if hasattr(fn, "args") else set()

    # A comprehension's variable lives only in that comprehension; the same letter in two of them
    # is two names, so one is never written through the other.
    comp = [n for n in own_nodes(fn) if isinstance(n, ast.comprehension)]
    comp_names = set().union(*(bound(c.target) for c in comp)) if comp else set()
    inside = {id(x) for c in comp for x in ast.walk(c.target)}
    comp_only = comp_names - {n.id for n in own_nodes(fn)
                              if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store) and id(n) not in inside}

    calls: dict[str, set[str]] = {}

    def pure_call(c: ast.Call) -> bool:
        f = c.func  # len(x), sorted(x), itertools.product(x) write nothing they are handed
        if isinstance(f, ast.Name):
            return f.id in PURE_BUILTINS
        return isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id in PURE_MODULES

    def add(names: set[str], deps: set[str]) -> None:
        for n in names:
            edges.setdefault(n, set()).update(deps - {n})

    def expr_edges(node: ast.AST, ctl: set[str]) -> None:
        for n in [node, *own_nodes(node)]:
            if isinstance(n, ast.NamedExpr):
                add({n.target.id}, loaded(n.value) | ctl)
            elif isinstance(n, ast.comprehension):
                add(bound(n.target), loaded(n.iter) | ctl)
            elif isinstance(n, ast.Lambda):
                nested[f"<lambda@{n.lineno}:{n.col_offset}>"] = n
            elif isinstance(n, ast.Call) and not pure_call(n):
                # A call may mutate what it is handed or called on: scores.append(x), fill(out).
                reach = loaded(n) | ctl
                if isinstance(n.func, ast.Attribute):
                    add(bound(n.func.value), reach)
                for name in loaded(n.func) | set().union(*(loaded(x) for x in [*n.args, *(k.value for k in n.keywords)])):
                    calls.setdefault(name, set()).update(reach)  # record(x), connect(record)
                for arg in [*n.args, *(k.value for k in n.keywords)]:
                    # anything handed over, a callback's captures included, may be written by the callee
                    add(loaded(arg) - comp_only, reach)

    def walk(stmts: list[ast.stmt], ctl: set[str]) -> None:
        for st in stmts:
            if isinstance(st, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                nested[st.name] = st
                continue
            if isinstance(st, (ast.Import, ast.ImportFrom)):
                nested.update(import_kinds(st))
                continue
            if isinstance(st, ast.Assign):
                for t in st.targets:
                    add(bound(t), loaded(st.value) | loaded(t) | ctl)
            elif isinstance(st, (ast.AnnAssign, ast.AugAssign)) and st.value is not None:
                add(bound(st.target), loaded(st.value) | loaded(st.target) | ctl)
            elif isinstance(st, (ast.For, ast.AsyncFor)):
                add(bound(st.target), loaded(st.iter) | ctl)
            elif isinstance(st, (ast.With, ast.AsyncWith)):
                inner = set().union(*(loaded(b) for b in st.body))
                for it in st.items:  # `pytest.raises(...) as exc` is filled in by the body
                    if it.optional_vars is not None:
                        add(bound(it.optional_vars), loaded(it.context_expr) | inner | ctl)
            elif isinstance(st, ast.Try):
                inner = set().union(*(loaded(b) for b in st.body))
                for h in st.handlers:
                    if h.name:
                        add({h.name}, inner | ctl)
            if isinstance(st, ast.Assert):
                continue  # an assertion reads; it does not feed a later one
            for field in ("test", "iter", "value", "targets", "target", "items", "exc", "msg"):
                sub = getattr(st, field, None)
                for node in sub if isinstance(sub, list) else [sub]:
                    if isinstance(node, ast.AST):
                        expr_edges(node, ctl)
            if isinstance(st, (ast.For, ast.AsyncFor)):
                walk(st.body + st.orelse, ctl | loaded(st.iter) | bound(st.target))
            elif isinstance(st, (ast.If, ast.While)):
                walk(st.body + st.orelse, ctl | loaded(st.test))
            elif isinstance(st, (ast.With, ast.AsyncWith)):
                walk(st.body, ctl)
            elif isinstance(st, ast.Try):  # whether a handler runs is decided by the body
                inner = set().union(*(loaded(b) for b in st.body))
                walk(st.body + st.finalbody, ctl)
                walk(st.orelse, ctl | inner)
                for h in st.handlers:
                    walk(h.body, ctl | inner)

    if isinstance(fn, ast.Lambda):
        expr_edges(fn.body, set())
    else:
        walk(fn.body, set())
    for name, fdef in list(nested.items()):
        if isinstance(fdef, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            # A nested function (or a fake class's methods) may write what it captures, with whatever
            # it is called with, wherever it is called or handed over. Its return value is not this:
            # that is traced at each call site.
            _, own, _, own_params = scope(fdef) if not isinstance(fdef, ast.ClassDef) else ({}, set(), {}, set())
            free = set().union(*(loaded(b) for b in fdef.body)) - own - own_params
            add(free, calls.get(name, set()) | {name})
    binds = {n.id for n in own_nodes(fn) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store)}
    binds |= {n.name for n in own_nodes(fn) if isinstance(n, ast.ExceptHandler) and n.name}
    return edges, binds, nested, params


def reaches_project(names: set[str], fn: ast.AST, env: dict[str, object], outer: list, seen: set[int],
                    is_test: bool = True) -> bool:
    """Could any of names, read inside fn, carry the project's behaviour?"""
    edges, binds, nested, params = scope(fn)
    frames = [(edges, binds, nested, params, is_test), *outer]
    todo, done = list(names), set()
    while todo:
        n = todo.pop()
        if n in done:
            continue
        done.add(n)
        for f_edges, f_binds, f_nested, f_params, f_is_test in frames:
            todo.extend(f_edges.get(n, ()))
            if n in f_binds:
                break
            if n in f_nested:
                kind = f_nested[n]
                if kind == "proj":
                    return True
                if isinstance(kind, ast.ClassDef):
                    return True
                if isinstance(kind, FUNCS) and id(kind) not in seen:
                    seen.add(id(kind))
                    body = loaded(kind.body) if isinstance(kind, ast.Lambda) else set().union(*(loaded(b) for b in kind.body))
                    if reaches_project(body, kind, env, frames, seen, is_test=False):
                        return True
                break
            if n in f_params:
                if f_is_test:
                    return True  # a fixture, or a value pytest hands in
                break  # a helper's argument: traced where the helper is called
        else:
            if n in env:
                kind = env[n]
                if kind == "proj" or isinstance(kind, ast.ClassDef):
                    return True
                if isinstance(kind, FUNCS) and id(kind) not in seen:
                    seen.add(id(kind))
                    if reaches_project(set().union(*(loaded(b) for b in kind.body)), kind, env, [], seen, False):
                        return True
            elif n not in PURE_BUILTINS:
                return True  # unknown: not provably pure
    # lambdas inside fn are reached through the calls that name them; nothing else is left
    return False


def assertion_is_blind(test_path: str, text: str) -> str | None:
    """The failing assert's source when nothing it reads comes from the project, else None."""
    rel = os.path.relpath(test_path)
    lines = [int(m.group("line")) for m in FRAME.finditer(text or "") if os.path.relpath(m.group("path")) == rel]
    if not lines:
        return None
    try:
        src = open(test_path).read()
        tree = ast.parse(src)
    except (OSError, SyntaxError):
        return None
    line = lines[-1]
    fns = [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
           and n.lineno <= line <= (n.end_lineno or n.lineno)]
    if not fns:
        return None
    fn = max(fns, key=lambda n: n.lineno)  # the innermost
    asserts = [n for n in ast.walk(fn) if isinstance(n, ast.Assert) and n.lineno <= line <= (n.end_lineno or n.lineno)]
    if not asserts:
        return None
    env = module_env(tree)
    if reaches_project(loaded(asserts[0].test), fn, env, [], set()):
        return None
    return ast.get_source_segment(src, asserts[0]) or f"line {line}"


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
                    blind = next((b for t in a.tests if t.endswith(".py")
                                  for b in [assertion_is_blind(t, ch.text or "")] if b), None)
                    if blind:
                        wrong.append(f"{name}: `{blind.splitlines()[0][:100]}` reads nothing from the project, so it fails "
                                     "on every implementation, the fixed one included: the test's own scenario is wrong")
                        continue
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
