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
ARG CLAWPATROL_VERSION=v0.5.1
ARG CLAWPATROL_SHA256_amd64=75c2a181811ca5d0f7ef4854700a10a8d353e27449d8cf6ec9cf804bff6bef2a
ARG CLAWPATROL_SHA256_arm64=d0b7ff699f61a35a1c4b20fa399c99a2c868030f186d594bf386455dd24738b5
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
