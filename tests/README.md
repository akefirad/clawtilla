# Clawtilla verification — test plan & harness

A complete, mostly-automated verification suite for the Clawtilla design
([architecture](../docs/architecture.md); historical
[plan](../docs/archive/plan.md) +
[discovery](../docs/archive/discovery.md)) and its
deployable stack ([`stack/`](../stack/)).

It does two things:

1. **Extracts every verifiable requirement** from the docs + stack and gives
   each a stable ID (the catalog below).
2. **Verifies each one** with a concrete check — a static parse, a build, or a
   runtime assertion against a live stack — and reports a pass/fail/skip/xfail
   ledger with full traceability back to the requirement and the plan's
   acceptance criteria (AC1–AC8) and the security review's findings (F/I/N/L).

The goal is to be able to say, with evidence, "the stack implements the
design, and the design's claims about clawpatrol hold," **or** to produce a
precise list of where it doesn't — including the security review's open gaps,
which are tracked as `XFAIL` (see below) rather than quietly omitted.

---

## How it's organised

```
tests/
├── README.md            # this file — the plan + the requirements catalog + matrix
├── run.sh               # orchestrator (phases: static | build | runtime; lifecycle + collision guard)
├── Makefile             # thin convenience wrapper
├── config.env           # tunable targets (hosts, ports, password) — keep in sync with the stack
├── verify.override.yaml # harness-only compose overlay: stamps the ownership label (collision safety)
├── lib/
│   ├── common.sh        # expect/pass/fail/skip/xfail model + assert_* helpers + reporting
│   ├── docker.sh        # compose/inspect/exec helpers
│   └── dashboard.sh     # clawpatrol gateway API client (login, approve, analytics, …)
├── static/              # no docker run required
│   ├── 10_compose.sh    # network topology, port exposure, gateway/client hardening
│   ├── 20_dockerfile.sh # multi-stage layout, source build (dual mode), no-USER, run wrapper
│   ├── 30_hcl.sh        # listen binding, profile/credential/rule presence, validate + F4/F6 lints
│   ├── 40_scripts.sh    # shellcheck + entrypoint logic (Table=off, plain join, …)
│   └── 50_source_lockstep.sh # source-build lockstep: submodule present, Dockerfile repo/ref default == submodule origin/commit
├── build/
│   └── 10_build.sh      # docker compose build both targets
└── runtime/             # live stack required (brought up by 00_bringup.sh)
    ├── 00_bringup.sh    # up + set password + enroll (fingerprint check + approval) + tunnel
    ├── 10_gateway_hardening.sh
    ├── 15_client_tunnel.sh
    ├── 20_cage.sh        # cage containment + review.md F1 (relay/SSRF) & F2 (DNS) gap probes
    ├── 30_tunnel_policy.sh
    ├── 40_credentials.sh # credential injection + review.md F6 (reflection) gap probe
    ├── 50_agent_env.sh
    ├── 60_lifecycle.sh
    └── 70_enroll_security.sh
```

### Reporting model

Each check is one `expect <REQ-ID> "<description>"` followed by exactly one
assertion. Results stream to the console **and** append to a result ledger
(`STATUS  REQ-ID  DESCRIPTION  SCRIPT  REASON`). `run.sh` prints an aggregate at
the end and exits non-zero **only if a `FAIL` occurred**. Statuses:

| Status | Meaning | Fails the run? |
|--------|---------|----------------|
| `PASS`  | the asserted invariant holds | — |
| `FAIL`  | the asserted invariant is broken (a regression) | **yes** |
| `SKIP`  | could not be exercised here (with a reason), never a silent pass | no |
| `XFAIL` | a **known, unresolved security gap**: the *desired* invariant is asserted and does **not** hold yet (it references a `docs/review.md` finding). Reported distinctly so it is visible, but tolerated. | no |

`XFAIL` exists so the review's open findings (F1 relay/SSRF, F2 DNS bypass, F4
dead policy, F6 credential reflection) are **exercised and reported** instead of
faked-green or quietly dropped. Each `XFAIL` check asserts the *fixed* behavior,
so it flips to `PASS` automatically the moment the gap is closed — at which point
the check should be promoted to a hard assertion. Where a gap can't be
demonstrated in the current environment (e.g. a metadata IP that isn't routable
from the gateway here), the probe records `SKIP`, not `PASS`, to avoid false
reassurance.

> **Finding-number caveat.** The `XFAIL` checks (`R-GAP-*`) cite the
> `docs/review.md` numbering (F1 = promiscuous relay / SSRF, F2 = DNS bypass,
> F4 = policy advertises unenforced rules, F6 = credential reflection). That is
> **not** the older finding scheme used in the traceability tables further down
> this file (where F1 = env-wiring, F2 = co-tenant enrollment, F3 = NET_ADMIN
> lateral, …). The `R-GAP-*` IDs are deliberately neutral to avoid the clash.

### Logging (one file per run, kept under `tests/logs/`)

All run artifacts live **under `tests/logs/` only** — nothing writes a log
outside that directory (the build log included). Each invocation of `run.sh`
creates a **fresh, timestamped** set so previous runs are never overwritten:

- `logs/verify-<YYYYmmdd-HHMMSS>.log` — full console transcript of the run
- `logs/results-<YYYYmmdd-HHMMSS>.tsv` — that run's machine-readable ledger
- `logs/build-<YYYYmmdd-HHMMSS>.log` — `docker compose build` output (build phase)

Old logs are **retained on disk** (handy for diffing runs). They're git-ignored,
so they accumulate locally without being committed. `make clean` removes only the
session/scratch files; `make clean-logs` is the explicit, destructive way to
delete retained run logs.

### Workflow: commit before each run

Treat the harness as code under change control. **Every time you change anything
(a script, the stack, config), make a git commit with a clear message _before_ the
next execution.** This keeps each run attributable to an exact, recorded state of
the tree, so a pass/fail can always be tied back to the precise code that
produced it (and a regression can be bisected). Suggested loop:

```bash
# 1. make a change
git add -A && git commit -m "verify: <what changed and why>"
# 2. then run
bash run.sh
```

---

## Prerequisites

- **Docker Desktop** (the design targets 4.73 on macOS arm64) with `docker compose` v2.
- **curl** and **jq** (`brew install jq`) — required for runtime/JSON checks.
- **shellcheck** (`brew install shellcheck`) — optional; static script linting skips without it.
- **git** — for the submodule-lockstep check; skips without it.
- Network egress on the Mac for the build (pull base image + clawpatrol binary)
  and for the supply-chain SHA check.

> **Sandbox note:** this repo enables a `beforeShellExecution` hook. If you run
> the suite from an automated agent and shell calls are being blocked, run it
> from a normal terminal instead — the harness is plain `bash`.

---

## Quickstart

```bash
cd tests

# Everything: static parse -> build images -> bring up & exercise the live stack.
bash run.sh                 # or: make all

# Just the cheap stuff (no docker run):
bash run.sh static          # or: make static

# Build then runtime only:
bash run.sh build runtime    # or: make verify

# Require a HUMAN to approve enrollment in the dashboard (production-faithful):
bash run.sh --manual-approve runtime   # or: make manual

# Leave the stack running afterwards for inspection (default is to tear it down):
bash run.sh --keep

# Wipe a leftover harness stack at startup, then run (needed after --keep / a crash):
bash run.sh --down

# Tear the harness stack down (volumes too), ownership-guarded:
bash run.sh --teardown      # or: make down

# List every check script:
bash run.sh --list
```

**Lifecycle & collision safety.** By default a run starts from a **clean slate**
and **tears the stack down at the end** (clean in, clean out); pass `--keep` to
retain it for inspection. Before bring-up the harness demands the `$PROJECT`
namespace be empty:

- A same-named project the harness did **not** create (its resources lack the
  `com.akefirad.clawtilla.harness=verify` ownership label, stamped via
  [`verify.override.yaml`](./verify.override.yaml)) is treated as a **foreign**
  deployment and is **refused outright** — never reused or destroyed. Run under a
  different name to proceed: `PROJECT=clawtilla-verify-$$ bash run.sh`.
- The harness's **own** leftover (after `--keep` or a crash) is refused **unless**
  you pass `--down`, which wipes it first. The destructive teardown
  (`--teardown` / `make down`) applies the same ownership check, so it can never
  reap a project the harness didn't create — even one that happens to share the
  name.

**Dashboard password.** The harness sets the root password on first run the
documented way — `clawpatrol gateway --set-dashboard-password <pw> <config>`
(which upserts the bcrypt password into `clawpatrol.db`, then serves;
`main.go:671-686`). It does this on a throwaway first-run container so the
password lands on the shared state volume; the real serving container then skips
the first-run web flow. (`config.env`'s `DASH_PW` is test-only — use a strong
random secret for anything real.)

**Enrollment approval.** The client's `join` prints a `Verify code in browser:`
block to its logs with the code and an onboarding URL on the loopback —
`http://127.0.0.1:5182/#/onboard/<code>` (`setup.go:1001-1016`). Approval is the
operator clicking **Approve** on that page.

- **Default (auto)**: the harness reads that URL + the CA fingerprint from the
  client logs, **enforces that the fingerprint matches** what the gateway
  advertises (review **F2**'s defense, automated), and only then performs the
  exact action the CTA performs — `POST /api/onboard/approve` over an
  authenticated session.
- **`--manual-approve`**: the harness prints **and opens** the onboarding URL and
  waits for you to compare the fingerprint and click **Approve** yourself.

### Isolation from a real deployment

The verification suite is built to coexist with a real deployment of the same
stack (e.g. a production stack brought up as `clawtilla`) on the same
machine, on three axes:

- **Project namespace.** The harness always runs under a **dedicated Compose
  project name** (`PROJECT`, default `clawtilla-verify` in `config.env`), passed
  as `-p "$PROJECT"` to every `docker compose` call. So all of the test stack's
  resources are namespaced — `clawtilla-verify_*` networks/volumes,
  `clawtilla-verify-*` images/containers — and **cannot collide with or tear
  down** the real stack. `-p` overrides the compose file's own `name:`, so this
  holds regardless of what the stack declares. `net_name` is likewise
  strictly project-scoped, so an ephemeral cage probe is never attached to
  another project's identically-suffixed network.
- **Ownership label (collision discriminator).** A fixed project name can't, on
  its own, tell the harness's *own* leftover stack apart from a real deployment
  that happens to share the name. So a harness-only overlay
  ([`verify.override.yaml`](./verify.override.yaml), merged into every
  `docker compose` call) stamps `com.akefirad.clawtilla.harness=verify` on every resource
  the harness creates; the shipped `stack/compose.yaml` never carries it. The
  harness checks this label before it reuses or destroys anything: a same-named
  project **without** the label is foreign and is left strictly untouched (see
  *Lifecycle & collision safety* above). This is what makes the destructive
  `down -v` safe even under a name collision.
- **Dashboard host port.** The stack publishes the dashboard on
  `127.0.0.1:${CLAWTILLA_DASH_PORT:-5182}:8080` — a real deployment leaves the
  knob unset and gets the documented `127.0.0.1:5182`. The test stack instead
  publishes on a **random loopback host port**: `runtime/00_bringup.sh` exports
  `CLAWTILLA_DASH_PORT=0` before bring-up (host port `0` ⇒ Docker assigns a free
  one), then discovers the assigned port (`docker compose port`) and records it
  in `logs/.dash_port` so the rest of the runtime scripts (separate processes)
  target the right URL. This means the suite never contends for `5182`, so it
  can run while your real stack is up. (The static port check still asserts the
  stack's `5182` default — it parses the config with `CLAWTILLA_DASH_PORT`
  unset. The baked `public_url` in `gateway.hcl` still says `5182`, so the
  onboarding link the client logs points there; the harness approves via the
  discovered port regardless, and in `--manual-approve` it prints the
  discovered-port link.)

To pin a fixed test port, export `CLAWTILLA_DASH_PORT`; to point the harness at
an already-running stack on a known port, export `DASH_HOST_URL`.

### Configuration

`config.env` holds the tunable targets and **must track the stack**:
`ALLOWED_MITM_HOST` (the in-scope, MITM'd endpoint), `RELAY_HOST` (an
unconfigured host used to prove the relay-not-deny behavior), `SECRET_PLAINTEXT`
(the dummy credential value wired in `compose.yaml`), and `DASH_PW`. The
known-gap (`XFAIL`) probes add a few more: `METADATA_IP` + `HOST_GATEWAY_NAME`
(F1 SSRF targets), `DNS_PROBE_NAME` (F2 off-tunnel resolution), and
`REFLECTING_HOSTS` (F6 — upstreams that echo request headers back). Every value
is overridable from the environment. **`DASH_PW` is a test-only default — set a
strong random secret for anything real.**

---

## Methodology — three phases

| Phase | Needs | Proves |
|-------|-------|--------|
| **static** | files only | the *config* encodes the design (topology, caps, pins, policy shape, entrypoint logic). Fast, deterministic, runnable in CI. |
| **build** | docker | the multi-stage Dockerfile builds and the SHA-pinned binary downloads + verifies. |
| **runtime** | docker + a live stack | the system actually *behaves* as designed — the cage contains, the tunnel carries policy-inspected traffic, secrets stay at the gateway, lifecycle is decoupled, hardening holds on the running containers. |

Static and runtime deliberately **overlap** on the load-bearing claims (e.g. "no
host bind mounts" is checked both in `compose.yaml` and on the live container via
`docker inspect`) — config can drift from reality, so both are asserted.

### Resilience to a flaky tunnel

The client↔gateway WireGuard link can be briefly unstable, so a single `curl`
from a ClawBot may fail transiently. Every **network-dependent positive check
retries** (`RETRY_ATTEMPTS` × `RETRY_DELAY`, plus `CURL_MAX_TIME` per request —
all in `config.env`):

- `tbot_http_code` / `tbot_body` (in `lib/docker.sh`) retry **only** on a
  connection failure (curl code `000`/empty). A *definite* HTTP status — a `200`
  allow or a `403` deny — is returned immediately and **never** retried, so the
  policy assertions stay exact (a real deny can't be masked by a retry).
- Dashboard log lookups (`analytics_has`) and tunnel/egress probes are wrapped in
  `wait_for` / `retry` so a momentary flap doesn't fail the run.
- **Negative / cage tests are *not* retried** (e.g. "no egress with the tunnel
  down", "host unreachable") — there, a connection failure is the expected
  outcome, so retrying would only waste time, never flip the result.

---

## Requirements catalog

Every requirement extracted from the docs + stack, its source, how it's verified,
and the check IDs that cover it. `AC*` = plan acceptance criterion; `F/I/N/L` =
security-review finding.

### A. Network isolation — the cage (load-bearing)

| ID | Requirement | Source | How verified | Checks |
|----|-------------|--------|--------------|--------|
| R-NET-1 | `clawcage-net` is `internal: true` (no NAT/host route) | discovery "Network separation" | parse compose | static/10 |
| R-NET-2 | clients attached **only** to `clawcage-net` | plan Step 1 | parse compose + `docker inspect` | static/10, runtime/15 |
| R-NET-3 | gateway dual-homed (clawegress-net + clawcage-net) | discovery topology | parse compose + inspect | static/10, runtime/10 |
| R-NET-4 | gateway has the `gateway` alias on clawcage-net | discovery "discovery" | parse compose | static/10 |
| R-NET-5 | **tunnel-down: a cage container has zero internet egress** (AC2-down) | plan AC2, discovery | ephemeral probe on clawcage-net → egress fails, gateway reachable | runtime/20 |
| R-NET-6 | client cannot reach the Mac host (`host.docker.internal`) | plan AC3, review L2 | live negative test from ClawBot | runtime/20 |
| R-NET-7 | WireGuard 51820/udp is **not** published to the host | discovery "Port binding" | parse compose + `docker compose port` | static/10, runtime/20 |
| R-NET-8 | dashboard published on `127.0.0.1:5182` only | discovery "Port binding" | parse compose + live port + reachability | static/10, runtime/00, runtime/20 |
| R-NET-v6 | **no IPv6 egress leak** from the cage (no v6 default route, or it is via the tunnel) | review **L3** | live `ip -6 route` from ClawBot | runtime/20 |
| R-NET-bind | `dashboard_listen = 0.0.0.0:8080` (clients need :8080 for join) | discovery N6 | parse hcl | static/30 |

### B. Tunnel / WireGuard bring-up

| ID | Requirement | Source | How verified | Checks |
|----|-------------|--------|--------------|--------|
| R-WG-4 | plain `clawpatrol join` (not `--whole-machine`); no `clawpatrol up` | plan Step 5 | parse client.sh | static/40 |
| R-WG-2 | tunnel up with `Table = off` + **manual default route** | plan Step 5 | parse client.sh + live route/conf | static/40, runtime/15 |
| R-WG-3 | `/proc/sys` stays **read-only**; no `systempaths=unconfined` | plan "Known risks" | live write-fail + inspect security_opt | runtime/15 |
| R-WG-1 | WG interface comes up and carries a peer; backend present (kernel module preferred, userspace `wireguard-go` accepted as SKIP) | plan Step 4 (resolved) | live `wg show` + `ip link add type wireguard` probe | runtime/00, runtime/15 |
| R-WG-5 | client → allowed upstream works through the tunnel | plan AC1 | live request from ClawBot → 200 | runtime/30 |
| R-WG-6 | that traffic is logged (tunneled + MITM + policy-inspected) | plan AC1 | dashboard `/api/analytics` shows allow event | runtime/30 |
| R-WG-cap/dev | client gets exactly `NET_ADMIN` + `/dev/net/tun` | plan Step 1 | parse compose + inspect + live | static/10, runtime/15 |

### C. Policy / rule engine

| ID | Requirement | Source | How verified | Checks |
|----|-------------|--------|--------------|--------|
| R-POL-4 | every ClawBot has a profile (unprofiled = fail-open passthrough) | stack/gateway.hcl, source main.go:1798 | parse hcl (profile + bound credential) | static/30 |
| R-POL-1 | configured endpoint: GET/HEAD allowed (200) + logged | plan AC2 | live GET → 200 + analytics allow | runtime/30 |
| R-POL-2 | configured endpoint: disallowed verb (POST) → clean 403 | plan AC2, discovery | live POST → 403 + analytics deny | runtime/30 |
| R-POL-3 | **unconfigured host still relays (success), not deny** | plan AC2c, **review I1**, **N1** | live request to RELAY_HOST → 2xx/3xx | runtime/30 |
| R-POL-5 | `unknown_host=deny` is dead config for HTTPS (monitor-only) | discovery "Open questions", main.go:1424 | documented + R-POL-3 demonstrates relay | static/30, runtime/30 |

### D. Credential injection ("secrets stay at the gateway")

| ID | Requirement | Source | How verified | Checks |
|----|-------------|--------|--------------|--------|
| R-CRED-1 | gateway **adds** `Authorization` when agent sends none | discovery "Open questions" | echo endpoint reflects injected header | runtime/40 |
| R-CRED-2 | gateway **overwrites** a client-supplied `Authorization` | discovery "Open questions" | echo reflects gateway secret, not client's | runtime/40 |
| R-CRED-3 | the real secret never reaches the agent (env/config/`clawpatrol env`) | plan F1/credential model | grep agent env + config for plaintext | runtime/40 |
| R-CRED-4 | no secret → injection skipped, rules still run | discovery "Open questions" | needs a config variant — **reported as SKIP** | runtime/40 |

### E. Agent env wiring (review F1)

| ID | Requirement | Source | How verified | Checks |
|----|-------------|--------|--------------|--------|
| R-ENV-1 | `run` wrapper sets `NODE_EXTRA_CA_CERTS` + `REQUESTS_CA_BUNDLE` (+curl/ssl) | plan AC8, **F1** | `run env` from ClawBot | runtime/50 |
| R-ENV-3 | plain join installed **no** shell rc (wrapper is required) | discovery CA/env, **F1** | `bash -lc env` has no CA vars | runtime/50 |
| R-ENV-4 | gateway CA is in the system trust store (installCATrust on plain join) | discovery CA/env | system-store curl validates MITM cert | runtime/50 |
| R-ENV-2 | any pushed credential placeholder var is a placeholder, not the secret | plan AC8 | env has no plaintext secret | runtime/50 |
| R-ENV-wrapper | the `run` wrapper is baked and evals `clawpatrol env` | stack/Dockerfile, **F1** | parse Dockerfile | static/20 |

### F. Lifecycle / persistence

| ID | Requirement | Source | How verified | Checks |
|----|-------------|--------|--------------|--------|
| R-LIFE-3 | PID 1 is tini (`init: true`) | plan "lifecycle" | parse compose + live `/proc/1/comm` | static/10, runtime/60 |
| R-LIFE-4 | entrypoint enrollment-aware (join once, bring-up always) | plan Step 5 | parse client.sh | static/40 |
| R-LIFE-1 | **agent restart decoupled**: kill agent → container Up, tunnel stays | plan AC6 | live: run+kill agent, assert container + tunnel | runtime/60 |
| R-LIFE-2 | **container restart survives**: re-up from conf, no re-join/approval; derived `/etc/wireguard` conf regenerated (`Table = off`) | plan AC7 | live `restart`, assert no re-enroll + same WG key + regenerated derived conf | runtime/60 |
| R-LIFE-5 | home volume persists `~/.config/clawpatrol/wg.conf` | discovery "Client state" | parse compose + WG-key stable across restart | static/10, runtime/60 |

### G. Gateway hardening

| ID | Requirement | Source | How verified | Checks |
|----|-------------|--------|--------------|--------|
| R-GW-1 | read-only rootfs (writing `/` fails) | discovery hardening | parse compose + live `touch /` | static/10, runtime/10 |
| R-GW-2 | `/tmp` tmpfs writable; named state volume writable under the RO rootfs | discovery hardening | parse compose + live touch (`/tmp` + `/opt/clawpatrol`) | static/10, runtime/10 |
| R-GW-3 | state_dir is `0700` (gateway.sh chmod) | plan Step 2 | parse gateway.sh + live `stat` | static/40, runtime/10 |
| R-GW-3f | no group/other-accessible dirs under state_dir (CA material included) | plan Step 2 | live `find -perm /077` | runtime/10 |
| R-GW-4 | `clawpatrol.db` is `0600` | discovery, db.go:69 | live `stat` | runtime/10 |
| R-GW-5 | no "state loosely permissioned" boot warning | plan Step 2, main.go:97 | grep gateway logs | runtime/10 |
| R-GW-6 | gateway has **no host bind mounts** | plan AC5, **review I2** | parse compose + live `Mounts` | static/10, runtime/10 |
| R-GW-7 | no `host.docker.internal`/host-gateway injected | plan AC5 | parse compose + live `ExtraHosts` | static/10, runtime/10 |
| R-GW-8 | gateway → internet works | plan AC5 | live curl from gateway | runtime/10 |
| R-GW-9 | `no-new-privileges`; no added caps; **no devices** (no `/dev/net/tun`); not on cage-only | plan Step 1 | parse compose + inspect | static/10, runtime/10 |
| R-GW-10 | gateway.hcl baked into image (not bind-mounted) | plan Step 2, **I2** | parse Dockerfile | static/20 |

### H. Enrollment security

| ID | Requirement | Source | How verified | Checks |
|----|-------------|--------|--------------|--------|
| R-ENR-1 | manual operator approval mandatory (no WG auto-approve) | plan Step 6, **N4** | enrollment requires API/human approve; approve needs auth | runtime/00, runtime/70 |
| R-ENR-2 | CA fingerprint (CLI) matches gateway (defeats on-path swap) | plan Step 6, **F2** | compare client-log fp vs `/info` fp | runtime/00 |
| R-ENR-3 | client reaches :8080 but can't act without root password (and the same route returns 200 *with* an operator session — proving an auth gate, not a dead route) | plan AC4 | live: /info 200, /api/status + /api/state 401 from ClawBot, /api/state 200 with session cookie | runtime/70 |
| R-ENR-4 | onboard public but approve requires operator session | discovery, web.go:247-249 | live: /ca.crt 200, approve 401 unauth | runtime/70 |
| R-ENR-5a | password set on first run via `--set-dashboard-password` CLI flag | plan Step 6, main.go:671-686 | throwaway gateway run upserts to the state volume | runtime/00 |
| R-ENR-5b | operator logs in with the CLI-set password (no web first-run) | plan Step 6 | live login → session cookie | runtime/00 |
| R-ENR-5 | dashboard password meets the 12-char minimum (strong secret) | **N3**, web.go:517 | length ≥ 12 | runtime/70 |

### I. Build / supply-chain integrity

| ID | Requirement | Source | How verified | Checks |
|----|-------------|--------|--------------|--------|
| R-IMG-1 | clawpatrol built from source (`make`), not downloaded; dual src-local/src-remote modes, pinnable + selectable flavor | plan Step 2 | parse Dockerfile | static/20 |
| R-IMG-2 | vendored submodule at `stack/clawpatrol` is the src-local source; remote-mode repo default == submodule origin | plan Step 2 | git + parse Dockerfile | static/50 |
| R-IMG-3 | client image has no `USER` line (root for bring-up) | plan Step 4 | parse Dockerfile (client stage) | static/20 |
| R-IMG-4 | one multi-stage Dockerfile → gateway/client targets | plan Step 2 | parse Dockerfile | static/20 |
| R-BUILD | both images build cleanly | plan Step 6 | `docker compose build` | build/10 |

### J. Accepted-risk nodes (verified-as-documented, not "closed")

| ID | Node | Source | Stance in this suite |
|----|------|--------|----------------------|
| N1 | egress is monitor-only, not default-deny | review N1 | **demonstrated** by R-POL-3 (relay succeeds); not treated as a failure |
| N2 | gateway → host best-effort on Docker Desktop | review N2 | **not asserted closed**; documented as residual (would need an in-container egress firewall) |
| N3 | clients can reach the dashboard port | review N3 | mitigated by R-ENR-3/4/5 (auth gate + strong password) |
| N5 / F3 | client↔client lateral movement (shared L2 + NET_ADMIN) | review F3/N5 | **accepted, not tested**; suite verifies the *cage* (escape) holds and caps are minimized to NET_ADMIN. Lateral isolation is an explicit open item. |
| F5 | agent runs root + NET_ADMIN | review F5 | accepted for POC; suite confirms caps live only via PID 1's needs; non-root exec is the documented future hardening. |
| L1 | test secret committed in compose | review L1 | flagged: static/10 asserts it's the known dummy (`L1`) **and** that no other `CLAWPATROL_SECRET_*` is committed (`L1b`) |
| L3 | IPv6 default route best-effort | review L3 | **asserted** by R-NET-v6 (no v6 egress path, or v6 default is via the tunnel) |

### K. Known security gaps (`XFAIL` — from `docs/review.md`)

Unresolved findings from the comprehensive review. Each check asserts the
**desired (fixed)** behavior, records `XFAIL` while the gap stands (it does
**not** fail the run), and flips to `PASS` the moment the gap closes — at which
point it should be promoted to a hard assertion. (`Fn` here is the
`docs/review.md` scheme, **not** the older one in the F/I/N tables above.)

| ID | Gap (desired invariant) | review.md | How verified | Checks |
|----|-------------------------|-----------|--------------|--------|
| R-GAP-DNS | cage cannot resolve arbitrary external names off-tunnel (DNS gated by the gateway) | **F2** | ephemeral no-tunnel cage probe resolves `DNS_PROBE_NAME` via `127.0.0.11` → `XFAIL` | runtime/20 |
| R-GAP-SSRF-META | gateway relay refuses the cloud-metadata IP from the cage | **F1** | live ClawBot reaches `METADATA_IP` via the relay → `XFAIL`; unroutable here → `SKIP` | runtime/20 |
| R-GAP-SSRF-RFC1918 | gateway relay refuses host-side RFC1918 (its egress bridge gateway) | **F1** | live ClawBot reaches the egress bridge-gateway IP via the relay → `XFAIL`; no listener → `SKIP` | runtime/20 |
| R-GAP-DEADRULE | every endpoint with an `allow` rule is bound by a credential (no dead allow rules) | **F4** | parse hcl: `ghapi`/`api.github.com` has an allow rule but no credential → `XFAIL` | static/30 |
| R-GAP-CRED-REFLECT | no endpoint host is a known header-reflecting upstream | **F6** | parse hcl: `postman-echo.com` is bound + reflects → `XFAIL` (benign dummy here) | static/30 |
| R-GAP-CRED-LEAK | agent cannot read the gateway-injected secret from the upstream response | **F6** | live: reflecting upstream echoes the injected `Authorization` back to the agent → `XFAIL` | runtime/40 |

---

## Acceptance-criteria traceability (plan Step 7)

| AC | Statement (as corrected for I1) | Covered by |
|----|----------------------------------|------------|
| AC1 | client → allowed upstream works **and** appears in the request log | R-WG-5, R-WG-6 |
| AC2 | cage contains (tunnel down) **+** per-endpoint policy applies (tunnel up); unconfigured hosts still relay | R-NET-5, R-POL-1, R-POL-2, R-POL-3 |
| AC3 | client ↛ host | R-NET-6 |
| AC4 | client ↛ privileged dashboard actions | R-ENR-3 |
| AC5 | gateway → internet; no host bind mounts; no host.docker.internal | R-GW-8, R-GW-6, R-GW-7 |
| AC6 | agent restart is decoupled | R-LIFE-1 |
| AC7 | container restart survives (no re-join) | R-LIFE-2 |
| AC8 | agent env is wired (F1) | R-ENV-1, R-ENV-2 |

## Security-review traceability (see docs/architecture.md)

| Finding | Addressed by |
|---------|--------------|
| **F1** env never wired | R-ENV-1, R-ENV-3 (and the fix is in stack/Dockerfile's `run` wrapper) |
| **F2** co-tenant enrollment hijack | R-ENR-2 (fingerprint match enforced before approval) |
| **F3** NET_ADMIN lateral isolation | N5 row — accepted; cage/escape verified, lateral left open |
| **F4** rogue/approval-fatigue → real creds | R-ENR-1, R-ENR-4 (approve requires operator session) |
| **F5** root + NET_ADMIN agent | N5/F5 row — accepted; future non-root exec documented |
| **I1** AC2 wording | R-POL-3 asserts the *real* (relay) behavior |
| **I2** gateway bind mount | R-GW-6, R-GW-10 (hcl baked, no bind) |
| **N1–N6, L1–L3** | J table above |

---

## Limitations (what is honestly *not* fully automated)

- **Enrollment approval** is operator-gated by design (clicking **Approve** on
  the onboarding page the client logs link to). The default mode performs that
  same action via the authenticated API *after* an enforced CA-fingerprint match;
  `--manual-approve` opens the URL and waits for you to click. There is no WG
  `--auto-approve` to test.
- **R-CRED-4** (no-secret injection-skip branch) needs an in-scope endpoint with
  no connected secret, which the stack config doesn't provide — reported as `SKIP`
  rather than faked. Add a `gateway.verify.hcl` variant to exercise it.
- **Lateral client↔client attacks** (F2 exploit, F3) are an accepted open item
  (N5). The suite verifies the cage (escape) and that caps are minimized, but
  does not run an ARP-spoofing co-tenant.
- **Gateway → host (N2)** is best-effort and intentionally *not* asserted closed.
- **Kernel-vs-userspace WG** is environment-dependent (LinuxKit); the suite
  confirms a working tunnel and *reports* which backend is in use.
```
