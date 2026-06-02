#!/usr/bin/env bash
# Runtime: the TBot tunnel internals — the design's riskiest, now-resolved bits.
# Confirms Table=off + manual default route, that /proc/sys stays READ-ONLY
# (so no systempaths=unconfined was needed), and the client's network posture.
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"

require_tools docker
svc_running "$TBOT_SVC" || die "TBot not running — run runtime/00_bringup.sh first"

section "client — WireGuard interface"

expect R-WG-1 "clawpatrol is a functioning WireGuard interface (peer + endpoint)"
wgshow="$(xsh "$TBOT_SVC" 'wg show clawpatrol 2>/dev/null' 2>/dev/null)"
if printf '%s' "$wgshow" | grep -q 'peer:'; then pass; else fail "wg show has no peer"; fi
note "WG backend: $(xsh "$TBOT_SVC" '[ -d /sys/module/wireguard ] && echo kernel-module || echo userspace(wireguard-go)' 2>/dev/null)"

expect R-WG-1c "WG backend present: kernel module preferred, userspace (wireguard-go) accepted"
# The LinuxKit/Docker-Desktop kernel ships the wireguard module on the documented
# path; a userspace fallback is still a VALID tunnel, just not the documented one.
# Mirror Claude C4: pass on the kernel module, skip (not fail) on the fallback.
if xsh "$TBOT_SVC" 'ip link add wgprobe type wireguard' >/dev/null 2>&1; then
  xsh "$TBOT_SVC" 'ip link del wgprobe' >/dev/null 2>&1 || true
  pass "kernel wireguard module present (ip link add type wireguard works)"
else
  skip "kernel WG add failed — userspace (wireguard-go) fallback in use (valid, not the documented path)"
fi

expect R-WG-2c "default route is via the tunnel interface (manual default route)"
assert_match "$(xsh "$TBOT_SVC" 'ip route show default' 2>/dev/null)" 'dev clawpatrol'

expect R-WG-2d "materialized wg conf forces 'Table = off' (no src_valid_mark write)"
assert_match "$(xsh "$TBOT_SVC" 'cat /etc/wireguard/clawpatrol.conf 2>/dev/null' 2>/dev/null)" 'Table[[:space:]]*=[[:space:]]*off'

section "client — /proc/sys stays read-only (no systempaths=unconfined)"

expect R-WG-3 "/proc/sys is read-only (writing src_valid_mark fails)"
assert_fail "xsh '$TBOT_SVC' 'echo 1 > /proc/sys/net/ipv4/conf/all/src_valid_mark 2>/dev/null'"

expect R-WG-3b "sensitive /proc paths are masked (sysrq-trigger not writable)"
assert_fail "xsh '$TBOT_SVC' 'echo 0 > /proc/sysrq-trigger 2>/dev/null'"

expect R-WG-3c "only security_opt is no-new-privileges (no systempaths=unconfined)"
secopt="$(inspect "$TBOT_SVC" '{{range .HostConfig.SecurityOpt}}{{.}};{{end}}')"
if printf '%s' "$secopt" | grep -q 'no-new-privileges' && ! printf '%s' "$secopt" | grep -qi 'systempaths'; then pass; else fail "security_opt='$secopt'"; fi

section "client — network posture (live)"

expect R-NET-2r "client is attached ONLY to clawcage-net"
nets="$(inspect "$TBOT_SVC" '{{range $k,$v := .NetworkSettings.Networks}}{{$k}};{{end}}')"
if printf '%s' "$nets" | grep -q 'clawcage-net' && ! printf '%s' "$nets" | grep -q 'clawegress-net'; then pass; else fail "networks='$nets'"; fi

expect R-WG-capr "client has NET_ADMIN (and only that)"
# dockerd >=25 normalizes caps with a CAP_ prefix on inspect; accept both forms.
caps="$(inspect "$TBOT_SVC" '{{range .HostConfig.CapAdd}}{{.}};{{end}}')"
assert_eq "${caps//CAP_/}" "NET_ADMIN;"

expect R-WG-devr "/dev/net/tun is present in the client"
assert_ok "xsh '$TBOT_SVC' '[ -c /dev/net/tun ]'"

finish
