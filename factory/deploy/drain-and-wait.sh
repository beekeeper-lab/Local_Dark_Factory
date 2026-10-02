#!/usr/bin/env bash
# drain-and-wait.sh — darkfactory@.service's ExecStop. Ask every run to stop at
# its next step boundary, then wait for the leases to go, so systemd's SIGTERM
# (which interrupts a step rather than finishing it) only reaches a line that has
# already stopped. Bounded below TimeoutStopSec, after which systemd signals
# anyway and reconciliation picks up what is left.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FACTORY="${FACTORY_BIN:-$HERE/../bin/factory}"
LIMIT="${FACTORY_DRAIN_WAIT:-6900}"
"$FACTORY" drain
for _ in $(seq 1 $((LIMIT / 10))); do
  [ "$("$FACTORY" state --json 2>/dev/null | jq '[.[] | select(.lease and .lease.live)] | length' 2>/dev/null || echo 0)" = 0 ] && exit 0
  sleep 10
done
echo "drain-and-wait: runs still leased after ${LIMIT}s; systemd will signal them" >&2
exit 0
