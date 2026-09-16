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

# Anything in OUR process group is us, and everything else is somebody else.
#
# Three things match a harness looking for itself, and excluding `$$` catches
# none of them: the wrapper shell that launched it (`bash -c "... bash
# size-sweep.sh ..."`), the subshell a command substitution forks (same command
# line, different pid), and the script itself. All three share our process group;
# a genuinely separate run started from another terminal or a background job does
# not. So the question is not "which pids are related to me" — it is one field in
# `ps`, and it is exact.
_inflight_ancestors() { # every pid from here up to init
  local pid=$$ n=0
  while [ "${pid:-0}" -gt 1 ] && [ "$n" -lt 30 ]; do
    printf '%s\n' "$pid"
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    n=$((n + 1))
  done
}

_inflight_others() { # _inflight_others <pgrep-pattern> -> a matching command, or nothing
  # Two exclusions, because neither alone is enough.
  #
  # Our process group covers the script and every subshell a command substitution
  # forks — same command line, different pid, which is the match that had this
  # refusing to run because it saw itself.
  #
  # Our ancestors cover the wrapper that launched us. A shell invoked as
  # `bash -c "... bash size-sweep.sh ..."` has that whole string as its command
  # line and its OWN process group, so the group test does not reach it.
  local pat="$1" mypgid pid rest anc
  mypgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  anc=" $(_inflight_ancestors | tr '\n' ' ')"
  while read -r pid rest; do
    [ -n "$pid" ] || continue
    [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$mypgid" ] && continue
    case "$anc" in *" $pid "*) continue ;; esac
    printf '%s\n' "$rest"
    return 0
  done < <(pgrep -af "$pat" 2>/dev/null)
}

refuse_if_inflight() { # refuse_if_inflight [evicts]
  local evicts="${1:-no}" what=""
  # A bean being built is one way to be busy. Another measurement is the other,
  # and this guard did not look for it — so a one-size probe started to check an
  # argument fix ran a judge request alongside a three-pass fitness measurement,
  # and that measurement's `clean` case went from 212 seconds in pass 1 to being
  # cut off at 395 in pass 2. Two harnesses on one card is exactly the contention
  # this function exists to prevent; it was only watching for the pipeline.
  #
  # `$$` is excluded so a harness does not find itself, and the pattern is
  # bracketed so pgrep does not match this shell.
  if [ -n "$(_inflight_others '[o]rchestrate\.sh')" ]; then
    what="a pipeline run (orchestrate.sh)"
  else
    local other
    other="$(_inflight_others '[j]udge-fitness\.sh|[j]udge-variance\.sh|[s]ize-sweep\.sh|[f]ormat-support\.sh' \
      | grep -oE '(judge-fitness|judge-variance|size-sweep|format-support)\.sh' | head -1)"
    [ -n "$other" ] && what="another measurement ($other)"
  fi
  [ -n "$what" ] || return 0
  if [ "${NO_EVICT:-0}" = 1 ] || [ "${FACTORY_MEASURE_ANYWAY:-0}" = 1 ]; then
    printf 'NOTE — %s is in flight and this is measuring anyway.\n' "$what" >&2
    printf 'The seconds in this record include contention for the GPU; do not compare\n' >&2
    printf 'them with a figure taken on a quiet box.\n' >&2
    return 0
  fi
  printf 'REFUSED — %s is in flight.\n' "$what" >&2
  if [ "$evicts" = evicts ]; then
    printf 'This harness evicts models to control what it is measuring, which would take\n' >&2
    printf 'the GPU out from under that run.\n' >&2
  else
    printf 'This does not evict anything, but it does load a model, and two models on one\n' >&2
    printf 'card means the run and the measurement each wait on the other — so the seconds\n' >&2
    printf 'in both records stop meaning what they say.\n' >&2
  fi
  printf 'Wait for it, or set FACTORY_MEASURE_ANYWAY=1 and accept the contention.\n' >&2
  exit 2
}
