#!/usr/bin/env bash
# Runtime: the load-bearing containment test. The cage (clawcage-net internal:true)
# — NOT the gateway — is what confines the fleet. Verified two ways:
#   (a) an ephemeral container on clawcage-net with NO tunnel has zero egress
#       (this is the "tunnel down" / AC2-down case, isolated from the live ClawBot)
#   (b) the live ClawBot cannot reach the Mac host (AC3)
# Plus: WG UDP not published; dashboard published on loopback only.
# Also exercises the review's KNOWN GAPS as XFAIL (do not fail the run):
#   F1 — promiscuous relay reaching host/RFC1918/metadata (SSRF surface)
#   F2 — DNS resolution that bypasses the gateway (exfil/C2 side channel)
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"

require_tools docker
svc_running "$GATEWAY_SVC" || die "gateway not running — run runtime/00_bringup.sh first"

TBOTS_NET="$(net_name clawcage-net)"
IMG="$(svc_image "$TBOT_SVC" 2>/dev/null)"
[ -n "$IMG" ] || IMG="$(dc images -q "$TBOT_SVC" 2>/dev/null)"
[ -n "$IMG" ] || die "could not resolve the client image (build first)"
note "probe image: $IMG   network: $TBOTS_NET"

# Run a probe command in a throwaway container on the cage net (no tunnel).
probe() { docker run --rm --network "$TBOTS_NET" --entrypoint sh "$IMG" -c "$*" 2>/dev/null; }

section "the cage — no NAT, no escape (tunnel-down equivalent)"

expect R-NET-5 "a container on clawcage-net with NO tunnel CANNOT reach the internet"
# direct (non-tunneled) egress must fail: internal net has no NAT/gateway.
assert_fail "probe 'curl -fsS --max-time 6 -o /dev/null https://$RELAY_HOST/'"

expect R-NET-5b "...but it CAN reach the gateway alias on :8080 (required for join/CA)"
if retry "probe 'curl -fsS --max-time $CURL_MAX_TIME -o /dev/null http://gateway:8080/info'"; then pass; else fail "cannot reach gateway:8080 from the cage after $RETRY_ATTEMPTS attempts"; fi

expect R-NET-5c "...and cannot reach the WireGuard UDP port as TCP / any other host"
assert_fail "probe 'curl -fsS --max-time 6 -o /dev/null https://1.1.1.1/'"

section "client -/-> host (AC3)"

expect R-NET-6a "host.docker.internal does not resolve from the TBot"
# getent/nslookup should fail to resolve on an internal network.
if xsh "$TBOT_SVC" 'getent hosts host.docker.internal' >/dev/null 2>&1; then
  # it may still resolve via baked DNS; the real test is reachability below.
  skip "name resolves; checking reachability instead"
else
  pass
fi

expect R-NET-6b "the Mac host is unreachable from the TBot"
assert_fail "xsh '$TBOT_SVC' 'curl -fsS --max-time 6 -o /dev/null http://host.docker.internal/'"

section "port exposure (live)"

expect R-NET-7r "WireGuard 51820/udp is NOT published to the host"
assert_empty "$(dc port "$GATEWAY_SVC" 51820/udp 2>/dev/null)"

expect R-NET-8c "dashboard is published on 127.0.0.1 only"
assert_match "$(dc port "$GATEWAY_SVC" 8080 2>/dev/null)" '^127\.0\.0\.1:'

section "client — no IPv6 egress leak (L3)"

expect R-NET-v6 "cage has no IPv6 egress path (no v6 default route, or it is via the tunnel)"
if svc_running "$TBOT_SVC"; then
  v6def="$(xsh "$TBOT_SVC" 'ip -6 route show default 2>/dev/null' 2>/dev/null | tr -d '\r')"
  if [ -z "$v6def" ]; then
    pass "no IPv6 default route (no v6 egress path)"
  elif printf '%s' "$v6def" | grep -q 'clawpatrol'; then
    pass "IPv6 default route is via the tunnel (policed like v4)"
  else
    fail "IPv6 default route bypasses the tunnel: $v6def"
  fi
else
  skip "TBot not running"
fi

# ---------------------------------------------------------------------------
# KNOWN GAPS — asserted as the DESIRED invariant. They are expected to NOT hold
# on the current build, so they record XFAIL (reported, but they do not fail the
# run). If a probe is inconclusive in this environment we SKIP rather than PASS,
# to avoid false reassurance. Flip to PASS the moment the gap closes.
# NOTE: F-numbers here reference docs/review.md (F1 = promiscuous relay / SSRF,
# F2 = DNS bypass), NOT this suite's older finding scheme in the README.
# ---------------------------------------------------------------------------
section "KNOWN GAP (review.md F2) — DNS resolution that bypasses the gateway"

# An internal cage container with NO tunnel still reaches Docker's embedded
# resolver (127.0.0.11), which forwards to the daemon's upstream on the host.
# So arbitrary names resolve even though packets can't egress — a metadata /
# C2 side channel the gateway never sees. DESIRED: the cage cannot resolve
# arbitrary external names off-tunnel.
expect R-GAP-DNS "cage with NO tunnel should NOT resolve arbitrary external names (review.md F2: DNS gated by gateway)"
dns_out="$(probe "getent hosts $DNS_PROBE_NAME 2>/dev/null || nslookup $DNS_PROBE_NAME 2>/dev/null")"
if printf '%s' "$dns_out" | grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}'; then
  xfail "resolved '$DNS_PROBE_NAME' off-tunnel via 127.0.0.11 (DNS egress bypasses the gateway)"
else
  pass "no off-tunnel resolution"
fi

section "KNOWN GAP (review.md F1) — promiscuous relay reaching host / RFC1918 / metadata"

# The live ClawBot (tunnel up) sends non-policy traffic through the gateway's
# WireGuard relay, which dials dstIP:dstPort with no destination filtering
# (oss main.go wgRelay). So link-local / RFC1918 / the cloud-metadata IP that
# the GATEWAY can route to become reachable from the cage. DESIRED: such
# destinations are refused. Reachability is environment-dependent, so:
#   reachable      -> XFAIL (gap confirmed)
#   not reachable  -> SKIP  (inconclusive: target may be unroutable from the gateway here)
if svc_running "$TBOT_SVC"; then
  expect R-GAP-SSRF-META "relay should REFUSE the cloud-metadata IP ($METADATA_IP) from the cage (review.md F1)"
  if tbot_body "$TBOT_SVC" --max-time 6 "http://$METADATA_IP/" >/dev/null 2>&1; then
    xfail "relay forwarded to $METADATA_IP (SSRF to instance metadata)"
  else
    skip "metadata IP not reachable/listening from the gateway in this env (inconclusive)"
  fi

  # The gateway's egress-side bridge gateway IP is a host-adjacent RFC1918
  # address the cage must never target; discover it from the gateway container.
  egw="$(inspect "$GATEWAY_SVC" '{{range $k,$v := .NetworkSettings.Networks}}{{if eq $k "clawegress-net"}}{{$v.Gateway}}{{end}}{{end}}' 2>/dev/null)"
  expect R-GAP-SSRF-RFC1918 "relay should REFUSE the gateway's egress bridge gateway (RFC1918) from the cage (review.md F1)"
  if [ -z "$egw" ]; then
    skip "could not resolve clawegress-net gateway IP"
  elif tbot_body "$TBOT_SVC" --max-time 6 "http://$egw/" >/dev/null 2>&1; then
    xfail "relay forwarded to host-side RFC1918 $egw (SSRF to host/docker bridge)"
  else
    skip "no service listening at $egw:80 to confirm (relay-vs-refuse indistinguishable here)"
  fi
else
  expect R-GAP-SSRF-META "relay host/metadata reach (live ClawBot)"; skip "ClawBot not running"
fi

finish
