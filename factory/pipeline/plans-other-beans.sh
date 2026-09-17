#!/usr/bin/env bash
# plans-other-beans.sh — is this plan doing a later bean's work?
#
# `bean-forbids.sh` answers "does this plan touch a place this bean forbids",
# from what the bean says about itself. This answers a different question from a
# different source: does a task's INTENT describe the subject matter of a
# different approved bean?
#
# The seeded defect it was built for is `unfinishable-task` — one task whose
# intent is "implement the complete seating optimizer: domain models, the CP-SAT
# solver, soft-constraint scoring, the persistence layer, the REST API and the
# report renderer". bench/controller-fitness.sh scored that as "not decidable
# from the documents, needs a judge", and the judge accepts about half of what it
# is shown. It IS decidable, because the other beans are on disk and each one
# says in its title what it is for. A task in bean-001 that names domain models
# and soft-constraint scoring is proposing bean-002's and bean-007's work.
#
# Two rules keep this from becoming a word-matching toy:
#
#   1. A term counts only if it is DISTINCTIVE, which is two conditions. It must
#      be absent from this bean's own title, intent, criteria and non-goals — a
#      scaffold bean that says "tests" is not planning the test bean's work. And
#      it must appear in exactly ONE other bean's title: a word several beans use
#      belongs to none of them. That second rule was not in the first version and
#      the first version raised a false alarm immediately, on the real bean-001
#      task list: "rules" (from ruff's rule list `E,F,I,UP,B`) and "seating" (from
#      the name of the product) matched bean-003's title, and two coincidences of
#      English read as a topic. Both words appear in several bean titles, so the
#      corpus itself says they are not anybody's subject.
#   2. TWO distinct terms from the same other bean, not one. One shared word is a
#      coincidence of English; two is a topic. This is the difference between a
#      check with no false alarms and a check nobody trusts, and the number was
#      chosen by measuring: controller-fitness counts false alarms and the clean
#      control must stay clean.
#
# Task INTENTS only, not spec.md. A task intent is a commitment to do work; spec
# prose is discussion, and a spec legitimately names other beans — its own
# dependencies, its non-goals, the seam it is leaving for someone else. Reading
# the prose would double the words and halve the meaning of a match. If this ever
# misses a defect that lives only in spec.md, the fix is a different check, not a
# wider net on this one.
#
# It reports; it does not decide alone. A match is a finding for the spec audit
# with the bean it belongs to named, which is the thing a human or a judge can
# act on in one line instead of reading twenty beans.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

usage() {
  cat <<'EOF'
plans-other-beans.sh — does this plan describe another bean's work?

usage: plans-other-beans.sh --bean <bean.yaml> --tasks <tasks.yaml>
                            [--beans-dir <dir>] [--min-terms N] [--json <path>]

  --beans-dir  where the other beans live (default: the bean's own directory,
               or its parent if each bean has a directory of its own)
  --min-terms  distinct terms from one other bean before it is reported
               (default 2 — one shared word is a coincidence of English)

Exit: 0 nothing, or nothing decidable · 1 a task describes another bean's work
      2 could not check
EOF
}

BEAN=""; TASKS=""; BEANS_DIR=""; MIN_TERMS=2; JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bean)      BEAN="${2:?--bean needs a file}"; shift 2 ;;
    --tasks)     TASKS="${2:?--tasks needs a file}"; shift 2 ;;
    --beans-dir) BEANS_DIR="${2:?--beans-dir needs a directory}"; shift 2 ;;
    --min-terms) MIN_TERMS="${2:?--min-terms needs a number}"; shift 2 ;;
    --json)      JSON="${2:?--json needs a path}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    --version)   cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    *) usage >&2; printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$BEAN" ] && [ -f "$BEAN" ] || { usage >&2; printf 'plans-other-beans: no bean at %s\n' "${BEAN:-<unset>}" >&2; exit 2; }
[ -n "$TASKS" ] && [ -f "$TASKS" ] || { usage >&2; printf 'plans-other-beans: no tasks at %s\n' "${TASKS:-<unset>}" >&2; exit 2; }

if [ -z "$BEANS_DIR" ]; then
  BEANS_DIR="$(cd "$(dirname "$BEAN")" && pwd)"
  # A bean in a directory of its own: the set is the parent.
  [ -f "$BEANS_DIR/$(basename "$BEAN")" ] && [ "$(find "$BEANS_DIR" -maxdepth 1 -name '*.yaml' | wc -l)" -le 1 ] \
    && BEANS_DIR="$(dirname "$BEANS_DIR")"
fi

BEAN_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$BEAN")" \
  || { printf 'plans-other-beans: cannot read the bean: %s\n' "$BEAN" >&2; exit 2; }
TASKS_JSON="$("$PIPELINE_DIR/yaml2json.sh" "$TASKS")" \
  || { printf 'plans-other-beans: cannot read the tasks: %s\n' "$TASKS" >&2; exit 2; }
BEAN_ID="$(jq -r '.id // "?"' <<<"$BEAN_JSON")"
PY="$(factory_python)"

# Collect the other beans: id, title. A bean whose file cannot be read is skipped
# and counted, because "I could not read four of the beans" is a different answer
# from "none of them matched".
OTHERS='[]'; UNREADABLE=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  oj="$("$PIPELINE_DIR/yaml2json.sh" "$f" 2>/dev/null)" || { UNREADABLE=$((UNREADABLE+1)); continue; }
  oid="$(jq -r '.id // empty' <<<"$oj")"
  [ -n "$oid" ] || { UNREADABLE=$((UNREADABLE+1)); continue; }
  [ "$oid" = "$BEAN_ID" ] && continue
  OTHERS="$(jq -c --arg i "$oid" --arg t "$(jq -r '.title // ""' <<<"$oj")" '. + [{id:$i, title:$t}]' <<<"$OTHERS")"
done < <(find "$BEANS_DIR" -maxdepth 2 -name '*.yaml' 2>/dev/null | sort)

if [ "$(jq 'length' <<<"$OTHERS")" -eq 0 ]; then
  printf 'plans-other-beans: no other beans to compare against in %s; nothing was checked\n' "$BEANS_DIR"
  [ -n "$JSON" ] && jq -n --arg b "$BEAN_ID" '{schema:"plans-other-beans/1.0.0", bean:$b, compared_against:0, findings:[], note:"No other beans were found, so nothing was checked. That is not the same as nothing being wrong."}' > "$JSON"
  exit 0
fi

RESULT="$("$PY" - "$BEAN_JSON" "$TASKS_JSON" "$OTHERS" "$MIN_TERMS" <<'PY'
import json, re, sys

bean = json.loads(sys.argv[1]); tasks = json.loads(sys.argv[2])
others = json.loads(sys.argv[3]); min_terms = int(sys.argv[4])

# Words that every bean in every corpus uses. A match on one of these says
# nothing about whose work it is.
STOP = {
    "the","and","for","with","that","this","from","into","only","not","its",
    "test","tests","testing","code","file","files","path","paths","work","bean",
    "data","type","types","value","values","field","fields","name","names",
    "using","use","uses","when","where","which","what","then","than","are","was",
    "have","has","been","will","can","may","must","should","would","all","any",
    "new","old","one","two","more","most","less","each","every","some","other",
    "run","runs","running","make","makes","made","add","adds","added","set",
    "sets","get","gets","project","support","supports","mode","modes","result",
    "results","report","reports","reporting","check","checks","explicit","never",
    "always","real","first","last","before","after","without","within","given",
}
WORD = re.compile(r"[a-z][a-z0-9-]{2,}")

def words(text):
    return {w for w in WORD.findall((text or "").lower()) if w not in STOP}

# This bean's own vocabulary: everything it says about itself. A term it already
# uses is not distinctive of anybody else.
own = []
own.append(bean.get("title") or "")
own.append(bean.get("intent") or "")
for ac in bean.get("acceptance_criteria") or []:
    own.append(ac.get("text") or "")
for key in ("non_goals", "constraints"):
    for item in bean.get(key) or []:
        own.append(item if isinstance(item, str) else (item.get("text") or ""))
own.append(((bean.get("context") or {}).get("background")) or "")
own_words = words(" ".join(own))

# How many of the other beans' titles each word appears in. A word in more than
# one belongs to none of them: it is the corpus's own vocabulary, not a subject.
from collections import Counter
df = Counter()
for o in others:
    for w in words(o["title"]):
        df[w] += 1

findings = []
for t in tasks.get("tasks") or []:
    intent = t.get("intent") or ""
    tw = words(intent)
    for o in others:
        # Distinctive: in the other bean's title, and NOT in this bean's own
        # vocabulary. The title is what a bean is for, in one line, written by a
        # person — a better summary than anything derived.
        distinctive = {w for w in words(o["title"]) if w not in own_words and df[w] == 1}
        hit = sorted(tw & distinctive)
        if len(hit) >= min_terms:
            findings.append({
                "task": t.get("id") or "?",
                "belongs_to": o["id"],
                "their_title": o["title"],
                "terms": hit,
            })

print(json.dumps({"findings": findings, "compared_against": len(others)}))
PY
)" || { printf 'plans-other-beans: could not compare\n' >&2; exit 2; }

N="$(jq '.findings | length' <<<"$RESULT")"
CMP="$(jq '.compared_against' <<<"$RESULT")"
if [ -n "$JSON" ]; then
  mkdir -p "$(dirname "$JSON")"
  jq -n --arg b "$BEAN_ID" --argjson r "$RESULT" --argjson u "$UNREADABLE" --argjson m "$MIN_TERMS" \
    '{schema:"plans-other-beans/1.0.0", bean:$b, compared_against:$r.compared_against,
      unreadable_beans:$u, min_terms:$m, findings:$r.findings,
      caveat:"Word overlap between a task intent and another approved bean TITLE, after removing every word this bean already uses about itself and a stoplist of words every corpus shares. Two distinct terms are required, because one is a coincidence of English. It finds a plan describing another bean subject matter; it cannot find one that describes it in different words."}' > "$JSON"
fi

if [ "$N" -eq 0 ]; then
  printf 'plans-other-beans: %s task(s) against %s other bean(s), none describes another bean'"'"'s work\n' \
    "$(jq '(.tasks // []) | length' <<<"$TASKS_JSON")" "$CMP"
  [ "$UNREADABLE" -gt 0 ] && printf '  (%s bean file(s) could not be read and were not compared)\n' "$UNREADABLE"
  exit 0
fi
printf 'plans-other-beans: %s task(s) plan work that belongs to another bean:\n' "$N" >&2
jq -r '.findings[] | "  - \(.task) describes \(.belongs_to) — \(.their_title)\n      shared terms: \(.terms | join(", "))"' <<<"$RESULT" >&2
printf '\n  A task whose intent is another bean'"'"'s subject is either that bean arriving\n' >&2
printf '  early or a task nobody can finish inside this one. Both end the same way: the\n' >&2
printf '  work lands outside these write paths, or it does not land at all.\n' >&2
exit 1
