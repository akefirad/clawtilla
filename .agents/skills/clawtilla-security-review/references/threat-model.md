# Threat model & first-principles networking lenses

This is the reasoning engine for the review. It is **not** a checklist — it is a
set of adversaries and a set of lenses to think *through*. The goal is to derive
whether containment holds for *this* configuration, including in ways nobody has
written down yet. The known, already-reasoned failure modes live in
[invariants.md](invariants.md); use that to avoid missing a known trap, but the
findings that matter most are the ones you reason your way to here.

## Where the unfound findings hide (lead with these)

The lenses below are generic; these are the Clawtilla-specific spots the known
AC/F/I/L/N codes under-cover — the concrete places to dig first. Trace each to the
code, not the comment:

- The actual TLS splice/passthrough branch in `oss/clawpatrol` — exactly which
  hosts get MITM'd vs. relayed, and whether `unknown_host = "deny"` (`gateway.hcl`)
  is dead config for HTTPS as N1 claims.
- The unprofiled-device fail-open as an *enforcement gap*, not a config note:
  `gateway.hcl` cites it (with a stale `main.go:1798`) — confirm an unprofiled
  device really bypasses all policy in the running stack.
- Which interfaces `dashboard_listen = "0.0.0.0:8080"` actually opens — the gateway
  is dual-homed, so this binds the **egress** bridge too, not only the cage
  (cross-check the loopback-only *publish* in compose vs. the in-app bind — N6).
- DNS and IPv6 in the *running* stack, not the design: `client.sh` forces
  `Table = off` + a manual route — verify no v6 default and no second route rides
  around the tunnel (L3).
- Whether the F1 `run` wrapper covers *every* launch path an operator would
  realistically use, or a bare/login shell drops CA trust (AC8).
- Supply-chain lockstep: the pinned `CLAWPATROL_VERSION`/SHA256s (Dockerfile) vs.
  the actual `oss/clawpatrol` submodule tag — a mismatch ships a binary whose
  behaviour differs from the code you read.
- Comment-vs-code drift: any place `gateway.hcl`/`compose.yaml` comments assert
  posture ("default-deny") that clawpatrol's real verdict logic contradicts.

## The containment chain (in depth)

Clawtilla assumes the agent is hostile and contains it with five links. Egress
*policy* is monitoring, not containment (N1) — do not mistake it for the
boundary. For each link, know what enforces it and what one change defeats it.

### Link 1 — The cage (`clawcage-net internal: true`)
- **Enforces:** agent ↛ internet and agent ↛ host. With `internal: true` Docker
  attaches no NAT/gateway to the bridge, so there is *no route off it* regardless
  of what the agent does — `NET_ADMIN` can't conjure a default gateway that
  doesn't exist.
- **Defeated by:** dropping/flipping `internal`; attaching a client to a second
  (non-internal) network; a client gaining `clawegress-net`; a static route or
  an injected `host.docker.internal`; an IPv6 path that bypasses the v4 cage.
- **Blast radius if broken:** full escape — direct internet egress and/or host
  reachability for an untrusted agent. Critical.

### Link 2 — The single chokepoint (only the gateway is dual-homed)
- **Enforces:** all egress funnels through one auditable point.
- **Defeated by:** any client joining the egress net; a third network bridging
  cage↔egress; the gateway's egress path being granted to something else.
- Note the gateway *having* full egress is by design (it is the egress point) —
  that is not a finding.

### Link 3 — Secrets stay at the gateway
- **Enforces:** the agent never holds real upstream credentials; the gateway
  injects them into in-scope requests and the agent sees only a placeholder.
- **Defeated by:** a real `CLAWPATROL_SECRET_*` in the agent's env/image/compose;
  an endpoint pulled out of scope so it's relayed un-injected with a real key the
  agent supplies; the dashboard reachable + unauthenticated so creds can be read;
  a profile change that exposes a credential the agent can echo back.
- **Subtlety:** injection only happens for *in-scope* (configured + credential-
  bound) endpoints. A host that is relayed (passthrough) gets whatever header the
  agent sends — so "secrets at the gateway" only holds for endpoints actually in
  scope. A change that moves a sensitive endpoint out of scope quietly breaks it.

### Link 4 — Gateway self-protection
- **Enforces:** a compromised gateway can't rewrite its binary, escalate, or
  reach the host; its secrets DB stays sealed.
- **Defeated by:** `read_only: false`; added caps; a host bind mount;
  `host.docker.internal`/`extra_hosts`; the dashboard published on a routable
  interface; `no-new-privileges` removed; loosened state-dir perms; running as a
  principal that can read the DB.

### Link 5 — Enrollment integrity
- **Enforces:** a new ClawBot binds to the *real* gateway CA, and only operator-
  approved devices get a profile (hence real injected creds).
- **Defeated by:** scripting/auto-approving `join` (F4) — a rogue device gets a
  profile and real creds; skipping the CA-fingerprint comparison (F2) — an
  on-path co-tenant swaps the CA during the plain-HTTP join and MITMs the new
  peer; blanket approval; a default profile that over-grants.

## Adversaries

Reason about each explicitly. For each, the question is: *given the config in
front of me, can this actor break a link?*

### A1 — Compromised agent (the baseline assumption)
Has root + `NET_ADMIN` inside a ClawBot. Wants out (internet/host), wants
secrets, wants persistence. Cannot escape **as long as the cage holds** — so its
power is entirely a function of Links 1–3. Check: any route off the cage? any
real secret reachable in env/files/process? any writable host path?

### A2 — Hostile co-tenant on the cage (N5, accepted lateral risk)
A second compromised ClawBot on the same `clawcage-net`. With `NET_ADMIN` on a
shared L2 it can ARP/ND-spoof, sniff neighbours, run rogue DNS/DHCP, and become
on-path for a peer's plain-HTTP `join`. This is *accepted* for the single-tenant
model — but the **escape boundary (Link 1) must still hold** for every tenant,
and **enrollment CA-swap (Link 5)** is the live consequence to keep verifying.
Live MITM can't be simulated here — classify it "reasoned, not demonstrated"
(verification.md). Flag if a change widens this beyond "lateral only" (e.g. lets a co-tenant reach
the host or the gateway's secrets).

### A3 — On-path attacker during enrollment
Sits between a joining client and the gateway (often = A2). `join` fetches the CA
over plain HTTP (TOFU); a swapped CA lets the attacker MITM all of the new peer's
"inspected" traffic. Defense is the manual fingerprint comparison (F2/F4). Check
the runbook/automation still forces it and that nothing auto-approves. The live
exploit can't be simulated without an on-path attacker — classify it "reasoned,
not demonstrated" (verification.md), not a demonstrated exploit nor dismissed.

### A4 — Compromised gateway
The gateway terminates TLS for in-scope endpoints and holds every upstream
credential and the WG keys — the highest-value target. Link 4 limits the damage:
immutable rootfs, no caps, no host reach, sealed DB. Check those haven't eroded.

### A5 — Malicious or compromised upstream / supply chain
The clawpatrol binary, the base image, and apt packages all enter the trust
boundary at build time. A binary not pinned by SHA, an unpinned/`latest` base
image, or `install.sh`-style fetch lets a compromised upstream ship code into the
gateway and clients. Check the Dockerfile's pinning and submodule lockstep.

## First-principles lenses

Think *through* each lens against the current config. These are how a network
engineer finds the unlisted issues.

### Docker networking
- `internal: true` = no NAT, no gateway, no off-net route. The cage's whole
  security rests on this one property — verify it on the *resolved* config and at
  runtime (`docker network inspect`), not just the YAML.
- Bridge ICC: containers on the same bridge talk freely (drives A2); `internal:
  true` only strips the off-net route, it does **not** isolate peers — see N5 for
  the `enable_icc=false` lever. A new bridge shared between cage and egress
  workloads silently bridges the boundary.
- Published ports (`-p`) expose a container port to the **host**; they are
  orthogonal to in-cage reachability. `0.0.0.0` publish = reachable from the
  Mac's LAN; `127.0.0.1` = loopback only. WG must not be published at all.
- Embedded DNS + network aliases (`gateway`) are resolvable by anyone on the net
  and **spoofable by a co-tenant with `NET_ADMIN`** — identity by alias is not
  authentication.
- `host.docker.internal` / `extra_hosts` / the Docker Desktop host-gateway are
  the host-reachability vector; their presence on the gateway breaks Link 4, on a
  client breaks Link 1.

### Linux capabilities & namespaces
- `NET_ADMIN` grants: configure interfaces and routes, iptables/nftables, raw &
  packet sockets, ARP/ND manipulation, bind transparent, modify netns settings.
  It does **not** grant a route that doesn't exist (so it can't beat the cage) but
  it fully enables L2 attacks on co-tenants and has a history of LPE/escape bugs.
- `/dev/net/tun` is needed for kernel WG; benign with `NET_ADMIN` already present.
- `no-new-privileges` blocks setuid escalation — its removal re-opens privilege
  escalation paths and should never silently disappear.
- `privileged: true`, added caps beyond `NET_ADMIN`, `systempaths=unconfined`,
  `cap_add: [SYS_ADMIN]`, or `userns` changes each materially widen the escape
  surface. `systempaths=unconfined` in particular un-masks `/proc` for the
  untrusted client → `/proc/sysrq-trigger` (VM-wide DoS) and `/proc/kcore` (read
  VM kernel memory, incl. other containers' secrets). This was explicitly removed
  once; its return is a High-severity regression.

### WireGuard / transport
- Gateway runs **userspace** WG (wireguard-go + gVisor netstack) — the binary is
  the endpoint, so it needs **no** caps. Clients run **kernel** WG via `wg-quick`.
- `Table = off` + a manual default route is deliberate: it avoids `wg-quick`'s
  `Table=auto` `src_valid_mark` write, which fails on Docker's read-only
  `/proc/sys`. A change to `Table=auto` / `--whole-machine` reintroduces the
  crash-loop *or* tempts a `systempaths=unconfined` "fix" (see above).
- `AllowedIPs` and the routing table decide what actually traverses the tunnel.
  Anything routed *around* the tunnel (a leftover direct route, a second
  interface, an IPv6 default) is egress that escapes inspection — and, if the
  cage is the only boundary, may not escape it but does dodge the gateway log.
- The WG handshake to `gateway:51820` rides the connected cage route (same L2),
  which is why no fwmark dance is needed.

### TLS interception & trust
- The gateway MITMs **only in-scope endpoints** using its CA; everything else is
  relayed with the real upstream cert. So "the gateway inspects traffic" is true
  only for configured endpoints — a relayed host is opaque to policy by design.
- **Agent-chosen protocol/port/SNI — the inspected set is dodgeable.** The agent
  controls its own TLS client, and the MITM-vs-splice decision is made on
  attacker-influenced inputs. Both edges below are *policy bypass for in-scope
  hosts*, not cage escape (relayed hosts are opaque by design — N1):
  - **Port downgrade.** The WG forwarder dispatches by destination port and only
    `:443` runs the SNI-peek MITM path; other ports fall through to a raw relay. An
    in-scope host reached on plaintext `:80` (or any non-443 port) is relayed
    un-inspected — the rule engine never sees it.
  - **SNI selection.** On `:443` the endpoint (hence MITM-vs-splice) is keyed on
    the SNI the agent put in its ClientHello, not the connect target — a
    non-matching SNI hits splice (relayed un-decrypted).
  - **Verify in `oss/clawpatrol` (needs-submodule-verification):** whether the
    deployed flow takes the SNI-keyed `:443` path or a DNS-VIP path keyed on the
    gateway-allocated VIP (not SNI-spoofable); whether ALPN/h2 is pinned (an
    unparsed protocol should fail closed, not bypass). A confirmed un-inspected
    in-scope flow is a real bypass of the inspected set, scaled to what the endpoint
    exposes; it does **not** break the cage.
- The client trusts the gateway CA via the **system store** (installed by
  `client.sh`) and, for Node/Python, via `NODE_EXTRA_CA_CERTS`/`REQUESTS_CA_BUNDLE`
  set by the `run` wrapper. A tool that uses none of these won't trust the MITM CA
  (the request just fails) — not a hole *on its own*. But reason one step further —
  **the operator-fix trap.** When CA-trust or placeholder wiring silently fails
  (e.g. the agent is exec'd directly instead of via the `run` wrapper, so it gets no
  `NODE_EXTRA_CA_CERTS`/`REQUESTS_CA_BUNDLE` and no placeholder token — F1/AC8), the
  predictable operator "fix" is catastrophic: paste a real API key into the
  container (breaks Link 3 — secrets at the gateway) or set
  `NODE_TLS_REJECT_UNAUTHORIZED=0` / `verify=False` (defeats the MITM integrity
  inspection rests on). Rate the wiring bug by the link the workaround defeats, not
  as a functional glitch. This is narrower than "all TLS": `client.sh` installs the
  CA into the system store unconditionally, so OS-trust tools (git, plain curl, Go)
  still work — the exposed surface is the env-bundle (Node/Python) and the
  placeholder-token path the `run` wrapper owns. The *other* direction still matters
  too: an over-broad CA trust, or the CA bootstrapped insecurely (Link 5).

### Routing, DNS, and leaks
- Default route via the tunnel is what forces traffic through the gateway. A
  client with a default route on the cage interface (not the tunnel) relays
  nothing — but recall the cage has no off-net route, so the failure mode is
  usually "no egress" rather than "uninspected egress." The dangerous version is a
  *second* route/interface that does reach off-net.
- IPv6 is the classic leak: a v6 default route that isn't via the tunnel (L3) is
  an egress path the v4 cage analysis misses. Always check v6 separately.
- A swapped/forwarded `resolv.conf` changes what resolves and through which path;
  reachability must be tested by connection, not by name resolution (a name can
  resolve while being unreachable, and vice versa).
- The agent controls its own resolver (root + `NET_ADMIN`), but for in-scope HTTPS
  endpoints this does **not** create a DNS-rebinding/TOCTOU bypass — and knowing
  *why* is the review point: clawpatrol keys the endpoint/rule decision on the SNI
  hostname in the agent's own ClientHello, then dials upstream by that same name,
  re-resolved with the gateway's own resolver. The agent's chosen dst IP never
  enters the decision or the upstream connection, so there's no
  resolve→decide→connect window to poison. The genuine residual is the reverse: the
  agent fully controls the SNI string, so policy is only as strong as the
  host-string match — confirm wildcard/exact-match handling and that there's no
  SNI-vs-`Host`/`:authority` split. (A resolve-then-index dst-IP path *would* be
  TOCTOU-prone — raw-conn families like postgres — but none is declared in
  `gateway.hcl`; flag only if such an endpoint is added.)
- Link-local / metadata IPs are an SSRF reflex, not a separate escape class here:
  cloud IMDS (`169.254.169.254`, `fd00:ec2::254`) is N/A on Docker Desktop/macOS,
  and `169.254.0.0/16` is unrouted on the `internal: true` cage exactly like any
  other off-cage IP (already covered by AC2's raw-IP probe). Still worth a concrete
  probe — a compromised agent *will* try them, and a successful connection means a
  second interface or injected route (a cage break), not link-local magic. The
  host-gateway (`host.docker.internal`) is the one real host-reachability vector
  (AC3/L2).

### Supply chain & build
- Pin the clawpatrol binary by **version + SHA256**, keep the submodule tag in
  lockstep, pin the base image by digest/tag. Verify nothing fetches `latest` or
  pipes a remote `install.sh` into a shell. A dropped SHA check is a real
  supply-chain regression even though nothing "looks" broken at runtime.
- Watch for secrets entering image layers (a `COPY` of a key, a build-arg secret
  baked into a layer, a `.env` committed).
