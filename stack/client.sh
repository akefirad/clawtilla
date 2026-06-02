#!/bin/sh
# ClawBot client entrypoint — enrollment-aware: join ONCE, bring-up ALWAYS.
# PID 1's only job is to enroll/bring up the tunnel and then stay alive; the
# agent is launched separately via `docker compose exec`. tini (init: true) is
# the real PID 1 and reaps the exec'd agent processes.
#
# We bring the tunnel up ourselves with `Table = off` rather than using
# `clawpatrol join --whole-machine` (which runs wg-quick with Table=auto and
# writes net.ipv4.conf.all.src_valid_mark — fatal on Docker's read-only
# /proc/sys, which previously forced systempaths=unconfined). The gateway is on
# the same L2 (clawcage-net), so wg-quick's fwmark/src_valid_mark routing trick is
# unnecessary: a manual default route sends egress through the tunnel while the
# handshake to the gateway uses the connected route (no loop, no sysctl write).
# Net effect: /proc/sys stays read-only — no systempaths=unconfined needed.
set -eu

CONF="/root/.config/clawpatrol/wg.conf"
IFACE="clawpatrol"

if [ ! -f "$CONF" ]; then
  # Plain join (NOT --whole-machine): enroll + persist the wg.conf, no bring-up.
  # Prints a user-code to approve at the dashboard and fetches the gateway CA to
  # /root/.clawpatrol/ca.crt. --no-trust: clawpatrol's own installCATrust shells
  # out to `sudo`, which refuses to run under no-new-privileges (and is redundant
  # when we're already root). We install the CA into the system store ourselves
  # below, so skip its doomed sudo attempt and the misleading log line.
  echo "[entrypoint] no persisted conf; enrolling (plain join, conf-only)"
  clawpatrol join --no-trust "${GATEWAY_URL:-http://gateway:8080}"
fi

# Install the gateway CA into the system trust store so OS-trust tools (git,
# wget, plain curl, Go binaries) succeed against MITM'd in-scope endpoints — not
# just the env-CA-bundle-aware tools the `run` wrapper covers. We're root on a
# writable rootfs, so no sudo. Idempotent: the source ca.crt persists on the
# /root volume, the system copy lives on the (non-persisted) rootfs, so reinstall
# whenever it's missing.
CA="/root/.clawpatrol/ca.crt"
DST="/usr/local/share/ca-certificates/clawpatrol.crt"
if [ -f "$CA" ] && [ ! -f "$DST" ]; then
  echo "[entrypoint] installing gateway CA into system trust store"
  cp "$CA" "$DST"
  update-ca-certificates
fi

# Materialize the kernel conf and force `Table = off` so wg-quick adds no routes
# and never touches net.ipv4.conf.all.src_valid_mark.
install -D -m600 "$CONF" "/etc/wireguard/${IFACE}.conf"
if grep -q '^[[:space:]]*Table' "/etc/wireguard/${IFACE}.conf"; then
  sed -i 's/^[[:space:]]*Table.*/Table = off/' "/etc/wireguard/${IFACE}.conf"
else
  sed -i '/\[Interface\]/a Table = off' "/etc/wireguard/${IFACE}.conf"
fi

wg-quick up "$IFACE"

# Send all egress through the tunnel. The handshake to the gateway endpoint sits
# on the connected clawcage-net subnet, so it keeps using the connected route — no
# loop, and no fwmark/src_valid_mark dance required.
ip route add default dev "$IFACE"
ip -6 route add default dev "$IFACE" 2>/dev/null || true

echo "[entrypoint] tunnel up (Table=off + manual default route); holding open"
exec sleep infinity
