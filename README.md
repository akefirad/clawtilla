# 🦀 Clawtilla

**Run untrusted AI agents like you mean it!**

Clawtilla is a Docker Compose stack setting up a self-hosted network firewall for AI agents. You run a fleet of
agent containers — _ClawBots_ — sealed inside a network cage whose only _direct_
route out is a single gateway you control: no direct internet, no direct route to
your host. The gateway is the intended egress chokepoint — connections to
_configured_ endpoints are weighed against per-endpoint allow/deny rules and
logged, and when a real API key is needed the request is handed off with
credentials the agent never holds and can never walk away with.

Assume every agent is already compromised, jailbroken, or just having a very bad
day. The cage stops its _direct_ escape cold and the gateway records and bounds
the rest. The blast radius is contained, but not zero, and the cage is not airtight. See **What's not included** below.

The substance is all <img src="https://demo.clawpatrol.dev/claw-patrol-icon.svg" alt="clawpatrol" width="20" style="vertical-align: middle"> [clawpatrol](https://github.com/denoland/clawpatrol) (gateway,
WireGuard, TLS inspection, policy, credential injection). Clawtilla is just a Docker Compose stack putting pieces together.

> 🚨 **Clawtilla was not built by security professionals and has had no independent
> security audit.** It is provided as-is, with no warranty, **use it at your own
> risk.** Read the [architecture doc](./docs/architecture.md), threat-model it
> against your own needs, and decide for yourself before trusting it
> with anything that matters.

## 🤔 Why

AI agents run untrusted code and make arbitrary network calls. This setup gives
them a hard network boundary and a single auditable egress point:

- Agents are **network-caged** — their only route out is the gateway.
- The gateway **inspects** in-scope endpoints, applies **allow/deny rules** per
  host + verb, and **logs** everything.
- Upstream credentials stay **at the gateway** and are injected into requests; the
  agent only ever holds a placeholder token.

## 🎯 Goals

- **Contain** untrusted agents — no direct internet, no host reachability.
- A **single egress chokepoint** with per-endpoint policy and full request logging.
- **Keep secrets out of the agent** — credentials are injected at the gateway.
- **Self-hostable on one machine** with plain Docker Compose — no SaaS, no external
  dependency.
- **Scale by adding agents** — one service + volume per client.
- **A default-deny egress allowlist** — (**_Not Supported Yet!_**) Blocking arbitrary unlisted domains needs a separate egress filter.

## 🚧 Non-goals

- **Not multi-host / distributed.** One Docker host (designed and tested on Docker
  Desktop for macOS).
- **Not a code-execution sandbox.** It secures the _network_; process and kernel
  isolation remain the container runtime's job.
- **Not hardened against a hostile co-tenant** on the agent network (single-tenant
  assumption).

## ✨ Features

- Network-caged agent containers on an internal Docker network (no NAT).
- A userspace-WireGuard gateway — no kernel WireGuard, no extra capabilities on the
  gateway.
- Per-endpoint allow/deny policy, TLS inspection, and a request-log dashboard.
- Gateway-side credential injection (the agent sees only a placeholder).
- Persistent, restart-safe enrollment (no re-approval) and a decoupled agent
  lifecycle.
- The gateway CA auto-installed into the agent's system trust store.
- Full acceptance + security [test harness](./tests).

## ⚠️ What's not included (known limitations)

Each is a deliberate, documented decision — see **Key decisions** and the design docs.

- **No default-deny by domain** — egress is monitor + per-endpoint policy.
- **No client↔client isolation** on the agent network — a compromised agent can
  spoof or sniff its neighbours.
- **The agent runs as root** with `NET_ADMIN` in v1 — an accepted trade-off,
  bounded by the cage, the VM boundary, and `no-new-privileges`.
- **Gateway → host isolation is best-effort** on Docker Desktop.
- **"No reach into your host" is direct-only.** The cage blocks the agent's
  _direct_ route off-net, but the gateway's WireGuard relay forwards agent traffic
  to anything the gateway itself can reach — the host-gateway, RFC1918 neighbours,
  or cloud metadata. No _direct_ route, not no _indirect_ reach.
- **DNS is not contained.** Tunneled DNS content isn't run through the rule engine,
  and a malicious agent can query Docker's embedded resolver (`127.0.0.11`)
  directly, bypassing the gateway — usable for low-bandwidth exfil / beaconing.
- **Single host only.**

These and the full residual analysis are catalogued in an external network-security
review: [`docs/review.md`](./docs/review.md).

## 🧭 Key decisions

Brief; the as-built summary is in [architecture](./docs/architecture.md), full
rationale + source citations in the archived [design records](./docs/archive).

- **WireGuard, not Tailscale** — Tailscale would break the cage (it needs internet
  to reach its control plane). → [discovery](./docs/archive/discovery.md)
- **Plain `join` + a manual whole-tunnel bring-up (`Table = off`)**, not `join
--whole-machine` — the latter crash-loops on Docker's read-only `/proc/sys`. →
  [discovery](./docs/archive/discovery.md), [plan](./docs/archive/plan.md)
- **Agent environment supplied by a `run` wrapper, not a shell rc** — plain join
  wires no rc. → [plan](./docs/archive/plan.md)
- **Agents trust the gateway CA _and_ the public roots** — else relayed hosts (real
  certs) break tools like `uv`/`pip`. → [architecture](./docs/architecture.md)
- **Gateway CA installed by the entrypoint**, not clawpatrol's built-in trust step
  — the latter needs `sudo`, which `no-new-privileges` refuses. →
  [discovery](./docs/archive/discovery.md)
- **Monitor + per-endpoint policy, not default-deny egress** — the gateway relays
  unknown hosts; the cage is the boundary. → [discovery](./docs/archive/discovery.md)
- **Manual, fingerprint-verified enrollment approval** — closes a plain-HTTP CA
  swap by a co-tenant. → [plan](./docs/archive/plan.md)
- **Agent runs as root in v1; non-root deferred** — a cost trade-off with bounded
  residual risk. → [plan](./docs/archive/plan.md)
- **Gateway hardened** — read-only rootfs, no added capabilities, loopback-only
  dashboard, named volumes (no host binds). → [discovery](./docs/archive/discovery.md)

## 🗂️ Repository layout

- [`stack/`](./stack) — the deployable Compose stack (gateway + ClawBot
  images, policy, entrypoints).
- [`tests/`](./tests) — acceptance + security test harness.
- [`docs/`](./docs) — [architecture](./docs/architecture.md) (the design record,
  as built) and [`archive/`](./docs/archive) (the historical discovery + plan,
  kept for rationale and source citations).
- [`stack/clawpatrol`](./stack/clawpatrol) — the gateway source (fork
  `akefirad/clawpatrol`), vendored as a submodule and compiled into the image.

## 🚀 Quick start

```sh
git clone --recurse-submodules <repo-url>
cd <repo>/stack

# 1. Bring up the gateway on its own — no ClawBots yet.
docker compose up -d gateway

# 2. Set the dashboard root password at http://127.0.0.1:5182 (see the warning below).

# 3. Start an agent, then approve its enrollment in the dashboard.
docker compose up -d clawbot-418
docker compose exec -it clawbot-418 run <your-agent>
```

> 🚨 **Set the dashboard password before starting any ClawBot.** Until it is set,
> clawpatrol's first-run form is open to anyone who can reach `:8080` — and ClawBots
> reach `:8080` over the cage by design. A ClawBot started before the password
> exists can claim root: the approval gate and the credential APIs.

Add agents by copying the `clawbot-418` service (new name, hostname, and volume).  
To run the full evaluation, see [`tests/README.md`](./tests/README.md).

## 🛠️ Deploying for real

The tracked `stack/` is a **reference**, wired for the acceptance tests
(`postman-echo` as the only in-scope endpoint, a dummy bearer credential). A real
deployment **copies `stack/` and diverges**: fill `gateway.hcl` with your real
upstreams + credentials, add a service per agent in `compose.yaml`, and keep
secrets in an untracked `.env`. (Manage that copy however you like — e.g. vendor
`stack/` and reconcile it as upstream moves.)

Two halves you supply outside this repo:

- **The agent and its provisioning.** The client image ships **bare** — it brings
  up the cage and the tunnel, then waits. You launch your agent into it
  (`docker compose exec -it clawbot-418 run <agent>`) and provision the agent's
  home however you like (e.g. bake your own dotfiles/installer into the client
  image).
- **The client half of credential injection.** The gateway only _swaps_ a
  placeholder for the real secret; the agent's home must already carry that
  placeholder. For ChatGPT-subscription (Codex/Hermes) auth that means seeding a
  fake, far-future JWT into the agent's `auth.json` — the provisioning layer's
  job, not this stack's. The gateway brings the upstream into scope and injects
  the real token. See [`docs/architecture.md`](./docs/architecture.md).

## 📊 Status

v0 — Built against clawpatrol `v0.5.1`.

## ⚖️ License

[MIT](./LICENSE).
