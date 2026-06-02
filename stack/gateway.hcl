# Clawtilla gateway config. Trimmed from
# clawpatrol/examples/gateway.example.hcl to the minimum needed.
#
# Hot-reloadable: every policy block. The `gateway` block (listen ports,
# state_dir, transport sub-blocks) needs a restart.

gateway {
  dashboard_listen = "0.0.0.0:8080"          # clients need :8080 on clawcage-net for join/CA
  public_url       = "http://127.0.0.1:5182" # operator approval links only
  state_dir        = "/opt/clawpatrol"

  wireguard {
    subnet_cidr = "10.55.0.0/24"
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
# allowlist — the verification suite flags this as the R-GAP-DEADRULE XFAIL in
# tests/static/30_hcl.sh. To add read-only GitHub for real, uncomment ALL of the
# following AND the profile line below:
#
#   endpoint "https" "ghapi" { hosts = ["api.github.com"] }
#   # Binds ghapi into scope. Connect a real token via the dashboard, OR leave the
#   # secret unset — an empty bearer secret injects nothing (bearer_token.InjectHTTP
#   # returns early on len==0), so unauthenticated public GETs still work, policed.
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
# dummy credential just to bind `echo` into the profile (→ in scope → MITM'd).
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
