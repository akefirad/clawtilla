#!/usr/bin/env bash
# Runtime: gateway hardening, asserted against the LIVE container via
# `docker inspect` and in-container `exec`. Covers AC5 + the discovery/review
# hardening claims (read-only rootfs, 0700 state, 0600 db, no host reach).
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"

require_tools docker
svc_running "$GATEWAY_SVC" || die "gateway not running — run runtime/00_bringup.sh first"

section "gateway — docker inspect (host-reach surface)"

expect R-GW-6r "gateway has NO host bind mounts (live container)"
binds="$(inspect "$GATEWAY_SVC" '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}};{{end}}{{end}}')"
assert_empty "$binds"

expect R-GW-6br "only mount is the named volume at /opt/clawpatrol"
mounts="$(inspect "$GATEWAY_SVC" '{{range .Mounts}}{{.Type}}:{{.Destination}};{{end}}')"
assert_eq "$mounts" "volume:/opt/clawpatrol;"

expect R-GW-7r "no host.docker.internal / host-gateway in ExtraHosts"
assert_empty "$(inspect "$GATEWAY_SVC" '{{range .HostConfig.ExtraHosts}}{{.}};{{end}}')"

expect R-GW-1r "ReadonlyRootfs is true"
assert_eq "$(inspect "$GATEWAY_SVC" '{{.HostConfig.ReadonlyRootfs}}')" "true"

expect R-GW-9r "no-new-privileges is set"
assert_contains "$(inspect "$GATEWAY_SVC" '{{range .HostConfig.SecurityOpt}}{{.}};{{end}}')" "no-new-privileges"

expect R-GW-9br "no added capabilities (CapAdd empty)"
assert_empty "$(inspect "$GATEWAY_SVC" '{{range .HostConfig.CapAdd}}{{.}};{{end}}')"

expect R-GW-9dr "no /dev/net/tun device in the live gateway (CapAdd + no tun = inert)"
assert_empty "$(inspect "$GATEWAY_SVC" '{{range .HostConfig.Devices}}{{.PathInContainer}};{{end}}')"

expect R-GW-9cr "gateway is NOT on clawcage-net-only / has the egress network"
nets="$(inspect "$GATEWAY_SVC" '{{range $k,$v := .NetworkSettings.Networks}}{{$k}};{{end}}')"
if printf '%s' "$nets" | grep -q 'clawegress-net' && printf '%s' "$nets" | grep -q 'clawcage-net'; then pass; else fail "networks='$nets'"; fi

section "gateway — in-container state hardening"

expect R-GW-1e "rootfs is read-only (writing to / fails)"
assert_fail "xsh '$GATEWAY_SVC' 'touch /clawtilla-rotest 2>/dev/null'"

expect R-GW-2e "/tmp is writable (tmpfs)"
assert_ok "xsh '$GATEWAY_SVC' 'touch /tmp/clawtilla-rwtest && rm -f /tmp/clawtilla-rwtest'"

expect R-GW-2f "named state volume /opt/clawpatrol is writable under the RO rootfs"
assert_ok "xsh '$GATEWAY_SVC' 'touch /opt/clawpatrol/.clawtilla-rwtest && rm -f /opt/clawpatrol/.clawtilla-rwtest'"

expect R-GW-3e "state_dir /opt/clawpatrol is mode 0700 (drwx------)"
assert_eq "$(xsh "$GATEWAY_SVC" 'stat -c %a /opt/clawpatrol' 2>/dev/null)" "700"

expect R-GW-4e "clawpatrol.db is mode 0600 (-rw-------)"
dbmode="$(xsh "$GATEWAY_SVC" 'stat -c %a /opt/clawpatrol/clawpatrol.db 2>/dev/null' 2>/dev/null)"
if [ -z "$dbmode" ]; then skip "clawpatrol.db not present yet"; else assert_eq "$dbmode" "600"; fi

expect R-GW-3f "no group/other-accessible dirs under state_dir (CA material included)"
# Catches a loosely-permissioned subdir the two checks above would miss (e.g. the
# CA dir, whose name varies by version): any dir with group/other perm bits set.
loose="$(xsh "$GATEWAY_SVC" 'find /opt/clawpatrol -maxdepth 2 -type d -perm /077 2>/dev/null' 2>/dev/null | tr -d '\r')"
if [ -z "$loose" ]; then pass "no group/other-accessible dirs under state_dir"; else fail "loosely-permissioned dir(s): $loose"; fi

section "gateway — boot warnings & egress"

expect R-GW-5 "no 'state loosely permissioned' warning at boot"
assert_not_match "$(dc logs --no-color "$GATEWAY_SVC" 2>/dev/null)" 'loosely permissioned|readable beyond owner'

expect R-GW-8 "gateway has working internet egress"
if retry "xsh '$GATEWAY_SVC' 'curl -fsS -o /dev/null --max-time $CURL_MAX_TIME https://$RELAY_HOST/'"; then pass; else fail "gateway egress failed after $RETRY_ATTEMPTS attempts"; fi

finish
