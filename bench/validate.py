#!/usr/bin/env python3
"""validate.py — check every schema is well-formed, and validate payloads against them.

Two jobs, because the cross-cutting plan task is "implement all schemas, then
schema-audit each: validate real payloads; fix; re-validate". A schema that has
never seen a payload is a guess.

usage:
  validate.py                       # check all schemas are valid Draft 2020-12
  validate.py <schema> <payload>... # validate payloads (.json or .yaml) against one schema
  validate.py --corpus <dir>        # validate every bean in a bean-set directory
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    import jsonschema
    import yaml
except ImportError:
    sys.exit("missing deps: run  .venv/bin/pip install jsonschema pyyaml")

ROOT = Path(__file__).resolve().parent.parent
SCHEMAS = ROOT / "schemas"


class _StringDateLoader(yaml.SafeLoader):
    """YAML loader that leaves timestamps as strings.

    PyYAML implicitly resolves an unquoted `2026-09-14T15:10:00Z` into a
    datetime object, which then fails every `"type": "string"` check in the
    schemas. The bean on disk is correct RFC 3339 text; only the loader is
    lossy. Anything that reads beans must do this, or the schemas reject
    valid artifacts.
    """


_StringDateLoader.add_constructor(
    "tag:yaml.org,2002:timestamp", yaml.SafeLoader.construct_yaml_str
)


def load(path: Path):
    text = path.read_text()
    if path.suffix in (".yaml", ".yml"):
        return yaml.load(text, Loader=_StringDateLoader)
    return json.loads(text)


def resolve_schema(name: str) -> Path:
    """Accept 'bean', 'bean.schema.json', or a full path."""
    candidate = Path(name)
    if candidate.is_file():
        return candidate
    for stem in (name, f"{name}.schema.json"):
        p = SCHEMAS / stem
        if p.is_file():
            return p
    sys.exit(f"no such schema: {name} (looked in {SCHEMAS})")


def check_all_schemas() -> int:
    failures = 0
    for path in sorted(SCHEMAS.glob("*.json")):
        try:
            jsonschema.Draft202012Validator.check_schema(json.loads(path.read_text()))
            print(f"  ok    {path.name}")
        except Exception as exc:  # noqa: BLE001 - report, don't raise
            failures += 1
            print(f"  FAIL  {path.name}: {exc}")
    print(f"\n{len(list(SCHEMAS.glob('*.json')))} schemas, {failures} invalid")
    return 1 if failures else 0


def validate_payloads(schema_name: str, payloads: list[str]) -> int:
    schema_path = resolve_schema(schema_name)
    validator = jsonschema.Draft202012Validator(json.loads(schema_path.read_text()))
    failures = 0
    for raw in payloads:
        path = Path(raw)
        if not path.is_file():
            failures += 1
            print(f"  FAIL  {raw}: not a file")
            continue
        errors = sorted(validator.iter_errors(load(path)), key=lambda e: list(e.path))
        if errors:
            failures += 1
            print(f"  FAIL  {path.name}")
            for err in errors:
                where = "/".join(str(p) for p in err.path) or "<root>"
                print(f"          {where}: {err.message}")
        else:
            print(f"  ok    {path.name}")
    print(f"\n{len(payloads)} payload(s) against {schema_path.name}, {failures} invalid")
    return 1 if failures else 0


def validate_corpus(directory: str) -> int:
    """Validate a bean-set: every bean against bean.schema.json, plus corpus rules
    the schema alone cannot express (§05: every AC needs a verify; §04: a queued
    bean must be approved)."""
    beans = sorted(Path(directory).rglob("*.yaml"))
    beans = [b for b in beans if b.name != "manifest.json"]
    if not beans:
        sys.exit(f"no bean files found under {directory}")

    validator = jsonschema.Draft202012Validator(
        json.loads((SCHEMAS / "bean.schema.json").read_text())
    )
    failures = 0
    ids: dict[str, Path] = {}
    all_ids: set[str] = set()

    for path in beans:
        bean = load(path)
        problems = [
            f"{'/'.join(str(p) for p in e.path) or '<root>'}: {e.message}"
            for e in sorted(validator.iter_errors(bean), key=lambda e: list(e.path))
        ]

        bean_id = bean.get("id")
        if bean_id in ids:
            problems.append(f"duplicate id, also in {ids[bean_id].name}")
        if bean_id:
            ids[bean_id] = path
            all_ids.add(bean_id)

        # §05 — an acceptance criterion without a verify is not agentic.
        for ac in bean.get("acceptance_criteria") or []:
            if not ac.get("verify"):
                problems.append(f"acceptance_criteria/{ac.get('id', '?')}: no verify")

        if problems:
            failures += 1
            print(f"  FAIL  {path.name}")
            for p in problems:
                print(f"          {p}")
        else:
            print(f"  ok    {path.name}")

    # Dependencies must resolve within the set, or the queue can never drain.
    for path in beans:
        bean = load(path)
        for dep in bean.get("dependencies") or []:
            if dep not in all_ids:
                failures += 1
                print(f"  FAIL  {path.name}\n          dependencies: '{dep}' is not a bean in this set")

    print(f"\n{len(beans)} bean(s) in {directory}, {failures} invalid")
    return 1 if failures else 0


def main() -> int:
    args = sys.argv[1:]
    if not args:
        return check_all_schemas()
    if args[0] == "--corpus":
        if len(args) != 2:
            sys.exit("usage: validate.py --corpus <bean-set-dir>")
        return validate_corpus(args[1])
    if len(args) < 2:
        sys.exit(__doc__)
    return validate_payloads(args[0], args[1:])


if __name__ == "__main__":
    sys.exit(main())
