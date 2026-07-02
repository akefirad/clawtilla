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

section "Dockerfile — clawpatrol built from source (not downloaded)"

expect R-IMG-1 "clawpatrol is compiled via make, not fetched as a prebuilt binary"
if printf '%s' "$SRC" | grep -Eq 'make "\$CLAWPATROL_MAKE_TARGET"' \
   && ! printf '%s' "$SRC" | grep -q 'releases/download' \
   && ! printf '%s' "$SRC" | grep -q 'install.sh'; then pass; else fail "not a source build (download/install.sh present or make target missing)"; fi

expect R-IMG-1b "dual source modes: src-local (default) + src-remote"
if printf '%s' "$SRC" | grep -Eq '^FROM builder-base AS src-local' \
   && printf '%s' "$SRC" | grep -Eq '^FROM builder-base AS src-remote' \
   && printf '%s' "$SRC" | grep -Eq '^ARG CLAWPATROL_SRC=src-local' \
   && printf '%s' "$SRC" | grep -Eq '^FROM \$\{CLAWPATROL_SRC\} AS builder'; then pass; else fail "src-local/src-remote select pattern missing"; fi

expect R-IMG-1c "remote mode is pinnable via CLAWPATROL_REPO + CLAWPATROL_REF"
if printf '%s' "$SRC" | grep -Eq 'ARG CLAWPATROL_REPO=' \
   && printf '%s' "$SRC" | grep -Eq 'ARG CLAWPATROL_REF='; then pass; else fail "missing CLAWPATROL_REPO/CLAWPATROL_REF args"; fi

expect R-IMG-1d "build flavor is selectable (CLAWPATROL_MAKE_TARGET, default unstripped 'build')"
if printf '%s' "$SRC" | grep -Eq 'ARG CLAWPATROL_MAKE_TARGET=build'; then pass; else fail "CLAWPATROL_MAKE_TARGET arg missing or not defaulting to build"; fi

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
