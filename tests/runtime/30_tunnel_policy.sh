#!/usr/bin/env bash
# Runtime: traffic is tunneled + policy-inspected (AC1), the per-endpoint rule
# engine works (AC2: allow GET / deny POST on an in-scope endpoint), and an
# UNCONFIGURED host still relays — which is EXPECTED, not a failure (review I1 /
# design N1: monitor-only, not default-deny). All requests issue from the live
# TBot through the tunnel via the `run` wrapper.
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"
. "$VERIFY_DIR/lib/dashboard.sh"

require_tools docker curl jq
svc_running "$TBOT_SVC" || die "TBot not running — run runtime/00_bringup.sh first"
dash_login >/dev/null 2>&1 || die "could not log in to the dashboard"

# HTTP status of a request from inside the TBot (retries transient link flaps,
# returns real HTTP statuses immediately — see lib/docker.sh).
tbot_code() { tbot_http_code "$TBOT_SVC" "$@"; }

# True if analytics (last 5m) has an event matching host/method/action.
analytics_has() {  # host method action
  local j; j="$(dash_analytics 5m 1000)" || return 1
  printf '%s' "$j" | jq -e --arg h "$1" --arg m "$2" --arg a "$3" \
    '.events[] | select(.host==$h and (.method|ascii_upcase)==$m and .action==$a)' >/dev/null 2>&1
}

section "AC1 — allowed upstream works through the tunnel"

expect R-WG-5 "GET to in-scope endpoint ($ALLOWED_MITM_HOST) returns 200"
assert_eq "$(tbot_code "$ALLOWED_MITM_GET_URL")" "200"

expect R-WG-6 "...the request is logged as allow (proves tunneled + MITM + policy-inspected)"
if wait_for 10 "analytics_has '$ALLOWED_MITM_HOST' GET allow"; then pass; else fail "no allow event for $ALLOWED_MITM_HOST GET in analytics"; fi

section "AC2 — per-endpoint rule engine (allow GET / deny POST)"

expect R-POL-1 "configured endpoint: GET/HEAD allowed (200)"
assert_eq "$(tbot_code "$ALLOWED_MITM_GET_URL")" "200"

expect R-POL-2 "configured endpoint: disallowed verb (POST) gets a clean 403"
assert_eq "$(tbot_code -X POST "$ALLOWED_MITM_POST_URL")" "403"

expect R-POL-2b "...the POST is logged as deny"
if wait_for 10 "analytics_has '$ALLOWED_MITM_HOST' POST deny"; then pass; else fail "no deny event for $ALLOWED_MITM_HOST POST"; fi

section "AC2c — UNCONFIGURED host still relays (expected, not default-deny)"

expect R-POL-3 "unconfigured host ($RELAY_HOST) still succeeds via transparent relay"
code="$(tbot_code "$RELAY_URL")"
# example.com returns 200; accept any 2xx/3xx as 'relayed, reachable'.
case "$code" in 2??|3??) pass "HTTP $code — relayed";; *) fail "expected relay success, got HTTP $code (did the cage block it? that's a different failure)";; esac

note "Per design N1 / review I1: do NOT assert that only allowlisted hosts are reachable."
note "unknown_host=deny is dead config for HTTPS (main.go:1424); the cage is the real boundary."

finish
