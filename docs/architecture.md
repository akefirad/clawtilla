# Clawtilla — architecture

The architecture of record for Clawtilla, as built and validated. For the design
deliberation and full rationale (with `stack/clawpatrol` source citations) see the
archived [discovery](./archive/discovery.md) and [plan](./archive/plan.md); for the
normative requirements and the test harness see [`tests/`](../tests/).

## What it is

Clawtilla runs untrusted AI agents (**ClawBots**) sealed on an internal Docker
network with exactly one way out: a [clawpatrol](https://github.com/denoland/clawpatrol)
gateway. Every connection an agent opens is dragged through the gateway, weighed
against per-endpoint policy, logged, and — for configured endpoints — handed real
upstream credentials the agent never holds. The security value is the **network
boundary**, and the boundary is assumed to hold even when an agent is fully
compromised. clawpatrol is the substance (gateway, WireGuard, TLS inspection,
policy, credential injection); Clawtilla is the Docker Compose glue that wires it
into a single-host cage.

It targets **one macOS / Docker Desktop host** (engine in a LinuxKit VM),
single-tenant. It is **not** multi-host, **not** a process/kernel sandbox (that is
the container runtime's job — this secures the *network*), and **not** hardened
against a hostile co-tenant on the agent network.

## Topology

```
                 clawegress-net (bridge, NAT → internet)   ← gateway ONLY
                      │
                 ┌────┴─────┐
   internet ◄────┤ GATEWAY  ├── dashboard :8080  → published 127.0.0.1:5182 on the Mac
                 │ container│                       (bound 0.0.0.0 in-app; clients also
                 │          │                        reach :8080 over clawcage-net for join/CA)
                 └────┬─────┘── WireGuard :51820/udp  (NOT published; reached only over the cage)
                      │
                  clawcage-net  (internal: true — no NAT, no gateway, no host route)
                 ┌────┼────┬────┐
              ClawBot ClawBot … ClawBot   (attached ONLY to clawcage-net; cap NET_ADMIN + /dev/net/tun)
```

The gateway is the only dual-homed container. ClawBots are single-homed on
`clawcage-net`; their default route goes through the WireGuard tunnel to the
gateway, which is also their only L2 neighbour with a route off-net.

## The containment model

Security does **not** come from the gateway's egress policy — that is monitor +
per-endpoint policy, not a default-deny allowlist. Containment is a chain of five
links; it holds only if every link holds.

1. **The cage.** `clawcage-net` is `internal: true`, so Docker attaches no
   NAT/gateway and there is no route off it. This single primitive blocks
   agent→internet and agent→host regardless of what the agent does (`NET_ADMIN`
   cannot conjure a route that doesn't exist). **It is the load-bearing boundary.**
2. **The single chokepoint.** Only the gateway is dual-homed (cage + egress), so
   all egress funnels through one auditable point.
3. **Secrets stay at the gateway.** Real upstream credentials live at the gateway
   and are injected into in-scope requests; the agent only ever holds a placeholder
   token (validated: the gateway adds `Authorization` when the agent sends none and
   overwrites a client-supplied one).
4. **Gateway self-protection.** Read-only rootfs (`tmpfs: [/tmp]`), no added
   capabilities (userspace WireGuard needs none), no host bind mounts, no
   `host.docker.internal`, dashboard published to loopback only, named volumes,
   `no-new-privileges`, state-dir tightened to `0700`.
5. **Enrollment integrity.** `join` bootstraps the CA over plain HTTP (TOFU);
   the defense is *manual, fingerprint-verified* operator approval — the operator
   compares the CLI-printed CA fingerprint against the dashboard before approving.

**Egress is monitor-only.** clawpatrol relays (splices) any HTTPS host not bound to
a configured endpoint — `unknown_host = "deny"` is dead config for that path. The
gateway gives *visibility + per-endpoint policy + credential injection* for
configured endpoints; the **cage**, not a gateway allowlist, is what contains the
fleet. The per-endpoint rule engine itself is real (allowed verb → 200, denied verb
→ clean 403). Three rules to respect when authoring policy — each fails *open*:
(1) a device with **no profile bypasses all policy**, so every ClawBot must be
assigned a profile; (2) an endpoint is only in scope (MITM'd + rule-evaluated) if
a profile reaches it via the transitive closure profile → credential → endpoint —
a bare `endpoint` + `rule` bound to no profile is **dead config**, relayed not
policed; and (3) an in-scope endpoint **fails open on no-rule-match** (clawpatrol
denies only on an explicit `deny` verdict), so every `endpoint` with an `allow`
rule needs a lowest-priority catch-all `deny`. *(Verified still true in v0.5.1:
the HTTPS path takes `MatchRequest` → nil-on-no-match, and `main.go` denies only
when `cr.Outcome.Verdict == "deny"`. The v0.2.5 "viral CEL unknowns" change
(#633) added fail-**closed** behaviour only for requests clawpatrol could not
honestly evaluate — bytes truncated at the inspection buffer or unparseable, which
synthesize a deny — and the HTTPS path deliberately skips `MatchRequestFailClosed`.
So a fully-inspected, in-scope, no-rule-match HTTPS request still fails open; the
catch-all `deny` remains mandatory.)*

## Where the load-bearing pieces live

- [`stack/compose.yaml`](../stack/compose.yaml) — networks (`clawcage-net
  internal: true` is the cage wall), service topology, caps (`NET_ADMIN` +
  `/dev/net/tun` on clients only), `security_opt`, ports (`127.0.0.1:5182:8080`
  loopback dashboard; WireGuard not published), named volumes, and the committed
  `CLAWPATROL_SECRET_ECHO_DUMMY` *test* secret.
- [`stack/Dockerfile`](../stack/Dockerfile) — multi-stage `base` → `gateway` /
  `client`. The clawpatrol binary is pinned by version **and** SHA256 and verified
  at build (`sha256sum -c`); the gateway stage adds no caps (userspace WG), the
  client stage adds the WireGuard + diagnostic tooling and carries no `USER` line.
- [`stack/gateway.hcl`](../stack/gateway.hcl) — policy: `dashboard_listen`,
  WireGuard subnet/endpoint, `defaults` (`unknown_host`, `llm_fail_mode`),
  endpoints + allow/deny rules + the `default` profile. Edited by rebuilding the
  image (baked in — no host bind mount).
- [`stack/gateway.sh`](../stack/gateway.sh) — gateway entrypoint: `chmod 700` the
  state-dir mountpoint, then exec clawpatrol.
- [`stack/client.sh`](../stack/client.sh) — client entrypoint: enrollment-aware
  (join once, bring the tunnel up always), install the CA into the system trust
  store, bring the tunnel up with `Table = off` + a manual default route.
- [`stack/clawpatrol`](../stack/clawpatrol) — the gateway source, vendored as a
  git submodule (`origin` = the fork `akefirad/clawpatrol`; add a `denoland`
  `upstream` remote locally to pull releases — `.gitmodules` only records
  `origin`, so a fresh `submodule update --init` won't have it) and **compiled
  into the image** by the Dockerfile's builder stage (src-local).
  **The real enforcement logic (verdict/splice, `unknown_host` handling,
  credential injection, auth) lives here, not in the stack** — verify mechanism
  claims against this source.

## Key decisions

Condensed; full rationale and source citations in the archived
[discovery](./archive/discovery.md) and [plan](./archive/plan.md).

- **WireGuard, not Tailscale.** Tailscale needs internet to reach its control
  plane + DERP relays, which breaks the cage; WireGuard + a Docker DNS alias
  (`gateway`) is a direct one-hop link with no discovery problem.
- **Plain `join` + `Table = off` + a manual default route** (not
  `--whole-machine`). `--whole-machine`'s `wg-quick` bring-up (`Table=auto`) writes
  `net.ipv4.conf.all.src_valid_mark`, which fails on Docker's read-only
  `/proc/sys` → crash-loop. `Table = off` skips that write (the gateway is on the
  same L2, so no fwmark dance is needed) and keeps `/proc/sys` read-only — avoiding
  the `systempaths=unconfined` "fix" that would un-mask `/proc` to the untrusted
  client (sysrq-trigger VM DoS, `kcore` kernel-memory read).
- **CA installed by the entrypoint**, with `join --no-trust`. clawpatrol's own
  `installCATrust` shells out to `sudo`, which `no-new-privileges` refuses; the
  entrypoint installs the CA into the system store itself.
- **Agent env via a `run` wrapper** (`eval "$(clawpatrol env)"`). Plain `join`
  wires no shell rc (that is `--whole-machine` only), so the wrapper supplies the
  CA-bundle + placeholder-token vars before exec'ing the agent. It then widens the
  CA bundle from gateway-only to the system store (gateway CA + public roots) so
  tools also work against relayed hosts (see **CA trust for relayed hosts** below).
- **Monitor + per-endpoint policy, not default-deny egress** (see containment
  model above). Accepted; the cage is the boundary.
- **Manual, fingerprint-verified enrollment.** No WG `--auto-approve` exists;
  approval is mandatory and must bind to a verified per-client identity — a
  rogue/auto-approved device gets a profile and real injected credentials.
  *(v0.5.1: confirmed — clawpatrol's `autoApprove` is opt-in to the Tailscale
  `--login` bootstrap path only (`setup.go`: "auto-approve unexpected status…"
  only after a tsnet whois the gateway trusts); our plain WG `join` never takes
  it, so approval stays a manual operator action. v0.2.7/v0.2.8 also added
  profile assignment at approval time — the `--profile` join flag and the
  approver's pick — which reinforces "every ClawBot must get a profile". The
  join CLI now prints the CA fingerprint on its own line under a "confirm this
  matches the dashboard" prompt; the harness parses it as colon-hex.)*
- **Agent runs as root + `NET_ADMIN` (v1).** PID 1 needs the caps for tunnel
  bring-up; the agent does not but is kept root for v1. A cost trade-off, not a
  safety claim — residual escape risk is bounded by the cage + the VM boundary +
  `no-new-privileges`.
- **Gateway hardened** — read-only rootfs, no caps, loopback-only dashboard,
  named volumes (no host binds).

## CA trust for relayed hosts

The `run` wrapper makes the agent trust the gateway CA **and** the public root CAs.
This is deliberate — and it took a wrong default to get here.

**The issue.** `clawpatrol env` (which the wrapper `eval`s) points the CA-bundle
variables — `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `CURL_CA_BUNDLE`, `PIP_CERT`,
`DENO_CERT`, `AWS_CA_BUNDLE`, `GIT_SSL_CAINFO` — at a file holding **only the
gateway CA**, on the assumption that every upstream is MITM'd. But the gateway
MITMs only the *allowlisted* hosts and **relays** (splices) everything else (N1),
and a relayed host presents its **real** certificate. A tool that treats those
variables as a *replacement* trust store therefore rejects every relayed host:
`uv python install`, for instance, fetches CPython from `github.com` (allowlisted,
MITM'd → gateway cert, fine) but follows a redirect to
`release-assets.githubusercontent.com` (not allowlisted → relayed → real Let's
Encrypt cert) and dies with `invalid peer certificate: UnknownIssuer`. It is not
tool-specific — pip, `requests`, deno, aws-cli, git all hit it. (Node's
`NODE_EXTRA_CA_CERTS` is *additive* to its built-in roots, so Node is immune; curl
falls back to its CA *path*, so it limps along — which is why the bug hides from a
quick `curl` test.)

**Options.**

- **A — trust the gateway CA + the public roots.** Point the replace-style bundle
  variables at the system trust store (`/etc/ssl/certs/ca-certificates.crt`), which
  `client.sh` already seeds with the gateway CA *and* the public roots (it runs
  `update-ca-certificates`). One change in the `run` wrapper fixes every current
  and future tool.
- **B — keep gateway-only trust, allowlist each host.** Add every host each tool
  needs to `gateway.hcl` so it is MITM'd. Whack-a-mole (python-build-standalone,
  pypi + pythonhosted, npm, crates, apt, …); "curate forever", and it MITMs large
  public binary downloads for no gain.
- **C — true allowlist-only egress.** If the goal is to *block* unlisted hosts, do
  it at the network layer — an egress firewall in front of the gateway, or a relay
  deny-list (see F1/N1) — not via CA rejection, which is leaky (curl / `-k` bypass
  it) and breaks tools confusingly. A separate posture change.

**Decision: A.** It matches this stack's posture — egress is monitor + per-endpoint
policy, the cage is the boundary, and relayed hosts are *reachable* by design (N1).
Gateway-only trust never enforced an egress boundary (it is trivially bypassed), so
widening it to the public roots removes confusing breakage without weakening
anything real: the cage still gates egress, allowlisted hosts still validate against
the gateway CA (which is in the system store), and **credential injection is
untouched** — real secrets are injected gateway-side and never reach the agent. If
you want unlisted hosts actually *blocked*, that is Option C, not this. Implemented
in [`stack/Dockerfile`](../stack/Dockerfile)'s `run` wrapper, on by default. Set
`CLAWTILLA_TRUST_PUBLIC_CAS=0` to keep strict gateway-only trust for a locked-down
ClawBot — at build (`--build-arg`, baked as the image default via `ARG`/`ENV`) or
at runtime (compose `environment:` / `exec -e`, which overrides the baked default).
Strict mode binds only tools that honor `SSL_CERT_FILE`/`*_CA_BUNDLE` strictly
(uv/rustls, pip, requests, aws); curl falls back to the system store regardless, so
it is best-effort friction, not a hard egress block (that is Option C).

## Accepted risks & non-goals

Deliberately accepted, documented limitations (the **N-nodes**; the *enforced half*
beside each is what the harness checks):

- **N1** — egress is monitor-only, not default-deny (containment is the cage).
- **N2** — gateway → host is best-effort only (Docker Desktop); the gateway has
  real egress by design and can reach the Mac via the host-gateway.
- **N3** — clients can reach the dashboard port (required for self-service join);
  protection is the bcrypt root password + the approval gate. *Caveat (review F3):*
  before first-run there is **no** password and clawpatrol's setup form is open to
  anyone reaching `:8080`, so a ClawBot started before the password is set can
  claim root (the approval gate + credential APIs). Bounded to Medium/Low — root
  cannot read connected secrets (set/clear only), cannot edit the baked-in policy,
  and stays caged; lockout is loud and recoverable via `--reset-dashboard-password`.
  Mitigated by ordering: bring the gateway up and set the password **before any
  ClawBot starts** (a client-free bootstrap — see the README quick start).
- **N4** — manual per-client approval (no WG auto-approve).
- **N5** — client ↔ client lateral access is open (single-tenant assumption);
  `NET_ADMIN` on a shared L2 permits ARP/ND spoofing and sniffing between peers.
- **N6** — `dashboard_listen = 0.0.0.0` is intentional; the in-tunnel forwarder
  dispatches the dashboard by port number, so rebinding breaks enrollment without
  locking enrolled clients out.

**Non-goals** (not findings): not multi-host/distributed; not a code-execution /
kernel-escape sandbox (the network is the boundary); not hardened against a
hostile co-tenant.

## Reviewed residual findings

An external adversarial network review ([`review.md`](./review.md)) checked these
guarantees against the `stack/clawpatrol` source. Beyond the accepted N-nodes it
also flagged the following; this is the repo's disposition:

- **F1 (open)** — the WireGuard relay is promiscuous: it forwards agent traffic to
  the raw destination IP, so the agent inherits whatever the *gateway* can reach —
  the host-gateway, RFC1918 neighbours on the egress net, or cloud metadata
  (`169.254.169.254`). "No host reachability" is therefore **direct-only**; the
  indirect reach via the relay is bounded by N2 on Docker Desktop and is a genuine
  exposure on a cloud/Linux deploy (a non-target). A fix needs a destination
  deny-list in the relay (upstream) or an egress firewall in front of the gateway.
- **F2 (open)** — DNS escapes containment: tunneled DNS content is not run through
  the rule engine, and a malicious agent can query Docker's `127.0.0.11` embedded
  resolver directly, bypassing the gateway entirely. A low-bandwidth exfil / C2
  channel. (The `127.0.0.11`-bypass half is now confirmed live: the v0.5.1
  runtime suite's R-GAP-DNS resolved `example.com` off-tunnel via `127.0.0.11`.)
- **F3 (mitigated — runbook)** — first-run dashboard-password claim; see N3.
- **F4 (fixed)** — the stack advertised a read-only GitHub allowlist (`ghapi`)
  that was never bound into a profile, so `api.github.com` was relayed, not policed
  (dead config). Removed; the policy fail-open footguns are now documented above
  and inline in `gateway.hcl`.

## Status

v0, built from the `stack/clawpatrol` submodule (fork `akefirad/clawpatrol`).
clawpatrol is **compiled from source** in the Dockerfile rather than downloaded:
the default `src-local` mode builds the vendored submodule working tree as-is
(so a local edit → rebuild needs no push), while `src-remote`
(`--build-arg CLAWPATROL_SRC=src-remote`) clones `CLAWPATROL_REPO`@`CLAWPATROL_REF`
for template/CI/release builds. There is no binary SHA to keep in lockstep any
more; the image simply contains whatever the submodule (or the pinned ref) builds.
The network security posture is reviewed by
the [`clawtilla-security-review`](../.claude/skills/clawtilla-security-review/)
skill; the runnable test suites live in [`tests/`](../tests/).

The `v0.2.4 → v0.2.12` bump was validated end-to-end on Docker Desktop (static +
build + runtime: 0 failures; only the documented F2/F6 XFAILs and the
config-variant SKIPs). The only stack-relevant change in the eight intervening
releases that the boundary depends on was cosmetic — the `join` CLI moved the CA
fingerprint to its own line (harness parser updated). `gateway.hcl` gained
`schema_version = 1` (clawpatrol now versions the grammar; omitting it loads as
legacy v0 with a deprecation warning) and an explicit `wireguard.listen_port =
51820` (v0.2.6 began honouring it instead of always binding 51820 — pinned equal
to the advertised endpoint port so the two can't drift). Upstream also now
documents egress interception as "best-effort" (v0.2.11), which matches this
repo's long-standing N1/F1 framing — the cage, not the gateway, is the boundary.

The subsequent `v0.2.12 → v0.3.2` bump (three releases, crossing the `0.3` minor)
was likewise validated end-to-end on Docker Desktop (static + build + runtime:
0 failures; only the same documented F2/F6 XFAILs and config-variant SKIPs). The
`0.3` line is dominated by a new external-plugin subsystem (`extplugin`) that is
**inert with no `plugin` blocks** — no new listener, socket, subprocess, or
default egress — plus relay/seccomp/nsswitch fixes scoped to `clawpatrol run`,
which this stack never invokes (it uses `join` + `clawpatrol env`). No
`gateway.hcl` change was required: the `schema_version` window is unchanged
(`0..1`; pin stays `1`) and every config construct this stack uses is
byte-identical. The N1 splice (`ep == nil → splice`), unprofiled fail-open
(`profileFor → defaultProfileName`), and `bearer_token` add/overwrite injection
were re-verified against the v0.3.2 source and all hold. The one genuinely new
applicable feature — opt-in OTel GenAI telemetry (`genai_telemetry {}`) — was
deliberately not adopted: it adds a new egress destination and, with
`include_message_content`, routes raw prompts/completions off-box (both off by
default), and buys nothing for this minimal stack with no collector.

The subsequent `v0.3.2 → v0.5.1` bump (four releases, crossing `0.3 → 0.4 → 0.5`)
was likewise validated end-to-end on Docker Desktop (static + build + runtime:
0 failures; only the documented F2/F6 XFAILs and config-variant SKIPs). Despite
the two minor bumps, the changes are dominated by GenAI/Codex telemetry, the
`extplugin` subsystem (still inert without `plugin` blocks), and dashboard UI —
none of which this stack uses. No `gateway.hcl` change was required: the
`schema_version` window is still `0..1` (pin stays `1`) and every config construct
this stack uses is byte-identical. The N1 splice, unprofiled fail-open, and
`bearer_token` injection were re-verified against the v0.5.1 source and hold, and
`clawpatrol env` + `join` are byte-identical; the new Codex telemetry splice
(`codexSpliceOutput`) is observe-only (feeds the GenAI span, gated on
`genai_telemetry`) and does not alter the agent's response. OTel remains opt-in
and unadopted.
