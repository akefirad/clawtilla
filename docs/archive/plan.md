# Implementation plan — Clawtilla (ClawBot fleet + clawpatrol gateway)

Handoff plan for building the setup designed in
[discovery.md](./discovery.md).
**Read that doc first** — it carries the rationale and the source citations; this plan is the
build sequence and the concrete artifacts. Where the two disagree, the discovery doc wins on
*why* and this plan wins on *how*.

## Goal (one line)

One **clawpatrol** gateway container with internet egress + N **ClawBot** client containers
that can reach **only** the gateway (no internet, no host), on one macOS / Docker Desktop machine.

## Verified environment / hard constraints

- Docker Desktop 4.73.0 (Docker Engine 29.4.3, Docker Compose v5.1.3) on macOS arm64, engine in a
  LinuxKit VM (kernel 6.12.76).
- **Transport is WireGuard, not Tailscale** (rationale in discovery "Transport: WireGuard, not Tailscale".
- Clients enroll with **plain `clawpatrol join`** (NOT `--whole-machine`) → need `NET_ADMIN` +
  `/dev/net/tun`. The entrypoint then brings the tunnel up itself with **`Table = off`** + a manual
  default route (see Step 5 for why). There is **no** `clawpatrol up` subcommand
  ([main.go:2699-2732](../oss/clawpatrol/cmd/clawpatrol/main.go#L2699-L2732)); the entrypoint runs
  `wg-quick up` on both first enrollment and restart, from the persisted conf.

## Container lifecycle & in-container user (decided)

- **Decoupled lifecycle (docker-exec model).** PID 1 is a long-lived **root** process that enrolls +
  holds the tunnel and never exits (`exec sleep infinity`). The **agent is run separately** via
  `docker compose exec`, so restarting/updating the agent never cycles the container or flaps the
  tunnel. Container restarts are rare (real failures / host reboot only); on restart the entrypoint
  re-ups the tunnel from the persisted conf — no re-enrollment.
- Set `init: true` on the client service so **tini is PID 1** (signal handling + reaps zombies from
  exec'd agent processes); the entrypoint runs as its child and ends with `exec sleep infinity`.
- Entrypoint **runs as root** — `join`/`wg-quick up` need `NET_ADMIN`. Client image has **no `USER` line**.
- **Persistence home = `/root`.** `join` writes `~/.config/clawpatrol/wg.conf` (+ the fetched CA) — this
  must land on the named volume → mount it at `/root`. (Plain `join` does **not** wire `clawpatrol env`
  into the shell rc — that's whole-machine only; the `run` wrapper supplies the env instead. See F1.)
- **Run the agent as root via the `run` wrapper**: `docker compose exec -it clawbot-418 run <agent>`.
  Plain `join` (not `--whole-machine`) does **not** install the shell rc (that path is whole-machine
  only — [setup.go:356](../oss/clawpatrol/cmd/clawpatrol/setup.go#L356)), so `bash -l` would source nothing.
  The baked `/usr/local/bin/run` wrapper does `eval "$(clawpatrol env)"` then `exec`s the agent, setting
  the placeholder-token vars + Node/Python CA-bundle vars (`NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`,
  …) the agent needs (F1). The gateway CA is in the **system** trust store too, but **not** via
  clawpatrol's `installCATrust`: that shells out to `sudo`, which refuses under `no-new-privileges`
  (and is redundant when already root). The entrypoint installs it itself — `cp
  /root/.clawpatrol/ca.crt /usr/local/share/ca-certificates/clawpatrol.crt && update-ca-certificates`
  — so OS-trust tools (`git`, `wget`, plain `curl`, Go binaries) also work; the `run` wrapper's env
  vars are only needed for the injected credential tokens (and for tools that ignore the system store).
  Pass `join --no-trust` to skip clawpatrol's doomed sudo attempt. Security delta from non-root is
  small here (cage blocks escape regardless of uid, no host mounts, VM boundary, real secrets stay at
  the gateway). Keep `no-new-privileges`. **No `sudo`** in the image.
- Dashboard is clawpatrol default `:8080` in-app; **do not** change the app port. Publish to the Mac as `5182`.
- Onboard + CA endpoints share the dashboard mux and are reached pre-tunnel → `dashboard_listen` must bind `0.0.0.0`.

## Target repo layout

```
tbot/                          repo root (project: Clawtilla)
├── stack/                    the deployable stack (flat — one multi-stage Dockerfile)
│   ├── compose.yaml
│   ├── .env.example        COMPOSE_PROJECT_NAME, gateway image ref, client count, agent cmd
│   ├── Dockerfile          multi-stage: `base` → `gateway` / `client` targets (Step 2 + Step 4)
│   ├── gateway.hcl         gateway policy (baked into the gateway image — NO bind mount; AC5)
│   ├── gateway.sh          gateway entrypoint — chmod 700 state dir, then exec clawpatrol
│   ├── client.sh           client entrypoint — enrollment-aware tunnel bring-up
│   └── test/               runnable evaluation harness (see docs/evaluation.md)
│       ├── run.sh          orchestrator: build → enroll → suites A–G → summary
│       ├── lib.sh          shared helpers (docker wrappers, assertions, dashboard auth)
│       ├── 00-static.sh … 60-agent-env.sh   suite scripts A–G
│       ├── README.md       harness usage + canonical requirements/AC + test catalog & matrix
│       └── logs/           timestamped run logs
├── oss/
│   └── clawpatrol/         git submodule (denoland/clawpatrol) — source of truth (not to be built)
└── docs/
    ├── discovery.md        design + rationale + source citations
    ├── plan.md             this file — build sequence + Step 7 acceptance criteria
    ├── evaluation.md       implementation-vs-docs evaluation (harness results)
    └── review.md           adversarial security review of the design
```

## Step 0 — Prerequisites

- Docker Desktop running; `docker compose version` ≥ v2.
- Decide what agent runs inside a ClawBot. The client image must
  install it; you launch it via `docker compose exec` (not from the entrypoint).

## Step 1 — `compose.yaml`

Concrete starting point (adjust names/counts):

```yaml
name: clawtilla

networks:
  clawegress-net:                # gateway egress → internet
    driver: bridge
  clawcage-net:                  # client cage — no NAT, no host route
    driver: bridge
    internal: true

volumes:
  gateway-state:              # gateway state_dir (db, CA, WG keys, secrets)
  clawbot-418-home:              # naming: clawbot-<name>-home (e.g. clawbot-foo-home);

services:
  gateway:
    build:
      context: .              # one multi-stage Dockerfile for both images (Step 2)
      target: gateway
    networks:
      clawegress-net: {}
      clawcage-net:
        aliases: [gateway]    # clients dial http://gateway:8080 and WG gateway:51820
    ports:
      - "127.0.0.1:5182:8080" # dashboard on the Mac loopback only
    volumes:
      - gateway-state:/opt/clawpatrol
      # gateway.hcl is baked into the image (Dockerfile COPY) — NO host bind mount (AC5). Edit
      # policy by rebuilding: `docker compose build gateway && up -d gateway` (state persists).
    environment:
      # connect a credential's secret via env (CLAWPATROL_SECRET_<UPPER, - → _>)
      # instead of the dashboard. The stack uses this to verify credential injection.
      CLAWPATROL_SECRET_ECHO_DUMMY: "test-secret-123"
    security_opt: [no-new-privileges:true]
    read_only: true             # immutable rootfs; state persists on the volume, /config is ro
    tmpfs: ["/tmp"]             # only writable rootfs path the gateway needs (boot-validated)
    # NO host bind mounts, NO host.docker.internal, NO extra caps (userspace WG).
    restart: unless-stopped

  clawbot-418: &clawbot           # one service per agent, named clawbot-<name>
    build:
      context: .
      target: client          # client stage of the same Dockerfile (Step 4)
    hostname: clawbot-418        # stable device identity — clawpatrol keys peer + /32 on (owner, hostname)
    init: true                # tini as PID 1 — signals + zombie reaping for exec'd agents
    networks: [clawcage-net]     # ONLY the cage
    cap_add: [NET_ADMIN]
    devices: ["/dev/net/tun"]
    # No sysctls / no systempaths=unconfined: the entrypoint brings the tunnel up with
    # `Table = off`, so wg-quick never writes net.ipv4.conf.all.src_valid_mark → /proc/sys
    # stays read-only. (See Step 5 and "Known risks".)
    security_opt: [no-new-privileges:true]
    volumes: [clawbot-418-home:/root]   # persists wg.conf + fetched CA (no rc — plain join skips it)
    environment:
      GATEWAY_URL: "http://gateway:8080"
      # wg-quick falls back to userspace WG if the LinuxKit kernel lacks the wireguard
      # module; clawpatrol's wgQuickUp doesn't set this itself.
      WG_QUICK_USERSPACE_IMPLEMENTATION: "wireguard-go"
    depends_on: [gateway]
    restart: unless-stopped   # only real restarts; the agent runs via `docker compose exec`

  # add agents by copying the service: clawbot-<name> + hostname clawbot-<name> + a clawbot-<name>-home volume
  # clawbot-foo:
  #   <<: *clawbot
  #   hostname: clawbot-foo
  #   volumes: [clawbot-foo-home:/root]
```

Notes for the implementer:
- Keep `internal: true` on `clawcage-net` — it is the load-bearing isolation primitive. Do not add a
  second non-internal network to a client.
- `aliases: [gateway]` is what makes `http://gateway:8080` and `Endpoint = gateway:51820` resolve.
- Scale by copying the service: each agent is `clawbot-<name>` with `hostname: clawbot-<name>` and its own
  `clawbot-<name>-home` volume. (`deploy.replicas` won't work — replicas can't each get a distinct named
  volume or hostname, which the per-agent identity needs.)

## Step 2 — `Dockerfile` (multi-stage: `base` → `gateway` / `client`)

One Dockerfile builds both images. A shared `base` stage pins the OS and installs the clawpatrol
release binary **by version + SHA256** (not `install.sh`) so the deployed binary stays in lockstep with
the `oss/clawpatrol` submodule — bump `CLAWPATROL_VERSION` ⇒ move the submodule to that tag AND update
the SHAs from the release's SHA256SUMS. The `gateway` and `client` stages branch off `base`; compose
selects between them with `target:` (Step 1). The pinned values live in [stack/Dockerfile](../stack/Dockerfile)
— don't duplicate them here (they drift on every version bump):

  ```dockerfile
  # syntax=docker/dockerfile:1.7
  # ---- base: OS + pinned, SHA-verified clawpatrol ----
  FROM ubuntu:jammy-20260509 AS base
  RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
      && rm -rf /var/lib/apt/lists/*
  ARG TARGETARCH
  ARG CLAWPATROL_VERSION=v0.2.4
  ARG CLAWPATROL_SHA256_amd64=…   # from the release SHA256SUMS
  ARG CLAWPATROL_SHA256_arm64=…
  RUN set -eu; arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
      case "$arch" in amd64) sha="$CLAWPATROL_SHA256_amd64";; arm64) sha="$CLAWPATROL_SHA256_arm64";; \
        *) echo "unsupported arch: $arch" >&2; exit 1;; esac; \
      url="https://github.com/denoland/clawpatrol/releases/download/${CLAWPATROL_VERSION}/clawpatrol-linux-${arch}"; \
      curl -fsSL -o /usr/local/bin/clawpatrol "$url"; \
      echo "${sha}  /usr/local/bin/clawpatrol" | sha256sum -c -; \
      chmod 0755 /usr/local/bin/clawpatrol

  # ---- gateway ----
  FROM base AS gateway
  COPY gateway.hcl /config/gateway.hcl
  COPY gateway.sh  /usr/local/bin/entrypoint.sh   # chmod 700 state dir, then exec clawpatrol
  RUN chmod +x /usr/local/bin/entrypoint.sh
  EXPOSE 8080 51820/udp
  ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
  CMD ["gateway", "/config/gateway.hcl"]
  ```

**Why the `gateway.sh` wrapper exists.** clawpatrol stores secrets in a 0600 `clawpatrol.db` + a 0700
CA dir, but its `MkdirAll(0700)` on `state_dir` no-ops on the pre-existing 0755 named-volume mountpoint
→ it logs a "state loosely permissioned" warning. The wrapper `chmod 700`s the dir before launch (the
volume stays writable under the RO rootfs — `chmod` targets the mount, not `/`), then `exec`s the
binary with the same `CMD` args:
  ```sh
  #!/bin/sh
  set -eu
  chmod 700 /opt/clawpatrol 2>/dev/null || true
  exec /usr/local/bin/clawpatrol "$@"
  ```
  Boot-validated with `read_only: true` (Step 1): state dir becomes `drwx------`, DB `-rw-------`,
  rootfs RO (`touch /` fails), `/tmp` writable, no startup warning.

## Step 3 — `gateway.hcl`

Start from [clawpatrol/examples/gateway.example.hcl](../oss/clawpatrol/examples/gateway.example.hcl) and
trim to the minimum, with the Clawtilla-specific values:

```hcl
gateway {
  dashboard_listen = "0.0.0.0:8080"          # clients need :8080 on clawcage-net for join/CA
  public_url       = "http://127.0.0.1:5182" # operator approval links only
  state_dir        = "/opt/clawpatrol"

  wireguard {
    subnet_cidr = "10.55.0.0/24"
    endpoint    = "gateway:51820"            # overrides public_url-derived endpoint
  }
}

defaults {
  unknown_host  = "deny"          # NOTE: dead config for HTTPS today — see below (accepted, monitor-only)
  llm_fail_mode = "closed"
}

# Add endpoints + rules per the allowlist you want the fleet to have.
# Example (copy real ones from the example file):
# endpoint "https" "anthropic" { hosts = ["api.anthropic.com"] }
# rule "anthropic-allow" { endpoint = https.anthropic  verdict = "allow" }
```

**Egress posture (Validated, see discovery "Open questions"):** `unknown_host = "deny"` is **dead
config for HTTPS** — the unbound-host path hardcodes passthrough
([main.go:1424-1429](../oss/clawpatrol/cmd/clawpatrol/main.go#L1424)), so the gateway transparently
relays every host that isn't an explicitly-configured endpoint. clawpatrol is therefore **monitor +
per-endpoint policy, not an egress allowlist**; the **network cage** (`clawcage-net internal: true`) is
what actually contains the fleet. What *does* work, and was validated: the per-endpoint **rule engine** and **credential injection**.

## Step 4 — client stage (same `Dockerfile`, `target: client`)

Branches off the same `base` (so `ca-certificates` + `curl` + the pinned binary are already present —
the client stage only adds the WireGuard/diagnostic tooling):

```dockerfile
# ---- client ----
FROM base AS client
# iproute2/iptables: wg-quick routing. wireguard-tools: wg-quick + wg.
# wireguard-go: userspace WG fallback (selected via WG_QUICK_USERSPACE_IMPLEMENTATION
# in compose) for when the LinuxKit kernel lacks the wireguard module — hence /dev/net/tun.
# procps/iputils-ping/dnsutils: ps/kill/ping/dig for the acceptance checks.
RUN apt-get update && apt-get install -y --no-install-recommends \
      iproute2 iptables procps iputils-ping dnsutils \
      wireguard-tools wireguard-go \
    && rm -rf /var/lib/apt/lists/*
# persistence is root's home (/root) — mounted from the named volume in compose.
# install whatever agent runs here (claude/codex/...) so `docker compose exec` can run it.
# (optional non-root: `RUN useradd -m -u 1000 agent`, mount the volume at /home/agent, launch with
#  `exec -u agent … run <agent>`; also make the enrollment config readable by the agent uid — see F5.)
COPY client.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
# NO `USER` line — container starts as root so the entrypoint can bring up the tunnel.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

RESOLVED at runtime (was the riskiest part):
- The LinuxKit kernel **HAS** the `wireguard` module (`ip link add … type wireguard` succeeds) → kernel
  WG is used; the `wireguard-go` userspace fallback is provisioned but unused. `NET_ADMIN` +
  `/dev/net/tun` are sufficient.
- We **avoid** `wg-quick`'s `0.0.0.0/0` + `fwmark 51820` + `suppress_prefixlength` dance entirely by
  bringing the tunnel up with `Table = off` and adding the default route by hand (Step 5). That dodges
  the read-only `/proc/sys` write (`src_valid_mark`) that crash-looped the `--whole-machine` path.

## Step 5 — `client.sh` (the client entrypoint; enrollment-aware: join once, bring-up always)

Runs as **root** (no `USER` line). PID 1's only job is to enroll/bring-up the tunnel and then stay
alive — it does **not** run the agent.

**Why not `--whole-machine`:** that path runs `wg-quick` with `Table=auto`, which unconditionally writes
`net.ipv4.conf.all.src_valid_mark`. Docker mounts `/proc/sys` **read-only**, so the write fails and
`wg-quick` rolls back → entrypoint crash-loops. Instead we enroll
with **plain `join`** (conf-only, no bring-up), force **`Table = off`** in the conf (no routes added, no
`src_valid_mark` write), `wg-quick up`, then add the default route by hand. The gateway is on the same
L2 (`clawcage-net`), so the handshake to `gateway:51820` uses the connected route — no fwmark trick needed,
and `/proc/sys` stays read-only. Same path on first run and restart.

```sh
#!/bin/sh
set -eu
CONF="/root/.config/clawpatrol/wg.conf"
IFACE="clawpatrol"

if [ ! -f "$CONF" ]; then
  # Plain join (NOT --whole-machine): enroll + persist wg.conf, no bring-up. Prints a
  # user-code to approve at the dashboard and fetches the gateway CA to /root/.clawpatrol/ca.crt.
  # --no-trust: clawpatrol's installCATrust shells out to `sudo`, which refuses under
  # no-new-privileges (and is redundant as root) — we install the CA ourselves below.
  # NOTE: plain join does NOT install the shell rc — the agent gets its env via the `run`
  # wrapper (eval "$(clawpatrol env)"), not from a login shell. See F1.
  echo "[entrypoint] no persisted conf; enrolling (plain join, conf-only)"
  clawpatrol join --no-trust "${GATEWAY_URL:-http://gateway:8080}"
fi

# Install the gateway CA into the system trust store so OS-trust tools (git, wget,
# plain curl, Go binaries) work against MITM'd in-scope endpoints. Root + writable
# rootfs, so no sudo. Idempotent: ca.crt persists on the /root volume, the system
# copy lives on the (non-persisted) rootfs — reinstall whenever missing.
CA="/root/.clawpatrol/ca.crt"
DST="/usr/local/share/ca-certificates/clawpatrol.crt"
if [ -f "$CA" ] && [ ! -f "$DST" ]; then
  echo "[entrypoint] installing gateway CA into system trust store"
  cp "$CA" "$DST"
  update-ca-certificates
fi

# Materialize the kernel conf and force `Table = off` so wg-quick adds no routes
# and never touches net.ipv4.conf.all.src_valid_mark.
install -D -m600 "$CONF" "/etc/wireguard/${IFACE}.conf"
if grep -q '^[[:space:]]*Table' "/etc/wireguard/${IFACE}.conf"; then
  sed -i 's/^[[:space:]]*Table.*/Table = off/' "/etc/wireguard/${IFACE}.conf"
else
  sed -i '/\[Interface\]/a Table = off' "/etc/wireguard/${IFACE}.conf"
fi

wg-quick up "$IFACE"

# Send all egress through the tunnel; the handshake stays on the connected clawcage-net route.
ip route add default dev "$IFACE"
ip -6 route add default dev "$IFACE" 2>/dev/null || true

echo "[entrypoint] tunnel up (Table=off + manual default route); holding open"
exec sleep infinity   # agent runs separately via `docker compose exec`; tini reaps it
```

Run / restart the agent without touching the container:
`docker compose exec -it clawbot-418 run <agent>` (the `run` wrapper `eval`s `clawpatrol env` → CA-bundle + placeholder-token vars, then execs the agent — F1). The persisted conf (`wg.conf`) materializes as interface `clawpatrol` per
[setup.go](../oss/clawpatrol/cmd/clawpatrol/setup.go).

## Step 6 — First-run runbook

1. `docker compose build`
2. `docker compose up -d gateway`
3. Dashboard password (one-time). The CA **self-mints** into sqlite on first gateway boot — no
   `init-ca` needed ([getting-started.md:47-49](../oss/clawpatrol/site/doc/getting-started.md#L47)). Open
   `http://127.0.0.1:5182`, set the **root password** (or `clawpatrol gateway --set-dashboard-password
   '…'`). Connect any credentials the HCL declares.
4. Bring up one client: `docker compose up -d clawbot-418` (PID 1 enrolls + holds the tunnel; the agent is
   not started here).
5. Approve enrollment: watch `docker compose logs -f clawbot-418` for the user-code; approve it in the
   dashboard. **WG mode has no `--auto-approve`** (verified — auto-approve only exists on the Tailscale
   `--login` path, [setup.go:188-194](../oss/clawpatrol/cmd/clawpatrol/setup.go#L188)); manual approval is
   mandatory. **Approval is ALWAYS manual — never script `/api/onboard/approve` or blanket-approve**
   (F4): a rogue/auto-approved enrollment gets a profile and the gateway injects real upstream
   credentials for it.
   **Before clicking approve, compare the CA fingerprint (F2).** `join` runs over plain HTTP, and a
   compromised co-tenant on `clawcage-net` (every client has `NET_ADMIN`) can ARP-spoof the `gateway`
   alias to swap the CA mid-enrollment and MITM the new peer. The defense: the CLI prints a
   `CA fingerprint: …` line ([setup.go:1011-1016](../oss/clawpatrol/cmd/clawpatrol/setup.go#L1011)) — shown
   only because approval is manual — and the dashboard approval page shows the same value next to the
   user-code. **They MUST match; a mismatch means an on-path CA swap — reject and investigate.**
   Residual (accepted, N5): a hostile co-tenant can still ARP-spoof to *blackhole* a peer's join/tunnel
   — intra-cage DoS, not interception. Inherent to shared-L2 + `NET_ADMIN`; closing it needs per-client
   networks or pre-seeded `wg.conf`, both declined.
6. Run the agent: `docker compose exec -it clawbot-418 run <agent>` (the `run` wrapper `eval`s
   `clawpatrol env` → placeholder-token + CA-bundle vars, then execs the agent — F1). Restart/update
   the agent by re-running this — container + tunnel stay up.
7. Bring up + enroll the rest: `docker compose up -d`, repeat steps 5-6 per client.

## Step 7 — Acceptance criteria (must all pass)

The acceptance criteria (**AC1–AC8**) are defined canonically in
[tests/claude/README.md](../tests/claude/README.md) (which also carries the test catalog +
coverage matrix) and verified by the test harness.
Run them from inside a ClawBot once the tunnel is up — `docker compose exec clawbot-418 sh`,
or the full suite via [`tests/claude/run.sh`](../tests/claude/run.sh). AC codes referenced
elsewhere in this doc (AC2, AC5, …) resolve to that registry.

## Known risks / open items (carry from discovery)

- ~~LinuxKit `wg-quick` kernel-vs-userspace~~ **RESOLVED at runtime**: the LinuxKit kernel HAS the
  `wireguard` module (`ip link add … type wireguard` succeeds) → kernel WG is used; the `wireguard-go`
  userspace fallback is provisioned but unused.
- ~~`wg-quick` crash-loop on read-only `/proc/sys`~~ **RESOLVED via `Table = off`** (Step 5). Root cause:
  `wg-quick --whole-machine` (`Table=auto`) unconditionally writes `net.ipv4.conf.all.src_valid_mark`;
  Docker mounts `/proc/sys` read-only, so the write fails (`Read-only file system`) and `wg-quick` rolls
  back → loop. Confirmed by a direct write test (RO mount fails; `--privileged` → `rc=0`). A `sysctls:`
  entry only pre-sets the *value*, it doesn't make `/proc/sys` writable, so it alone does **not** fix it.
  The temporary unblock — `security_opt: [systempaths=unconfined]` — un-masks all of `/proc` for the
  untrusted ClawBot (it could then write `/proc/sysrq-trigger` to crash/reboot the Docker Desktop VM → DoS
  the whole fleet, and read `/proc/kcore` → VM kernel memory incl. **other containers' secrets, the
  gateway's included**), breaking "secrets stay at the gateway". **Now removed.** The `Table = off` +
  manual-default-route approach avoids the `src_valid_mark` write entirely (the fwmark dance only matters
  for a gateway reached *over* the default route; ours is on the same L2), so `/proc/sys` stays read-only
  with **only** `security_opt: [no-new-privileges:true]`. Validated at runtime: tunnel up, `/proc/sys`
  `ro`, egress through the tunnel works, no re-enrollment. *(Alternative considered and rejected: a
  `sysctl` PATH-shim that no-ops the `src_valid_mark` write — smaller change but shadows a system binary.)*
- **Egress is monitor-only, not default-deny** (carry from discovery): `unknown_host = "deny"` is dead
  config for HTTPS ([main.go:1424-1429](../oss/clawpatrol/cmd/clawpatrol/main.go#L1424) hardcodes
  passthrough). The **network cage** contains the fleet; the gateway gives visibility + per-endpoint
  policy + credential injection (both validated — Step 3). True default-deny needs a main.go patch or a
  separate allowlist firewall. Deferred for now.
- ~~Gateway secret storage under-hardened~~ **RESOLVED** (security review, Medium → Low): gateway now
  runs `read_only: true` + `tmpfs: [/tmp]`, and a `gateway.sh` wrapper `chmod 700`s the state-dir
  mountpoint before launch (Step 2). Secrets were already in a 0600 db / 0700 CA dir; the only finding
  was the 0755 mountpoint bits, which had no second principal to exploit. Non-root gateway user
  considered and **deferred** — feasible (userspace WG needs no caps) and upstream-endorsed
  ([run_safety.go:20](../oss/clawpatrol/cmd/clawpatrol/run_safety.go#L20)) but blocked on the named volume
  being created root-owned (needs a chown-then-drop entrypoint). Revisit if shipping.
- **Agent runs as root + NET_ADMIN (F5) — accepted design decision (v1).** The exec'd agent runs as
  root in the same container as PID 1. PID 1 *requires* root + NET_ADMIN for tunnel bring-up (`join`,
  `wg-quick up`, `ip route`); the agent does **not**, but we deliberately **do not** drop it to a
  non-root uid for v1. This is a cost trade-off, not a safety claim — the risk below is real but
  bounded:
  - **Why not non-root (the cost):** (a) clawpatrol resolves its config dir via `$HOME` and `join`
    writes it under root's home, so a non-root `agent` uid needs the enrollment config — including the
    `0600` root-owned `api-token` that `clawpatrol env` reads for credential push-down — re-owned or
    relocated; it is **not** just `-u agent`. (b) Agents that mutate the system at runtime (`apt`,
    global installs) break under non-root unless deps are baked into the image and a writable home is
    provided. (c) The stronger end-state — a separate tunnel container + a capless, non-root agent
    container sharing the netns — is a larger orchestration change than v1 warrants.
  - **Residual risk:** root + NET_ADMIN on the untrusted agent maximizes the kernel/Docker *escape*
    surface (NET_ADMIN has LPE/escape history).
  - **Bounded by:** the cage blocks network escape regardless of uid; the LinuxKit/Docker-Desktop VM
    boundary; and `no-new-privileges` (blocks setuid escalation, so a would-be non-root agent couldn't
    regain caps anyway).
  - **Revisit if** the threat model tightens (multi-tenant gateway, higher-value upstream creds): the
    target hardening is the non-root `agent` uid (`docker compose exec -u agent … run <agent>`, caps
    stay on PID 1) or the container split, with the `$HOME`/`api-token` perm work above.
- Mac publish (`127.0.0.1:5182:8080`) reaching the dashboard on the multi-homed gateway container.
- Manual dashboard approval is **mandatory** per client (no WG `--auto-approve` — only the Tailscale
  `--login` path has it).
- Gateway → host is **best-effort** only (gateway has real egress by design; on Docker Desktop can
  still reach the Mac via host-gateway). Not closed; document, don't pretend otherwise. Accepted for now.
- `dashboard_listen` is intentionally `0.0.0.0` — do **not** rebind to the clawegress-net IP later
  (breaks new enrollment, needs a restart, and doesn't lock enrolled clients out anyway — the
  in-tunnel forwarder dispatches the dashboard by port number).
