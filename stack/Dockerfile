# syntax=docker/dockerfile:1.7

# ---- base: OS + pinned, SHA-verified clawpatrol --------------------------
# Keep oss/clawpatrol submodule and the deployed binary in lockstep:
# bumping CLAWPATROL_VERSION means moving the submodule to the matching
# tag AND updating the two SHA256s below (from that release's SHA256SUMS).

FROM ubuntu:jammy-20260509 AS base

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
ARG CLAWPATROL_VERSION=v0.2.4
ARG CLAWPATROL_SHA256_amd64=472cfea1587848b019b1e97dc80a554f275b4be7dba206825e6e1c0f78626be4
ARG CLAWPATROL_SHA256_arm64=20e933dca9251809f8ad934135a4c3612ff48c7e9b3b6f304d8902cf889f8753
RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
      amd64) sha="$CLAWPATROL_SHA256_amd64" ;; \
      arm64) sha="$CLAWPATROL_SHA256_arm64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/denoland/clawpatrol/releases/download/${CLAWPATROL_VERSION}/clawpatrol-linux-${arch}"; \
    curl -fsSL -o /usr/local/bin/clawpatrol "$url"; \
    echo "${sha}  /usr/local/bin/clawpatrol" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/clawpatrol

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
    && rm -rf /var/lib/apt/lists/*

# Persistence home is /root (mounted from the named volume in compose).
# join writes ~/.config/clawpatrol/wg.conf + ~/.clawpatrol/ca.crt there. Plain
# join does NOT wire `clawpatrol env` into the shell rc (whole-machine only) — the
# `run` wrapper supplies that env; client.sh installs the CA into the system store.

COPY client.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Agent launch wrapper. Plain `clawpatrol join` (not --whole-machine) never
# installs the shell rc, so an exec'd agent gets NO placeholder-token vars and
# NO Node/Python CA-bundle vars (NODE_EXTRA_CA_CERTS, REQUESTS_CA_BUNDLE, …).
# `eval "$(clawpatrol env)"` pulls both (CA vars from local config, tokens from
# the gateway). Launch the agent with: `docker compose exec -it clawbot-418 run <agent>`.
RUN printf '#!/bin/sh\nset -eu\neval "$(clawpatrol env)"\nexec "$@"\n' \
      > /usr/local/bin/run && chmod +x /usr/local/bin/run

# NO `USER` line - starts as root so the entrypoint can
# bring up the tunnel (join / wg-quick up need NET_ADMIN).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
