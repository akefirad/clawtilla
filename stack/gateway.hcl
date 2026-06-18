# Clawtilla gateway config. Trimmed from
# clawpatrol/examples/gateway.example.hcl to the minimum needed.
#
# Hot-reloadable: every policy block. The `gateway` block (listen ports,
# state_dir, transport sub-blocks) needs a restart.

# Config grammar version (clawpatrol v0.2.5+). Omitting it loads as legacy
# version 0 WITH a deprecation warning (internal/config/config.go); pinning it
# makes a future, too-new clawpatrol fail loudly ("upgrade clawpatrol") instead
# of silently misreading the grammar. Supported window is 0..1.
schema_version = 1

gateway {
  dashboard_listen = "0.0.0.0:8080"          # clients need :8080 on clawcage-net for join/CA
  public_url       = "http://127.0.0.1:5182" # operator approval links only
  state_dir        = "/opt/clawpatrol"

  wireguard {
    subnet_cidr = "10.55.0.0/24"
    listen_port = 51820                      # UDP bind port. clawpatrol HONORS this
                                             # since v0.2.6 (cl-94cf); before, it was
                                             # silently ignored and always bound 51820.
                                             # Pinned == the endpoint port below so the
                                             # advertised and actual ports can't drift.
    endpoint    = "gateway:51820"            # overrides public_url-derived endpoint;
                                             # clients resolve `gateway` via Docker DNS
  }
}

defaults {
  # DEAD CONFIG for HTTPS — kept only because clawpatrol requires the key.
  # clawpatrol's SNI-peek handler hardcodes passthrough (splice) for any host
  # NOT bound to the active profile's endpoints, REGARDLESS of this value (the
  # `ep == nil` branch in cmd/clawpatrol/main.go). The cage — not unknown_host —
  # is the egress boundary (see N1 in docs/architecture.md). It is NOT a
  # default-deny posture for the relay path.
  unknown_host  = "deny"
  llm_fail_mode = "closed"
}

# HOW TO POLICY-ENFORCE AN UPSTREAM (this replaces the old, DEAD `ghapi` rule).
# clawpatrol only MITMs + rule-evaluates an endpoint that is IN SCOPE — i.e.
# reachable through the active profile via the transitive closure
# profile -> credential -> endpoint (internal/config/compile.go). An `endpoint` +
# `rule` that NO profile's credential points at is DEAD CONFIG: the host is
# passthrough-relayed (spliced), never rule-evaluated — it only LOOKS policed.
# The old `ghapi`/api.github.com pair was exactly that (defined, never bound to
# `default`), so api.github.com was relayed, not the advertised read-only
# allowlist (review.md F4). It has since been removed — the commented example
# below is inert. The R-GAP-DEADRULE check in tests/static/30_hcl.sh guards
# against a LIVE dead allow rule (an allowed endpoint no credential binds) and
# currently PASSES: the only live endpoint, `echo`, is bound. If you uncomment
# the `ghapi` rules below but forget the credential, that check will catch it.
# To add read-only GitHub for real, uncomment ALL of the following AND the
# profile line below:
#
#   endpoint "https" "ghapi" { hosts = ["api.github.com"] }
#   # Binds ghapi into scope. Use `bearer_token` when you want to INJECT a token
#   # (connect a real one via the dashboard). For a purely public, no-auth endpoint
#   # prefer `credential "passthrough" "ghapi" { endpoint = https.ghapi }` (v0.2.5+)
#   # over the old empty-bearer hack — same in-scope/policed effect, injects nothing.
#   credential "bearer_token" "ghapi-token" { endpoint = https.ghapi }
#   rule "ghapi-reads"   { endpoint = https.ghapi  condition = "http.method in ['GET', 'HEAD']"  verdict = "allow" }
#   # MANDATORY catch-all: clawpatrol does NOT default-deny in-scope-no-match — it
#   # denies only on an explicit deny verdict (main.go, cr.Outcome.Verdict=="deny").
#   rule "ghapi-default" { endpoint = https.ghapi  priority = -100  verdict = "deny"  reason = "verb not allowed" }
#   # ...then add bearer_token.ghapi-token to profile.default.credentials below.

# CRITICAL: a device with NO profile bypasses ALL policy — clawpatrol fail-opens
# unprofiled devices to passthrough ("single-tenant/legacy mode"; the profileFor →
# defaultProfileName path in cmd/clawpatrol/main.go — anchor on the function name,
# the line number drifts across versions). Every ClawBot MUST be assigned a profile.
# The `default` profile below binds echo-dummy, so postman-echo is in scope (MITM'd
# + policed); any host NOT in scope is RELAYED (passthrough), NOT denied — the cage,
# not unknown_host, is the boundary (see the defaults note above). To policy-enforce
# another upstream, bind it the way the commented `ghapi` example above shows.
# --- HTTP-verb policy test (in-scope endpoint, so it gets MITM'd + rule-evaluated) ---
# postman-echo.com ignores the injected Authorization header, so a dummy credential
# lets us exercise the rule engine without breaking the target.
endpoint "https" "echo" {
  hosts = ["postman-echo.com"]
}
# DELIBERATELY a bearer_token (not the cleaner v0.2.5+ `passthrough` type): this
# credential does double duty — it binds `echo` into the profile (→ in scope →
# MITM'd) AND injects `Bearer $CLAWPATROL_SECRET_ECHO_DUMMY`, which the
# credential-injection runtime test (tests/runtime/40_credentials.sh, R-CRED-1/2)
# observes reflected back by postman-echo. A `passthrough` credential injects
# nothing, so swapping it here would silently delete that coverage. For a purely
# no-auth endpoint that only needs binding into scope, prefer `passthrough` (see
# the ghapi example above).
credential "bearer_token" "echo-dummy" {
  endpoint = https.echo
}
# allow GET/HEAD …
rule "echo-get" {
  endpoint  = https.echo
  condition = "http.method in ['GET', 'HEAD']"
  verdict   = "allow"
}
# … deny everything else (catch-all; clawpatrol does NOT default-deny in-scope-no-match).
rule "echo-default" {
  endpoint = https.echo
  priority = -100
  verdict  = "deny"
  reason   = "verb not allowed"
}

profile "default" {
  credentials = [bearer_token.echo-dummy]
}
