# syntax=docker/dockerfile:1.7

# Selects which source stage feeds `builder` (src-remote | src-local). Declared
# here (before any FROM) because a FROM can only interpolate a *global* ARG.
ARG CLAWPATROL_SRC=src-remote

# ---- builder: compile clawpatrol from source (Go + Deno) -----------------
# clawpatrol is BUILT here, not downloaded.
# Two source modes feed the `builder` stage, selected by CLAWPATROL_SRC:
#   src-remote (default) — git clone CLAWPATROL_REPO @ CLAWPATROL_REF (a pinned
#                          upstream release). Reproducible and self-contained;
#                          this is what a template consumer / CI / release uses.
#   src-local            — build a vendored ./clawpatrol working tree AS-IS
#                          (opt-in: set CLAWPATROL_SRC=src-local and drop a
#                          clawpatrol/ checkout in the build context). Gives an
#                          edit→rebuild loop with no push/ref bump; this is how
#                          a deployment that hacks on its own fork builds (see
#                          the private/clawtilla deployment).
# Toolchain digest-pinned (like the ubuntu runtime base below) so the binary
# that enforces policy has reproducible provenance. Bump deliberately.
FROM golang:1.26-bookworm@sha256:b305420a68d0f229d91eb3b3ed9e519fcf2cf5461da4bef997bf927e8c0bfd2b AS builder-base
# Deno bundles the dashboard (make dashboard -> //go:embed) before `go build`.
# Digest-pinned too — it is embedded into the gateway binary via //go:embed,
# so it is part of the artifact's provenance. (Tracks CI's deno v2.x line.)
COPY --from=denoland/deno:bin@sha256:978d3d9d73452234f830739773a0a1a7e3b60463da3dfbcd99375e86ac5481e5 /deno /usr/local/bin/deno

# -- source mode A: remote clone (default; template / CI / release)
FROM builder-base AS src-remote
# Defaults to canonical upstream at a pinned release tag, so a bare build is
# reproducible and resolves out of the box. Override REPO+REF to build a fork
# (enforced pinned — not a floating branch — by tests/static/50).
ARG CLAWPATROL_REPO=https://github.com/denoland/clawpatrol
ARG CLAWPATROL_REF=v0.5.3
RUN git clone "$CLAWPATROL_REPO" /src \
    && git -C /src checkout --detach "$CLAWPATROL_REF"

# -- source mode B: local vendored working tree (opt-in; deployment dev loop)
# No clawpatrol/ is vendored in this template — a consumer that wants src-local
# drops its own checkout here (the private/clawtilla deployment vendors its fork
# as a submodule). Kept out of the default path so a bare build never needs it.
FROM builder-base AS src-local
COPY clawpatrol /src

# Buildx resolves the global ${CLAWPATROL_SRC} to one of the source stages above.
FROM ${CLAWPATROL_SRC} AS builder
# build   = unstripped, keeps file:line in panics (best while hacking the gateway)
# release = stripped (-s -w -trimpath) for lean packaging
ARG CLAWPATROL_MAKE_TARGET=build
ENV DENO_DIR=/deno-dir
WORKDIR /src
# Single build platform: the Go/Deno toolchain runs natively. A multi-arch
# `buildx --platform linux/amd64,linux/arm64` build has no BUILDPLATFORM +
# GOARCH cross-compile wiring here, so each arch would build under QEMU
# (correct, just slow). No multi-arch CI today; add cross-compile if that changes.
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/deno-dir \
    make "$CLAWPATROL_MAKE_TARGET"

# ---- base: OS + clawpatrol built above -----------------------------------
FROM ubuntu:noble-20260509.1@sha256:786a8b558f7be160c6c8c4a54f9a57274f3b4fb1491cf65146521ae77ff1dc54 AS base

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/clawpatrol /usr/local/bin/clawpatrol
RUN chmod 0755 /usr/local/bin/clawpatrol

# ---- gateway -------------------------------------------------------------
FROM base AS gateway

COPY gateway.hcl /config/gateway.hcl
# Wrapper tightens the 0755 named-volume mountpoint to 0700 before launch
# (clawpatrol's MkdirAll(0700) no-ops on the pre-existing mount). See gateway.sh.
COPY gateway.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 8080 = dashboard + onboard/CA mux (clients reach over clawcage-net).
# 51820/udp = WireGuard endpoint (reached only over clawcage-net, not published).
EXPOSE 8080 51820/udp

# Gateway runs userspace WireGuard (wireguard-go + gVisor netstack) inside
# the binary itself -> no NET_ADMIN, no /dev/net/tun, no caps needed.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["gateway", "/config/gateway.hcl"]

# ---- client --------------------------------------------------------------
FROM base AS client
# Extra tooling beyond the base (ca-certificates + curl already present):
#   iproute2 iptables         - wg-quick's ip rule / routing dance
#   procps iputils-ping       - ps/kill/ping for the acceptance checks
#   dnsutils                  - host/dig/nslookup for the host-isolation check
#   wireguard-tools           - provides wg-quick + wg
#   wireguard-go              - USERSPACE WireGuard impl, used by wg-quick when the
#                               LinuxKit kernel exposes no `wireguard` module.
#                               Selected via WG_QUICK_USERSPACE_IMPLEMENTATION
#                               (set in compose.yaml). clawpatrol's wgQuickUp shells
#                               out to `wg-quick up` and does NOT set this itself.
RUN apt-get update && apt-get install -y --no-install-recommends \
      iproute2 iptables procps iputils-ping dnsutils \
      wireguard-tools wireguard-go \
      git unzip curl wget xz-utils

# Persistence home is /root (mounted from the named volume in compose).
# Set HOME explicitly so home-targeted provisioning lands in /root regardless of
# base/USER changes. (Docker defaults HOME=/root for root, but don't rely on it.)
ENV HOME=/root

# There `clawpatrol join` writes ~/.config/clawpatrol/wg.conf + ~/.clawpatrol/ca.crt.
# Plain join does NOT wire `clawpatrol env` into the shell rc (whole-machine only) —
# the `run` wrapper supplies that env; client.sh installs the CA into the system store.

COPY client.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# CA trust for relayed hosts (used by the run wrapper below): 1 = widen to gateway
# CA + public roots (default), 0 = strict gateway-only. Build default here;
# compose `environment:` / `exec -e` override it at runtime.
ARG CLAWTILLA_TRUST_PUBLIC_CAS=1
ENV CLAWTILLA_TRUST_PUBLIC_CAS=${CLAWTILLA_TRUST_PUBLIC_CAS}

# Agent launch wrapper. Plain `clawpatrol join` (not --whole-machine) never
# installs the shell rc, so an exec'd agent gets NO placeholder-token vars and
# NO Node/Python CA-bundle vars (NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE, …).
# `eval "$(clawpatrol env)"` pulls both (CA vars from local config, tokens from
# the gateway). Launch the agent with: `docker compose exec -it clawbot-418 run <agent>`.
RUN printf '%s\n' \
      '#!/bin/sh' \
      'set -eu' \
      'eval "$(clawpatrol env)"' \
      '# clawpatrol env trusts only the gateway CA; widen to the system store (gateway' \
      '# CA + public roots) so tools reach relayed hosts, unless CLAWTILLA_TRUST_PUBLIC_CAS=0.' \
      'if [ "${CLAWTILLA_TRUST_PUBLIC_CAS:-1}" != "0" ]; then' \
      '  C=/etc/ssl/certs/ca-certificates.crt' \
      '  export SSL_CERT_FILE="$C" REQUESTS_CA_BUNDLE="$C" CURL_CA_BUNDLE="$C" GIT_SSL_CAINFO="$C" DENO_CERT="$C" PIP_CERT="$C" AWS_CA_BUNDLE="$C"' \
      'fi' \
      'exec "$@"' \
      > /usr/local/bin/run && chmod +x /usr/local/bin/run

# NO `USER` line - starts as root so the entrypoint can
# bring up the tunnel (join / wg-quick up need NET_ADMIN).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
