#!/usr/bin/env bash
# test-inflight.sh — more than one bean in flight (Phase 4 tasks 2 and 4): the
# worktree manager, preflight in a worktree, the inference gate's role batching,
# and `factory go --max-inflight` driving them.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PIPELINE_DIR/../.." && pwd)"
FACTORY="$PIPELINE_DIR/../bin/factory"
WORK="$(mktemp -d)"
cleanup() { git -C "$WORK/repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
              | grep -F "$WORK/repo.worktrees/" | while read -r w; do git -C "$WORK/repo" worktree remove --force "$w" 2>/dev/null; done
            rm -rf "$WORK"; }
trap cleanup EXIT
PY="${PIPELINE_PYTHON:-$ROOT/.venv/bin/python}"; [ -x "$PY" ] || PY=python3

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
want() {
  local n="$1" d="$2"; shift 2
  if "$@"; then printf '  ok    %s\n' "$n"; PASS=$((PASS+1))
  else printf '  FAIL  %s — %s\n' "$n" "$d"; FAIL=$((FAIL+1)); fi
}

# A target with an origin, three independent approved beans.
git init -q --bare "$WORK/origin.git"
REPO="$WORK/repo"; git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e.com; git -C "$REPO" config user.name T
git -C "$REPO" remote add origin "$WORK/origin.git"
mkdir -p "$REPO/factory/runs"
cat > "$REPO/factory/pipeline-config.json" <<'CFG'
{"runs_root":"factory/runs","branch_pattern":"bean/BEAN-NNN-<slug>",
 "bean_dir_pattern":"factory/beans/BEAN-NNN-<slug>","bean_index_path":"factory/beans/INDEX.md",
 "corpus":{"name":"fix","bean_set":"v1","requirements_sha256":"9f2c1a4b7d3e8056f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f701"}}
CFG
for i in 1 2 3; do
  d="$REPO/factory/beans/bean-00$i-x"; mkdir -p "$d"
  printf 'schema_version: bean/2.0.0\nid: bean-00%s\ntitle: T%s\nstatus: approved\napproval:\n  order: %s\ndependencies: []\n' "$i" "$i" "$i" > "$d/bean.yaml"
done
printf 'factory/runs/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A && git -C "$REPO" commit -qm init && git -C "$REPO" push -q origin main
export PIPELINE_CONFIG="$REPO/factory/pipeline-config.json"
WT() { ( cd "$REPO" && bash "$PIPELINE_DIR/worktree.sh" "$@" 2>&1 ); }

printf '\n== worktrees: one per bean, beside the main checkout ==\n\n'
p="$(WT add bean-001)"
check "it is created beside the repo"      "$WORK/repo.worktrees/bean-001" "$p"
want  "detached at main's tip"             "HEAD should equal main" \
      test "$(git -C "$p" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse main)"
out="$(cd "$p" && PIPELINE_CONFIG="$PIPELINE_CONFIG" bash "$PIPELINE_DIR/preflight.sh" bean-001 2>&1)"
check "preflight accepts it as on main"     "a bean worktree, detached at main's tip" "$out"
git -C "$p" checkout -q --detach HEAD~0 && printf 'y\n' > "$p/keep2.txt" && git -C "$p" add -A \
  && git -C "$p" -c user.email=t@e.com -c user.name=T commit -qm other
out="$(cd "$p" && PIPELINE_CONFIG="$PIPELINE_CONFIG" bash "$PIPELINE_DIR/preflight.sh" bean-001 2>&1)"
check "but not when it has moved off main"  "expected 'main'" "$out"
git -C "$p" checkout -q --detach main
check "runs resolve to the main checkout"  "$REPO/factory/runs" \
      "$(cd "$p" && source "$PIPELINE_DIR/lib.sh" && CONFIG_PATH="$PIPELINE_CONFIG" runs_root_dir)"
export FACTORY_STATE_DIR="$REPO/factory/runs/.state"
"$PY" "$PIPELINE_DIR/beanstate.py" transition bean-001 --to leased --key w1 >/dev/null
"$PY" "$PIPELINE_DIR/beanstate.py" block bean-001 --key w2 --why test >/dev/null
out="$(WT remove bean-001)"
check "a blocked bean keeps its worktree"   "kept: bean-001 is blocked" "$out"
want  "and it is still there"               "the worktree should survive" test -d "$p"
out="$(WT remove bean-001 --force)"
want  "--force removes it"                  "the worktree should be gone" test ! -d "$p"
unset FACTORY_STATE_DIR; rm -rf "$REPO/factory/runs/.state"

printf '\n== the inference gate: one model at a time, batched by role ==\n\n'
G=("$PY" "$PIPELINE_DIR/infergate.py")
export FACTORY_STATE_DIR="$WORK/gate" FACTORY_GATE_POLL=0.2
# Each contender is a live process whose pid names it, as a real step's is.
contend() { # contend <role> <bean> <label> [env...] — acquire, log the grant, hold until released
  local role="$1" bean="$2" label="$3"; shift 3
  ( env "$@" "${G[@]}" acquire --role "$role" --bean "$bean" --owner "$(hostname):$BASHPID" 2>/dev/null
    echo "$label" >> "$WORK/grants"
    while [ ! -f "$WORK/release-$label" ]; do sleep 0.1; done
    "${G[@]}" release --owner "$(hostname):$BASHPID" ) &
}
let_go() { touch "$WORK/release-$1"; }
nth() { for _ in $(seq 1 100); do [ "$(wc -l < "$WORK/grants" 2>/dev/null || echo 0)" -ge "$1" ] && break; sleep 0.1; done; sed -n "${1}p" "$WORK/grants"; }

contend developer bean-001 h; nth 1 >/dev/null
contend judge bean-002 j; sleep 0.5
contend developer bean-003 d; sleep 0.5
check "while held, nobody else is granted"  "h" "$(cat "$WORK/grants")"
let_go h
check "the resident role goes first, though it asked later" "d" "$(nth 2)"
let_go d
check "then the judge"                      "j" "$(nth 3)"
check "and the switch is recorded"          '"switch": true' "$(grep '"role": "judge"' "$FACTORY_STATE_DIR/inference-log.jsonl" | grep switch | head -1)"
let_go j; sleep 0.5
rm -f "$WORK"/grants "$WORK"/release-*; rm -rf "$FACTORY_STATE_DIR"

contend developer bean-001 h2; nth 1 >/dev/null
contend judge bean-002 j2 FACTORY_MAX_WAIT_MINUTES=0; sleep 0.5
contend developer bean-003 d2 FACTORY_MAX_WAIT_MINUTES=0; sleep 0.5
let_go h2
check "past max_wait, the longest waiter goes" "j2" "$(nth 2)"
let_go j2; let_go d2; sleep 0.5
rm -f "$WORK"/grants "$WORK"/release-*; rm -rf "$FACTORY_STATE_DIR"

# A holder that dies holding the gate does not wedge it.
( "${G[@]}" acquire --role developer --bean bean-001 --owner "$(hostname):$BASHPID" 2>/dev/null; sleep 300 ) &
DEAD=$!
for _ in $(seq 1 50); do grep -q '"holder": {' "$FACTORY_STATE_DIR/inference.json" 2>/dev/null && break; sleep 0.1; done
kill -9 "$DEAD" 2>/dev/null; wait "$DEAD" 2>/dev/null
out="$( timeout 10 "${G[@]}" acquire --role judge --bean bean-002 --owner "$(hostname):$$" 2>&1 )"; rc=$?
want  "a dead holder does not wedge the gate" "acquire timed out (rc $rc)" test "$rc" -eq 0
"${G[@]}" release --owner "$(hostname):$$"
unset FACTORY_STATE_DIR

printf '\n== factory go --max-inflight 2 ==\n\n'
cat > "$WORK/runner" <<'SH'
#!/usr/bin/env bash
# A stand-in for `factory run`: cut the branch, note when it ran, and finish.
b="$1"; git checkout -q -b "bean/$b-x"
echo "start $b $(date +%s.%N) $(pwd)" >> "$FACTORY_TEST_LOG"
sleep 3
echo "end $b $(date +%s.%N)" >> "$FACTORY_TEST_LOG"
exit 0
SH
chmod +x "$WORK/runner"
export FACTORY_TEST_LOG="$WORK/runs.log"
out="$(cd "$REPO" && FACTORY_GO_RUNNER="$WORK/runner" FACTORY_GO_STAGGER=0.5 bash "$FACTORY" go --max-inflight 2 2>&1)"; rc=$?
check "three beans run"                     "3 bean(s) run" "$out"
want  "with exit 0"                         "rc=$rc" test "$rc" -eq 0
starts="$(grep -c '^start' "$WORK/runs.log")"
want  "each started once"                   "$starts starts" test "$starts" = 3
overlap="$("$PY" - "$WORK/runs.log" <<'EOF'
import sys
ev = [l.split() for l in open(sys.argv[1])]
live = peak = 0
for kind, *_ in sorted(ev, key=lambda e: float(e[2])):
    live += 1 if kind == "start" else -1; peak = max(peak, live)
print(peak)
EOF
)"
want  "two were in flight at once"          "peak concurrency $overlap" test "$overlap" = 2
check "each in its own worktree"            "$WORK/repo.worktrees/bean-002" "$(cat "$WORK/runs.log")"
check "and the main checkout stayed on main" "main" "$(git -C "$REPO" branch --show-current)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
