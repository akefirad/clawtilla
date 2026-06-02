# Discovery: secure Docker network for a clawpatrol gateway + clients

## Objective

Run a [clawpatrol](https://github.com/denoland/clawpatrol) **gateway** container (the "forward
proxy", a security firewall for agents) alongside N **client** (aka ClawBot) containers on one macOS machine,
such that:

- Clients reach **only** the gateway — no internet, no host, nothing else.
- The gateway has internet egress (it is the egress point).
- The gateway exposes a **dashboard** to the operator's Mac and a **client-facing port** to the clients.
- The gateway should not be able to touch the host (best-effort on Docker Desktop).

## Environment (verified)

- **Docker Desktop 4.73.0** (Docker Engine 29.4.3, Docker Compose v5.1.3), macOS arm64, engine in a
  LinuxKit VM (kernel 6.12.76). `docker version`.
- No native iptables on the Mac → any egress firewalling lives inside the managed VM and resets.
- The "host" a container can reach is the Mac via the Docker-Desktop-injected `host.docker.internal` gateway.

## Key facts (from clawpatrol source)

- `gateway {}` block ([clawpatrol/examples/gateway.example.hcl](../oss/clawpatrol/examples/gateway.example.hcl)):
  - `dashboard_listen = "<host>:<port>"` — operator dashboard real socket. **Left on clawpatrol's
    default `8080` in-app**; exposed on the Mac as `5182` via the publish mapping (do not customize the
    app port).
  - `public_url` — onboarding URL printed to clients during `join`.
  - `state_dir` — holds `clawpatrol.db` (bcrypt root password, peer map, WG keys, VIPs), CA, secrets.
  - `wireguard { subnet_cidr = "10.55.0.0/24"; listen_port = 51820 }` — WG UDP endpoint; `endpoint`
    overrides the advertised host:port handed to clients.
- **Transport**: gateway runs **userspace** WireGuard (wireguard-go + gVisor netstack,
  [clawpatrol/doc/wireguard.md](../oss/clawpatrol/doc/wireguard.md)). The binary *is* the WG endpoint and
  L3 forwarder. Boots WG on UDP 51820; dashboard + MITM ride the same forwarder. Gateway needs **no**
  kernel WG / NET_ADMIN.
- **Clients** enroll with plain `clawpatrol join <gw>` → writes a `wg-quick` conf (and the gateway CA +
  shell rc), no bring-up. The entrypoint then materializes the conf, forces **`Table = off`**, runs
  `wg-quick up`, and adds the default route by hand (`ip route add default dev clawpatrol`) → **kernel**
  WireGuard. `Table = off` is deliberate: it skips `wg-quick`'s `Table=auto` default-route + `fwmark
  51820` dance — and crucially its `net.ipv4.conf.all.src_valid_mark` write, which fails on Docker's
  read-only `/proc/sys` (see Open questions). The gateway is on the same L2, so the handshake to
  `gateway:51820` uses the connected route without the fwmark trick. PostUp still swaps resolv.conf to
  1.1.1.1 (forwarded through the tunnel). Needs `NET_ADMIN` + `/dev/net/tun`. (We do **not** use
  `join --whole-machine`, whose `Table=auto` bring-up is exactly what hits the RO `/proc/sys` write.)
- `clawpatrol run <agent>` ([clawpatrol/cmd/clawpatrol/run_linux.go:32-38](../oss/clawpatrol/cmd/clawpatrol/run_linux.go#L32-L38))
  is the alternative: unprivileged userns, ambient `CAP_NET_ADMIN` only for TUN setup, **cleared
  before exec'ing the agent**. Cleaner least-privilege but fragile under LinuxKit. Not chosen.
- Dashboard auth = bcrypt root password set on first visit (`clawpatrol gateway --set-dashboard-password`).
- **Routing mode**: default `join` is *per-process* — only `clawpatrol run`-wrapped commands traverse
  the gateway ([getting-started.md:80-83](../oss/clawpatrol/site/doc/getting-started.md#L80)). `join
  --whole-machine` is clawpatrol's built-in whole-tunnel path, but its `wg-quick` bring-up
  (`Table=auto`) crash-loops on Docker's RO `/proc/sys`. **Chosen mode for ClawBot clients: plain `join` +
  an entrypoint that brings the whole tunnel up with `Table = off` + a manual default route** — same
  whole-machine routing effect, no `src_valid_mark` write.
- **CA / env**: `join`'s `installCATrust` ([setup.go:375-379](../oss/clawpatrol/cmd/clawpatrol/setup.go#L375))
  *tries* to install the gateway CA into the device's **system trust store** on plain join too — but in
  our container it **no-ops**: it shells out to `sudo` ([setup.go:678-683](../oss/clawpatrol/cmd/clawpatrol/setup.go#L678)),
  which refuses to run under `no-new-privileges` (and is redundant when already root). The failure is
  swallowed into a hint. So **the entrypoint installs the CA itself** (`cp /root/.clawpatrol/ca.crt
  /usr/local/share/ca-certificates/clawpatrol.crt && update-ca-certificates`, as root) — and we pass
  `join --no-trust` to skip the doomed sudo attempt. With that, OS-trust tools (`git`, `wget`, plain
  `curl`, Go binaries) reach MITM'd in-scope endpoints. `join` does **NOT** wire `clawpatrol env` into
  the shell rc on plain `join` — `installShellRC` fires
  **only** in `--whole-machine` mode ([setup.go:356](../oss/clawpatrol/cmd/clawpatrol/setup.go#L356)), which we
  don't use. So there is no rc to source; tools that bypass the system store (Node
  `NODE_EXTRA_CA_CERTS`, Python `REQUESTS_CA_BUNDLE`) and credential **placeholder-token** injection
  get nothing from a login shell. The agent must therefore get its env explicitly via
  `eval "$(clawpatrol env)"` — handled by the baked `run` wrapper (F1), since the agent is exec'd
  separately and the entrypoint that holds the tunnel never sources anything either.

## Topology (agreed)

```
                 clawegress-net (bridge, NAT → internet)   ← gateway ONLY
                      │
                 ┌────┴─────┐
   internet ◄────┤ GATEWAY  ├── dashboard :8080  → publish 127.0.0.1:5182 on the Mac
                 │ container│                       (bound 0.0.0.0 — clients also need :8080 on
                 │          │                        clawcage-net for join/CA; gated by app auth)
                 └────┬─────┘── WG UDP :51820   (NOT published; reached only over clawcage-net)
                      │
                  clawcage-net  (internal: true — no gateway, no NAT)
                 ┌────┼────┬────┐
              client1 client2 ... clientN   (attached ONLY to clawcage-net; cap NET_ADMIN + /dev/net/tun)
```

## Decisions / constraints

### Transport: WireGuard, not Tailscale
clawpatrol supports two client transports — WireGuard and embedded Tailscale (`tsnet`); both can coexist
in one `gateway {}` block ([configure-gateway.md:10-48](../oss/clawpatrol/site/doc/configure-gateway.md#L10-L48)).
**We use WireGuard.** Tailscale mode is a net negative for this topology:
- **It breaks the cage — the hard requirement.** In Tailscale mode the gateway acts as the clients'
  Tailscale **exit node** ([configure-gateway.md:52](../oss/clawpatrol/site/doc/configure-gateway.md#L52)):
  each client must `tailscale up` against the tailnet and `EditPrefs(ExitNodeIP=<gateway>)`. Joining a
  tailnet requires reaching Tailscale's control plane + DERP relays **over the internet**. Our clients
  sit on a `clawcage-net` (`internal: true`) whose entire purpose is "reach ONLY the gateway." Tailscale
  needs the opposite, so it can't run inside the cage without punching clients out to the internet.
- **It solves problems we don't have.** Tailscale's value is NAT traversal + rendezvous for *distributed*
  fleets across hosts/networks (README framing: "fleets already on a tailnet"). Our whole clawtilla is on
  one Mac on a Docker network we control; WireGuard + a Docker DNS alias (`gateway`) is already a direct
  one-hop link with no discovery problem. Tailscale adds an external dependency (account, OAuth client,
  minted auth key, tailnet ACL `autoApprovers.exitNode` — skip the ACL and every client dial silently
  times out, [configure-gateway.md:50-76](../oss/clawpatrol/site/doc/configure-gateway.md#L50-L76)) to replace
  something already trivial.
- **The dashboard-auth angle doesn't help.** The only WG-independent Tailscale feature is the operator
  allowlist — authenticating dashboard access by tailnet whois identity
  ([security-model.md:195-230](../oss/clawpatrol/site/doc/security-model.md#L195-L230)). We already bind the
  dashboard to `127.0.0.1:5182` on the Mac (loopback-only), which is strictly simpler and needs no tailnet.
- **Escape hatch (if this stops being single-machine):** if clients later spread across multiple
  hosts/cloud VMs that can't share a Docker network, Tailscale mode becomes the natural transport — no
  UDP port to open, NAT traversal handled, `funnel = true` for onboarding non-tailnet devices. Revisit then.

### Network separation
- **`clawcage-net`**: `internal: true`. No NAT/gateway → anything on it has no internet and no route to
  the host **automatically**. This single primitive enforces clients↛internet and clients↛host.
- **`clawegress-net`**: normal bridge. **Only the gateway** joins it → gateway's sole internet path.
- Gateway is dual-homed (both nets); clients are on `clawcage-net` only.

### Port binding
- **Dashboard**: bind `dashboard_listen = "0.0.0.0:8080"`. Clients **must** reach `:8080` over
  `clawcage-net` during `join` — the onboarding + CA endpoints (`/api/onboard/{start,poll,claim}`,
  `/ca.crt`, `/info`) ride the **same** mux and are `authPublic`
  ([web.go:247-251,327](../oss/clawpatrol/cmd/clawpatrol/web.go#L247-L251)), and `join` happens before the
  tunnel exists. Publish `127.0.0.1:5182:8080` for the operator's Mac. **Not** blocked at L2 — see
  "Dashboard exposure to clients".
- **WG (51820/UDP)**: **not** published. Clients reach it over `clawcage-net`.

### Client → gateway discovery
- Gateway gets Docker network **alias `gateway`** on `clawcage-net`.
- **Enrollment**: clients run plain `clawpatrol join http://gateway:8080` (the entrypoint does the
  `Table = off` bring-up afterward). The client dials the *join arg* (not `public_url`) for CA fetch +
  onboard ([setup.go:166,940](../oss/clawpatrol/cmd/clawpatrol/setup.go#L166)).
- **WG endpoint**: set `wireguard.endpoint = "gateway:51820"`; `wg-quick` resolves `gateway` via Docker's
  embedded DNS. This overrides the `public_url`-derived endpoint
  ([wireguard.go:761-790](../oss/clawpatrol/cmd/clawpatrol/wireguard.go#L761-L790)), so `public_url` is left
  for operator-facing approval links only (point it at `http://127.0.0.1:5182`).

### Client mode
- **Plain `clawpatrol join` + an entrypoint that brings up a whole-tunnel with `Table = off`** (kernel
  WG) so the agent runs **unwrapped** with all traffic tunneled and policy-inspected — not the default
  per-process mode (which would route only `clawpatrol run`-wrapped commands), and not `--whole-machine`
  (whose `Table=auto` bring-up writes `src_valid_mark` and crash-loops on Docker's RO `/proc/sys` — see
  Open questions). Same routing effect, no sysctl write. Each client: `cap_add: NET_ADMIN`, `devices:
  /dev/net/tun`, `clawcage-net` only. NET_ADMIN does **not** weaken **egress** isolation — the internal
  net blocks escape regardless (NET_ADMIN can't conjure a route to a non-existent gateway/NAT). It
  **does** weaken **lateral** (client↔client) isolation: a hostile agent can ARP/ND-spoof, sniff
  co-tenant traffic, run rogue DNS/DHCP, and become on-path for a peer's plain-HTTP `join` (F2/F3).
  We accept this — see "Client ↔ client" (N5). The escape boundary (cage) is unaffected; only the
  intra-cage trust between agents is.
- The agent must get its env via `eval "$(clawpatrol env)"` before running — there is no rc to source
  (plain join, see CA/env note). The agent is exec'd separately (`docker compose exec … run <agent>`),
  so a baked `run` wrapper does the eval then execs the agent (F1) rather than the tunnel entrypoint.
- **Agent user = root (accepted, v1).** The exec'd agent runs as root + NET_ADMIN, same container as
  PID 1. Non-root was considered and deferred for cost, not safety: clawpatrol's `$HOME`-based config +
  the `0600` root-owned `api-token` would need re-owning, and runtime `apt`/global-install agents break
  under non-root. Residual escape risk is bounded by the cage + VM boundary + `no-new-privileges`.
  Revisit if the threat model tightens. See PLAN F5.

### Client state
- **Each client gets its own volume mounted at its home directory** (e.g. `/home/<user>` or `/root`).
  Holds the client's enrollment — `~/.config/clawpatrol` (minted WG keypair, allocated `/32`), the CA
  bundle, and agent working state — so restarts don't force a fresh `join`/re-enroll.
- Use a **named Docker volume per client** (`clawbot-<name>-home`), not a host bind mount: keeps the home off
  the Mac filesystem (consistent with host-isolation) and keeps clients isolated from each other.
  The canonical identity (`PrivateKey`) is the `~/.config/clawpatrol/wg.conf` written by `join`
  ([setup.go:1145-1148](../oss/clawpatrol/cmd/clawpatrol/setup.go#L1145-L1148)); `/etc/wireguard/clawpatrol.conf`
  is a derived copy that does **not** survive a container restart. So the home volume is the correct
  store, but the **client entrypoint must be enrollment-aware** — *join once, bring-up always*:
    1. If `~/.config/clawpatrol/wg.conf` exists → re-materialize `/etc/wireguard/clawpatrol.conf` from it
       (or `wg-quick up` that path directly) and **skip** `join`.
    2. Else → `clawpatrol join <gw>` (one-time, needs dashboard approval), then bring the tunnel up.
  A naïve `join`-on-every-boot entrypoint still works (the gateway recycles the `/32` per
  `(owner, hostname)`, [onboard.go:349,772](../oss/clawpatrol/cmd/clawpatrol/onboard.go#L349)) but re-mints a
  keypair and churns dashboard approvals each restart — avoid it.

### Client ↔ client
- **Left open** (user's call; not a dealbreaker). All clients on one `clawcage-net`; they can talk to
  each other but cannot escape the net.

### Gateway → host (best-effort)
- `state_dir` on a **named Docker volume**, never a host bind mount (a bind mount would hand the
  gateway a Mac path).
- No `host.docker.internal` injection, no host bind mounts, `security_opt: no-new-privileges`,
  default caps only (userspace WG needs none).
- **Rootfs hardening (implemented + boot-validated):** gateway runs `read_only: true` with
  `tmpfs: [/tmp]` — `/tmp` is the only writable rootfs path it needs. State persists on the
  `gateway-state` volume (a mount, stays writable under the RO rootfs) and `/config` is a `:ro` mount,
  so nothing on `/` needs to be writable. A compromised gateway can't rewrite its own binary.
- **State-dir perms (implemented):** the crown jewels live in `clawpatrol.db`, which clawpatrol chmods
  0600 on every open ([db.go:69](../oss/clawpatrol/cmd/clawpatrol/db.go#L69)); the CA dir is 0700. But
  Docker pre-creates the named-volume mountpoint 0755 and clawpatrol's `MkdirAll(0700)` no-ops on an
  existing dir, tripping its "state loosely permissioned" warning
  ([main.go:97](../oss/clawpatrol/cmd/clawpatrol/main.go#L97)). A gateway entrypoint wrapper (`gateway.sh`)
  `chmod 700`s `/opt/clawpatrol` before launch. Low real impact (single root process, no second
  principal in the gateway container, clients can't reach the volume) — but cheap hygiene that silences
  the warning. See PLAN Step 2.
- **Residual (documented, accepted)**: the gateway has full internet egress by design, and on Docker
  Desktop can still reach the Mac via the host-gateway. Closing this needs an in-container egress
  firewall (NET_ADMIN + iptables DROP RFC1918/host-gateway), which was declined for now.

### Dashboard exposure to clients
- Clients **can** reach the dashboard port on `clawcage-net` — **required** for self-service `join`
  (onboard + CA fetch happen on `:8080` before any tunnel). Reachable two ways: directly at
  `gateway:8080` (pre-tunnel) and via the WG forwarder's port dispatch (post-tunnel,
  [wireguard.md](../oss/clawpatrol/doc/wireguard.md) step 4). L2 blocking is **not** attempted — it would
  break enrollment.
- Isolation is by clawpatrol's **auth model**, not the network: onboard routes are `authPublic` but
  gated by **operator approval** of the one-time user-code (`/api/onboard/approve` needs operator/dashboard
  auth, [web.go:249](../oss/clawpatrol/cmd/clawpatrol/web.go#L249)); every privileged dashboard action needs the
  **bcrypt root password**. So a client reaching the port can't do anything without approval/password.
- Decision: **bind `0.0.0.0`, rely on app auth** (chosen over pre-seeding wg.conf to preserve an L2 block).
- **Don't rebind to the clawegress-net IP after onboarding** — it gains nothing and breaks things. The
  in-tunnel forwarder dispatches the dashboard purely by **port number** (`dashPort := portOf(dashListen)`,
  [main.go:3034,3049-3050](../oss/clawpatrol/cmd/clawpatrol/main.go#L3034)), independent of the OS bind host,
  so enrolled clients still reach it over the tunnel regardless. Rebinding only closes the pre-tunnel L2
  socket (→ **new clients can't `join`**, lost-volume clients can't re-enroll), needs a gateway restart
  (gateway block isn't hot-reloadable, [gateway.example.hcl:8-9](../oss/clawpatrol/examples/gateway.example.hcl#L8-L9)),
  and risks breaking the Mac publish on a multi-homed container. The dashboard's real protection is the
  bcrypt root password, which already holds over the tunnel.

### Config sketch
```hcl
gateway {
  dashboard_listen = "0.0.0.0:8080"        # clients need :8080 on clawcage-net for join/CA
  public_url       = "http://127.0.0.1:5182" # operator approval links only (wg endpoint set below)
  state_dir        = "/opt/clawpatrol"
  wireguard {
    subnet_cidr = "10.55.0.0/24"
    endpoint    = "gateway:51820"
  }
}
```

## Open questions / risks

- **Egress containment is NOT implemented upstream (DEFERRED, REVISIT LATER).** Confirmed: clawpatrol's
  `unknown_host = "deny"` is dead config for HTTPS — the unbound-host path
  ([main.go:1424-1429](../oss/clawpatrol/cmd/clawpatrol/main.go#L1424)) hardcodes `g.splice()` (passthrough)
  and never reads the value (comment: *"passthrough today … A 'deny' mode would close the conn"*).
  So the gateway MITMs/polices only explicitly-configured endpoints and **transparently relays every
  other host** — an agent can reach any internet host through it. **Decision: accept the monitor-only
  model for now** (the network cage is the containment; the gateway is visibility + per-endpoint
  policy, not an egress allowlist). **The per-endpoint rule engine itself works** — Validated on an
  in-scope endpoint: `GET`→allow (200), `POST`→deny (clean **403**) via a catch-all rule. So policy is
  real for configured+bound endpoints; the *only* gap is the global default for unconfigured hosts.
  **Credential injection also validated**: with a secret connected, the gateway *adds* `Authorization`
  when the agent sends none and *overwrites* a client-supplied one — real secret stamped server-side,
  agent can't read or override it ("secrets stay at the gateway" holds for in-scope endpoints).
  Injection is gated on a configured secret (no secret → skipped, rules still run).
  To get true default-deny later: patch main.go:1424 to close the
  conn when `unknown_host=deny` (the comment describes it; build the gateway from the patched
  submodule), or front egress with a separate allowlist firewall. Also unverified: whether a client
  can actually reach the Mac (`host.docker.internal` *resolves* because the resolv.conf→1.1.1.1 swap
  didn't persist; reachability untested).
- **LinuxKit / `wg-quick` (RESOLVED):** `NET_ADMIN` + `/dev/net/tun` work; the LinuxKit kernel has
  the `wireguard` module (kernel WG, no userspace fallback needed). **The `/proc/sys` gotcha is solved.**
  `/proc/sys` is mounted read-only by default, so `wg-quick`'s `Table=auto` `src_valid_mark` write fails
  → crash-loop. The temporary unblock (`security_opt: [systempaths=unconfined]`) un-masked all of `/proc`
  for the untrusted client (sysrq-trigger DoS of the whole Docker Desktop VM, kcore read of VM kernel
  memory incl. other containers' secrets) — unacceptable, **now removed**. The chosen fix brings the
  tunnel up with **`Table = off`** + a manual default route, which skips the `src_valid_mark` write
  entirely (the fwmark dance only matters for a gateway reached *over* the default route; ours is on the
  same L2). Result, validated at runtime: tunnel up, egress works, `/proc/sys` stays `ro`, the only
  `security_opt` is `no-new-privileges:true`, no re-enrollment. See PLAN Step 5.
- **NAT hairpin**: not a concern here — client→gateway is direct on the docker bridge, not behind a
  shared public NAT (the constraint that forces a public-IP VPS in remote mode doesn't apply).
- **Client reaches dashboard port** (accepted, by design): if clients ever become less trusted, the only
  way to L2-block them is pre-seeding wg.conf/ca.crt (declined) or fronting the dashboard with an auth
  proxy. Today's protection is operator approval + bcrypt root password.
- **Operator approval is manual per client**: each `join` prints a user-code to approve at
  `http://127.0.0.1:5182`.

## Suggested next steps

1. Write `compose.yaml`: `clawcage-net` (`internal: true`), `clawegress-net` (bridge); gateway on both with
   alias `gateway` on `clawcage-net`, `-p 127.0.0.1:5182:8080`, named volume at `/opt/clawpatrol`,
   `no-new-privileges`; client service template with `NET_ADMIN` + `/dev/net/tun` on `clawcage-net` only,
   plus a per-client named volume mounted at the client's home directory.
2. Author `gateway.hcl` from the sketch + endpoints/rules from
   [clawpatrol/examples/gateway.example.hcl](../oss/clawpatrol/examples/gateway.example.hcl).
3. Build a client image whose entrypoint is enrollment-aware (plain join-once + `Table = off` bring-up
   always) and runs `eval "$(clawpatrol env)"` before exec'ing the agent.
4. Bring up gateway, set the root password, `init-ca`; bring up one client, `join`, verify: client
   reaches an allowed upstream through the tunnel, is denied **direct (non-tunneled) internet** (the
   cage, not gateway egress filtering — unconfigured hosts still relay through the gateway when the
   tunnel is up; see Open questions), cannot reach the Mac, and cannot reach the dashboard on the
   docker-net path.
