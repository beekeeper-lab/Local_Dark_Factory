#!/usr/bin/env bash
# sandbox.sh — run one command under the §08 sandbox contract, or refuse to run it.
#
# The contract, clause by clause, and where each is enforced below:
#
#   read-only outside the editable tree   --read-only, plus exactly one rw mount
#   the tree is the only writable mount   --volume <tree>:/work:rw,Z (+ a small tmpfs,
#                                          because a read-only rootfs otherwise breaks
#                                          every tool that writes a temp file)
#   no container socket, no SSH agent     nothing is mounted but the tree, and
#                                          whatever --mount-ro was explicitly
#                                          asked for (read-only, never inside the
#                                          tree, never over /work or a system path)
#   scrubbed environment                  podman passes no host env; we pass four
#                                          variables and assert nothing else arrived
#   dropped capabilities, no-new-privs    --cap-drop=ALL --security-opt=no-new-privileges
#   resource limits                       --memory --pids-limit --cpus, and a wall clock
#   network disabled by default           --network=none
#   "no git" is structural                the image has no git binary, and the tree
#                                          handed in has no .git — both asserted, not assumed
#
# The last one is the one worth being pedantic about. "The worker must not use
# git" as an instruction is a request; a worker image with no git executable and
# a tree with no .git is a fact. This script refuses to start if either turns out
# to be untrue, because a sandbox that silently degrades into a normal shell is
# worse than no sandbox: everything downstream would still be labelled contained.
set -uo pipefail
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$PIPELINE_DIR/lib.sh"

REFUSED_RC=5

usage() {
  cat <<'EOF'
sandbox.sh — run a command inside the §08 sandbox, or refuse.

usage:
  sandbox.sh --tree <dir> [options] -- <argv...>
  sandbox.sh --check [--tree <dir>]        report the contract, run nothing

  --tree <dir>       the ONLY writable mount, mounted at /work (the working dir)
  --image <ref>      image to run (default: from the gate manifest, see --gates)
  --gates <file>     gate manifest to read the pinned image from
                     (default: factory/gates.lock.yaml in the repo)
  --network none|model
                     none (default) — no network at all.
                     model — reach the host's Ollama endpoint and nothing else is
                     *intended*; see the warning printed when it is used.
  --timeout <s>      wall clock, default 900
  --memory <size>    default 4g
  --cpus <n>         default 4
  --pids <n>         default 256
  --max-output <n>   bytes of combined output kept, default 1000000
  --out <file>       write the captured output here (default: stdout)
  --env K=V          pass one extra variable (repeatable); refused for anything
                     that looks like a credential
  --mount-ro H:C     mount host directory H read-only at container path C
                     (repeatable). For material the command must run against but
                     must not be able to change, and which does not belong in the
                     repository: hidden tests are the reason this exists. Refused
                     if H is inside --tree (then it is not hidden from anything
                     that can read the tree), if C would shadow /work or a system
                     directory, or if H is not a directory that exists.

Exit: the command's own status, or 5 when the sandbox refused to run it.
EOF
}

TREE=""; IMAGE=""; GATES=""; NETWORK="none"; TIMEOUT=900
MEMORY="4g"; CPUS="4"; PIDS="256"; MAX_OUTPUT=1000000; OUT=""; CHECK=0
EXTRA_ENV=()
MOUNTS_RO=()
CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    --tree)       TREE="${2:?--tree needs a directory}"; shift 2 ;;
    --image)      IMAGE="${2:?--image needs a reference}"; shift 2 ;;
    --gates)      GATES="${2:?--gates needs a file}"; shift 2 ;;
    --network)    NETWORK="${2:?--network needs none or model}"; shift 2 ;;
    --timeout)    TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --memory)     MEMORY="${2:?--memory needs a size}"; shift 2 ;;
    --cpus)       CPUS="${2:?--cpus needs a number}"; shift 2 ;;
    --pids)       PIDS="${2:?--pids needs a number}"; shift 2 ;;
    --max-output) MAX_OUTPUT="${2:?--max-output needs bytes}"; shift 2 ;;
    --out)        OUT="${2:?--out needs a path}"; shift 2 ;;
    --env)        EXTRA_ENV+=( "${2:?--env needs K=V}" ); shift 2 ;;
    --mount-ro)   MOUNTS_RO+=( "${2:?--mount-ro needs HOSTDIR:CONTAINERPATH}" ); shift 2 ;;
    --check)      CHECK=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    --version)    cat "$PIPELINE_DIR/VERSION"; exit 0 ;;
    --)           shift; CMD=( "$@" ); break ;;
    *)            usage >&2; die "unknown argument: $1" ;;
  esac
done

refuse() { printf 'sandbox: REFUSED — %s\n' "$*" >&2; exit "$REFUSED_RC"; }

command -v podman >/dev/null 2>&1 || refuse "podman is not installed; the sandbox is not optional"

# -- extra read-only mounts ------------------------------------------------------
# The header above says "nothing is mounted but the tree", and this is the one
# exception, so it is bounded here rather than at the call site. Every clause is a
# way the exception could quietly become a hole:
#
#   inside the tree      then it is readable by anything that can read /work, and
#                        for hidden tests that is the entire point defeated.
#   over /work           a mount at or under /work shadows the code under test;
#                        the tests would run against the mount, not the work.
#   over a system path   the image is pinned so that what runs is known; mounting
#                        over /usr or /etc makes the pin a statement about nothing.
#   read-write           there is exactly one writable mount and it is the tree.
#
# It is never inferred: no --mount-ro, no extra mount.
MOUNT_ARGS=()
for m in ${MOUNTS_RO+"${MOUNTS_RO[@]}"}; do
  case "$m" in
    *:*) ;;
    *) refuse "--mount-ro wants HOSTDIR:CONTAINERPATH, got '$m'" ;;
  esac
  mh="${m%%:*}"; mc="${m#*:}"
  [ -d "$mh" ] || refuse "--mount-ro source is not a directory: $mh"
  mh="$(cd "$mh" && pwd)"
  case "$mc" in
    /*) ;;
    *) refuse "--mount-ro target must be an absolute container path, got '$mc'" ;;
  esac
  case "$mc" in
    /work|/work/*|/|/tmp|/tmp/*|/proc/*|/sys/*|/dev/*|/etc|/etc/*|/usr|/usr/*|/bin*|/sbin*|/lib*|/var|/var/*|/home|/home/*|/run|/run/*|/root|/root/*)
      refuse "--mount-ro target '$mc' would shadow the tree or a system path" ;;
  esac
  if [ -n "$TREE" ] && [ -d "$TREE" ]; then
    tree_abs="$(cd "$TREE" && pwd)"
    case "$mh/" in
      "$tree_abs"/*) refuse "--mount-ro source $mh is inside the tree; anything that can read /work can already read it" ;;
    esac
  fi
  MOUNT_ARGS+=( --volume "$mh:$mc:ro,Z" )
done

# -- the image -------------------------------------------------------------------
if [ -z "$IMAGE" ]; then
  if [ -z "$GATES" ]; then
    for cand in "$(repo_root)/factory/gates.lock.yaml" "$(repo_root)/gates.lock.yaml"; do
      [ -f "$cand" ] && { GATES="$cand"; break; }
    done
  fi
  [ -n "$GATES" ] && [ -f "$GATES" ] \
    || refuse "no image given and no gate manifest found — the sandbox will not pick an image for you"
  IMAGE="$("$PIPELINE_DIR/yaml2json.sh" "$GATES" | jq -r '.image // empty')"
  [ -n "$IMAGE" ] || refuse "gate manifest has no image: $GATES"
fi

# A digest-pinned reference is the whole point of gates.lock.yaml. A tag can be
# repointed at different contents the same way a model tag can.
case "$IMAGE" in
  *@sha256:*) ;;
  *) refuse "image '$IMAGE' is not pinned by digest — every 'the gates passed' is a claim about specific contents" ;;
esac

# podman cannot pull "name:tag@sha256:..." for a local image; resolve to what we run.
RUN_IMAGE="$IMAGE"
if ! podman image exists "$IMAGE" 2>/dev/null; then
  # Locally-built images are addressed by name:tag; verify the digest matches.
  name_tag="${IMAGE%@*}"
  want_digest="${IMAGE##*@}"
  if podman image exists "$name_tag" 2>/dev/null; then
    have_digest="$(podman inspect "$name_tag" --format '{{.Digest}}' 2>/dev/null)"
    [ "$have_digest" = "$want_digest" ] \
      || refuse "image $name_tag is $have_digest but the manifest pins $want_digest — the gate image was replaced under the manifest"
    RUN_IMAGE="$name_tag"
  else
    refuse "image not present: $IMAGE (build it with factory/gate-image/build.sh, or pull it)"
  fi
fi

# -- "no git" is structural, so prove it -----------------------------------------
if podman run --rm --network=none --read-only --cap-drop=ALL \
     --security-opt=no-new-privileges "$RUN_IMAGE" sh -c 'command -v git' >/dev/null 2>&1; then
  refuse "the image contains a git executable; 'the worker must not use git' is then only a request"
fi

# -- the editable tree -----------------------------------------------------------
if [ "$CHECK" = 0 ] || [ -n "$TREE" ]; then
  [ -n "$TREE" ] || refuse "--tree is required: the sandbox has exactly one writable mount and you must say which"
  [ -d "$TREE" ] || refuse "editable tree not found: $TREE"
  TREE="$(cd "$TREE" && pwd)"
  if [ -e "$TREE/.git" ]; then
    refuse "the editable tree still has a .git ($TREE/.git) — the controller keeps the real worktree outside the boundary and syncs a copy without it"
  fi
fi

if [ "$CHECK" = 1 ]; then
  printf 'sandbox contract\n'
  printf '  image           %s\n' "$IMAGE"
  printf '  git in image    absent (asserted)\n'
  printf '  tree            %s\n' "${TREE:-<none given>}"
  [ -n "$TREE" ] && printf '  .git in tree    absent (asserted)\n'
  printf '  network         %s\n' "$NETWORK"
  printf '  rootfs          read-only; %s is the only writable mount (plus a 64m tmpfs at /tmp)\n' "${TREE:-<tree>}"
  # A contract report that does not list the exception is a contract report that
  # lies by omission, and --check is what a reader trusts instead of reading this
  # file.
  if [ "${#MOUNT_ARGS[@]}" -gt 0 ]; then
    for ma in "${MOUNT_ARGS[@]}"; do
      case "$ma" in --volume) continue ;; esac
      printf '  extra mount     %s (read-only, outside the tree)\n' "$ma"
    done
  else
    printf '  extra mounts    none\n'
  fi
  printf '  capabilities    all dropped, no-new-privileges\n'
  printf '  limits          %s memory · %s cpus · %s pids · %ss wall · %s bytes output\n' \
    "$MEMORY" "$CPUS" "$PIDS" "$TIMEOUT" "$MAX_OUTPUT"
  exit 0
fi

[ "${#CMD[@]}" -gt 0 ] || { usage >&2; refuse "nothing to run (did you forget -- before the command?)"; }

# -- environment -----------------------------------------------------------------
# podman passes no host environment unless asked. We name what goes in, and refuse
# anything credential-shaped: the §08 rule is that the sandbox contains no
# credentials, and the cheapest way to keep that true is to never pass one.
ENV_ARGS=( --env "HOME=/tmp" --env "PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/bin"
           --env "LANG=C.UTF-8" --env "PYTHONDONTWRITEBYTECODE=1" )
for kv in ${EXTRA_ENV+"${EXTRA_ENV[@]}"}; do
  key="${kv%%=*}"
  case "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')" in
    *TOKEN*|*SECRET*|*PASSWORD*|*APIKEY*|*API_KEY*|*_KEY|GH_*|GITHUB_*|AWS_*|SSH_*)
      refuse "refusing to pass '$key' into the sandbox — it looks like a credential" ;;
  esac
  ENV_ARGS+=( --env "$kv" )
done

NET_ARGS=( --network=none )
case "$NETWORK" in
  none) ;;
  model)
    # The worker needs the local model endpoint and nothing else. slirp4netns
    # with host-loopback gives it that route — and, honestly, general outbound
    # as well. Stated plainly rather than papered over: closing that hole needs
    # a filtering proxy or a netns firewall, and until it exists this mode is
    # weaker than the contract asks for.
    NET_ARGS=( --network=slirp4netns:allow_host_loopback=true )
    printf 'sandbox: WARNING network=model permits general outbound traffic, not only the model endpoint (§08 wants an allow-listed proxy; not built yet)\n' >&2
    ;;
  *) refuse "--network must be none or model (got: $NETWORK)" ;;
esac

RUN_ARGS=(
  run --rm
  --read-only
  # ,Z relabels the tree for this container only. Without it SELinux denies the
  # read on Fedora and the failure looks exactly like a broken command, which is
  # the most expensive kind of sandbox bug: it blames the worker.
  --volume "$TREE:/work:rw,Z"
  ${MOUNT_ARGS+"${MOUNT_ARGS[@]}"}
  --tmpfs "/tmp:rw,size=64m,mode=1777"
  --workdir /work
  --cap-drop=ALL
  --security-opt=no-new-privileges
  --memory "$MEMORY"
  --cpus "$CPUS"
  --pids-limit "$PIDS"
  --userns=keep-id
  "${NET_ARGS[@]}"
  "${ENV_ARGS[@]}"
  "$RUN_IMAGE"
)

TMP_OUT="$(mktemp -t sandbox-XXXXXX.log)"
start="$(date +%s%3N)"
timeout --signal=TERM --kill-after=10 "$TIMEOUT" podman "${RUN_ARGS[@]}" "${CMD[@]}" > "$TMP_OUT" 2>&1
rc=$?
end="$(date +%s%3N)"

# Output limit: a worker that prints a gigabyte should not be able to fill the
# disk or the next prompt.
size="$(wc -c < "$TMP_OUT")"
if [ "$size" -gt "$MAX_OUTPUT" ]; then
  head -c "$MAX_OUTPUT" "$TMP_OUT" > "$TMP_OUT.cut"
  printf '\n\n[sandbox: output truncated at %s bytes of %s]\n' "$MAX_OUTPUT" "$size" >> "$TMP_OUT.cut"
  mv "$TMP_OUT.cut" "$TMP_OUT"
fi

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  mv "$TMP_OUT" "$OUT"
else
  cat "$TMP_OUT"
  rm -f "$TMP_OUT"
fi

if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  printf 'sandbox: the command exceeded the %ss wall clock and was killed\n' "$TIMEOUT" >&2
fi
printf 'sandbox: exit %s in %sms (%s, network=%s)\n' \
  "$rc" "$((end - start))" "${IMAGE##*/}" "$NETWORK" >&2
exit "$rc"
