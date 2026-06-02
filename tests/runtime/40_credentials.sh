#!/usr/bin/env bash
# Runtime: credential injection ("secrets stay at the gateway"). The in-scope
# echo endpoint reflects the headers it RECEIVED, so we can observe what the
# gateway injected on the way out — without the secret ever living in the agent.
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"

require_tools docker jq
svc_running "$TBOT_SVC" || die "TBot not running — run runtime/00_bringup.sh first"

EXPECT_AUTH="Bearer $SECRET_PLAINTEXT"

# Reflected request header from the echo endpoint (gateway-injected value).
# tbot_body retries transient client<->gateway flaps until it gets a response.
reflected_auth() {  # extra curl args...
  tbot_body "$TBOT_SVC" "$@" "$ALLOWED_MITM_GET_URL" \
    | jq -r '.headers.authorization // .headers.Authorization // empty'
}

section "credential injection — add when absent"

expect R-CRED-1 "gateway ADDS Authorization when the agent sends none"
assert_eq "$(reflected_auth)" "$EXPECT_AUTH"

section "credential injection — overwrite when present"

expect R-CRED-2 "gateway OVERWRITES a client-supplied Authorization header"
got="$(reflected_auth -H 'Authorization: Bearer client-supplied-bogus')"
if [ "$got" = "$EXPECT_AUTH" ]; then pass; else fail "expected gateway secret, got '$got'"; fi

section "secrets stay at the gateway (agent cannot read them)"

expect R-CRED-3 "the plaintext secret is NOT present in the agent's environment"
env_dump="$(xrun "$TBOT_SVC" env 2>/dev/null)"
assert_not_contains "$env_dump" "$SECRET_PLAINTEXT"

expect R-CRED-3b "the plaintext secret is NOT present in 'clawpatrol env' output"
ce="$(xsh "$TBOT_SVC" 'clawpatrol env 2>/dev/null' 2>/dev/null)"
assert_not_contains "$ce" "$SECRET_PLAINTEXT"

expect R-CRED-3c "the plaintext secret is NOT in any client-side config file"
grephit="$(xsh "$TBOT_SVC" "grep -rl '$SECRET_PLAINTEXT' /root 2>/dev/null" 2>/dev/null)"
assert_empty "$grephit"

# ---------------------------------------------------------------------------
# KNOWN GAP (review.md F6) — credential reflection. The injector writes the REAL
# secret into the UPSTREAM request; a header-reflecting upstream echoes it back
# in the response body, where the agent reads it. "Secrets stay at the gateway"
# therefore only holds for NON-reflecting upstreams. Here the bound secret is a
# TEST DUMMY so the leak is benign — but the channel is real, so we assert the
# DESIRED invariant (agent cannot read the injected secret) and expect XFAIL.
# (Static counterpart: REFLECTING-HOSTS lint in static/30_hcl.sh.)
# ---------------------------------------------------------------------------
section "KNOWN GAP (review.md F6) — credential reflection to the agent"
expect R-GAP-CRED-LEAK "agent should NOT be able to read the gateway-injected secret from the upstream response"
leaked="$(reflected_auth)"
if [ "$leaked" = "$EXPECT_AUTH" ]; then
  xfail "reflecting upstream ($ALLOWED_MITM_HOST) echoed the injected secret to the agent (benign here: dummy secret; a REAL credential bound to a reflecting host would leak)"
else
  pass "injected secret not reflected to the agent"
fi

# R-CRED-4 (no-secret -> injection skipped, rules still run) needs a config
# variant (an in-scope endpoint with NO connected secret). The POC config wires
# the secret for the only bound credential, so this branch isn't exercisable
# as-is — reported honestly rather than faked.
section "credential injection — no-secret branch"
expect R-CRED-4 "no-secret -> injection skipped but rules still evaluated"
skip "needs a config variant (in-scope endpoint without a connected secret); see README extended checks"

finish
