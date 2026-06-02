# Known invariants — a memory aid, not the scope

This is the catalogue of failure modes **already reasoned about** for Clawtilla,
mirrored from the canonical registry in `tests/README.md` (the source of
truth — if it has changed, trust it over this file). Use this to avoid missing a
known trap. It is deliberately **not exhaustive**: the containment chain can break
in ways no one has written down. After you've confirmed these, keep reasoning
from [threat-model.md](threat-model.md). A review that only walks this list is
under-reviewing.

Each entry: **what it protects · how it breaks · static check · live check.**
Codes match the harness so you can map a finding to a test ID and the design
docs. The harness suites A–G *are* these checks in runnable form — see
[verification.md](verification.md).

## Acceptance criteria (AC) — functional containment guarantees

- **AC1 — Allowed in-scope upstream works and is logged.** *Protects:* proof that
  traffic is actually tunneled, MITM'd, and policy-inspected. *Breaks:* tunnel not
  established; CA not trusted; endpoint silently out of scope. *Static:* an
  endpoint + allow rule + bound credential exist in `gateway.hcl`. *Live:* request
  to the in-scope host returns 2xx **and** appears in the dashboard analytics log
  (suite D1).

- **AC2 — The cage contains; configured endpoints are policed.** *Protects:* the
  load-bearing boundary. Three sub-claims: tunnel **down** → *all* egress fails
  (the cage, not the gateway); tunnel **up + configured** → the rule applies
  (allow→200, denied verb→clean 4xx); tunnel **up + unconfigured** → relayed
  (log-only, **expected**, not a failure — see N1/I1). *Breaks:* any off-cage
  route makes "tunnel down → egress fails" false → cage breached. *Static:*
  `clawcage-net.internal == true`; clients single-homed. *Live:* with the tunnel
  down, egress to both a hostname and a raw IP must fail (suite D2). **Do not
  assert an egress allowlist** — relayed unknown hosts are by design.

- **AC3 — Client cannot reach the host.** *Protects:* agent↛host. *Breaks:* an
  injected host-gateway, a host bind, a route to the Docker Desktop host. *Static:*
  no `host.docker.internal`/`extra_hosts`/host mounts on the client; cage is
  internal. *Live:* an actual connection attempt to `host.docker.internal` fails
  (000), not merely "doesn't resolve" — test by connection (suite D5, L2).

- **AC4 — Client cannot perform privileged dashboard actions.** *Protects:* the
  dashboard being reachable on the cage (by design, N3) doesn't grant control.
  *Breaks:* an unauthenticated privileged endpoint; dashboard auth weakened.
  *Live:* `:8080` authPublic endpoints reachable, but `/api/state` (and other
  privileged actions) without the root password return 401/403/302 (suite D6).

- **AC5 — Gateway egress works; gateway has no host coupling.** *Protects:* the
  gateway is the egress point yet stays host-isolated. *Breaks:* host bind mounts,
  injected `host.docker.internal`, added caps. *Static:* gateway volumes are named
  (no `bind`); no `extra_hosts`; no `cap_add`/`devices` (I2 exception: the policy
  file is baked into the image, not bind-mounted). *Live:* gateway reaches the
  internet; `docker inspect` shows no host binds, no extra_hosts, empty `CapAdd`
  (suites B5/B6, A4/A7).

- **AC6 / AC7 — Lifecycle decoupling & restart survival.** *Protects:* operational
  correctness (agent restart doesn't flap the tunnel; container restart re-ups
  from persisted conf with no re-enrollment). *Security-relevant edge:* a naïve
  join-every-boot churns enrollment and re-mints keys; persistence belongs on a
  **named volume**, not a host bind. *Live:* suites F1/F2.

- **AC8 — Agent environment is wired via the `run` wrapper.** *Protects:* the
  agent gets CA-bundle + placeholder-token env explicitly (plain `join` wires no
  shell rc — F1), so it trusts the MITM CA and uses placeholders, never real keys.
  *Live:* `run env` carries `NODE_EXTRA_CA_CERTS`/`REQUESTS_CA_BUNDLE` (+ any
  declared placeholder); a bare login shell does not (suites G1/G2).

## Security requirements (F) — from the adversarial review

- **F1 — Agent env must be explicit.** Plain `join` installs no shell rc; the
  `run` wrapper supplies env. A change that assumes a login shell sources
  `clawpatrol env` is wrong and may drop CA trust or leak a real key.
- **F2 — Enrollment CA must be fingerprint-verified.** `join` is TOFU over plain
  HTTP; a co-tenant can swap the CA. The operator must compare the CLI-printed
  fingerprint against the dashboard before approving. *Check:* the runbook still
  mandates it; nothing automates approval past it.
- **F3 — `NET_ADMIN` weakens lateral isolation, not egress.** Accepted (N5). The
  cage blocks escape regardless of caps; `NET_ADMIN` only enables L2 attacks on
  co-tenants. Flag only if a change lets it reach beyond lateral (host/gateway).
- **F4 — Approval is a hard gate; never blanket-approve.** A rogue/auto-approved
  device gets a profile and **real injected upstream credentials**. *Check:* no
  script calls `/api/onboard/approve` unconditionally; no auto-approve; approval
  binds to a verified identity. Auto-approve is High severity.
- **F5 — Agent runs as root + `NET_ADMIN` (accepted, v1).** A cost trade-off,
  bounded by the cage + VM boundary + `no-new-privileges`. Not a finding on its
  own; flag if the bounding mitigations erode (e.g. `no-new-privileges` dropped).

## Consistency & hygiene (I, L)

- **I1 — AC2 is monitor + per-endpoint policy, not an allowlist.** Don't claim
  "only allowlisted hosts succeed." Relayed unknown hosts are expected.
- **I2 — Gateway's only host mount is the read-only policy file** (baked into the
  image, so AC5 holds on `docker inspect`).
- **L1 — No real secret committed.** Only the dummy echo secret may appear in
  `compose.yaml`; real creds via the dashboard. A committed real `CLAWPATROL_SECRET_*`
  is Critical. *Static:* grep `CLAWPATROL_SECRET_` in `compose.yaml`.
- **L2 — Host-unreachability is tested by connection, not assumed.** A name can
  resolve yet be unreachable.
- **L3 — No IPv6 egress leak.** The cage must not provide an unpoliced v6 path.
  *Live:* no IPv6 default route, or one via the tunnel (suite D8). Easy to miss in
  a v4-only mental model.
- **L4 — Key/state-dir perms stay tight; bounded by single-tenant.** *Protects:*
  the on-disk WG keys, CA key, and secrets DB from a *second* principal inside a
  container (the cage already keeps them off the agent and off the host). *Checks:*
  `client.sh` writes the kernel conf `install -D -m600`; `gateway.sh` does
  `chmod 700 /opt/clawpatrol` to tighten the named-volume mountpoint Docker
  pre-creates `0755` (the secrets DB is 0600 by clawpatrol on every open, not the
  entrypoint). *Static:* grep `client.sh` for `-m600`, `gateway.sh` for `chmod 700`.
  *Severity:* dropping either is **Medium** — single-tenant bounds the blast radius
  to a second principal inside the same container, and the agent never holds these
  files (Link 3); escalates only if a change introduces a second principal or exec
  path that could read them.

## Accepted-risk nodes (N) — confirm, do NOT file as new findings

These are deliberate, documented design decisions. Reporting them as
vulnerabilities is noise — confirm they're still in their accepted state in the
report's "Accepted risks confirmed" section. **Exception:** flag if a change
makes one *materially worse than documented*, or breaks the *enforced half*
beside it.

- **N1 — Egress is monitor-only, not default-deny.** For an HTTPS host bound to no
  endpoint in the active profile, clawpatrol splices it through *regardless of*
  `unknown_host`, so `unknown_host = "deny"` is effectively dead config for that
  path. *Confirm in source, don't assume:* the `ep == nil` branch of the SNI-peek
  handler in `oss/clawpatrol/cmd/clawpatrol/main.go` (it `splice`s; the comment
  says "passthrough today … A 'deny' mode would close the conn") — a current
  default, not a guarantee, so **re-verify this branch after any `CLAWPATROL_VERSION`
  bump** (line numbers drift, and the pinned version may differ from the
  checked-out submodule). The tension with `gateway.hcl` (which leans on
  `unknown_host = "deny"` for the empty `default` profile) is a deliberate
  code/config gap, not a finding — but the first place to look if the branch
  changes. Containment is the cage, not a gateway allowlist. *Enforced half still
  required:* the cage (AC2 down→fail).
- **N2 — Gateway → host is best-effort** (Docker Desktop). The gateway has real
  egress by design and can reach the Mac via the host-gateway. Closing it needs an
  in-container egress firewall — declined for now.
- **N3 — Clients can reach the dashboard port** (required for self-service join).
  *Enforced half:* the bcrypt root password + approval gate (AC4/F4).
- **N4 — Manual per-client approval** (no WG auto-approve). See F4.
- **N5 — Client ↔ client lateral access left open** (single-tenant assumption).
  *Enforced half:* the cage escape boundary still holds for every tenant (AC2).
  *Why it's open:* `internal: true` only strips the off-net route — it gives zero
  L2 peer isolation. The lever that would enforce client↔client isolation is
  `driver_opts: com.docker.network.bridge.enable_icc: "false"` (or per-tenant
  segments) on `clawcage-net`; none is set today. Accepted under single-tenant —
  but flag if a config or doc *claims* peer isolation while relying on `internal:
  true` alone.
- **N6 — `dashboard_listen = 0.0.0.0` intentionally.** The in-tunnel forwarder
  dispatches the dashboard by port number; rebinding breaks enrollment and
  wouldn't lock enrolled clients out anyway. The real protection is the root
  password + loopback-only *publish* (not the in-app bind).

## The fail-open footgun worth re-checking every time

Not an AC code, but load-bearing and easy to break in `gateway.hcl`: **a device
with no profile bypasses ALL policy** — clawpatrol fail-opens unprofiled devices
to passthrough ("single-tenant/legacy mode"). Every ClawBot must be assigned a
profile, and the `default` profile (and the credential bindings that put
endpoints in scope) must exist. A change that removes the profile, approves a
client without one, or empties the credential bindings silently turns inspection
off for that device while everything still "works." Treat a regression here as
High-to-Critical depending on what it exposes. The fail-open path is `profileFor`
→ `defaultProfileName` returning `""` for an unprofiled device, landing in the
same `ep == nil` splice. **Don't trust the hardcoded `main.go:1798` citation in
`gateway.hcl`** — anchor on the function names and pair with the lockstep check
(see SKILL.md's source-verification note).

**Second fail-open — in-scope-no-match.** Even a properly-profiled, in-scope
(MITM'd) endpoint fails OPEN when no rule matches: clawpatrol's HTTP handler
denies *only* on an explicit deny verdict (the branch is `cr != nil &&
cr.Outcome.Verdict == "deny"`); a nil match falls through to forward-upstream. So
every `endpoint "https" "X"` with an `allow` rule MUST also carry a lowest-priority
catch-all `deny` (the `echo-default` rule in `gateway.hcl`: `priority = -100`).
Delete it, or add an endpoint without one, and every verb the allow rule doesn't
cover (POST/PUT/DELETE) sails through on an endpoint that still *appears* policed —
inspection and the allowed-verb path keep working, so it passes a smoke test. This
is **not** what `defaults.unknown_host = "deny"` covers (that governs unbound
hosts, and is dead config for HTTPS anyway — N1). *Static:* every `endpoint
"https"` with an `allow` rule has a matching lowest-priority `deny`. *Live:* a
denied verb returns a clean 403, not a connection error (harness D4). Treat a
regression here as High — it defeats per-endpoint policy without touching the cage.

## `llm_fail_mode` — keep it `closed`, but verify it bites first

`gateway.hcl` defaults set `llm_fail_mode = "closed"`; it governs only requests
guarded by an `llm_approver` when the model call errors or times out. Not a live
finding in the current stack, for two reasons, plus one to watch:
- The current policy uses **no `llm_approver`** — only static CEL verb rules. With
  no approver in scope the value is inert; flipping it to `open` changes nothing
  today.
- Verify against the code, not the config, before treating it as enforcement —
  confirm the pinned clawpatrol actually consults the knob in a runtime decision
  path (in some versions it's parsed but the approver hardcodes deny-on-error).
- **Watch:** a finding only if a future change (a) adds an `llm_approver`, (b)
  flips `llm_fail_mode` to `open` or relies on a default, AND (c) runs a version
  that consults the knob — then a classifier timeout could relay an in-scope
  request uninspected. Low/INFO unless all three hold; the cage still bounds
  escape. Don't pre-file it.
