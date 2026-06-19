#!/usr/bin/env bash
# Static checks on stack/Dockerfile (pure text parse — no build required).
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"

DF="$STACK_DIR/Dockerfile"
[ -f "$DF" ] || die "Dockerfile not found at $DF"
SRC="$(cat "$DF")"

section "Dockerfile — multi-stage layout"

expect R-IMG-4 "single Dockerfile defines base/gateway/client stages"
if printf '%s' "$SRC" | grep -Eq '^FROM .* AS base' \
   && printf '%s' "$SRC" | grep -Eq '^FROM base AS gateway' \
   && printf '%s' "$SRC" | grep -Eq '^FROM base AS client'; then pass; else fail "missing base/gateway/client stages"; fi

section "Dockerfile — supply-chain pinning"

expect R-IMG-1 "clawpatrol is pinned to an explicit version"
ver="$(printf '%s' "$SRC" | grep -E 'ARG CLAWPATROL_VERSION=' | head -1 | sed 's/.*=//')"
assert_match "$ver" '^v[0-9]+\.[0-9]+\.[0-9]+'

expect R-IMG-1b "per-arch SHA256 pins are present (amd64 + arm64)"
if printf '%s' "$SRC" | grep -Eq 'CLAWPATROL_SHA256_amd64=[0-9a-f]{64}' \
   && printf '%s' "$SRC" | grep -Eq 'CLAWPATROL_SHA256_arm64=[0-9a-f]{64}'; then pass; else fail "missing 64-hex SHA pins"; fi

expect R-IMG-1c "downloaded binary is verified with sha256sum -c"
assert_match "$SRC" 'sha256sum -c'

expect R-IMG-1d "binary is fetched from the pinned version URL, not install.sh"
if printf '%s' "$SRC" | grep -q 'releases/download/${CLAWPATROL_VERSION}' \
   && ! printf '%s' "$SRC" | grep -q 'install.sh'; then pass; else fail "uses install.sh or unpinned URL"; fi

section "Dockerfile — client stage"

expect R-IMG-3 "client stage has NO USER line (must start as root for tunnel bring-up)"
# Inspect only the client stage (from 'FROM base AS client' to EOF).
client_stage="$(printf '%s' "$SRC" | awk '/^FROM base AS client/{f=1} f')"
assert_not_match "$client_stage" '^[[:space:]]*USER[[:space:]]'

expect R-ENV-wrapper "client bakes a /usr/local/bin/run wrapper that evals clawpatrol env"
if printf '%s' "$client_stage" | grep -q '/usr/local/bin/run' \
   && printf '%s' "$client_stage" | grep -q 'clawpatrol env'; then pass; else fail "run wrapper / eval missing"; fi

# The run wrapper must widen CA trust from clawpatrol's gateway-only bundle to the
# system store (gateway CA + public roots) so tools reach RELAYED hosts (real
# certs) — gated by CLAWTILLA_TRUST_PUBLIC_CAS, settable at build (ARG) and runtime.
expect R-ENV-catrust "run wrapper widens CA trust to the system store, toggled by CLAWTILLA_TRUST_PUBLIC_CAS (build-arg + runtime)"
if printf '%s' "$client_stage" | grep -q 'ca-certificates.crt' \
   && printf '%s' "$client_stage" | grep -q 'SSL_CERT_FILE=' \
   && printf '%s' "$client_stage" | grep -Eq 'ARG[[:space:]]+CLAWTILLA_TRUST_PUBLIC_CAS' \
   && printf '%s' "$client_stage" | grep -q 'CLAWTILLA_TRUST_PUBLIC_CAS:-1'; then pass; else fail "wrapper does not widen CA / missing build-arg + runtime toggle"; fi

expect R-WG-tools "client installs wireguard-tools + userspace fallback + diag tools"
missing_pkg=
for pkg in wireguard-tools wireguard-go iproute2 dnsutils procps; do
  printf '%s' "$client_stage" | grep -q "$pkg" || missing_pkg="$missing_pkg $pkg"
done
if [ -z "$missing_pkg" ]; then pass; else fail "missing packages:$missing_pkg"; fi

section "Dockerfile — gateway stage"

gw_stage="$(printf '%s' "$SRC" | awk '/^FROM base AS gateway/{f=1} /^FROM base AS client/{f=0} f')"

expect R-GW-10 "gateway.hcl is COPYed (baked) into the image, not bind-mounted"
assert_match "$gw_stage" 'COPY gateway.hcl'

expect R-GW-entry "gateway entrypoint is the gateway.sh wrapper"
assert_match "$gw_stage" 'COPY gateway.sh'

finish
