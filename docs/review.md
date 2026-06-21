# Clawtilla — adversarial security review (network)

Independent security review of the Clawtilla solution: untrusted AI agents
(**ClawBots**) run on a single Docker host behind a [clawpatrol](https://github.com/denoland/clawpatrol)
gateway acting as firewall / forward proxy / credential vault. This report
consolidates two independent review passes against the same tree.

- **Scope:** the deployable glue — `stack/compose.yaml`, `stack/Dockerfile`,
  `stack/gateway.hcl`, `stack/gateway.sh`, `stack/client.sh` — plus the
  `tests/` harnesses and the design docs. The pinned `oss/clawpatrol` source is
  used **only** to verify Clawtilla's mechanism claims and the security
  *consequences of how Clawtilla composes clawpatrol*; auditing clawpatrol itself
  is out of scope.
- **Ground rule:** a clearly-stated accepted risk (N1–N6, the root-agent
  trade-off, the non-goals) is **not** reported as a finding unless it chains
  into a distinct new weakness, or the mitigation the design relies on does not
  actually hold. Three findings below are exactly such chains.
- **Method:** every load-bearing claim was checked against source rather than
  taken from the docs. File:line references point at the pinned submodule.

---

## Summary of findings

| ID | Finding | Severity |
|----|---------|----------|
| **F1** | Agents can proxy to host / private / metadata addresses through the gateway's promiscuous relay | **High** |
| **F2** | DNS resolution escapes both the cage and the gateway (unmonitored exfil / C2) | **High** |
| **F3** | First-run dashboard password can be claimed from the agent network | **Medium** (runbook-closable) |
| **F4** | Shipped policy advertises stronger enforcement than it applies (dead rule, misleading comment, no in-scope default-deny) | **Medium** |
| **F5** | Public onboarding endpoint is an unauthenticated gateway DoS vector | **Low / Medium** |
| **F6** | Credential injection is observable through header-reflecting upstreams | **Low / Medium** |
| **F7** | Supply-chain pinning is partial (apt packages unpinned) | **Low / Info** |
| **F8** | Secret-via-env pattern demonstrated in the committed Compose file | **Low / Info** |

Plus test/assurance observations (T1–T3) and a list of what is genuinely solid.

---

## Findings

### F1 — Agents can proxy to host / private / metadata addresses through the gateway — High

The cage is real at the Docker-network layer: `clawcage-net` is `internal: true`
(`stack/compose.yaml:8`), which matches Docker's "externally isolated network"
semantics — no NAT, no gateway, no host route, and `NET_ADMIN` cannot conjure
one. That blocks the agent's *direct* egress and host access.

But once the WireGuard tunnel is up, the gateway's forwarder is **promiscuous**:
the client's default route is `dev clawpatrol` with `AllowedIPs = 0.0.0.0/0`
(`oss/clawpatrol/cmd/clawpatrol/wireguard.go:850`), so the agent can emit raw
packets to **any IP on any port**, and the forwarder relays everything that is
not a special port straight to the requested destination:

- dispatch: `…else → g.wgRelay(c, dstIP, int(dstPort))` (`main.go:3024`), after a
  log line that literally advertises "any dst → … else=relay" (`main.go:3037`).
- relay: `wgRelay` dials the **raw destination IP:port** with
  `net.DialTimeout("tcp", net.JoinHostPort(dstIP, …))` (`main.go:3397`,
  `main.go:3405`) — no RFC1918 / loopback / link-local / host-gateway / metadata
  filter, no SNI or hostname required.

Because the gateway is dual-homed and (per accepted risk **N2**) can reach the
Docker host, this turns "gateway → host is best-effort" into an
**agent-accessible** path to any host, RFC1918 service on `clawegress-net`,
loopback service, or — on a cloud/Linux deployment — the `169.254.169.254`
metadata endpoint, none of which the cage permits directly. This is a
confused-deputy SSRF: the cage stops direct host access; the relay hands it back
indirectly.

This conflicts with the README's headline "No reach into your host"
(`README.md:7`). N2 is scoped to *the gateway* reaching the host; the new fact is
that the *untrusted agent* inherits that reach through the relay. On Docker
Desktop the blast radius is the Mac (any service bound to the host-gateway IP, on
any port) and co-resident containers on `clawegress-net`; on a cloud VM it is
metadata-credential theft.

**Recommendation:** add gateway egress ACLs that block the host-gateway, RFC1918,
link-local (incl. `169.254.0.0/16`), and loopback ranges except for explicitly
configured endpoints — i.e. give `wgRelay`/the dialer a destination deny-list —
or implement true default-deny relay behavior. Failing that, front
`clawegress-net` with an egress firewall and re-word the README so the
host-unreachability guarantee is stated as *direct-only / best-effort*, matching
N2.

### F2 — DNS resolution escapes the cage and the gateway — High

Name resolution is not contained, and it is not covered by N1 (which governs only
traffic that *reaches the gateway*).

The generated client conf has no `DNS =` line and swaps `/etc/resolv.conf` to
public resolvers via PostUp (`wireguard.go:844`), so the intended path is DNS →
`1.1.1.1` over the tunnel; in WG mode the gateway does handle UDP/53
(`main.go:3027-3033`). Two problems remain:

1. **Tunneled DNS is an uninspected exfil/C2 channel.** Arbitrary-domain
   resolution must work for the relay model, so an agent resolving
   `<stolen-data>.attacker.com` delivers that data to the attacker's
   authoritative server. The README's "written to the log" / "every connection
   dragged through the gateway" is weak here: DNS content is not in the
   per-endpoint rule engine.
2. **The agent can bypass the gateway entirely.** A malicious agent need not
   honor `/etc/resolv.conf`; it can query Docker's embedded resolver at
   `127.0.0.11` directly. That DNAT lives in the container netns (unaffected by
   the default-route change) and the daemon forwards external queries **in the
   host netns**, resolving public names regardless of `internal: true`. That path
   touches neither the tunnel nor clawpatrol.

This undercuts "no direct internet … no quiet escape hatch." Low bandwidth, but
sufficient for secret exfiltration and beaconing — exactly the advertised threat
model. Neither test suite probes DNS at all (the cage tests only exercise TCP
HTTP/HTTPS).

**Recommendation:** filter UDP/53 at the cage (fold DNS into the same egress
control as F1), or force agents through a controlled resolver whose queries the
gateway logs/policies. At minimum, test whether `127.0.0.11` resolves external
names in the target environment and document the result in the threat model.

### F3 — First-run dashboard password can be claimed from the agent network — Medium (runbook-closable)

Clients can reach the dashboard port on `clawcage-net` by design (accepted **N3**,
required for self-service join), and `/__login` is public (`web.go:260`). N3 says
the protection is "the bcrypt root password + the approval gate" — but **before
first-run setup there is no password**, and the first-run flow lets *anyone who
reaches `:8080`* create the root user by POSTing matching password fields
(`web.go:430`, `web.go:454`). Upstream treats this as benign because it assumes
the dashboard is isolated — its docs say the first request "from anywhere" sets
the password (`oss/clawpatrol/site/doc/security-model.md:175`); in Clawtilla
"anywhere" includes the untrusted agent network.

**What the attacker actually gains (not the empty UI).** At takeover the dashboard
is empty, so there is nothing to steal *then*. The real prize is the root
password's two standing authorities: (1) the **enrollment-approval gate** —
`POST /api/onboard/approve?code=…&profile=<name>` lets the holder approve any
device into any profile, i.e. self-approve a rogue ClawBot and receive whatever
real credentials that profile later binds (this is the gate N4/F-policy call
load-bearing); and (2) the **credential-connection surface** going forward. So
the risk is seizing the chokepoint's admin authority, not owning an empty page.

**Why it is Medium, not High.** Exploitation requires a conjunction, all inside a
one-time window:

- the gateway is up with **no password set yet** (first deployment only — the
  password persists on the state volume, so reboots under `restart:
  unless-stopped` never reopen the window); **and**
- attacker-controlled code is **executing inside a cage container**. With a
  trusted client image this only happens once the operator launches the agent
  (normally `docker compose exec … run <agent>`); the client entrypoint itself is
  benign and ends in `sleep infinity`. (Note: the trigger is *any* execution on
  the cage that can `curl http://gateway:8080/__login` over plain HTTP — not
  specifically the `run` wrapper, which only supplies CA/token env. A
  **malicious client image** collapses this into the entrypoint, needing no
  operator `run` — but that is the supply-chain threat, see F7.)

The takeover is also **loud and recoverable**: the operator can no longer log in
with their own password (immediate signal), and `--reset-dashboard-password`
(host/Docker access, which the operator has) recovers it. No test exercises the
window (R-ENR-5 only checks password length ≥ 12).

**Disposition — closable by runbook.** Because untrusted code runs only on
explicit `exec` and the window never reopens, an **explicit ordering line** —
*"set the dashboard password (and complete onboarding) before bringing up or
exec'ing any agent"* — breaks the precondition chain and converts F3 from a
finding into a documented accepted risk (consistent with this review's ground
rule on stated limitations). The close is *procedural, not structural*: a
poisoned client image is the one shape the runbook line only partially helps.

**Recommendation.** Add the runbook ordering line (sufficient to close F3 for a
trusted image). For defense-in-depth that makes it structurally impossible,
pre-seed the password before the cage-facing socket serves (set it
non-interactively via `--set-dashboard-password` at provision, or only allow the
first-run flow on the loopback publish `127.0.0.1:5182`).

### F4 — Shipped policy advertises stronger enforcement than it applies — Medium

The committed `stack/gateway.hcl` reads like a default-deny allowlist; the
enforced behavior is weaker on three counts.

1. **Misleading comment.** `unknown_host = "deny"` is annotated as a
   "default-deny posture" (`stack/gateway.hcl:20`), but it is dead config for
   HTTPS — the unbound-host path hardcodes passthrough (`main.go:1424-1429`,
   confirmed; the cage, not this setting, is the boundary). The comment should
   say so at the point of use, not only in the design docs.
2. **Dead allow rule (`ghapi`).** `endpoint "https" "ghapi"` + `rule
   "ghapi-reads"` (`stack/gateway.hcl:25`, `:31`) look like a GitHub
   read-only allowlist, but `ghapi` is never bound into the `default` profile —
   only `echo-dummy` is (`:67`). clawpatrol compiles endpoint membership as the
   transitive closure `profile → credential → endpoint`
   (`oss/clawpatrol/internal/config/compile.go:337`, `:352-357`), so
   `api.github.com` is out of scope and gets **spliced (relayed), not
   rule-evaluated**. An operator would reasonably believe GitHub access is
   verb-restricted when it is only monitored. (The verification suite surfaces
   this as the `R-GAP-DEADRULE` XFAIL in `tests/static/30_hcl.sh` — asserting the
   desired invariant, "every endpoint with an allow rule is bound by a
   credential", rather than burying it in a skip.)
3. **No in-scope default-deny.** Even for an in-scope endpoint, a request that
   matches no rule is not denied — `MatchRequest` returns nil and the request
   proceeds unless an explicit deny rule exists (`dispatch.go:88`). The shipped
   `echo` endpoint has a catch-all deny (`echo-default`, priority -100), but the
   pattern is a footgun: any future endpoint added without a catch-all deny
   silently fails open on unmatched verbs/paths.

**Recommendation:** fix the stack — bind every rule-targeted endpoint into a
profile via a credential, give every in-scope endpoint an explicit catch-all
deny, and correct the `unknown_host` comment. Add a config lint that flags
rule-targeted endpoints unreachable by any profile and in-scope endpoints with no
terminal deny.

### F5 — Public onboarding endpoint is an unauthenticated DoS vector — Low / Medium

`/api/onboard/start` is `authPublic` (`web.go:247`) and reachable from the cage
(required for self-service join). Each call allocates two map entries
(`byDevice`, `byUser`) under lock (`onboard.go:438-449`); the only reclamation is
a 10-minute GC (`onboard.go:466-474`) with **no global cap and no rate limit**. A
single compromised agent can flood `start` from the cage and grow gateway memory
(and lock contention) unboundedly within each 10-minute window — degrading or
killing the one chokepoint the whole fleet depends on.

**Recommendation:** add per-peer/IP rate limiting and a global cap on pending
onboard sessions; shed or 429 beyond the cap.

### F6 — Credential injection is observable through header-reflecting upstreams — Low / Medium

The "secrets stay at the gateway" property guarantees the agent never *holds* the
real credential, but not that it can never *observe* it. The gateway overwrites a
client-supplied `Authorization` and stamps the real secret server-side (confirmed:
`internal/config/plugins/credentials/util.go:51`), but if a real credential is
bound to an endpoint that **reflects request headers** (echo/debug services,
request-bins, verbose error pages, or any upstream the agent can influence), the
agent reads the injected secret back out of the response body.

This is not theoretical: the verification suite *proves* injection precisely by
reading the gateway-injected secret out of `postman-echo.com/get`'s reflected
headers (`tests/runtime/40_credentials.sh`, `R-CRED-1`/`R-CRED-2`). The shipped
value is the dummy `test-secret-123`, so nothing real leaks as shipped — but the
stack demonstrates the dangerous binding (a credential on a reflecting endpoint),
and the suite now records the reflection explicitly as the `R-GAP-CRED-LEAK`
XFAIL instead of reframing the leak as a benign test artifact.

**Recommendation:** document that credentials may only be bound to endpoints that
*consume* the header, never reflect it; choose a non-reflecting example endpoint
for the stack.

### F7 — Partial supply-chain pinning — Low / Info

The clawpatrol binary is well pinned (version + per-arch SHA256, verified at
build, `stack/Dockerfile:18-28`) and the submodule tag is checked for
lockstep. The base image is now pinned by index digest
(`ubuntu:noble-20260509.1@sha256:786a8b…`, `Dockerfile:8`), so it is immutable
across rebuilds. The remaining gap is apt packages (`apt-get install` pulls
floating versions, `Dockerfile:10-12,60-63`), which are not pinned and which the
tests do not verify. A compromised mirror could inject at apt time. Inherent to
most Docker builds and bounded on the gateway by the read-only rootfs, but worth
noting given the "assume hostile" posture.

### F8 — Secret-via-env pattern in the committed Compose file — Low / Info

`CLAWPATROL_SECRET_ECHO_DUMMY` is committed in `stack/compose.yaml:34`. It is a
documented test value (test-enforced as dummy-only by A10/L1), so nothing leaks —
but the pattern teaches the env-var path, and real secrets placed there land in
git, `docker inspect`, and `/proc/1/environ`. Architecture says to use the
dashboard; the stack should say so next to the example.

---

## Test / assurance observations

### T1 — stale verification defaults after the project rename — RESOLVED

Originally the verification suite (then `tests/cursor`) still carried the former
project's names (`tpatrol`, `tbot-418`, `poc/`), so its runtime phase targeted
paths/services that no longer existed. **Resolved:** the suite has been
consolidated to `tests/` (the sole, canonical harness) and its defaults now track
the shipped stack — `COMPOSE_FILE := $STACK_DIR/compose.yaml`, `GATEWAY_SVC :=
gateway`, `TBOT_SVC := clawbot-418` (`tests/lib/common.sh`) — and the static
phase verifies the real deployable topology end-to-end.

### T2 — The adversarial half of two guarantees was the half left untested — largely RESOLVED

The original harness was honest about the accepted N-risks, but it tested two
load-bearing guarantees in ways that could not catch their own counterexamples:

- **"Client cannot reach the host" (AC3):** only `http://host.docker.internal/`
  was probed — port 80, by name. That returns `000` because the name may not
  resolve in the cage or nothing listens on the host's :80 — never because the
  relay refused. The working path (a raw internal IP on a live port through the
  tunnel, per F1) was never exercised, so the AC3 checkmark was only
  coincidentally green.
- **"Secrets stay at the gateway":** the injection proof *is* the leak (F6).

**Status:** the consolidated suite at `tests/` now adds the counterexamples this
recommended — direct host-reachability probing (`R-NET-6b`), the off-tunnel DNS
query to `127.0.0.11` (`R-GAP-DNS`), the host-gateway/RFC1918 + cloud-metadata
relay probes (`R-GAP-SSRF-RFC1918`, `R-GAP-SSRF-META`), and the
real-secret-on-reflecting-endpoint case (`R-GAP-CRED-LEAK`) — each asserting the
desired (fixed) behavior and recorded as `XFAIL` while the gap stands, flipping to
`PASS` the moment it closes.

### T3 — Build / harness state

- `docker compose config` parses cleanly.
- `go test ./internal/config` passes; `go test ./cmd/clawpatrol` does **not**
  build (the `dashboard/dist` embed target is missing from the submodule
  checkout) — so the upstream gateway test suite cannot be run as-is here.
- The repo ships a single verification suite at `tests/` (canonical, runnable;
  the former `tests/cursor`/`tests/claude` split has been consolidated — see T1).

---

## Accepted risks (documented; not reported as findings)

These are clearly stated in `docs/architecture.md` / `tests/README.md` and
are **not** treated as findings except where F1/F2/F3 chain them into something
new:

- **N1** egress is monitor-only, not default-deny (the cage is the boundary).
- **N2** gateway → host is best-effort on Docker Desktop.
- **N3** clients can reach the dashboard port (self-service join).
- **N4** manual per-client approval (no WG auto-approve).
- **N5** client↔client lateral access open (single-tenant; `NET_ADMIN` permits
  ARP/ND spoof + sniff between peers).
- **N6** `dashboard_listen = 0.0.0.0` is intentional.
- Agent runs as root + `NET_ADMIN` in v1 (cost trade-off, bounded by the cage +
  VM boundary + `no-new-privileges`).
- Non-goals: not multi-host; not a process/kernel sandbox; not hardened against a
  hostile co-tenant.

---

## What is genuinely solid

- **The cage is a true L3 boundary**, and the obvious bypass fails: the
  dual-homed gateway has no added caps and forwards in gVisor userspace, and
  Docker does not enable `ip_forward` inside a container netns — so a client
  cannot use the gateway as a plain kernel router to escape. clawpatrol's
  userspace proxy really is the only forwarder.
- **Compose topology is correctly shaped:** `internal: true` cage, single
  dual-homed gateway, WireGuard 51820/udp not published, dashboard published
  loopback-only (`127.0.0.1:5182`).
- **Gateway self-protection:** read-only rootfs + `tmpfs:[/tmp]`,
  `no-new-privileges`, no host bind mounts, no `host.docker.internal`, no added
  caps, SHA256-pinned binary verified at build.
- **Credential overwrite is real** (client-supplied `Authorization` is replaced
  server-side), and the **SNI / HTTP Host mismatch path is handled** — upstream
  host fields are rewritten before credential injection, so the secret is stamped
  for the intended host.
- The design docs are unusually honest about residual risk.

---

## Bottom line

The cage-as-L3-boundary thesis is sound and well-engineered, and the accepted
risks are documented candidly. But the headline guarantees — "no direct internet,"
"no reach into your host," "everything is logged," "secrets stay at the gateway"
— are **stronger than what is enforced**, because the chokepoint the model
depends on can be sidestepped or abused: the promiscuous relay (**F1**) lets the
untrusted agent borrow the gateway's host/internal/metadata reach, **DNS** (**F2**)
leaves via the Docker daemon without touching the gateway at all, and the shipped
policy (**F4**) advertises enforcement it does not apply. **F1 and F2** are the
ones to fix before trusting this with anything that matters; **F4** is a cheap,
high-value correction to the stack; and **F3** (first-run dashboard claimable
from the cage) is Medium and closes with an explicit runbook ordering line — set
the password and finish onboarding before any agent is brought up or exec'd.
