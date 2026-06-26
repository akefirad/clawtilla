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

# ── EXAMPLE: ChatGPT-subscription (Codex) credential for a Hermes agent ───────
# Lets a Hermes agent run inference on your ChatGPT Plus/Pro subscription WITHOUT
# the agent ever holding the real OAuth token. Hermes POSTs to
# chatgpt.com/backend-api/codex/responses with `Authorization: Bearer <token>`
# and a `chatgpt-account-id` header.
#
# This has three parts; the last two live in this file:
#   1. CLIENT (your agent's provisioning, NOT this file): something on the client
#      seeds a fake Codex JWT into ~/.hermes/auth.json — with a far-future
#      `exp` and the `["https://api.openai.com/auth"].chatgpt_account_id` claim
#      Hermes requires. Hermes never verifies the signature, so it accepts the
#      token and skips its device-login; the far-future `exp` means it SHOULD
#      never refresh against auth.openai.com. Don't bank on that alone — part (3)
#      blocks the refresh path at the gateway so the fake refresh token can't leak
#      even if a build ignores `exp` or the clock is wrong.
#   2. GATEWAY (here): bring chatgpt.com into scope so it's MITM'd, and bind the
#      `openai_codex_oauth` credential. Its injector OVERWRITES the fake Bearer
#      with the REAL subscription token and re-stamps `chatgpt-account-id` from
#      that token's own claims — so the fake token never authenticates upstream,
#      the fake account-id is irrelevant, and the real token never reaches the
#      agent process.
#   3. GATEWAY (here), DEFENSE IN DEPTH — the point the far-future-`exp` story
#      alone misses: bring auth.openai.com into scope and DENY it, so a seeded
#      agent's refresh/device-login attempt is blocked AT the gateway and the fake
#      refresh token never reaches OpenAI. A deny rule only fires on an IN-SCOPE
#      endpoint, and scope is profile -> credential -> endpoint (see the in-scope
#      notes above) — so auth.openai.com needs a `passthrough` credential (binds it
#      into scope, injects nothing) AND a profile entry. An endpoint + deny rule
#      that NO credential binds is DEAD CONFIG: the host is relayed, not denied,
#      and the block silently does nothing. The deny does NOT touch the gateway's
#      OWN server-side refresh: that dials auth.openai.com directly
#      (http.DefaultClient in cmd/clawpatrol/oauth.go), not through the tunnel/rule
#      engine, so the rule never sees it — which is why connecting the real token
#      out-of-band still works.
#
# Give the gateway the real token out-of-band: connect the subscription through
# the dashboard's OAuth (device) flow, or supply the refresh token via the secret
# store (CODEX_REFRESH). The gateway refreshes it itself over direct egress (not
# through the tunnel/rule engine), so the auth.openai.com endpoint in (3) is NOT
# what makes refresh work — it exists only to DENY the agent's own refresh path.
#
# Use a plain `https` endpoint here. The `openai_codex_https` endpoint type adds a
# synthetic-JWT env push-down plus a JWKS / agent-task responder that ONLY the
# official `codex` CLI's AgentIdentity mode needs — Hermes routes to chatgpt.com
# on its own and uses none of it.
#
# Uncomment ALL the lines below AND add `openai_codex_oauth.codex` and
# `passthrough.openai-auth` to the profile below.
# (An endpoint no profile credential binds is passthrough-relayed, never injected
# — see the in-scope note above; a bare endpoint here would silently do nothing.)
#
#   endpoint "https" "openai-chatgpt" { hosts = ["chatgpt.com"] }
#   credential "openai_codex_oauth" "codex" { endpoint = https.openai-chatgpt }
#   # Part (3), defense in depth. The passthrough credential binds auth.openai.com
#   # into scope so the deny rule actually fires; without it the host is relayed,
#   # not denied (dead config). Harmless to the gateway's own refresh (direct dial).
#   endpoint "https" "openai-auth" { hosts = ["auth.openai.com"] }
#   credential "passthrough" "openai-auth" { endpoint = https.openai-auth }
#   rule "deny-openai-auth" { endpoint = https.openai-auth  verdict = "deny"  reason = "agents must not refresh Codex tokens; the gateway holds the real one" }

# ── EXAMPLE: Telegram bot token for a Hermes agent ───────────────────────────
# Lets a Hermes agent drive a Telegram bot WITHOUT ever holding the real bot token.
# Hermes calls api.telegram.org/bot<TOKEN>/<method> with the token in the URL PATH
# (not a header), and setWebhook posts a URL containing it in the body.
#
# Two parts; this file holds the gateway half:
#   1. CLIENT (the agent's provisioning, NOT this file): seed the FIXED placeholder
#      0000000000:clawpatrol-placeholder-do-not-use as TELEGRAM_BOT_TOKEN in the
#      agent's env (e.g. ~/.hermes/.env). It is shaped to pass Hermes's own token
#      validator, so Hermes accepts it and skips Telegram setup.
#   2. GATEWAY (here): bring api.telegram.org into scope (MITM'd) and bind the
#      `telegram_bot_token` credential. Its injector ReplaceAll's the placeholder with
#      the REAL token across path/query/body — so the real token never reaches the
#      agent and the placeholder never authenticates upstream.
#
# Unlike the Codex example there is NO part 3 (refresh deny): Telegram tokens don't
# refresh and there's no second host to fence off. Connect the real token via the
# dashboard secret store (the credential's single "Telegram bot token" slot).
#
# An endpoint no profile credential binds is passthrough-relayed, never injected (see
# the in-scope notes above) — so uncomment ALL lines below AND the profile entry.
#
#   endpoint "https" "telegram" { hosts = ["api.telegram.org"] }
#   credential "telegram_bot_token" "telegram" { endpoint = https.telegram }

profile "default" {
  credentials = [
    bearer_token.echo-dummy,
    # openai_codex_oauth.codex,   # uncomment together with the Codex/Hermes example above
    # passthrough.openai-auth,    # ditto — puts auth.openai.com in scope so deny-openai-auth can fire
    # telegram_bot_token.telegram, # uncomment together with the Telegram/Hermes example above
  ]
}
