# syntax=docker/dockerfile:1.7

# Selects which source stage feeds `builder` (src-local | src-remote). Declared
# here (before any FROM) because a FROM can only interpolate a *global* ARG.
ARG CLAWPATROL_SRC=src-local

# ---- builder: compile clawpatrol from source (Go + Deno) -----------------
# clawpatrol is BUILT here, not downloaded.
# Two source modes feed the `builder` stage, selected by CLAWPATROL_SRC:
#   src-local  (default) — build the vendored stack/clawpatrol working tree
#                          AS-IS. Edit the submodule, rebuild, done — no commit,
#                          push, or ref bump. This is the dev inner loop.
#   src-remote           — git clone CLAWPATROL_REPO @ CLAWPATROL_REF. The
#                          template / CI / release path; override REPO to point
#                          at denoland/clawpatrol + a release tag.
FROM golang:1.26-bookworm AS builder-base
# Deno bundles the dashboard (make dashboard -> //go:embed) before `go build`.
# Pull just the deno binary from the official image (tracks CI's deno v2.x).
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno

# -- source mode A: local vendored working tree (dev default)
FROM builder-base AS src-local
COPY clawpatrol /src

# -- source mode B: remote clone (template / CI / release)
FROM builder-base AS src-remote
ARG CLAWPATROL_REPO=https://github.com/akefirad/clawpatrol
ARG CLAWPATROL_REF=main
RUN git clone "$CLAWPATROL_REPO" /src \
    && git -C /src checkout --detach "$CLAWPATROL_REF"

# Buildx resolves the global ${CLAWPATROL_SRC} to one of the source stages above.
FROM ${CLAWPATROL_SRC} AS builder
# build   = unstripped, keeps file:line in panics (best while hacking the gateway)
# release = stripped (-s -w -trimpath) for lean packaging
ARG CLAWPATROL_MAKE_TARGET=build
ENV DENO_DIR=/deno-dir
WORKDIR /src
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
