#!/usr/bin/env bash
# check-unit.sh <repo> — run as root after installing, before `systemctl enable`.
# Each line is a claim the unit makes, checked on this machine.
set -uo pipefail
R="${1:?usage: check-unit.sh <repo directory under /var/lib/darkfactory/repos>}"
U="darkfactory@$R.service"; bad=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; bad=1; }
id factory >/dev/null 2>&1 && ok "the factory user exists" || fail "no factory user"
grep -q '^factory:' /etc/subuid && ok "it has subordinate uids for rootless podman" || fail "no /etc/subuid entry for factory"
[ -d "/var/lib/darkfactory/repos/$R/.git" ] && ok "the target is cloned" || fail "no clone at /var/lib/darkfactory/repos/$R"
[ "$(stat -c %a /etc/darkfactory/env 2>/dev/null)" = 600 ] && ok "the env file is 0600" || fail "/etc/darkfactory/env is not mode 0600"
extra="$(grep -vE '^\s*(#|$|GH_TOKEN=)' /etc/darkfactory/env 2>/dev/null)"
[ -z "$extra" ] && ok "the env file holds only GH_TOKEN" || fail "the env file holds more than GH_TOKEN: $(cut -d= -f1 <<<"$extra" | tr '\n' ' ')"
grep -q '^GH_TOKEN=..' /etc/darkfactory/env && ok "GH_TOKEN is set" || fail "GH_TOKEN is empty"
keys="$(sudo -u factory env | grep -E '^[A-Z_]*(API_KEY|SECRET)[A-Z_]*=' | cut -d= -f1)"
[ -z "$keys" ] && ok "the factory user's login environment has no API key" || fail "factory's environment has: $keys"
gr="$(sudo -u factory env CONTAINERS_STORAGE_CONF=/etc/darkfactory/storage.conf XDG_RUNTIME_DIR=/run/darkfactory \
      podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
[ "$gr" = /var/lib/darkfactory/containers/storage ] && ok "podman stores under the StateDirectory" || fail "podman graphroot is '$gr'"
systemctl cat "$U" >/dev/null 2>&1 && ok "systemd knows $U" || fail "systemd does not know $U (daemon-reload?)"
score="$(systemd-analyze security "$U" 2>/dev/null | tail -1)"
printf '  --    %s\n' "${score:-systemd-analyze security gave no score}"
[ "$bad" = 0 ] && printf '\nready: systemctl enable --now %s\n' "$U" || { printf '\nnot ready\n'; exit 1; }
