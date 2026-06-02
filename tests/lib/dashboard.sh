# shellcheck shell=bash
# Clawtilla verification — clawpatrol gateway API client (host side).
# All calls go to the dashboard published on the Mac loopback (DASH_HOST_URL).
# Auth model (verified from source): bcrypt root password set via first-visit
# POST /__login; success returns a `cp_session` cookie used on later calls.
# Requires common.sh (DASH_HOST_URL, DASH_PW, COOKIE_JAR) + docker.sh (dc) + curl.

# --- public (authPublic) endpoints -----------------------------------------
gw_info()   { curl -fsS "$DASH_HOST_URL/info"; }
gw_ca_pem() { curl -fsS "$DASH_HOST_URL/ca.crt"; }

# CA fingerprint as advertised by the gateway (/info -> ca_fingerprint).
gw_fp() {
  local j; j="$(gw_info)" || return 1
  json_get "$j" '.ca_fingerprint'
}

# --- first-run password (CLI flag) ------------------------------------------
# Set the dashboard root password the documented way:
#   `clawpatrol gateway --set-dashboard-password <pw> <config>`
# upserts the bcrypt password into clawpatrol.db, THEN serves (main.go:671-686,
# gatewayHelp). We only need the upsert, so run a throwaway gateway container
# that writes the password into the shared state volume, wait for the confirming
# log line, then drop it. The real serving container (brought up next) then skips
# the first-run web flow entirely. Returns 0 on success.
set_dashboard_password() {
  local name="clawtilla-setpw-$$"
  # Routed through dc() so it inherits the test-scoped project name.
  dc run -d --no-deps --name "$name" \
    "$GATEWAY_SVC" gateway --set-dashboard-password "$DASH_PW" /config/gateway.hcl \
    >/dev/null 2>&1 || { docker rm -f "$name" >/dev/null 2>&1 || true; return 1; }
  local rc=1 i=0
  while [ "$i" -lt 30 ]; do
    if docker logs "$name" 2>&1 | grep -q 'root password set via --set-dashboard-password'; then rc=0; break; fi
    i=$((i+1)); sleep 1
  done
  docker rm -f "$name" >/dev/null 2>&1 || true
  return "$rc"
}

# --- session auth -----------------------------------------------------------
# Acquire a dashboard session cookie. Password is already set (set_dashboard_password);
# this just logs in. Falls back to the first-run setup POST if no root exists yet.
dash_login() {
  # Steady-state login (root already exists, e.g. set via set_dashboard_password).
  curl -fsS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null \
    -X POST "$DASH_HOST_URL/__login" \
    --data-urlencode "password=$DASH_PW" 2>/dev/null && return 0
  # Fallback: first-run setup (password + confirm) if no root exists yet.
  curl -fsS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null \
    -X POST "$DASH_HOST_URL/__login" \
    --data-urlencode "password=$DASH_PW" \
    --data-urlencode "confirm=$DASH_PW" 2>/dev/null
}

# Authenticated GET/POST helpers (carry the session cookie).
dash_get()  { curl -fsS -b "$COOKIE_JAR" "$DASH_HOST_URL$1"; }
dash_post() { local p="$1"; shift; curl -fsS -b "$COOKIE_JAR" -X POST "$DASH_HOST_URL$p" "$@"; }

# Approve a pending enrollment by user-code (needs a session).
dash_approve() {  # user-code  [profile]
  dash_post "/api/onboard/approve?code=$1${2:+&profile=$2}" -d ''
}

# Recent proxied-request log (analytics). Args: range limit
dash_analytics() {  # [range=5m] [limit=200]
  dash_get "/api/analytics?range=${1:-5m}&limit=${2:-200}"
}

# Connect a credential secret via the dashboard API.
dash_set_credential() {  # cred-id  secret
  dash_post "/api/credentials/set" -H 'Content-Type: application/json' \
    -d "{\"id\":\"$1\",\"slots\":{\"\":\"$2\"}}"
}
