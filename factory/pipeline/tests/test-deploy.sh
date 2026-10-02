#!/usr/bin/env bash
# test-deploy.sh — the unattended entry point (factory/deploy/run-line.sh), its
# stop (drain-and-wait.sh) and the unit file, without installing anything.
#
# The environment scrub is the claim that matters most: §08 says no provider key
# reaches the runtime. It is tested by putting several in and looking at what the
# line's own command receives.
set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="$(cd "$PIPELINE_DIR/../deploy" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() {
  if grep -qF -- "$2" <<<"$3"; then printf '  ok    %s\n' "$1"; PASS=$((PASS+1))
  else printf '  FAIL  %s\n          expected: %s\n          got: %s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
nope() {
  if grep -qF -- "$2" <<<"$3"; then printf '  FAIL  %s — found: %s\n' "$1" "$2"; FAIL=$((FAIL+1))
  else printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); fi
}

# A stand-in for bin/factory: records each call and the environment it got, and
# answers `go` from a script of exit codes and outputs.
cat > "$WORK/factory" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FACTORY_STUB_DIR/calls"
case "$1" in
  state)
    if [ "${2:-}" = --control ]; then cat "$FACTORY_STUB_DIR/control" 2>/dev/null; exit 0; fi
    cat "$FACTORY_STUB_DIR/state.json" 2>/dev/null || echo '{}'; exit 0 ;;
  reconcile) exit 0 ;;
  drain) echo drain > "$FACTORY_STUB_DIR/control"; exit 0 ;;
  go)
    env > "$FACTORY_STUB_DIR/env.go"
    n="$(cat "$FACTORY_STUB_DIR/go.n" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$FACTORY_STUB_DIR/go.n"
    line="$(sed -n "${n}p" "$FACTORY_STUB_DIR/go.script")"
    [ -z "$line" ] && { echo drain > "$FACTORY_STUB_DIR/control"; echo "0 bean(s) run."; exit 0; }
    rc="${line%% *}"; msg="${line#* }"
    echo "$msg"; exit "$rc" ;;
esac
SH
chmod +x "$WORK/factory"
export FACTORY_STUB_DIR="$WORK/stub"
fresh() { rm -rf "$FACTORY_STUB_DIR"; mkdir -p "$FACTORY_STUB_DIR"; printf '%s\n' "$@" > "$FACTORY_STUB_DIR/go.script"; }
line() { ( cd "$WORK" && FACTORY_BIN="$WORK/factory" FACTORY_IDLE_SECONDS=0 timeout 60 bash "$DEPLOY/run-line.sh" "$@" 2>&1 ); }

printf '\n== the environment is rebuilt from an allowlist ==\n\n'
fresh "0 1 bean(s) run."
out="$(ANTHROPIC_API_KEY=sk-ant-x OPENAI_API_KEY=sk-y SOME_SERVICE_API_KEY=z AWS_SECRET_ACCESS_KEY=w \
       GH_TOKEN=ghp_keep FACTORY_ADVISORY_AUDITS=1 RANDOM_THING=1 line)"
envgo="$(cat "$FACTORY_STUB_DIR/env.go")"
nope  "no Anthropic key reaches the line"   "ANTHROPIC_API_KEY" "$envgo"
nope  "no OpenAI key"                        "OPENAI_API_KEY" "$envgo"
nope  "no key by any other name"             "SOME_SERVICE_API_KEY" "$envgo"
nope  "no cloud secret"                      "AWS_SECRET_ACCESS_KEY" "$envgo"
nope  "nothing off the allowlist"            "RANDOM_THING" "$envgo"
check "GitHub's token does"                  "GH_TOKEN=ghp_keep" "$envgo"
check "and the line's own switches"          "FACTORY_ADVISORY_AUDITS=1" "$envgo"

printf '\n== the loop: reconcile, go, wait, until drained ==\n\n'
fresh "0 1 bean(s) run." "0 0 bean(s) run."
out="$(line)"; rc=$?
calls="$(cat "$FACTORY_STUB_DIR/calls")"
check "it reconciles before each go"         "reconcile --apply" "$calls"
check "it waits when nothing is ready"       "nothing ready; waiting" "$out"
check "and stops on drain"                   "factory drain: stopping" "$out"
check "with exit 0"                          "0" "$rc"
first_two="$(grep -E '^(reconcile|go)' "$FACTORY_STUB_DIR/calls" | head -2 | tr '\n' ' ')"
check "reconcile comes first"                "reconcile --apply go" "$first_two"

printf '\n== a halt moves on; three in a row stops the line ==\n\n'
fresh "1 HALT one" "0 1 bean(s) run."
out="$(line)"; rc=$?
check "one halt is reported"                 "a bean halted (exit 1), 1 in a row" "$out"
check "and the line goes on"                 "factory drain: stopping" "$out"
fresh "1 HALT a" "1 HALT b" "1 HALT c" "0 never reached"
out="$(line)"; rc=$?
check "three in a row stop it"               "3 beans in a row halted" "$out"
check "with exit 3"                          "3" "$rc"
nope  "and nothing after is run"             "never reached" "$out"
fresh "1 HALT a" "0 1 bean(s) run." "1 HALT b" "1 HALT c"
out="$(line)"
nope  "a success between halts resets the count" "3 beans in a row halted" "$out"

printf '\n== drain-and-wait: drain, then wait for the leases ==\n\n'
rm -rf "$FACTORY_STUB_DIR"; mkdir -p "$FACTORY_STUB_DIR"
echo '{"bean-001":{"state":"building","lease":{"owner":"h:1","live":true}}}' > "$FACTORY_STUB_DIR/state.json"
( sleep 2; echo '{"bean-001":{"state":"building"}}' > "$FACTORY_STUB_DIR/state.json" ) &
t0="$(date +%s)"
out="$( cd "$WORK" && FACTORY_BIN="$WORK/factory" FACTORY_DRAIN_WAIT=60 bash "$DEPLOY/drain-and-wait.sh" 2>&1 )"; rc=$?
t1="$(date +%s)"
check "it asks for a drain"                  "drain" "$(cat "$FACTORY_STUB_DIR/calls")"
check "and returns once nothing is leased"   "0" "$rc"
if [ $((t1 - t0)) -ge 2 ] && [ $((t1 - t0)) -lt 30 ]; then printf '  ok    it waited for the lease to go (%ss)\n' $((t1 - t0)); PASS=$((PASS+1))
else printf '  FAIL  it waited for the lease to go — took %ss\n' $((t1 - t0)); FAIL=$((FAIL+1)); fi

printf '\n== the unit file ==\n\n'
U="$(cat "$DEPLOY/darkfactory@.service")"
for d in "User=factory" "StateDirectory=darkfactory" "ProtectSystem=strict" "ProtectHome=true" \
         "PrivateTmp=true" "CONTAINERS_STORAGE_CONF=/etc/darkfactory/storage.conf" \
         "ExecStart=/opt/darkfactory/factory/deploy/run-line.sh" "ExecStop=/opt/darkfactory/factory/deploy/drain-and-wait.sh"; do
  check "it sets $d" "$d" "$U"
done
check "podman storage is under the StateDirectory" "graphroot = \"/var/lib/darkfactory/containers/storage\"" \
      "$(cat "$DEPLOY/storage.conf")"
if command -v systemd-analyze >/dev/null 2>&1; then
  cp "$DEPLOY/darkfactory@.service" "$WORK/darkfactory@t.service"
  sec="$(systemd-analyze security --offline=true "$WORK/darkfactory@t.service" 2>&1 | tail -1)"
  check "systemd can read it and score it"   "Overall exposure level" "$sec"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
