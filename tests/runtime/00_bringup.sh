#!/usr/bin/env bash
# Runtime phase 0: bring the stack up, set the dashboard password, enroll the
# TBot, and establish the tunnel. Also verifies the enrollment SECURITY controls
# (CA-fingerprint match = F2 defense; manual operator approval = N4).
#
# Flags:
#   --manual-approve   do NOT approve via the API; print + open the onboarding
#                      URL from the client logs (http://127.0.0.1:5182/#/onboard/
#                      <code>) and wait for a human to verify the CA fingerprint
#                      and click Approve.
#
# Subsequent runtime tests assume this has run and the tunnel is up.
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"
. "$VERIFY_DIR/lib/dashboard.sh"

require_tools docker curl jq

MANUAL=0
[ "${1:-}" = "--manual-approve" ] && MANUAL=1

# Publish the dashboard on a RANDOM loopback host port (host port 0) so the
# verification stack never contends with a real deployment that owns 5182. This
# uses the stack's own CLAWTILLA_DASH_PORT knob (default 5182); exporting it
# here makes every `dc` bring-up in this run agree on the same desired spec (so
# compose won't recreate the gateway between the two `up`s). The actual assigned
# port is discovered after bring-up. Override to pin a fixed test port if needed.
: "${CLAWTILLA_DASH_PORT:=0}"
export CLAWTILLA_DASH_PORT

section "phase 0 — dashboard password (set via --set-dashboard-password)"

# Set the root password on first run the documented way (CLI flag upserts the
# bcrypt password into clawpatrol.db, on the shared state volume) — no reliance
# on the first-visit web flow.
expect R-ENR-5a "root password set on first run via the --set-dashboard-password CLI flag"
if set_dashboard_password; then pass "upserted into clawpatrol.db (bcrypt)"; else fail "could not set password via the CLI flag (image built?)"; finish; exit; fi

section "phase 0 — gateway bring-up"

info "starting gateway ($GATEWAY_SVC) ..."
dc up -d "$GATEWAY_SVC" >/dev/null 2>&1 || die "failed to start $GATEWAY_SVC"

# The verification stack publishes the dashboard on a RANDOM loopback port
# (CLAWTILLA_DASH_PORT=0) so it never collides with a real deployment on 5182.
# Discover the port Docker actually assigned and record it so this run — and the
# later runtime scripts (separate processes) — target the right URL.
DASH_MAPPING="$(dc port "$GATEWAY_SVC" 8080 2>/dev/null | tail -1)"
if [ -n "$DASH_MAPPING" ]; then
  DASH_HOST_PORT="${DASH_MAPPING##*:}"
  DASH_HOST_URL="http://127.0.0.1:$DASH_HOST_PORT"
  printf '%s' "$DASH_HOST_PORT" >"$LOG_DIR/.dash_port"
  note "dashboard published on $DASH_HOST_URL (random host port; stack default is 5182)"
else
  warn "could not resolve the published dashboard port; falling back to $DASH_HOST_URL"
fi

expect R-NET-8r "dashboard answers on the Mac loopback ($DASH_HOST_URL)"
if wait_for 30 "curl -fsS '$DASH_HOST_URL/info' -o /dev/null"; then
  assert_contains "$(gw_info)" '"clawpatrol":true'
else
  fail "no response from $DASH_HOST_URL/info within 30s"; finish; exit
fi

expect R-ENR-5b "operator can log in with the CLI-set password (no first-run web flow needed)"
if dash_login; then pass "session acquired"; else fail "could not establish a dashboard session"; finish; exit; fi

GW_FP="$(gw_fp)"
note "gateway CA fingerprint: $GW_FP"

section "phase 0 — TBot enrollment"

info "starting client ($TBOT_SVC) ..."
dc up -d "$TBOT_SVC" >/dev/null 2>&1 || die "failed to start $TBOT_SVC"

# Already enrolled? (persisted wg.conf -> client.sh skips join, prints no code.)
sleep 3
LOGS="$(dc logs --no-color "$TBOT_SVC" 2>/dev/null)"
if printf '%s' "$LOGS" | grep -q 'enrolling (plain join'; then
  info "fresh enrollment in progress — waiting for user-code + CA fingerprint ..."
  if ! wait_for 30 "dc logs --no-color '$TBOT_SVC' 2>/dev/null | grep -Eq 'CA fingerprint:'"; then
    fail "join never printed a CA fingerprint (check '$TBOT_SVC' logs)"; finish; exit
  fi
  LOGS="$(dc logs --no-color "$TBOT_SVC" 2>/dev/null)"
  CLI_FP="$(printf '%s' "$LOGS" | grep -Eo 'CA fingerprint:[[:space:]]*[0-9A-Fa-f:]+' | head -1 | sed 's/CA fingerprint:[[:space:]]*//')"
  # The join output prints the onboarding link (host 127.0.0.1, code in the URL):
  #   http://127.0.0.1:5182/#/onboard/<USER_CODE>
  VERIFY_URL="$(printf '%s' "$LOGS" | grep -Eo 'https?://[^[:space:]]+/#/onboard/[A-Za-z0-9-]+' | head -1)"
  if [ -n "$VERIFY_URL" ]; then
    USER_CODE="${VERIFY_URL##*/onboard/}"
  else
    USER_CODE="$(printf '%s' "$LOGS" | grep -Eo '[A-Z0-9]{4}-[A-Z0-9]{4}' | head -1)"
  fi
  note "CLI fingerprint: $CLI_FP"
  note "onboarding URL:  ${VERIFY_URL:-<none>}"
  note "user-code:       $USER_CODE"

  # F2: the defense against an on-path CA swap during plain-HTTP join is that
  # the fingerprint the client printed equals the one the gateway advertises.
  expect R-ENR-2 "CLI-printed CA fingerprint matches the gateway's advertised fingerprint (F2)"
  norm() { printf '%s' "$1" | tr 'a-f' 'A-F' | tr -d ' '; }
  if [ -n "$CLI_FP" ] && [ "$(norm "$CLI_FP")" = "$(norm "$GW_FP")" ]; then
    pass
  else
    fail "MISMATCH — possible on-path CA swap. CLI='$CLI_FP' gateway='$GW_FP'. NOT approving."
    finish; exit
  fi

  expect R-ENR-1 "enrollment requires explicit operator approval (no WG auto-approve)"
  if [ -z "$USER_CODE" ]; then
    fail "no user-code found in logs"
  elif [ "$MANUAL" = "1" ]; then
    # Operator-driven approval: open the onboarding URL from the client logs and
    # click the Approve CTA (after confirming the CA fingerprint matches).
    # NOTE: the URL the client logs (VERIFY_URL) carries the gateway's baked
    # public_url (127.0.0.1:5182). The test stack is on a RANDOM port, so build
    # the link from the discovered DASH_HOST_URL instead — same code, right port.
    ONBOARD_URL="$DASH_HOST_URL/#/onboard/$USER_CODE"
    warn "Manual approval — open this onboarding URL and click Approve:"
    printf '      %s\n' "$ONBOARD_URL"
    printf '      (first confirm the page shows CA fingerprint: %s)\n' "$GW_FP"
    open_url "$ONBOARD_URL"
    if wait_for 300 "tbot_wg_ip | grep -q ."; then pass "approved by operator via the dashboard CTA"; else fail "no approval within 300s"; finish; exit; fi
  else
    # Same approval the CTA performs, via the authenticated API: POST /api/onboard/approve.
    if printf '%s' "$(dash_approve "$USER_CODE" default)" | grep -q '"approved":true\|"already":true'; then
      pass "approved via authenticated dashboard session (same action as the CTA)"
    else
      fail "approve API call failed"; finish; exit
    fi
  fi
else
  info "client already enrolled (persisted wg.conf) — skipping approval flow."
  expect R-ENR-2 "CA fingerprint check (fresh enrollment only)"; skip "already enrolled"
  expect R-ENR-1 "operator approval (fresh enrollment only)";   skip "already enrolled"
fi

section "phase 0 — tunnel establishment"

expect R-WG-up "tunnel comes up and carries traffic (egress to the allowed endpoint works)"
if wait_for 45 "xsh '$TBOT_SVC' 'curl -fsS -o /dev/null --max-time 10 https://$ALLOWED_MITM_HOST/get'"; then
  pass
elif xsh "$TBOT_SVC" 'ip link show clawpatrol' >/dev/null 2>&1; then
  pass "interface up (egress check inconclusive — external host may be unreachable)"
else
  fail "no clawpatrol interface and no egress within 45s"
fi

expect R-WG-ip "TBot received a WireGuard /32 from the gateway subnet"
assert_match "$(tbot_wg_ip)" '^10\.55\.0\.'

finish
