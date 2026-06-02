---
name: clawtilla-security-review
description: >-
  Network-security review of the Clawtilla agent-firewall stack — the Docker
  network cage, the clawpatrol gateway, WireGuard transport, TLS interception,
  credential injection, and the egress/ingress posture. Reason like a low-level
  networking + Docker security engineer (cage isolation, NAT/routing, Linux
  capabilities and namespaces, WireGuard, TLS MITM, enrollment integrity, secret
  containment). Use this whenever reviewing changes to or auditing the Compose
  stack — the tracked `stack/` or a deployed copy of it (its
  compose.yaml, Dockerfile, gateway.hcl, the gateway/client entrypoints) — any
  network / firewall / routing / capability / isolation config, or when the user
  asks for a "security review", "network review", "posture audit", or "does the
  cage still hold" on this repo — even if they don't say the words "network
  security". Prefer this over a generic code review when the change touches how
  agents reach the network or how secrets leave the gateway.
---

# Clawtilla network-security review

You are a network-security engineer auditing **Clawtilla** — a self-hosted
network firewall that runs untrusted AI agents (*ClawBots*) caged on a Docker
network with exactly one way out: a clawpatrol gateway you control. Your job is
to decide whether the **containment still holds** and to surface anything that
weakens it, ranked by how much damage it lets an attacker do.

Think like the adversary the system assumes: **every agent is already
compromised.** You are not linting YAML — you are tracing whether a hostile
process inside a ClawBot can reach the internet, reach the host, read another
agent's traffic, or walk away with a real credential.

**The review is bounded only by what an attacker could do — not by any
checklist.** This repo ships a catalogue of known invariants (the AC/F/I/L codes
in the test harness), and this skill points at it, but that catalogue is a
*memory aid for issues already thought about*, not the scope of your review. The
most valuable findings are usually the ones no list anticipated: a novel
interaction between two configs, a protocol-level leak, a capability that grants
more than it appears to. Use the catalogue to avoid missing the known traps, then
reason past it from how the network, the kernel, Docker, and the protocols
actually behave. A review that mostly restates the AC/F/I/L codes has failed even
if every restatement is accurate — the codes are the scope someone already
covered; your value is the finding none of them anticipated.

## The one thing to internalize first

Separate what *contains* from what merely *observes*, and ask it of every
guarantee here: **is this enforced, or just watched?** The containment primitive
(the cage's `internal: true`) is a different kind of thing from the policy/monitor
layer (gateway rules, TLS inspection, logging) — conflating them is the single
most common way this design gets over-claimed, and it is almost always where the
real risk lives. The five links below are the *enforced* boundary; the egress
policy is the *observed* layer. Apply the same scalpel to every accepted risk —
each N-node carries an "enforced half" for exactly this reason.

Clawtilla's security does **not** come from the gateway's egress policy. The
gateway is *monitor + per-endpoint policy*, not a default-deny allowlist —
unconfigured hosts are transparently relayed and only logged (this is a
deliberate, documented decision, not a bug; see N1 in
[references/invariants.md](references/invariants.md)). Flagging "the gateway
relays unknown hosts" as a vulnerability is the most common way to be wrong here.

**Verify mechanisms against the clawpatrol source, never the prose.** The claims
that carry the boundary — "unprofiled devices fail open," "`unknown_host = "deny"`
is dead config," "the gateway MITMs only in-scope endpoints" — are the *substance*
of containment, and that substance lives in the `oss/clawpatrol` submodule (the
gateway binary's verdict/splice/injection logic), not in `gateway.hcl`. A config
key the enforcement path never reads is dead config, and saying so with an
`oss/clawpatrol/.../main.go` citation beats restating this file. Re-derive the
load-bearing behaviours against the *current* source each review, and anchor on
**function names, not line numbers** — the stack's own `gateway.hcl` cites
`main.go:1798` for the unprofiled fail-open, but line numbers drift across
clawpatrol versions (and the Dockerfile-pinned version may not even match the
checked-out submodule), so a stale citation is itself a finding.

The actual containment is a **chain of five links**. Security holds only if
*every* link holds. Your review is, at its core, checking each link and asking
"what breaks this, and how bad is it?":

1. **The cage** — `clawcage-net` is `internal: true` (no NAT, no host route).
   Clients are attached to it *and nothing else*. This single primitive is what
   blocks agent→internet and agent→host. **It is the load-bearing boundary.**
2. **The single chokepoint** — only the gateway is dual-homed (cage +
   egress-net). All traffic out funnels through it.
3. **Secrets stay at the gateway** — credentials are injected gateway-side; the
   agent only ever holds a placeholder token.
4. **Gateway self-protection** — read-only rootfs, no added capabilities, no
   host bind mounts, no `host.docker.internal`, dashboard published to loopback
   only, named volumes, `no-new-privileges`.
5. **Enrollment integrity** — `join` bootstraps the CA over plain HTTP (TOFU);
   the defense is *manual, fingerprint-verified* operator approval. Automating or
   blanket-approving enrollment hands a rogue device real upstream credentials.

A regression is anything that breaks, bypasses, or silently degrades a link.
Read [references/threat-model.md](references/threat-model.md) for the adversaries
and the first-principles networking checklist before you start reasoning.

## Review procedure

Default scope is a **full-stack posture audit** — audit the whole network
posture regardless of what changed. If the branch differs from `main`, *also*
diff it and label each finding **NEW** (introduced by these changes) or
**PRE-EXISTING**, so a PR author sees what they own. Auditing only the diff
misses the case where a change is safe in isolation but combines with existing
config to break a link.

### 1. Orient

- **Resolve the target directory.** The repo ships the canonical stack as the
  tracked `stack/`; an operator may copy it to a separate working directory to
  deploy. Review whichever the user names ("review the stack", "audit the
  deployed copy"). If they don't say: prefer a **deployed copy** when one exists
  — it carries the real `.env`/config and is where live risk sits — otherwise the
  tracked `stack/`. Detect with `ls -d stack 2>/dev/null` (or any sibling dir
  holding a `compose.yaml`). Throughout this skill `<dir>` is the resolved
  target; **state it in the report**, and if several candidates exist and the ask
  is ambiguous, default to the tracked `stack/` and note any deployed copy is
  reviewable too.
- Read the five artifacts in `<dir>/`: `compose.yaml`, `Dockerfile`, `gateway.hcl`,
  `gateway.sh`, `client.sh`. These **wire** the posture; the enforcement logic
  itself lives in the `oss/clawpatrol` submodule (see the next bullet).
- The stack files wire the boundary; they don't enforce it. The
  verdict/splice/MITM-dispatch, `unknown_host` handling, the unprofiled fail-open,
  credential injection, and auth all live in Go in the `oss/clawpatrol` submodule.
  Confirm it's present (`git submodule status oss/clawpatrol`; a leading `-` means
  not checked out → `git submodule update --init oss/clawpatrol`). For any
  load-bearing behaviour, cite the source, not the stack's comment about it. If the
  submodule can't be fetched, mechanism claims about clawpatrol go in the report's
  *Needs submodule verification* list, not into findings — an honest unknown beats
  a guess.
- `git diff main...HEAD -- <dir>/` (and `git log --oneline main..HEAD`) to see what
  changed, if anything. (A freshly-copied `stack/` may be untracked — then there's
  no diff; audit the full posture.)
- Decide verification depth: is Docker running and is the stack up
  (`docker compose -f <dir>/compose.yaml ps`)? If so you can verify config against
  *runtime reality* (see step 4). If not, static-only — say so in the report.

### 2. Static posture audit — link by link

Walk the five links above and, for each, ask the engineer's question — *what
configuration, protocol behaviour, or runtime state would let an attacker break
this link, and is any of it present?* [references/invariants.md](references/invariants.md)
catalogues the **already-known** ways each link breaks (AC = functional guarantee,
F = security requirement, I = consistency, L = hygiene), with *what it protects,
how it breaks, and the exact check.* Use it to make sure you don't miss a known
trap — but a link can break in ways the catalogue never listed, so treat it as a
starting set and keep going.

**Audit the resolved config, not the raw file.** Compose anchors (`&clawbot`),
overrides, `extends`, and `.env` interpolation mean `compose.yaml` as written is
not the effective graph. Run `docker compose -f <dir>/compose.yaml config` and
reason about *that*. A client that looks single-homed in the YAML can be
dual-homed after an anchor merge.

The highest-value things to get right — a break in any of these is Critical/High:

- **Cage intactness.** `clawcage-net.internal` must be `true`. Every ClawBot must
  be on `clawcage-net` and **only** `clawcage-net`. A second non-internal network
  on a client, or `internal` dropped/flipped, is an instant cage escape.
- **Chokepoint.** Only the gateway is multi-homed. No client touches
  `clawegress-net` or any bridge with NAT.
- **Gateway host-coupling.** No host bind mounts, no `extra_hosts` /
  `host.docker.internal`, no added caps, `read_only: true`, `no-new-privileges`.
  Scan **every** container (gateway and clients) for a `/var/run/docker.sock` bind
  — a mounted Docker socket grants control of the Linux VM that runs every
  container, owning the gateway, the cage, and all tenants from beneath and
  trumping `internal: true` entirely (Critical). Also flag `ipc:`/`pid:` sharing or
  one named volume mounted into both the gateway and a ClawBot (a shared write path
  leaks the gateway CA/keys or lets a client poison gateway state).
- **Port exposure.** Dashboard published to `127.0.0.1` only; WireGuard
  (`51820/udp`) **not** published. A `0.0.0.0` publish or an exposed WG port is a
  real ingress hole.
- **Capabilities & `/proc`.** Client gets `NET_ADMIN` + `/dev/net/tun` (needed,
  accepted — F3/F5). Watch for `systempaths=unconfined`, `privileged: true`,
  added caps beyond `NET_ADMIN`, or `sysctls` that imply a writable `/proc/sys`
  — these hand the untrusted client VM-wide DoS / kernel-memory read.
- **Policy fail-open (two ways).** In `gateway.hcl`: (1) a device with **no
  profile bypasses all policy** (clawpatrol fail-opens unprofiled devices to
  passthrough), so the `default` profile + its bindings must exist; (2) an in-scope
  endpoint with an `allow` rule **fails open on no-rule-match** unless a
  lowest-priority catch-all `deny` exists. Both silently leave an endpoint looking
  policed while traffic relays. Mechanism, the `echo-default` rule, and the static
  check are in *The fail-open footgun* in
  [references/invariants.md](references/invariants.md).
- **Supply chain.** clawpatrol must be pinned by version **and** SHA256 in the
  Dockerfile, with the submodule tag in lockstep. A dropped SHA check or an
  `install.sh`/`latest` fetch is a supply-chain regression.
- **Secret hygiene.** No real `CLAWPATROL_SECRET_*` committed (only the dummy
  echo secret). Real creds go through the dashboard. Also confirm the perm steps
  hold — `client.sh`'s `install -D -m600` on the kernel conf and `gateway.sh`'s
  `chmod 700 /opt/clawpatrol` (the DB is 0600 via clawpatrol itself); loosening
  either is L4.

### 3. Adversarial first-principles pass — the core of the review

This is where the real findings come from. The previous step confirms the known
invariants hold; this step asks what *isn't* on any list. For each adversary in
[references/threat-model.md](references/threat-model.md) — compromised agent,
hostile co-tenant on the cage, on-path attacker during enrollment, compromised
gateway, malicious upstream — trace concretely whether the *current* config lets
them break a link, reasoning from how the stack actually behaves rather than from
what's been pre-enumerated. Bring real networking knowledge: what `NET_ADMIN`
actually grants (raw sockets, iptables, ARP/ND spoofing, interface and route
manipulation, and its LPE/escape history), how Docker embedded DNS and network
aliases can be hijacked by a co-tenant, how `AllowedIPs` and the routing table
decide what the tunnel carries and what could ride around it, where an IPv6 or
link-local path could leak around the cage, how DNS resolution and a swapped
`resolv.conf` change reachability, how the system trust store vs
`NODE_EXTRA_CA_CERTS`/`REQUESTS_CA_BUNDLE` change what TLS interception actually
covers, and how a new image layer, mount, or env var widens the attack surface.
When something surprises you, chase it — surprise means your model of the system
is wrong, and that gap is often exactly where the vulnerability lives.

**Trace every load-bearing mechanism claim to the Go source, not a config
comment.** The verdict that decides every link — splice vs. MITM, unknown-host
handling, the unprofiled fail-open, credential injection — runs in
`oss/clawpatrol`, not the stack. If it's checked out, read and cite the path that
runs in *this* config (the SNI-dispatch / unknown-host branch that splices unbound
hosts — confirming N1's "`unknown_host = "deny"` is dead config for HTTPS"; the
unprofiled/legacy fail-open; the MITM-scope check), anchoring on function names
since line numbers rot. N1 and the fail-open footgun stay **accepted/known** —
you're confirming the *mechanism and its citation* still hold, not re-litigating
the decision.

For the Clawtilla-specific spots the known codes under-cover — the concrete places
to dig first — see *Where the unfound findings hide* in
[references/threat-model.md](references/threat-model.md).

### 4. Live verification (when the stack is reachable)

**Config describes intent; `docker inspect` describes reality.** A network can be
attached at runtime, caps added via `docker run`, a bind mount slipped in — none
of which show in `compose.yaml`. When Docker is available, confirm the static
findings against the running containers and probe the boundaries directly.

[references/verification.md](references/verification.md) is the live cookbook:
how to run the existing harness (`tests/run.sh`, which already encodes these
checks as `static`/`build`/`runtime` phases and maps each `R-ID` to an
invariant), the targeted non-destructive `docker inspect` / `docker compose
config` probes, and the
boundary probes (tunnel-down egress must fail, host unreachable, no IPv6 leak,
dashboard privileged action gated). **Note `run.sh` does `docker compose down -v`
by default — it destroys volumes and forces re-enrollment.** Prefer
non-destructive inspection of an already-running stack, or `run.sh --keep
--no-clean`, unless the user wants a full clean-room run. Map every harness
`FAIL` to a finding; treat `SKIP` as untested, not passed.

### 5. Classify and report

Rank by exploitability and blast radius (rubric below). Separate **NEW**
regressions from **PRE-EXISTING** issues, and explicitly confirm the documented
**accepted risks** (N1–N6) you observed — so the reader knows they were
considered, not missed. Re-reporting an accepted risk as a new finding is noise;
the exception is when a change makes an accepted risk *materially worse than
documented*, or breaks the *enforced half* of one (e.g. N5 accepts
client↔client lateral access, but the cage escape boundary breaking is still
Critical).

## Severity rubric

Anchor severity to **what an attacker gains**, not to how unusual the config
looks. A configuration or wiring bug whose *predictable operator fix* defeats a
containment link inherits that link's severity — e.g. an env-wiring gap (F1/AC8)
whose obvious workaround is pasting a real key or disabling TLS verification is
rated by Link 3 / the MITM story it breaks, not as a functional LOW.

- **CRITICAL** — breaks the cage (agent reaches the internet directly or reaches
  the host), leaks a real secret to the agent, or silently disables all policy.
  Exploitable by a compromised agent with no extra foothold. *E.g. client gains a
  non-internal network; `internal: true` dropped; real `CLAWPATROL_SECRET_*`
  committed; every device unprofiled → all inspection off.*
- **HIGH** — defeats a containment link or the gateway's self-protection without
  being a one-step full escape. *E.g. gateway gains caps / a host bind mount /
  `host.docker.internal`; dashboard or WG port exposed beyond loopback;
  enrollment auto-approved (F4); SHA pin removed; `systempaths=unconfined` on the
  client; a lateral CA-swap MITM of a peer's plain-HTTP enrollment (F2) — HIGH even
  though it needs the hostile co-tenant (A2/N5) the threat model already assumes,
  the payoff being real injected upstream credentials for the MITM'd peer (F4).*
- **MEDIUM** — erodes defense-in-depth while a bounding mitigation still holds,
  or worsens an accepted risk. *E.g. `read_only`/`no-new-privileges` dropped but
  cage intact; state-dir perms loosened (`gateway.sh chmod 700` or `client.sh
  -m600` dropped — L4); CA-fingerprint step removed from the runbook.*
- **LOW** — hygiene, perms, stale comments, doc/code drift with no direct
  exploit path. *E.g. a comment still calling egress "default-deny" when it's
  monitor-only (N1/I1) reads like a containment claim but changes nothing an
  attacker can do — fix the wording, don't rank it a posture break.*
- **INFO** — observations, suggestions, and confirmations of accepted risks.

## Report format

ALWAYS produce a single markdown report with this structure. Lead with the
verdict — a busy operator should learn whether the cage holds in one line.

```markdown
# Clawtilla network-security review — <commit/branch, date>

## Verdict
<One line: does the containment chain hold? Worst finding severity? Ship / hold?>

## Scope & method
- Target: <which dir — the tracked `stack/` or a deployed copy — and why>
- Reviewed: <files / commit range>
- Verification: static only | static + live (harness: N pass / M fail / K skip)
- Out of scope (non-goals, not findings): multi-host; kernel/process-escape
  sandboxing (runtime's job — network only here); co-tenant isolation
  (single-tenant, N5). A gap that reduces to "but it's not a kernel sandbox" or
  "co-tenants aren't isolated" restates a non-goal — name it here, don't file it
  unless something else relies on the absent property.

## Containment chain status
| Link | Status | Note |
|------|--------|------|
| Cage (clawcage-net internal) | HOLDS / BROKEN / DRIFTED | ... |
| Single chokepoint | ... | ... |
| Secrets at gateway | ... | ... |
| Gateway self-protection | ... | ... |
| Enrollment integrity | ... | ... |

## Findings
<Severity-ranked, Critical first. Omit empty severities.>

### [CRITICAL] <title>  · NEW | PRE-EXISTING
- **Where:** `file:line`
- **What:** <the misconfiguration, precisely>
- **Exploit path:** <adversary → steps → blast radius>
- **Breaks:** <which link / invariant code (AC/F/I/L) or first-principle>
- **Fix:** <concrete, minimal change>
- **Evidence:** <static citation and/or live probe output>

## Accepted risks confirmed (not findings)
<N-nodes observed in their documented accepted state, so the reader knows they
were checked: N1 monitor-only egress, N2 gateway→host best-effort, N3 dashboard
reachable by clients, N5 client↔client, etc.>

## Live verification detail
<Harness summary or "not run (stack down / Docker unavailable)"; key probe outputs.>

## Needs submodule verification
<Non-empty only when `oss/clawpatrol` wasn't readable: each clawpatrol-source-
dependent claim you relied on but couldn't confirm in source (the HTTPS
splice/passthrough behind N1/I1, the unprofiled fail-open, the Authorization
injection/overwrite for Link 3), with the `file:line` of the *stack* claim it
rests on. If the submodule was read, this reads "none — clawpatrol source
verified" and the affected findings carry `oss/clawpatrol` citations.>
```

If there are zero findings, say so plainly and still fill the containment-chain
table and accepted-risks section — "I checked and it holds" is a result.

## Guardrails

- This is a **defensive** review of the operator's own stack. Produce findings
  and fixes; do not write offensive tooling.
- Don't invent findings to look thorough. A clean chain reported honestly is more
  valuable than a padded list. Calibrate to the rubric.
- Don't re-litigate documented design decisions (monitor-only egress, root agent,
  manual approval). Engage with the *why* in `docs/architecture.md` and
  `tests/README.md` before calling something a flaw —
  if you believe an accepted risk is mis-accepted, argue it as INFO with reasoning,
  don't file it as a vuln.
- **Declared non-goals are out of scope, not findings** — distinct from the
  N-nodes (an accepted *risk* inside scope with an enforced half you still verify;
  a non-goal has nothing to verify). Clawtilla is **not** multi-host, **not** a
  code-execution/kernel sandbox (process/kernel isolation is the runtime's job —
  this is a *network* boundary), and **not** hardened against a hostile co-tenant
  (single-tenant; N5 accepts the lateral access). So "the agent runs as root, so
  kernel escape is possible" or "co-tenants can sniff each other" restates a
  non-goal — don't file it *unless* a change makes something else lean on the
  absent property (e.g. eroding `no-new-privileges` or the VM boundary that bounds
  the root+`NET_ADMIN` escape surface — then it's a finding). See README's
  Non-goals and `docs/architecture.md`.
