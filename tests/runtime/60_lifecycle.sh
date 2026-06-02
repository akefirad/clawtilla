#!/usr/bin/env bash
# Runtime: decoupled lifecycle (AC6) + restart survival (AC7) + PID 1 = tini.
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"

require_tools docker
svc_running "$TBOT_SVC" || die "TBot not running — run runtime/00_bringup.sh first"

container_running() { [ "$(inspect "$TBOT_SVC" '{{.State.Running}}')" = "true" ]; }
wg_pubkey()        { xsh "$TBOT_SVC" 'wg show clawpatrol public-key 2>/dev/null'; }
egress_ok()        { xrun "$TBOT_SVC" curl -fsS -o /dev/null --max-time 20 "$ALLOWED_MITM_GET_URL"; }

section "lifecycle — PID 1 is the init shim (tini)"

expect R-LIFE-3r "PID 1 is tini/docker-init (signals + zombie reaping)"
assert_match "$(xsh "$TBOT_SVC" 'cat /proc/1/comm' 2>/dev/null)" 'tini|docker-init|init'

section "AC6 — agent restart is decoupled from the container/tunnel"

pk_before="$(wg_pubkey)"
note "starting a throwaway agent (run sleep 300) and killing it ..."
dc exec -dT "$TBOT_SVC" run sleep 300 >/dev/null 2>&1 || true
sleep 2
apid="$(xsh "$TBOT_SVC" "pgrep -f 'sleep 300' | head -1" 2>/dev/null)"
if [ -n "$apid" ]; then xsh "$TBOT_SVC" "kill $apid" >/dev/null 2>&1 || true; fi
sleep 2

expect R-LIFE-1 "killing the exec'd agent leaves the container Up"
if container_running; then pass; else fail "container is not Running after agent kill"; fi

expect R-LIFE-1b "...and the tunnel stays established (same WG identity, egress works)"
if [ "$(wg_pubkey)" = "$pk_before" ] && retry "egress_ok"; then pass; else fail "tunnel flapped or WG key changed after agent kill"; fi

section "AC7 — container restart re-ups the tunnel from persisted conf (no re-join)"

hash_before="$(xsh "$TBOT_SVC" 'sha256sum /root/.config/clawpatrol/wg.conf 2>/dev/null | cut -d" " -f1' 2>/dev/null)"
# Unix epoch for `docker logs --since`: a timezone-less RFC3339 stamp is parsed
# in the *daemon's* local time, which (on a non-UTC host) reaches back before the
# restart and re-captures the original bring-up enrollment line — a false R-LIFE-2b.
restart_ts="$(date +%s)"
note "restarting $TBOT_SVC ..."
dc restart "$TBOT_SVC" >/dev/null 2>&1 || die "restart failed"

expect R-LIFE-2a "tunnel comes back up after restart"
if wait_for 40 "xsh '$TBOT_SVC' 'ip link show clawpatrol' >/dev/null 2>&1 && egress_ok"; then pass; else fail "tunnel did not recover within 40s"; fi

expect R-LIFE-2b "NO re-enrollment occurred (entrypoint skipped 'clawpatrol join')"
post_logs="$(dc logs --since "$restart_ts" --no-color "$TBOT_SVC" 2>/dev/null)"
assert_not_contains "$post_logs" 'enrolling (plain join'

expect R-LIFE-2c "persisted wg.conf is unchanged (same identity, no re-mint)"
hash_after="$(xsh "$TBOT_SVC" 'sha256sum /root/.config/clawpatrol/wg.conf 2>/dev/null | cut -d" " -f1' 2>/dev/null)"
if [ -n "$hash_before" ]; then assert_eq "$hash_after" "$hash_before"; else skip "could not hash wg.conf"; fi

expect R-LIFE-5r "WG identity (public key) survives the restart"
assert_eq "$(wg_pubkey)" "$pk_before"

expect R-LIFE-2d "derived /etc/wireguard conf is regenerated from the persisted conf (Table = off)"
# The persisted wg.conf (named volume) is the source of truth; the entrypoint
# re-derives the ephemeral /etc/wireguard/clawpatrol.conf on every boot. Prove it
# exists AND still forces Table = off after the restart (not just at bring-up).
derived="$(xsh "$TBOT_SVC" 'cat /etc/wireguard/clawpatrol.conf 2>/dev/null' 2>/dev/null)"
if [ -n "$derived" ]; then assert_match "$derived" 'Table[[:space:]]*=[[:space:]]*off'; else fail "derived /etc/wireguard/clawpatrol.conf missing after restart"; fi

finish
