#!/usr/bin/env bash
# inflight.sh — refuse to measure while a bean is being built.
#
# Every harness here takes the GPU. `judge-fitness.sh` takes it hardest — it
# evicts resident models so a fitness score is not a measurement of VRAM — and
# grew a guard after nearly evicting the judge out from under a live spec audit,
# which would have recorded a dead runner as the judge's answer.
#
# The others do not evict, and are not therefore harmless. A 120b model loaded
# for a measurement while a 27B developer session is running means both wait on
# the same card: the run gets slower, the measurement gets slower, and the
# seconds in both records stop meaning what they say. `format-support.sh` loading
# four models at four thinking levels is the clearest case, and it ran alongside
# a live suite this morning and made `declared_matches_observed` report drift
# that had nothing to do with the run.
#
# One guard, sourced by all of them, so the next harness written inherits it.
#
#   source "$(dirname "$0")/inflight.sh"; refuse_if_inflight [evicts]
#
# NO_EVICT=1 or FACTORY_MEASURE_ANYWAY=1 proceeds, and says so, because measuring
# under contention on purpose is a legitimate thing to want.

refuse_if_inflight() { # refuse_if_inflight [evicts]
  local evicts="${1:-no}"
  pgrep -f '[o]rchestrate\.sh' >/dev/null 2>&1 || return 0
  if [ "${NO_EVICT:-0}" = 1 ] || [ "${FACTORY_MEASURE_ANYWAY:-0}" = 1 ]; then
    printf 'NOTE — a pipeline run is in flight and this is measuring anyway.\n' >&2
    printf 'The seconds in this record include contention for the GPU; do not compare\n' >&2
    printf 'them with a figure taken on a quiet box.\n' >&2
    return 0
  fi
  printf 'REFUSED — a pipeline run is in flight (orchestrate.sh).\n' >&2
  if [ "$evicts" = evicts ]; then
    printf 'This harness evicts models to control what it is measuring, which would take\n' >&2
    printf 'the GPU out from under that run.\n' >&2
  else
    printf 'This does not evict anything, but it does load a model, and two models on one\n' >&2
    printf 'card means the run and the measurement each wait on the other — so the seconds\n' >&2
    printf 'in both records stop meaning what they say.\n' >&2
  fi
  printf 'Wait for the run, or set FACTORY_MEASURE_ANYWAY=1 and accept the contention.\n' >&2
  exit 2
}
