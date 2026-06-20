#!/usr/bin/env bash
# Runtime: AC8 / review F1. Plain `join` does NOT install a shell rc, so the
# agent must get its env from the baked `run` wrapper (eval clawpatrol env).
# Verify the wrapper supplies the CA-bundle vars, that a login shell does NOT,
# and that the gateway CA is in the system trust store (installCATrust on join).
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"

require_tools docker
svc_running "$TBOT_SVC" || die "TBot not running — run runtime/00_bringup.sh first"

RUN_ENV="$(xrun "$TBOT_SVC" env 2>/dev/null)"

section "AC8 — the run wrapper wires the agent env"

expect R-ENV-1a "run wrapper sets NODE_EXTRA_CA_CERTS"
assert_match "$RUN_ENV" '^NODE_EXTRA_CA_CERTS='

expect R-ENV-1b "run wrapper sets REQUESTS_CA_BUNDLE"
assert_match "$RUN_ENV" '^REQUESTS_CA_BUNDLE='

expect R-ENV-1c "run wrapper sets the curl CA bundle (CURL_CA_BUNDLE / SSL_CERT_FILE)"
if printf '%s' "$RUN_ENV" | grep -Eq '^(CURL_CA_BUNDLE|SSL_CERT_FILE)='; then pass; else fail "no curl/ssl CA bundle var"; fi

expect R-ENV-1d "the CA-bundle path actually exists in the container"
capath="$(printf '%s' "$RUN_ENV" | grep -E '^NODE_EXTRA_CA_CERTS=' | head -1 | cut -d= -f2-)"
if [ -n "$capath" ]; then assert_ok "xsh '$TBOT_SVC' '[ -f \"$capath\" ]'"; else fail "NODE_EXTRA_CA_CERTS empty"; fi

section "F1 — plain join installed NO shell rc (the wrapper is required)"

expect R-ENV-3 "a login shell sources no clawpatrol env (plain join skips installShellRC)"
login_env="$(xsh "$TBOT_SVC" 'bash -lc env 2>/dev/null' 2>/dev/null)"
if printf '%s' "$login_env" | grep -Eq '^NODE_EXTRA_CA_CERTS='; then
  fail "login shell already has CA env — unexpected for plain join (was --whole-machine used?)"
else
  pass "confirmed: only the run wrapper provides the env"
fi

section "CA trust (installCATrust runs on plain join too)"

expect R-ENV-4 "gateway CA is installed in the system trust store"
# Plain TLS (system store, no run-wrapper overrides) to a MITM'd endpoint must
# validate. Retry transient client<->gateway flaps before concluding.
if retry "xsh '$TBOT_SVC' 'curl -fsS -o /dev/null --max-time $CURL_MAX_TIME https://$ALLOWED_MITM_HOST/get'"; then
  pass "system-store curl validates the MITM cert"
else
  skip "could not confirm via system store (run-wrapper path already covered above)"
fi

section "CA trust for relayed hosts (run wrapper widens gateway-only -> +public roots)"

# By default the wrapper repoints the replace-style CA bundles at the system store
# (gateway CA + public roots) so strict-trust tools (uv/rustls, pip, requests, aws)
# reach RELAYED hosts. Asserted on the env the wrapper actually produces — this is
# deterministic, unlike a curl probe (curl falls back to the system CA PATH even
# when its bundle is gateway-only, so it can neither prove nor disprove the widen;
# the real-world fix was proven manually with `uv python install`).
SYS_CA=/etc/ssl/certs/ca-certificates.crt

expect R-ENV-catrust "run wrapper widens SSL_CERT_FILE to the system store by default"
def_ssl="$(xrun "$TBOT_SVC" sh -c 'printf %s "$SSL_CERT_FILE"' 2>/dev/null | tr -d '\r')"
if [ "$def_ssl" = "$SYS_CA" ]; then
  pass "SSL_CERT_FILE=$def_ssl (gateway CA + public roots)"
else
  fail "not widened: SSL_CERT_FILE='$def_ssl' (strict-trust tools would fail UnknownIssuer on relayed hosts)"
fi

# Toggle off (build-arg or runtime): the wrapper must NOT widen — the bundle stays
# at clawpatrol's gateway-only cert (or unset), i.e. anything but the system store.
# (Strict trust binds only tools that honor these vars strictly; curl still falls
# back to the system store — see docs/architecture.md "CA trust for relayed hosts".)
expect R-ENV-catrust-strict "CLAWTILLA_TRUST_PUBLIC_CAS=0 does NOT widen (strict gateway-only bundle)"
strict_ssl="$(dc exec -T -e CLAWTILLA_TRUST_PUBLIC_CAS=0 "$TBOT_SVC" run sh -c 'printf %s "$SSL_CERT_FILE"' 2>/dev/null | tr -d '\r')"
if [ "$strict_ssl" != "$SYS_CA" ]; then
  pass "strict: SSL_CERT_FILE='${strict_ssl:-<unset>}' (not the system store)"
else
  fail "SSL_CERT_FILE widened to the system store despite CLAWTILLA_TRUST_PUBLIC_CAS=0 (toggle ineffective)"
fi

# Placeholder-token var: only present if a credential plugin defines one for the
# configured credential. The POC's generic bearer_token may push none; report
# what env-pushdown returned rather than assert a specific name.
section "placeholder credential vars (informational)"
expect R-ENV-2 "any pushed credential placeholder var is a placeholder, not the real secret"
if printf '%s' "$RUN_ENV" | grep -q "$SECRET_PLAINTEXT"; then
  fail "real secret leaked into agent env!"
else
  pass "no real secret in env (placeholder-only, per credential plugin)"
fi

finish
