"""Hidden tests for bean-001 — written from the bean, not from the diff.

The bean says the repository becomes "a runnable Python package whose lint, type
and test gates all execute and pass, so every later bean has something to be
verified against". Its gates already check that ruff, mypy and pytest are happy.
What they do not check is whether the package is a package in the sense the bean
means: installable, declaring the right floor, declaring ortools without using
it, and carrying no domain code.

Every assertion below traces to a line of bean.yaml. None of them was written by
looking at what the worker produced.
"""

from __future__ import annotations

import ast
import os
import sys
import tomllib
from pathlib import Path

# The tree under test. `hidden-tests.sh` sets HIDDEN_TREE; inside the gate
# container it is /work, which is also the default so the suite can be run by
# hand against a checkout.
#
# No fallback to "some sibling directory that looks right". The first version had
# one, and a suite that quietly tests a different tree when the real one is
# missing is a suite that reports green about nothing.
WORK = Path(os.environ.get("HIDDEN_TREE", "/work"))
assert WORK.is_dir(), f"HIDDEN_TREE is not a directory: {WORK}"

SRC = WORK / "src" / "seating_planner"


def _pyproject() -> dict:
    p = WORK / "pyproject.toml"
    assert p.is_file(), "the bean's whole point is that pyproject.toml declares the project"
    return tomllib.loads(p.read_text())


# --- ac1: "The package imports cleanly from an installed environment." --------
#
# The visible test imports the package with PYTHONPATH pointing at src/. That
# proves the file is there; it does not prove an INSTALL would find it, which is
# what the criterion says and what every later bean depends on.


def test_declares_a_build_backend() -> None:
    cfg = _pyproject()
    assert "build-system" in cfg, "without [build-system] there is nothing to install"
    assert cfg["build-system"].get("build-backend"), "a build backend must be named"


def test_an_install_would_find_the_package() -> None:
    cfg = _pyproject()
    assert (SRC / "__init__.py").is_file(), "there is no package to install"
    # src layout: something has to tell the backend where to look, or `pip install`
    # produces a distribution containing no package at all, and the import in ac1
    # works only because the gate sets PYTHONPATH.
    #
    # The first version of this ended `assert where == ["src"] or SRC.is_dir()`,
    # and the second clause is true whenever the first could possibly be checked.
    # A mutation run with `where = ["nope"]` passed it. That is the exact defect
    # the impl rubric calls a blocker — an assertion that would hold with the
    # change reverted — arriving in the file whose job is to catch it.
    st = cfg.get("tool", {}).get("setuptools", {})
    where = st.get("packages", {}).get("find", {}).get("where")
    package_dir = st.get("package-dir", {})
    assert where == ["src"] or package_dir.get("") == "src", (
        "nothing tells the build backend that the package lives under src/, so an "
        f"install would ship no package (tool.setuptools = {st})"
    )


def test_the_package_is_named_what_the_bean_names() -> None:
    cfg = _pyproject()
    assert cfg["project"]["name"].replace("_", "-") == "seating-planner"


# --- constraint: "Python 3.11 or later" --------------------------------------


def test_requires_python_311_or_later() -> None:
    cfg = _pyproject()
    req = cfg["project"].get("requires-python", "")
    assert req, "a floor that is not declared is not a floor"
    assert ">=3.11" in req.replace(" ", "") or ">=3.12" in req.replace(" ", "")


# --- constraint: "ortools declared as a dependency but not yet imported" ------
#
# Both halves. The gates cannot catch either: ruff and mypy are happy with an
# unused dependency and equally happy with an early import.


def test_ortools_is_declared() -> None:
    cfg = _pyproject()
    deps = cfg["project"].get("dependencies", [])
    assert any(d.split("[")[0].split(">")[0].split("=")[0].strip() == "ortools" for d in deps), (
        f"ortools must be declared; dependencies are {deps}"
    )


def test_nothing_imports_ortools_yet() -> None:
    offenders = []
    for py in sorted(SRC.rglob("*.py")):
        tree = ast.parse(py.read_text(), filename=str(py))
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                names = [node.module or ""]
            else:
                continue
            if any(n.split(".")[0] == "ortools" for n in names):
                offenders.append(str(py.relative_to(WORK)))
    assert not offenders, f"this bean declares ortools and does not use it yet: {offenders}"


# --- non_goals: "no domain models", "no solver code", "no CI workflow files" --


def test_no_domain_modules_yet() -> None:
    # The bean ships a scaffold. Anything beyond the package's own __init__ is a
    # later bean's work arriving early, which is what a non-goal is for.
    modules = [p.name for p in SRC.glob("*.py") if p.name != "__init__.py"]
    subpackages = [p.name for p in SRC.iterdir() if p.is_dir() and not p.name.startswith("__")]
    assert not modules, f"no domain modules in this bean: {modules}"
    assert not subpackages, f"no subpackages in this bean: {subpackages}"


def test_no_ci_workflow_files() -> None:
    wf = WORK / ".github" / "workflows"
    files = sorted(p.name for p in wf.glob("*")) if wf.is_dir() else []
    assert not files, f"CI workflows are a non-goal of this bean: {files}"


# --- the bean's background: the three gate tools must be declarable ----------
#
# "The gates the factory runs are exactly these three commands, so they must
# succeed on an empty-but-valid project." A project that passes them only because
# they happen to be on the developer's machine is not the same thing.


def test_the_gate_tools_are_declared_somewhere() -> None:
    cfg = _pyproject()
    optional = cfg["project"].get("optional-dependencies", {})
    declared = {
        d.split("[")[0].split(">")[0].split("=")[0].split("<")[0].strip()
        for group in optional.values()
        for d in group
    }
    declared |= {
        d.split("[")[0].split(">")[0].split("=")[0].split("<")[0].strip()
        for d in cfg["project"].get("dependencies", [])
    }
    missing = {"ruff", "mypy", "pytest"} - declared
    assert not missing, f"the gate tools are run but not declared: {sorted(missing)}"


# --- ac4: "Pytest runs and collects at least one passing test." --------------


def test_there_is_a_test_that_is_not_ours() -> None:
    # The bean asks the worker for a test. This suite is not it, and a criterion
    # satisfied only by the hidden tests is a criterion nobody met.
    tests = list((WORK / "tests").glob("test_*.py")) if (WORK / "tests").is_dir() else []
    assert tests, "the bean asks for a test of its own; /hidden does not count"


def test_the_package_actually_imports() -> None:
    # Last, because it is the one the visible test also makes. Here it runs in the
    # gate container against the synced tree, which is the environment the claim
    # is about.
    sys.path.insert(0, str(WORK / "src"))
    import seating_planner  # noqa: PLC0415

    assert seating_planner.__name__ == "seating_planner"
