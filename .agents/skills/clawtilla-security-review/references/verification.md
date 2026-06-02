# Live verification cookbook

Config describes **intent**; `docker inspect` describes **reality**. A network can
be attached at runtime, caps added, a mount slipped in — none visible in
`compose.yaml`. When Docker is reachable, confirm static findings against the
running stack and probe the boundaries directly. When it isn't, say "static only"
in the report and don't pretend otherwise.

All commands assume the repo root. Set `STACK` to the directory under review —
the tracked `stack/` or a deployed copy of it (see SKILL.md's Orient
step).

## Decide the mode first

```sh
STACK=stack                           # the dir under review (the tracked stack, or a deployed copy)
docker info >/dev/null 2>&1            # Docker reachable at all?
docker compose -f $STACK/compose.yaml ps   # is the stack already up?
```

- **Stack already up** → prefer **non-destructive** inspection + probes (below).
  This is the best signal: real runtime state, nothing torn down.
- **Stack down, user wants runtime proof** → the harness can build + bring it up,
  but read the warning next.
- **Docker unavailable** → static-only review.

## Is the enforcement source available?

Orthogonal to the Docker-reachability axis, and it matters even in a static-only
review: **the real verdict/splice/credential-injection logic is in
`oss/clawpatrol`, not the stack.** Claims like "unprofiled devices fail open to
passthrough" (`gateway.hcl`) or "clawpatrol hardcodes passthrough for unbound HTTPS
hosts" (N1) are *mechanism* claims — true only if that code does it. Confirm the
source is in front of you:

```sh
git submodule status oss/clawpatrol     # leading '-' = NOT checked out
```

- **Checked out** → read and cite the source for any load-bearing claim (anchor on
  function names, not line numbers — see SKILL.md's source-verification note).
- **Not checked out, claim load-bearing** → `git submodule update --init
  oss/clawpatrol`, then read it.
- **Can't be fetched** → every clawpatrol mechanism claim drops to
  *static-from-stack-comment*: cite the stack's own assertion with `file:line` and
  list the behaviour under **needs submodule verification** in the report. An honest
  gap beats a guess.

## The harness already encodes these checks

`tests/run.sh` runs three phases — `static` (parse compose/Dockerfile/hcl/scripts;
no containers), `build` (build both images), and `runtime` (bring the stack up and
exercise it) — printing `PASS/FAIL/SKIP/XFAIL <R-ID> <desc>`, each mapped to a
requirement in `tests/README.md`'s coverage matrix. It is the fastest way to get
runtime coverage.

```sh
cd tests && bash run.sh             # full: static -> build -> runtime; tears the stack down at the end
bash run.sh static                  # static config analysis only (no containers needed)
bash run.sh --keep runtime          # bring up + exercise, then LEAVE the stack running
bash run.sh --teardown              # just tear the harness stack down (== make down)
```

**Warning — the `runtime` phase tears the stack down by default** when it
finishes (`safe_down`, volumes included), forcing every client to re-enroll; pass
`--keep` to retain it. The harness runs under its own test-scoped project name
(`clawtilla-verify`) and an ownership label, so it refuses to adopt or wipe a
real deployment of the same name — but still don't run `runtime` against a stack
the user cares about without asking. The `static` phase is pure `docker compose
config` analysis and is always safe. Map each `FAIL` to a finding; treat `SKIP`
as **untested**, never as passed; and read `XFAIL` as a known, still-open gap —
the desired invariant is asserted but does not hold yet (the `R-GAP-*` probes:
off-tunnel DNS bypass, SSRF/metadata + RFC1918 relay, the dead allow rule, and
credential reflection). The live CA-swap MITM is still never exercised (`R-ENR-2`
only checks fingerprint *consistency*), so F2's live defense remains unproven.

## Non-destructive probes (run against an already-up stack)

### Resolved config — what compose *means* (no containers needed)
```sh
docker compose -f $STACK/compose.yaml config            # the effective graph; audit THIS
docker compose -f $STACK/compose.yaml config --format json | jq '.networks'
```
Check: `clawcage-net.internal == true`; `clawegress-net.internal == null`; each
ClawBot's `.networks` has `clawcage-net` and nothing else; gateway on both with
the `gateway` alias; dashboard port `host_ip == 127.0.0.1`, target 8080; no port
targets 51820; gateway `cap_add`/`devices`/`extra_hosts` null; gateway
`read_only == true`; `security_opt` contains `no-new-privileges` on both; no
`systempaths` anywhere; gateway volumes all `type == volume` (no `bind`).

### Runtime reality — `docker inspect` (config can lie)
```sh
GW=$(docker compose -f $STACK/compose.yaml ps -q gateway)
CL=$(docker compose -f $STACK/compose.yaml ps -q clawbot-418)

docker inspect "$GW" | jq '.[0].HostConfig.CapAdd, .[0].HostConfig.Binds, .[0].HostConfig.ExtraHosts, .[0].HostConfig.ReadonlyRootfs, .[0].HostConfig.SecurityOpt'
docker inspect "$CL" | jq '.[0].HostConfig.CapAdd, .[0].HostConfig.SecurityOpt'

# Which networks is each container ACTUALLY on right now?
docker inspect "$CL" | jq '.[0].NetworkSettings.Networks | keys'   # must be cage only
docker network inspect clawtilla_clawcage-net | jq '.[0].Internal' # must be true
```
A container on a network that isn't in `compose.yaml`, or a cap/bind present at
runtime but absent in the file, is drift — and a finding.

### Boundary probes (the actual security properties)
```sh
# Cage holds: with the tunnel DOWN, all egress must fail (000), to name AND raw IP.
docker compose -f $STACK/compose.yaml exec -T clawbot-418 wg-quick down clawpatrol
docker compose -f $STACK/compose.yaml exec -T clawbot-418 \
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://example.com/   # want 000
docker compose -f $STACK/compose.yaml exec -T clawbot-418 \
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://1.1.1.1/        # want 000
# (restore: container restart re-ups from the persisted conf)
docker compose -f $STACK/compose.yaml restart clawbot-418

# Host unreachable: by CONNECTION, not name resolution.
docker compose -f $STACK/compose.yaml exec -T clawbot-418 \
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://host.docker.internal/  # want 000

# No IPv6 leak: no v6 default route, or one via the tunnel.
docker compose -f $STACK/compose.yaml exec -T clawbot-418 ip -6 route show default

# Link-local unreachable too (SSRF reflex; same cage property as the raw-IP probe).
docker compose -f $STACK/compose.yaml exec -T clawbot-418 \
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://169.254.169.254/  # want 000 (non-000 = second iface / injected route)

# Dashboard reachable on the cage but privileged action gated without the password.
docker compose -f $STACK/compose.yaml exec -T clawbot-418 \
  curl -s -o /dev/null -w '%{http_code}' http://gateway:8080/ca.crt           # want 2xx
docker compose -f $STACK/compose.yaml exec -T clawbot-418 \
  curl -s -o /dev/null -w '%{http_code}' http://gateway:8080/api/state        # want 401/403/302

# Gateway egress works (it is the egress point).
docker compose -f $STACK/compose.yaml exec -T gateway \
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://example.com     # want 2xx/3xx

# Gateway self-protection: rootfs immutable.
docker compose -f $STACK/compose.yaml exec -T gateway touch /probe 2>&1         # want a read-only error
```

The tunnel-down probe is **disruptive** (kills egress for that client until
restart). Note that the client↔gateway WG link is flaky to re-establish in place;
the documented recovery is a container restart. `tests/lib/docker.sh` has hardened
helpers (`dc`, `xsh`/`xrun`, `tbot_http_code`, `wait_for`, `safe_down`) and
`tests/lib/common.sh` has `retry` if you script this; the cage-with-no-tunnel
probe is implemented as an ephemeral container in `tests/runtime/20_cage.sh`.

### Dashboard auth (for AC1 log confirmation / AC4)
The dashboard sets a `cp_session` cookie via the first-run form
(`POST /__login` with `password`). With the cookie, `GET /api/analytics?range=15m`
shows the request log (confirm an allowed request was tunneled+MITM'd), and
`GET /api/state` should be 200 *with* the cookie (`R-ENR-6`), rejected without
(`R-ENR-3c`). See `tests/lib/dashboard.sh` `dash_login`/`dash_analytics`/`dash_get`.

## Reading results into findings

- A `FAIL` or a failed probe → a finding at the severity its broken link implies
  (use the SKILL.md rubric, not the test's own weighting).
- Static says safe but `docker inspect` shows otherwise → **drift**, and the
  runtime reality wins. Report it.
- `SKIP` / a probe you couldn't run → list it under "Live verification detail" as
  untested. Don't imply coverage you didn't get.
- **Reasoned, not demonstrated.** Some exploits can't be shown without a simulated
  attacker — a live ARP/CA-swap MITM of a peer's plain-HTTP `join` (F2/A3),
co-tenant L2 spoofing/sniffing (A2), root-agent kernel escape (F5). The harness
can't run these (`tests/README.md` lists them as accepted-risk rows — section
"J. Accepted-risk nodes" — not as passing checks), so a PASS nearby is not
evidence the exploit fails. For each:
  reason it through, cite the enabling conditions (shared L2 + `NET_ADMIN` +
  TOFU-over-plain-HTTP enrollment) — the suite documents these as accepted-risk
  rows (e.g. `N5`/`F3` lateral movement) rather than passing checks — and report
  at the severity its link implies —
  explicitly labelled **reasoned, not demonstrated** under "Live verification
  detail," separate from "untested probe." Never dress it as a working exploit;
  never silently drop it.
