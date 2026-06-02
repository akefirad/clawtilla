#!/usr/bin/env bash
# Static checks on stack/compose.yaml (no running stack required).
# Parses the resolved config via `docker compose config --format json`.
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"

require_tools docker jq

section "compose.yaml — network / isolation topology"

# Parse the stack with CLAWTILLA_DASH_PORT unset so the port assertions
# verify the deployable DEFAULT (127.0.0.1:5182), independent of any random-port
# value the runtime phase may export into the environment.
CFG="$(unset CLAWTILLA_DASH_PORT; dc config --format json 2>/dev/null)" || die "docker compose config failed (is COMPOSE_FILE valid?)"
j() { printf '%s' "$CFG" | jq -r "$1"; }

expect R-NET-1 "clawcage-net is internal: true (the load-bearing cage)"
assert_eq "$(j '.networks["clawcage-net"].internal')" "true"

expect R-NET-1b "clawegress-net is a normal (non-internal) bridge"
assert_eq "$(j '.networks["clawegress-net"].internal // false')" "false"

expect R-NET-2 "client ($TBOT_SVC) is attached ONLY to clawcage-net"
assert_eq "$(j ".services[\"$TBOT_SVC\"].networks | keys | sort | join(\",\")")" "clawcage-net"

expect R-NET-3 "gateway ($GATEWAY_SVC) is dual-homed (clawcage-net + clawegress-net)"
assert_eq "$(j ".services[\"$GATEWAY_SVC\"].networks | keys | sort | join(\",\")")" "clawcage-net,clawegress-net"

expect R-NET-4 "gateway has the 'gateway' alias on clawcage-net"
assert_contains "$(j ".services[\"$GATEWAY_SVC\"].networks[\"clawcage-net\"].aliases | join(\",\")")" "gateway"

section "compose.yaml — port exposure"

expect R-NET-8 "dashboard is published on 127.0.0.1 only (loopback)"
assert_eq "$(j ".services[\"$GATEWAY_SVC\"].ports[]? | select(.target==8080) | .host_ip")" "127.0.0.1"

expect R-NET-8b "dashboard host port is $DASH_HOST_PORT -> container 8080"
assert_eq "$(j ".services[\"$GATEWAY_SVC\"].ports[]? | select(.target==8080) | .published|tostring")" "$DASH_HOST_PORT"

expect R-NET-7 "WireGuard 51820/udp is NOT published to the host"
assert_empty "$(j ".services[\"$GATEWAY_SVC\"].ports[]? | select(.target==51820) | .published")"

section "compose.yaml — gateway hardening (no host reach, no caps)"

expect R-GW-6 "gateway has NO host bind mounts (AC5 / review I2)"
assert_empty "$(j ".services[\"$GATEWAY_SVC\"].volumes[]? | select(.type==\"bind\") | .source")"

expect R-GW-6b "gateway state is a named volume mounted at /opt/clawpatrol"
assert_eq "$(j ".services[\"$GATEWAY_SVC\"].volumes[]? | select(.target==\"/opt/clawpatrol\") | .type")" "volume"

expect R-GW-7 "gateway has no host.docker.internal / host-gateway extra_hosts"
assert_empty "$(j ".services[\"$GATEWAY_SVC\"].extra_hosts // [] | join(\",\")")"

expect R-GW-1 "gateway rootfs is read_only"
assert_eq "$(j ".services[\"$GATEWAY_SVC\"].read_only")" "true"

expect R-GW-2 "gateway has tmpfs /tmp (only writable rootfs path)"
assert_contains "$(j ".services[\"$GATEWAY_SVC\"].tmpfs // [] | join(\",\")")" "/tmp"

expect R-GW-9 "gateway has no-new-privileges"
assert_contains "$(j ".services[\"$GATEWAY_SVC\"].security_opt // [] | join(\",\")")" "no-new-privileges"

expect R-GW-9b "gateway adds NO extra capabilities (userspace WG needs none)"
assert_empty "$(j ".services[\"$GATEWAY_SVC\"].cap_add // [] | join(\",\")")"

expect R-GW-9d "gateway exposes NO devices (no /dev/net/tun — userspace WG needs none)"
assert_eq "$(j ".services[\"$GATEWAY_SVC\"].devices // [] | length")" "0"

section "compose.yaml — client (TBot) caps & isolation"

expect R-WG-cap "client adds exactly NET_ADMIN"
assert_eq "$(j ".services[\"$TBOT_SVC\"].cap_add | sort | join(\",\")")" "NET_ADMIN"

expect R-WG-dev "client gets /dev/net/tun"
assert_contains "$(j ".services[\"$TBOT_SVC\"].devices")" "/dev/net/tun"

expect R-CAGE-secopt "client has no-new-privileges and no systempaths=unconfined"
secopt="$(j ".services[\"$TBOT_SVC\"].security_opt // [] | join(\",\")")"
if printf '%s' "$secopt" | grep -q 'no-new-privileges' && ! printf '%s' "$secopt" | grep -q 'systempaths'; then pass; else fail "security_opt='$secopt'"; fi

expect R-LIFE-3 "client runs with init: true (tini as PID 1)"
assert_eq "$(j ".services[\"$TBOT_SVC\"].init")" "true"

expect R-LIFE-5 "client has a per-agent named volume at /root (state persistence)"
assert_eq "$(j ".services[\"$TBOT_SVC\"].volumes[]? | select(.target==\"/root\") | .type")" "volume"

expect R-NET-2b "client adds no extra_hosts (no host-gateway backdoor)"
assert_empty "$(j ".services[\"$TBOT_SVC\"].extra_hosts // [] | join(\",\")")"

section "compose.yaml — hygiene"

expect L1 "env-var secret in compose is a placeholder, not a real credential"
sv="$(j ".services[\"$GATEWAY_SVC\"].environment.CLAWPATROL_SECRET_ECHO_DUMMY // empty")"
if [ -z "$sv" ] || [ "$sv" = "$SECRET_PLAINTEXT" ]; then pass "test-only dummy"; else fail "unexpected secret value '$sv' — is this a real credential?"; fi

expect L1b "no other (non-dummy) CLAWPATROL_SECRET_* is committed in compose.yaml"
# Guards against a real secret being added alongside the known dummy: scan the
# committed file for any CLAWPATROL_SECRET_* line that isn't the echo dummy or a comment.
othersec="$(grep -E 'CLAWPATROL_SECRET_' "$COMPOSE_FILE" 2>/dev/null | grep -vi 'echo_dummy' | grep -v '^[[:space:]]*#' || true)"
assert_empty "$othersec"

finish
