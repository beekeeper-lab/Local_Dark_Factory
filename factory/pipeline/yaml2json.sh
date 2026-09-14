#!/usr/bin/env bash
# yaml2json.sh — print a YAML file as JSON on stdout, so the rest of the
# pipeline can stay in jq.
#
# Timestamps are loaded as STRINGS. PyYAML implicitly resolves an unquoted
# `2026-09-14T15:10:00Z` into a datetime object, which then fails every
# `"type": "string"` check in the schemas — the spec's own bean-014 example
# failed validation on `approval/approved_at` for exactly this reason. The
# artifact was correct; the loader was lossy. Anything in this pipeline that
# reads YAML must do this or it will reject valid beans.
set -euo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

USAGE="yaml2json.sh <file.yaml|file.json>"
case "${1:-}" in
  --version) cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
  -h|--help)
    echo "yaml2json.sh — print YAML (or JSON) as JSON. Timestamps stay strings."
    echo "$USAGE"
    echo ""
    echo "Needs python3 with PyYAML for YAML input; JSON input passes through"
    echo "with jq and needs neither."
    exit 0 ;;
esac
require_args "$#" 1 "$USAGE"

FILE="$1"
[ -f "$FILE" ] || die "file not found: $FILE"

case "$FILE" in
  *.json)
    require_cmd jq
    jq -c . "$FILE"
    exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 \
  || die "python3 is required to read YAML ($FILE); convert the file to JSON or install python3"

PY="${PIPELINE_PYTHON:-python3}"
"$PY" - "$FILE" <<'PYEOF' || die "could not parse YAML: $FILE"
import json, sys
try:
    import yaml
except ImportError:
    sys.exit("yaml2json: python3 has no PyYAML — install it (pip install pyyaml) "
             "or set PIPELINE_PYTHON to an interpreter that has it")

class StringDateLoader(yaml.SafeLoader):
    """Leaves RFC 3339 timestamps as the strings the schemas require."""

StringDateLoader.add_constructor(
    "tag:yaml.org,2002:timestamp", yaml.SafeLoader.construct_yaml_str
)

with open(sys.argv[1]) as fh:
    doc = yaml.load(fh, Loader=StringDateLoader)
json.dump(doc, sys.stdout, separators=(",", ":"), default=str)
PYEOF
