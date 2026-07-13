# raspberry — a Raspberry Pi reference deployment

The [`stack/`](../stack) deployment runs the Clawtilla gateway + ClawBots as
Docker Compose services on one host. This is the **bare-metal twin**: cloud-init
seeds for flashing a fleet of Raspberry Pis with `rpi-imager --cli` (Raspberry Pi
OS Lite, arm64), where the gateway runs on its own Pi in **Tailscale mode** and
each ClawBot is a dedicated Pi that `clawpatrol join`s and tunnels through it.

Like `stack/`, everything here is a **reference**, wired with placeholders and a
dummy in-scope endpoint (`postman-echo.com`). A real deployment **copies this
directory and diverges**: fill in your WiFi, SSH key, Tailscale keys, and the real
upstreams + credentials in `gateway.hcl`, and keep secrets in the untracked files
described under [Secrets](#secrets).

> ⚠️ **Status: early / MVP — NOT hardened.** This is an early, get-it-working draft
> and is **not** at the hardening bar of the [`stack/`](../stack) Docker deployment.
> Known soft spots called out throughout: the `passwd` hash lands on the
> world-readable boot partition, VNC (tcp/5900) is exposed on the LAN *and* the
> tailnet outside the gateway, the WiFi PSK lives in a local file, and the tailnet
> ACL ships "allow all". Treat it as a starting point to copy and harden, not a
> turnkey secure deployment.

```
raspberry/
  network-config.example.yaml     # netplan v2 — WiFi + eth (SHARED across roles)
  tailscale-policy.jsonc          # tailnet ACL — paste into Tailscale → Access controls
  gateway/
    user-data.yaml                # the gateway Pi (tsnet node, serves the dashboard)
    gateway.hcl                   # gateway policy (Tailscale transport) — reference
    gateway.env.example           # TS auth key + OAuth client secret (template)
    clawpatrol-gateway.service    # systemd unit for the gateway
    deploy-gateway-bundle.sh      # stage the secret bundle onto a flashed card
  clawbot/
    user-data.yaml                # a dedicated agent Pi behind the gateway
```

## ⚠️ Requires the clawpatrol fork

Unlike `stack/` — which builds upstream
[`denoland/clawpatrol`](https://github.com/denoland/clawpatrol) from source — the
`user-data.yaml` seeds here download **prebuilt binaries from a fork's rolling
`edge` release**:

- `clawpatrol` from a fork that carries the core `aws_sso` OAuth flow, and
- the external `clawpatrol-plugin-aws` binary,

which the AWS SSO / EKS / kubectl credential examples in `gateway.hcl` depend on
(those features are **not** in upstream `v0.5.3`). Point the `base=…/releases/…`
URLs in both `user-data.yaml` files at your own fork/build before flashing, or
drop the AWS blocks and download an upstream release instead. The Anthropic,
OpenAI/Codex, GitHub, and Telegram credential types are all upstream.

## Flash a GATEWAY

```sh
# 1. Fill in your secrets first (see Secrets below):
cp network-config.example.yaml network-config.yaml   # add WiFi SSID + PSK
cp gateway/gateway.env.example  gateway/gateway.env   # add TS auth key + OAuth client
# ...and set your SSH key + upstreams in gateway/user-data.yaml + gateway/gateway.hcl.

# 2. Flash:
sudo rpi-imager --cli \
  --cloudinit-userdata      gateway/user-data.yaml \
  --cloudinit-networkconfig network-config.yaml \
  <raspios-lite-arm64.img.xz> /dev/diskN

# 3. Stage the secret bundle onto the flashed card's boot partition:
gateway/deploy-gateway-bundle.sh diskN
```

First boot: cloud-init installs the `clawpatrol` binary (+ the AWS plugin), drops
the gateway config/unit/env from the staged bundle, and starts
`clawpatrol-gateway` — it joins the tailnet as `clawpatrol-gateway` and serves the
dashboard. `gateway.env` (TS auth key + OAuth client secret) is dropped onto the
boot partition by the deploy script and **wiped off it on first boot**, never
committed.

## Flash a CLAWBOT

```sh
# set a UNIQUE hostname (clawbot-1, clawbot-2, …) in clawbot/user-data.yaml first
sudo rpi-imager --cli \
  --cloudinit-userdata      clawbot/user-data.yaml \
  --cloudinit-networkconfig network-config.yaml \
  <raspios-lite-arm64.img.xz> /dev/diskN
```

First boot: cloud-init installs the `clawpatrol` binary, stages a one-command
onboarding helper (`clawbot-join`), and drops the gateway-CA trust hooks, the
Firefox CA policy, and the exit-node guard — **all inert until you onboard**. It
does **not** provision the agent's home; that's your layer (bake your own
dotfiles/installer in, or clone it after first login). The order matters: install
any heavy toolchain **before** joining, so it downloads over the box's direct
internet and never rides the gateway.

Onboarding is one manual step (interactive Tailscale login):

```sh
ssh <user>@<clawbot>.local     # over LAN/mDNS, before it's on the tailnet
clawbot-join                   # joins the tailnet + installs the gateway CA into the system trust store
```

After onboarding the ClawBot is a `tag:clawbot` node routing **all** traffic
through the gateway; SSH it over the tailnet from then on.

### Enforced-mode gotchas (handled by the seeds)

- **Reboots** — `tailscaled` re-pins the exit node on boot, but clawpatrol's
  routing exemptions + gateway DNS pin are runtime-only and would be stripped,
  locking you out. `clawpatrol-exit-guard.service` re-applies them (SSH-first, so
  the box stays reachable by IP) after `tailscaled`/NetworkManager on every boot.
- **DNS** — enforced mode routes even the LAN subnet through the exit node, so the
  LAN resolver is unreachable; DNS is pinned at the gateway (the guard re-pins it
  past NetworkManager, which otherwise regenerates `/etc/resolv.conf`).
- **Installs** — all egress rides the gateway's userspace exit node, which can
  collapse under parallel connection bursts (uv's default fan-out). The seeds set
  `UV_CONCURRENT_DOWNLOADS=1` in `/etc/environment` to serialize uv. If you see
  `UnknownIssuer` / `client error (Connect)` on pypi, that's the exit node
  collapsing, not a trust bug — retry and/or tune the gateway side (kernel
  WireGuard / netstack).
- **Browsers** — use **Firefox** (the seed installs the gateway CA via an
  enterprise policy so MITM'd sites load). **Chromium does not work** behind the
  gateway: it opens many parallel connections per page and races QUIC (UDP/443),
  which the userspace exit node can't sustain. No Chromium trust is provisioned.

## Secrets

Nothing with a real secret is tracked here. Before flashing you create these
untracked files (all ignored via [`.gitignore`](./.gitignore)):

- `network-config.yaml` — from `network-config.example.yaml`; carries the WiFi SSID
  and the pre-computed WPA PSK.
- `gateway/gateway.env` — from `gateway.env.example`; the Tailscale auth key + OAuth
  client id/secret. Dropped onto the boot partition by `deploy-gateway-bundle.sh`
  and wiped on first boot.
- The `passwd` hash and `ssh_authorized_keys` in each `user-data.yaml` are
  placeholders — replace them with your own. SSH is key-only (`ssh_pwauth: false`);
  the password authorises `sudo` only.
- `*.img.xz` — the OS images are never committed. Download Raspberry Pi OS Lite
  (arm64) from [raspberrypi.com](https://www.raspberrypi.com/software/operating-systems/).

See [`docs/architecture.md`](../docs/architecture.md) for how the gateway,
credential injection, and the cage fit together.
