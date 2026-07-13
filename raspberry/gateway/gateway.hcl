# Clawtilla gateway config — Raspberry Pi / Tailscale mode.
#
# The policy blocks are the same reference as stack/gateway.hcl (a dummy in-scope
# endpoint plus commented examples); the ONLY structural difference is the
# transport: a `tailscale { }` block instead of `wireguard { }`. A real deployment
# copies this and fills in the real upstreams + credentials.
#
# Validate on the Pi with:  clawpatrol validate /etc/clawpatrol/gateway.hcl

schema_version = 1

gateway {
  dashboard_listen = "127.0.0.1:8080"       # clients reach :8080 over the tailnet for join/CA
  public_url       = "http://clawpatrol-gateway"
  state_dir        = "/var/lib/clawpatrol"

  tailscale {
    hostname = "clawpatrol-gateway"          # the gateway's device name on your tailnet
    tags     = ["tag:clawbot"]               # applied to the keys the gateway mints for joining clawbots

    # Gateway node auth key via $TS_AUTHKEY (gateway.env). The OAuth client mints
    # the per-ClawBot join keys.
    oauth_client_id     = "{{secret:TS_OAUTH_CLIENT_ID}}"
    oauth_client_secret = "{{secret:TS_OAUTH_CLIENT_SECRET}}"

    # Password-less dashboard for these tailnet logins (tagged devices never match).
    operators = ["you@example.com"]
  }
}

defaults {
  # Any host NOT bound to the active profile's endpoints is passthrough-relayed
  # (spliced), REGARDLESS of unknown_host — clawpatrol's SNI-peek handler hardcodes
  # that for out-of-scope hosts. The cage/tunnel, not unknown_host, is the egress
  # boundary (see docs/architecture.md). llm_fail_mode = closed: deny LLM-guarded
  # requests if the judge errors/times out.
  unknown_host  = "deny"
  llm_fail_mode = "closed"
}

# HOW TO POLICY-ENFORCE AN UPSTREAM. clawpatrol only MITMs + rule-evaluates an
# endpoint that is IN SCOPE — reachable through the active profile via the
# transitive closure profile -> credential -> endpoint. An `endpoint` + `rule` that
# NO profile credential binds is DEAD CONFIG: the host is passthrough-relayed, never
# rule-evaluated. To add read-only GitHub for real, uncomment ALL of the following
# AND the profile line below:
#
#   endpoint "https" "ghapi" { hosts = ["api.github.com"] }
#   credential "bearer_token" "ghapi-token" { endpoint = https.ghapi }
#   rule "ghapi-reads"   { endpoint = https.ghapi  condition = "http.method in ['GET', 'HEAD']"  verdict = "allow" }
#   # MANDATORY catch-all: clawpatrol denies only on an explicit deny verdict.
#   rule "ghapi-default" { endpoint = https.ghapi  priority = -100  verdict = "deny"  reason = "verb not allowed" }
#   # ...then add bearer_token.ghapi-token to profile.default.credentials below.

# CRITICAL: a device with NO profile bypasses ALL policy — clawpatrol fail-opens
# unprofiled devices to passthrough. Every ClawBot MUST be assigned a profile.
# The `default` profile below binds echo-dummy, so postman-echo is in scope (MITM'd
# + policed); any host NOT in scope is RELAYED, NOT denied.
# --- HTTP-verb policy test (in-scope endpoint, so it gets MITM'd + rule-evaluated) ---
# postman-echo.com ignores the injected Authorization header, so a dummy credential
# lets us exercise the rule engine without breaking the target.
endpoint "https" "echo" {
  hosts = ["postman-echo.com"]
}

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

# ── EXAMPLE: Anthropic (Claude) ───────────────────────────────────────────────
# Run Claude inference through the gateway on your subscription/API key. Connect
# the real credential via the dashboard; block client telemetry so only inference
# rides the tunnel. Uncomment these AND add anthropic_oauth_subscription.claude to
# the profile.
#
#   endpoint "https" "anthropic" { hosts = ["api.anthropic.com"] }
#   credential "anthropic_oauth_subscription" "claude" { endpoint = https.anthropic }
#   rule "deny-anthropic-telemetry" {
#     endpoint  = https.anthropic
#     priority  = 100
#     condition = "http.path == '/api/event_logging/v2/batch'"
#     verdict   = "deny"
#     reason    = "block Anthropic client telemetry; inference is unaffected"
#   }

# ── EXAMPLE: ChatGPT-subscription (Codex) credential for a Hermes agent ────────
# Lets an agent run inference on your ChatGPT subscription WITHOUT ever holding the
# real OAuth token: the client seeds a fake far-future Codex JWT, the gateway
# OVERWRITES it with the real token, and (defense in depth) DENIES the agent's own
# refresh path so the fake refresh token can't leak. See stack/gateway.hcl for the
# full three-part rationale. Uncomment these AND add both credentials to the profile.
#
#   endpoint "https" "openai-chatgpt" { hosts = ["chatgpt.com"] }
#   credential "openai_codex_oauth" "codex" { endpoint = https.openai-chatgpt }
#   endpoint "https" "openai-auth" { hosts = ["auth.openai.com"] }
#   credential "passthrough" "openai-auth" { endpoint = https.openai-auth }
#   rule "deny-openai-auth" { endpoint = https.openai-auth  verdict = "deny"  reason = "agents must not refresh Codex tokens; the gateway holds the real one" }

# ── EXAMPLE: Telegram bot token for a Hermes agent ─────────────────────────────
# Lets an agent drive a Telegram bot WITHOUT holding the real token: the client
# seeds the fixed placeholder as TELEGRAM_BOT_TOKEN, the gateway ReplaceAll's it with
# the real token across path/query/body. Uncomment these AND add the credential to
# the profile.
#
#   endpoint "https" "telegram" { hosts = ["api.telegram.org"] }
#   credential "telegram_bot_token" "telegram" { endpoint = https.telegram }

# ══ EXAMPLE: AWS SSO / EKS — REQUIRES THE clawpatrol FORK ══════════════════════
# The blocks below need (1) the external `clawpatrol-plugin-aws` binary at the
# `source` path (the ClawBot user-data downloads it), and (2) a clawpatrol build
# that carries the core `aws_sso` OAuth flow (NOT in upstream v0.5.3 — the fork's
# `edge` release does). The gateway runs the SSO device login itself (dashboard
# "Connect" card) and delivers the token to the plugin; the plugin decodes the
# target account from the agent's placeholder AKID (AKIA<account-id>…), mints
# per-role creds via sso:GetRoleCredentials, and re-signs. See
# clawpatrol-plugin-aws/examples/gateway.hcl for the real facet-based policy.
#
#   plugin "aws" {
#     # Same absolute path the Docker image uses, so this block is identical across
#     # both deployments. Installed by the ClawBot user-data on first boot.
#     source = "/usr/local/lib/clawpatrol/aws-plugin"
#   }
#
#   # The AWS CLI installer is a PLAIN public download on awscli.amazonaws.com, not a
#   # SigV4 API call — a more-specific https endpoint (exact host beats the wildcard)
#   # bound by a passthrough credential keeps it out of the aws_api plugin path.
#   endpoint "https" "awscli-download" { hosts = ["awscli.amazonaws.com"] }
#   credential "passthrough" "awscli" { endpoint = https.awscli-download }
#   rule "awscli-download" { endpoint = https.awscli-download  verdict = "allow" }
#
#   endpoint "aws_api" "aws" { hosts = ["*.amazonaws.com"] }
#   endpoint "aws_api" "s3"  { hosts = ["*.s3.amazonaws.com", "s3.amazonaws.com"] }
#
#   credential "aws_sso_credential" "aws-sso" {
#     start_url = "https://YOUR_ORG.awsapps.com/start"
#     region    = "us-east-1"
#     accounts  = ["000000000000"]   # your account ids
#     endpoints = [aws_api.aws, aws_api.s3]
#   }
#
#   # Manual approval for READING AWS secret values (scoped so routine metadata ops
#   # don't spam the operator). builtin.dashboard = the no-config approver.
#   rule "secretsmanager-read-approve" {
#     endpoint  = aws_api.aws
#     priority  = 100
#     condition = "aws.action in ['GetSecretValue', 'BatchGetSecretValue'] || aws.iam_action in ['secretsmanager:GetSecretValue', 'secretsmanager:BatchGetSecretValue']"
#     approve   = [builtin.dashboard]
#     reason    = "reading AWS secret values requires manual approval"
#   }
#   rule "aws-allow" { endpoint = aws_api.aws  verdict = "allow" }
#   rule "s3-allow"  { endpoint = aws_api.s3   verdict = "allow" }
#
#   # ── EKS via AWS SSO ──────────────────────────────────────────────────────────
#   # kubectl → the gateway MITMs the EKS apiserver host and injects a `k8s-aws-v1.`
#   # bearer minted from the operator's SSO session. The specific apiserver host
#   # out-specifies the *.amazonaws.com endpoint above, so kubectl bearer traffic
#   # routes here. ca_cert pins the per-cluster CA for the gateway→apiserver upstream
#   # TLS; the bot's kubeconfig carries NO ca and NO `aws eks get-token` exec.
#   endpoint "kubernetes" "eks" {
#     hosts        = ["EXAMPLE.gr7.us-east-1.eks.amazonaws.com"]
#     cluster_name = "YourCluster"
#     region       = "us-east-1"
#     account_id   = "000000000000"
#     role_name    = "YourAgentReadOnlyRole"
#     ca_cert      = <<PEM
# -----BEGIN CERTIFICATE-----
# ...your cluster CA (base64 PEM)...
# -----END CERTIFICATE-----
# PEM
#   }
#   credential "aws_sso_eks_credential" "eks-sso" {
#     start_url = "https://YOUR_ORG.awsapps.com/start"
#     region    = "us-east-1"
#     endpoints = [kubernetes.eks]
#   }
#   rule "eks-allow" { endpoint = kubernetes.eks  verdict = "allow" }

profile "default" {
  credentials = [
    bearer_token.echo-dummy,
    # anthropic_oauth_subscription.claude,  # uncomment with the Anthropic example above
    # openai_codex_oauth.codex,             # uncomment with the Codex/Hermes example above
    # passthrough.openai-auth,              # ditto — puts auth.openai.com in scope so deny-openai-auth can fire
    # telegram_bot_token.telegram,          # uncomment with the Telegram/Hermes example above
    # aws_sso_credential.aws-sso,           # uncomment with the AWS example above (requires the fork)
    # aws_sso_eks_credential.eks-sso,       # ditto — EKS/kubectl
    # passthrough.awscli,                   # ditto — AWS CLI download host
  ]
}
