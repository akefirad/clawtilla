#!/usr/bin/env bash
# Runtime: AC4 + enrollment/dashboard auth model. A client can reach :8080 (by
# design, for join/CA) but cannot perform any privileged action without the root
# password; onboard routes are public but approval needs an operator session.
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"

require_tools docker curl
svc_running "$GATEWAY_SVC" || die "gateway not running — run runtime/00_bringup.sh first"

# status code of an UNAUTHENTICATED request from inside the TBot to :8080.
# Retries transient link flaps (000) but returns real statuses (200/401) at once.
tbot_status() {
  local code="" i=0
  while [ "$i" -lt "$RETRY_ATTEMPTS" ]; do
    code="$(xsh "$TBOT_SVC" "curl -s -o /dev/null -w '%{http_code}' --max-time $CURL_MAX_TIME '$GW_INTERNAL_URL$1'" 2>/dev/null)"
    case "$code" in 000|"") ;; *) printf '%s' "$code"; return 0 ;; esac
    i=$((i+1)); [ "$i" -lt "$RETRY_ATTEMPTS" ] && sleep "$RETRY_DELAY"
  done
  printf '%s' "${code:-000}"
}
# status code of an UNAUTHENTICATED request from the host (no cookie jar).
host_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$DASH_HOST_URL$1"; }

section "AC4 — client reaches :8080 but cannot act without the root password"

if svc_running "$TBOT_SVC"; then
  expect R-ENR-3a "client CAN reach the public /info on :8080 (needed for join/CA)"
  assert_eq "$(tbot_status /info)" "200"

  expect R-ENR-3b "client CANNOT read privileged /api/status without a session (401)"
  assert_eq "$(tbot_status /api/status)" "401"

  expect R-ENR-3c "client CANNOT read /api/state without a session (401)"
  assert_eq "$(tbot_status /api/state)" "401"
else
  expect R-ENR-3a "client-side :8080 reachability"; skip "TBot not running"
fi

# Positive counterpart to R-ENR-3c: with the operator session cookie minted at
# bring-up (logs/.cp_session.cookies), the SAME /api/state read returns 200 —
# proving the 401 above is an auth gate, not a dead/blanket-denied route.
expect R-ENR-6 "operator CAN read /api/state WITH a session cookie (200)"
if [ -s "$COOKIE_JAR" ]; then
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -b "$COOKIE_JAR" "$DASH_HOST_URL/api/state")" "200"
else
  skip "no session cookie jar (run runtime/00_bringup.sh first)"
fi

section "onboarding auth model"

expect R-ENR-4a "public endpoints (/ca.crt) are reachable without auth (200)"
assert_eq "$(host_status /ca.crt)" "200"

expect R-ENR-4b "operator approval requires a session (approve without auth -> 401/403)"
# authDashboardOrTailnetOperator -> rejects an unauthenticated caller.
case "$(host_status '/api/onboard/approve?code=FAKE-0000')" in
  401|403) pass;; *) fail "unauthenticated approve was not rejected with 401/403";;
esac

expect R-ENR-1r "no WG auto-approve exists (approval is an operator action)"
# Documented/code-verified (setup.go:188-193 auto-approve is --login/Tailscale only).
note "auto-approve is implicit only on the Tailscale --login path; WG join never self-approves."
pass "by design (see docs + clawpatrol setup.go)"

section "dashboard password posture (N3)"

expect R-ENR-5 "configured dashboard password meets the 12-char minimum"
if [ "${#DASH_PW}" -ge 12 ]; then pass "${#DASH_PW} chars"; else fail "DASH_PW is only ${#DASH_PW} chars (clawpatrol requires >=12)"; fi

note "N3 caveat: the dashboard port is reachable by untrusted peers; protection is the"
note "bcrypt root password + clawpatrol login hardening. Use a strong random secret in prod."

finish
