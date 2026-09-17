#!/usr/bin/env bash
# scaffold.sh — install the factory's control surface into a target repository.
#
# The line builds in disposable repos, never in this one: `factory/**` here is
# Tier 3 agent-control, and a developer model must not hold a writable tree in
# the repo that holds the policy governing it. So the target repo gets a copy of
# the control files, generated from this repo, and this repo stays the source of
# truth for them.
#
# What lands in the target:
#   factory/repo.yaml            what the line may do to this repo (merge_mode)
#   factory/risk-policy.yaml     path -> minimum tier
#   factory/gates.lock.yaml      the pinned image and the gate commands
#   factory/templates/*.html     the two document templates (Tier 3: rendered
#                                with, never edited by the line)
#   factory/beans/<id>/bean.yaml the approved beans, copied from the corpus
#   factory/beans/<id>/bean.md   a readable view of the same bean, plus the
#                                pipeline tier row the driver reads
#   factory/beans/INDEX.md       the approval index preflight checks
#   factory/pipeline-config.json where the runs, branches and beans live
#
# Idempotent: re-running updates the control files in place. It never touches
# factory/specs/, factory/impl/ or factory/runs/ — those are the line's output,
# and a scaffold script that could delete evidence is a scaffold script that
# eventually will.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SRC="$HERE/scaffold/factory"

usage() {
  cat <<'EOF'
scaffold.sh — install the factory control surface into a target repository.

usage: scaffold.sh <target-repo> [--bean-set <dir>] [--tier small|full] [--dry-run]

  --bean-set <dir>  bean set to install (default:
                    benchmark/seating-planner/bean-sets/v1). Only beans with
                    status: approved are installed — §04 gates what queues, and
                    a scaffold that shipped drafts would route around it.
  --tier small|full pipeline tier written into each bean.md (default: full —
                    all seven stages and all three audits)
  --dry-run         list what would be written, change nothing
  --check           change nothing; report every control file in the target that
                    differs from what this repo would write. Exit 1 if any does.

Re-running is safe: control files are overwritten, the line's own output
(factory/specs, factory/impl, factory/runs) is never touched.
EOF
}

TARGET=""; BEAN_SET="$REPO_ROOT/benchmark/seating-planner/bean-sets/v1"; TIER="full"; DRY=0; CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --bean-set) BEAN_SET="${2:?--bean-set needs a directory}"; shift 2 ;;
    --tier)     TIER="${2:?--tier needs small or full}"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --check)    CHECK=1; shift ;;
    -*) usage >&2; echo "unknown flag: $1" >&2; exit 2 ;;
    *)  [ -z "$TARGET" ] || { echo "only one target repo" >&2; exit 2; }
        TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || { usage >&2; exit 2; }
case "$TIER" in small|full) ;; *) echo "--tier must be small or full" >&2; exit 2 ;; esac

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[ -d "$TARGET" ] || { echo "target repo not found: $TARGET" >&2; exit 1; }
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository: $TARGET" >&2; exit 1; }
[ -d "$SRC" ] || { echo "scaffold sources missing: $SRC" >&2; exit 1; }
[ -d "$BEAN_SET" ] || { echo "bean set not found: $BEAN_SET" >&2; exit 1; }

PY="${SCAFFOLD_PYTHON:-$REPO_ROOT/.venv/bin/python}"
[ -x "$PY" ] || PY=python3

# -- --check: has the target drifted from what this repo would write? -----------
#
# The scaffold is one-way. It copies the control surface into a target repo and
# never looks again, so an edit made downstream survives until the next scaffold
# run silently reverts it. That is not hypothetical: bean-002's non_goals were
# annotated with forbidden_paths in the deployed copy on 2026-09-16 and the bean
# set in this repo was never updated, so the annotation was one `scaffold.sh` away
# from being deleted, by the script whose job is to keep the two the same.
#
# It regenerates into a temporary repo and diffs, rather than comparing field by
# field, because a second description of "what the scaffold writes" is a second
# thing to keep in sync — the same failure one level up.
if [ "$CHECK" = 1 ]; then
  [ "$DRY" = 0 ] || { echo "--check and --dry-run are opposites; pick one" >&2; exit 2; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  git init -q "$TMP"
  SCAFFOLD_PYTHON="$PY" "$HERE/scaffold.sh" "$TMP" --bean-set "$BEAN_SET" --tier "$TIER" >/dev/null || {
    echo "could not generate a reference scaffold to compare against" >&2; exit 2; }
  drift=0
  # Only what the scaffold writes. The line's own output — specs, impl, runs — is
  # evidence, not control surface, and is not its business.
  while IFS= read -r rel; do
    case "$rel" in factory/specs/*|factory/impl/*|factory/runs/*|*/.gitkeep) continue ;; esac
    if [ ! -e "$TARGET/$rel" ]; then
      printf '  MISSING   %s\n' "$rel"; drift=$((drift+1))
    elif ! diff -q "$TMP/$rel" "$TARGET/$rel" >/dev/null 2>&1; then
      printf '  DIFFERS   %s\n' "$rel"; drift=$((drift+1))
    fi
  done < <(cd "$TMP" && find factory .github -type f 2>/dev/null | sort)
  # A bean the set no longer has, still installed. It would keep queueing.
  for d in "$TARGET"/factory/beans/*/; do
    [ -d "$d" ] || continue
    b="$(basename "$d")"
    [ -e "$TMP/factory/beans/$b/bean.yaml" ] || { printf '  EXTRA     factory/beans/%s (not in %s)\n' "$b" "$(basename "$BEAN_SET")"; drift=$((drift+1)); }
  done
  if [ "$drift" = 0 ]; then
    printf '\n%s is current with %s\n' "$TARGET" "$BEAN_SET"
    exit 0
  fi
  printf '\n%s control file(s) differ from what this repo would write.\n' "$drift" >&2
  printf 'Whichever copy is right, they are not the same. `scaffold.sh %s` overwrites the\n' "$TARGET" >&2
  printf 'target with this one; if the edit downstream is the one worth keeping, copy it\n' >&2
  printf 'back into %s FIRST, because the scaffold will not ask.\n' "$BEAN_SET" >&2
  exit 1
fi

say() { printf '  %-8s %s\n' "$1" "$2"; }
write() { # write <relative path> <content-on-stdin>
  local rel="$1" dest="$TARGET/$1"
  if [ "$DRY" = 1 ]; then cat > /dev/null; say "would" "$rel"; return 0; fi
  mkdir -p "$(dirname "$dest")"
  cat > "$dest"
  say "write" "$rel"
}
copy() { # copy <src> <relative path>
  if [ "$DRY" = 1 ]; then say "would" "$2"; return 0; fi
  mkdir -p "$(dirname "$TARGET/$2")"
  cp "$1" "$TARGET/$2"
  say "copy" "$2"
}

printf '\nscaffolding %s\n  from bean set: %s\n  pipeline tier: %s\n\n' "$TARGET" "$BEAN_SET" "$TIER"

# -- control files --------------------------------------------------------------
for f in repo.yaml risk-policy.yaml gates.lock.yaml; do
  copy "$SRC/$f" "factory/$f"
done
for f in "$SRC"/templates/*.html; do
  copy "$f" "factory/templates/$(basename "$f")"
done

# The workflow that makes `required_checks` true.
#
# Until this existed, repo.yaml named a check nothing produced — protection that
# reads as in force and is not. The workflow runs the SAME image the manifest
# pins, by digest, so a green on GitHub and a green on this machine are the same
# claim. It fails loudly when the image has not been published to a registry
# rather than skipping, because a required check that passes because it could not
# run is the failure mode this whole repository is about.
#
# Withheld while the manifest still pins a `localhost/` image, and this is a rule
# rather than a note. The job fails loudly on an image CI cannot pull — correct,
# and the right thing to do once it is a required check — but installed TODAY it
# puts a red X on every open pull request for a reason that has nothing to do with
# the change under review, and a reviewer reads that X as "this code is broken".
#
# It was a sentence in RESUME.md saying "deliberately NOT installed yet". I read
# the drift report, saw the file missing from the target, concluded nobody had
# re-run the scaffold, and installed it. A decision that lives only in prose is
# one re-derivation away from being reversed by someone who means well, so it
# lives here now: publish the image, put the digest in gates.lock.yaml, and the
# next scaffold run installs the workflow with no further decision to make.
GATES_IMAGE="$(sed -n 's/^image:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$SRC/gates.lock.yaml" 2>/dev/null | head -1)"
if [ -d "$HERE/scaffold/.github/workflows" ]; then
  case "$GATES_IMAGE" in
    localhost/*|"")
      say "hold" ".github/workflows/gates.yml (gates.lock.yaml pins ${GATES_IMAGE:-nothing}; CI could not pull it, and a red X on an open PR reads as a broken change)"
      ;;
    *)
      for f in "$HERE/scaffold/.github/workflows"/*.yml; do
        [ -e "$f" ] || continue
        copy "$f" ".github/workflows/$(basename "$f")"
      done
      ;;
  esac
fi

# Invariants: acceptance fixtures from outside the developer's reach (§05). They
# are tier 3 and absent from repo_allowed_paths, so the line can run them and
# never edit them — which is the only reason their passing means anything.
if [ -d "$SRC/invariants" ]; then
  for f in "$SRC"/invariants/*; do
    [ -e "$f" ] || continue
    copy "$f" "factory/invariants/$(basename "$f")"
  done
fi

# -- beans: approved only -------------------------------------------------------
BEANS_DIR="$BEAN_SET/beans"
[ -d "$BEANS_DIR" ] || BEANS_DIR="$BEAN_SET"
installed=0
skipped=0
INDEX_ROWS=""

for bean in "$BEANS_DIR"/*.yaml "$BEANS_DIR"/*.yml; do
  [ -e "$bean" ] || continue
  meta="$("$HERE/pipeline/yaml2json.sh" "$bean")" || { echo "cannot read bean: $bean" >&2; exit 1; }
  id="$(jq -r '.id // empty' <<<"$meta")"
  status="$(jq -r '.status // empty' <<<"$meta")"
  title="$(jq -r '.title // empty' <<<"$meta")"
  [ -n "$id" ] || { echo "bean has no id: $bean" >&2; exit 1; }

  if [ "$status" != "approved" ]; then
    say "skip" "$id ($status — only approved beans are installed)"
    skipped=$((skipped + 1))
    continue
  fi

  slug="$("$PY" -c 'import re,sys; print(re.sub(r"[^a-z0-9]+","-",sys.argv[1].lower()).strip("-")[:40])' "$title")"
  dir="factory/beans/$id-$slug"
  copy "$bean" "$dir/bean.yaml"

  # bean.md — the readable face of the same bean, and the file the driver reads
  # the pipeline tier from. Generated, never hand-edited: two hand-maintained
  # descriptions of one bean is one description that goes stale.
  "$PY" - "$meta" "$TIER" "$id" <<'PY' > "/tmp/bean-md.$$"
import json, sys
bean = json.loads(sys.argv[1]); tier = sys.argv[2]; bid = sys.argv[3]
out = []
out.append(f"# {bid} — {bean.get('title','')}\n")
out.append("> Generated from `bean.yaml` by `factory/scaffold.sh`. Edit the YAML, not this file.\n")
out.append("| Field | Value |")
out.append("|---|---|")
out.append(f"| **Pipeline Tier** | {tier} |")
out.append(f"| Status | {bean.get('status','')} |")
out.append(f"| Suggested risk tier | {bean.get('suggested_risk_tier','—')} |")
ap = bean.get("approval") or {}
out.append(f"| Approved by | {ap.get('approved_by','—')} |")
out.append(f"| Run order | {ap.get('order','—')} |")
deps = bean.get("dependencies") or []
out.append(f"| Depends on | {', '.join(deps) if deps else 'nothing'} |")
inv = bean.get("invariants_ref")
if inv:
    out.append(f"| Independent invariants | `{inv}` — authored outside this bean, not editable by the line |")
sb = bean.get("size_budget") or {}
if sb:
    out.append(f"| Size budget | {sb.get('max_tasks','?')} tasks · {sb.get('max_files','?')} files · {sb.get('max_diff_lines','?')} diff lines |")
out.append("")
out.append("## Intent\n")
out.append((bean.get("intent") or "").strip() + "\n")
ctx = (bean.get("context") or {}).get("background")
if ctx:
    out.append("## Background\n")
    out.append(ctx.strip() + "\n")
out.append("## May write\n")
for p in bean.get("allowed_write_paths") or []:
    out.append(f"- `{p}`")
out.append("")
out.append("## Acceptance criteria\n")
out.append("| ID | Criterion | Verified by |")
out.append("|---|---|---|")
for ac in bean.get("acceptance_criteria") or []:
    v = ac.get("verify") or {}
    kind = v.get("kind", "?")
    detail = " ".join(v.get("run", [])) or v.get("test_id") or v.get("gate_id") or v.get("note") or ""
    out.append(f"| {ac.get('id','')} | {ac.get('text','').strip()} | `{kind}` {('`' + detail + '`') if detail else ''} |")
out.append("")
def render_statement(n):
    """A non-goal or a constraint, which are the same shape of statement.

    Either prose or an object that ALSO says where — paths and imports the
    controller checks without asking a judge. Rendering the object with an
    f-string printed a Python dict into the document; it read as
    `{'text': 'no rule model', 'forbidden_paths': [...]}` and the sentence a
    reader needed was inside it. The text is the statement either way; what the
    machine checks is worth saying, because a reader cannot otherwise tell which
    of these the audit is still guessing at.
    """
    if not isinstance(n, dict):
        return f"- {n}"
    checked = [f"`{pat}`" for pat in (n.get("forbidden_paths") or [])]
    checked += [f"import `{mod}`" for mod in (n.get("forbidden_imports") or [])]
    line = f"- {n.get('text', '(no text)')}"
    if checked:
        line += "  \n  *checked, not judged:* " + ", ".join(checked)
    return line

# Constraints as well as non-goals. `non_goals` is what the bean is not for and
# `constraints` is what it may not do — the same shape of statement, checked by
# the same script, and bean.md carried only the first. A reader of the generated
# document saw three of bean-002's statements and not the other three.
cons = bean.get("constraints") or []
if cons:
    out.append("## Constraints\n")
    for c in cons:
        out.append(render_statement(c))
    out.append("")

ng = bean.get("non_goals") or []
if ng:
    out.append("## Non-goals\n")
    for n in ng:
        out.append(render_statement(n))
    out.append("")
print("\n".join(out))
PY
  write "$dir/bean.md" < "/tmp/bean-md.$$"
  rm -f "/tmp/bean-md.$$"

  order="$(jq -r '.approval.order // 999' <<<"$meta")"
  INDEX_ROWS="$INDEX_ROWS$(printf '%s\t| %s | %s | %s | %s | Approved |' \
    "$order" "$id" "$title" "$TIER" "$(jq -r '.approval.approved_by // "—"' <<<"$meta" | cut -c1-24)")
"
  installed=$((installed + 1))
done

# -- the index preflight reads --------------------------------------------------
# Column 5 is the status cell preflight checks; the order column decides what
# `factory go` would queue first.
{
  printf '# Beans — %s\n\n' "$(basename "$BEAN_SET")"
  printf 'Generated by `factory/scaffold.sh` from the approved bean set. A bean reaches\n'
  printf 'this file only with `status: approved`; the pipeline refuses anything else.\n\n'
  printf '| ID | Title | Tier | Approved by | Status |\n'
  printf '|---|---|---|---|---|\n'
  printf '%s' "$INDEX_ROWS" | sort -n | cut -f2-
  printf '\n'
} | write "factory/beans/INDEX.md"

# -- the pipeline's view of this repo -------------------------------------------
# The corpus, copied from the bean set's manifest, which already records all
# three. run-record.schema.json requires them on every run record, and
# `requirements_sha256` is the field that proves the input never moved between
# runs — without it, comparing one run to another is comparing two things that
# may not have had the same requirements.
# Hidden tests, if this repo has a suite for this target.
#
# It was added to the target's pipeline-config.json by hand and the scaffold knew
# nothing about it, which meant the next `scaffold.sh` run would have deleted the
# whole block and the gate would have gone back to measuring only what the worker
# could read — silently, because a missing hidden_tests key is indistinguishable
# from a repo that never had one. The scaffold owns this file, so the scaffold has
# to write every part of it.
#
# Derived, not configured: the suite lives at hidden-tests/<repo name>/ in THIS
# repo, so its presence is the whole condition. A target with no suite gets no
# key, which is the honest statement that nothing hidden is measured there.
#
# The name comes from the bean set (`repo: beekeeper-lab/seating-planner-py`), not
# from the target DIRECTORY. Two reasons, and the second is the one that bit:
# a suite belongs to a repository rather than to wherever somebody cloned it, and
# --check regenerates into a temporary directory whose basename is random — keyed
# on that, the reference scaffold would never find the suite and --check would
# report this file as drifted forever, which is a drift detector that cries wolf
# until nobody reads it.
HIDDEN_REPO="$(basename "$(jq -r '.repo // empty' <<<"$(for b in "$BEAN_SET"/beans/*.yaml "$BEAN_SET"/*.yaml; do [ -e "$b" ] && { "$HERE/pipeline/yaml2json.sh" "$b"; break; }; done)" 2>/dev/null)")"
HIDDEN_JSON='null'
if [ -n "$HIDDEN_REPO" ] && [ -d "$REPO_ROOT/hidden-tests/$HIDDEN_REPO" ]; then
  HIDDEN_JSON="$(jq -n --arg d "../../$(basename "$REPO_ROOT")/hidden-tests/$HIDDEN_REPO/<bean>" \
    --arg r "../../$(basename "$REPO_ROOT")/hidden-tests/results" '{
    dir: $d,
    command: ["python", "-m", "pytest", "-q", "-p", "no:cacheprovider"],
    mount_at: "/hidden",
    results_dir: $r
  }')"
fi

jq -n \
  --argjson hidden "$HIDDEN_JSON" \
  --arg corpus_name "$(jq -r '.corpus // "unknown"' "$BEAN_SET/manifest.json" 2>/dev/null)" \
  --arg corpus_set "$(jq -r '.bean_set // "unversioned"' "$BEAN_SET/manifest.json" 2>/dev/null)" \
  --arg corpus_sha "$(jq -r '.requirements_sha256 // ""' "$BEAN_SET/manifest.json" 2>/dev/null)" --arg tier "$TIER" '{
  runs_root: "factory/runs",
  branch_pattern: "bean/BEAN-NNN-<slug>",
  bean_dir_pattern: "factory/beans/BEAN-NNN-<slug>",
  bean_index_path: "factory/beans/INDEX.md",
  repo_config: "factory/repo.yaml",
  gates_ref: "factory/gates.lock.yaml",
  corpus: {
    name: $corpus_name,
    bean_set: $corpus_set,
    requirements_sha256: $corpus_sha
  },
  test_command: ["pytest", "-q"],
  verify_timeout_s: 900,
  sandbox_env: {
    PYTHONPATH: "/work/src"
  },
  _comment: [
    "Read by the factory pipeline scripts, which live in the Local_Dark_Factory repo.",
    "Point them at this file: PIPELINE_CONFIG=<this repo>/factory/pipeline-config.json",
    "gates_ref means the gate list comes from the pinned manifest, not from here —",
    "two lists of gates is one list that will eventually disagree with itself.",
    "sandbox_env says how this project becomes importable inside the gate container.",
    "A src-layout package is not importable in a bare synced tree: there is no",
    "install step and §08 gives the gate no network to run one. PYTHONPATH=/work/src",
    "is the honest minimum. It makes the package importable; it is not the same as",
    "an editable install, and a bean whose criterion really means *installed* is",
    "asking for something this line cannot currently give it.",
    "hidden_tests names tests the worker never sees. They live in the factory repo, which the worker never mounts -- it gets this repo at /work and factory/skills read-only -- and the gate mounts them read-only at /hidden. <bean> is the bean id of the run, because they are written from the acceptance criteria of one bean. Paths are relative to this file, so they assume the factory repo is a sibling of this one; preflight says so at once if it is not. What comes back to the worker is a count and nothing else."
  ]
} | if $hidden == null then . else . + {hidden_tests: $hidden} end' | write "factory/pipeline-config.json"

# The line writes here; git needs the directories to exist before it can.
for d in specs impl invariants runs; do
  if [ "$DRY" = 0 ]; then
    mkdir -p "$TARGET/factory/$d"
    # .gitkeep only where there is nothing else to keep the directory alive.
    if [ -z "$(ls -A "$TARGET/factory/$d" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
      [ -e "$TARGET/factory/$d/.gitkeep" ] || : > "$TARGET/factory/$d/.gitkeep"
    else
      rm -f "$TARGET/factory/$d/.gitkeep"
    fi
  fi
  say "mkdir" "factory/$d/"
done

if [ "$DRY" = 0 ]; then
  # Run directories are evidence of a run, not source. They are kept out of the
  # index so a branch switch cannot delete the record of why a bean blocked.
  gi="$TARGET/.gitignore"
  grep -qxF 'factory/runs/' "$gi" 2>/dev/null || printf 'factory/runs/\n' >> "$gi"
  say "write" ".gitignore (factory/runs/)"
fi

printf '\n%s bean(s) installed, %s skipped (not approved)\n' "$installed" "$skipped"
[ "$installed" -gt 0 ] || { echo "no approved beans were installed — the line would have nothing to do" >&2; exit 1; }

if [ "$DRY" = 0 ]; then
  printf '\nvalidate what was written:\n'
  printf '  %s bench/validate.py repo-config %s/factory/repo.yaml\n' "$PY" "$TARGET"
  printf '  %s bench/validate.py risk-policy %s/factory/risk-policy.yaml\n' "$PY" "$TARGET"
  printf '  %s bench/validate.py gate-manifest %s/factory/gates.lock.yaml\n' "$PY" "$TARGET"
  printf '  %s bench/validate.py --corpus %s/factory/beans\n' "$PY" "$TARGET"
fi
