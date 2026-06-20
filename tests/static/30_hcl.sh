#!/usr/bin/env bash
# Static checks on stack/gateway.hcl (text parse + optional `clawpatrol validate`).
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"

HCL="$STACK_DIR/gateway.hcl"
[ -f "$HCL" ] || die "gateway.hcl not found at $HCL"
SRC="$(cat "$HCL")"

section "gateway.hcl — gateway block"

expect R-NET-bind "dashboard_listen binds 0.0.0.0:8080 (clients need :8080 for join/CA)"
assert_match "$SRC" 'dashboard_listen[[:space:]]*=[[:space:]]*"0\.0\.0\.0:8080"'

expect R-WG-endpoint "wireguard.endpoint overrides to gateway:51820 (Docker DNS alias)"
assert_match "$SRC" 'endpoint[[:space:]]*=[[:space:]]*"gateway:51820"'

# clawpatrol HONORS wireguard.listen_port since v0.2.6 (cl-94cf); before it was
# silently ignored and always bound 51820. Now that it's live, a listen_port that
# disagrees with the advertised endpoint port breaks enrollment silently — so pin
# it and assert it equals the endpoint port.
expect R-WG-listenport "wireguard.listen_port is set and equals the endpoint port (no advertised/actual drift — v0.2.6)"
lp="$(printf '%s' "$SRC" | grep -E '^[[:space:]]*listen_port[[:space:]]*=' | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/')"
epp="$(printf '%s' "$SRC" | grep -E 'endpoint[[:space:]]*=[[:space:]]*"gateway:' | head -1 | sed -E 's/.*gateway:([0-9]+).*/\1/')"
if [ -n "$lp" ] && [ "$lp" = "$epp" ]; then pass; else fail "listen_port='$lp' endpoint-port='$epp' (must be set and equal)"; fi

expect R-GW-state "state_dir is /opt/clawpatrol (matches the named volume mount)"
assert_match "$SRC" 'state_dir[[:space:]]*=[[:space:]]*"/opt/clawpatrol"'

# schema_version pins the config grammar (clawpatrol v0.2.5+). Omitting it loads
# as legacy version 0 WITH a deprecation warning; pinning to the current grammar
# makes a future, too-new clawpatrol fail loudly instead of silently mis-parsing.
expect R-GW-schema "schema_version is pinned to the current grammar (1) — not left to legacy-v0 deprecation default"
sv="$(printf '%s' "$SRC" | grep -E '^[[:space:]]*schema_version[[:space:]]*=' | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/')"
if [ "$sv" = "1" ]; then pass; else fail "schema_version='$sv' (expected 1; pin it so a version bump fails loudly, not silently)"; fi

section "gateway.hcl — profile / policy (no fail-open device)"

expect R-POL-4 "a profile is declared (unprofiled devices fail-open to passthrough)"
assert_match "$SRC" 'profile[[:space:]]+"[^"]+"[[:space:]]*\{'

expect R-POL-4b "the default profile binds at least one credential (puts endpoints in scope)"
# crude block check: profile "default" { credentials = [ ... ] }
if printf '%s' "$SRC" | tr '\n' ' ' | grep -Eq 'profile[[:space:]]+"default"[[:space:]]*\{[^}]*credentials[[:space:]]*=[[:space:]]*\[[^]]+\]'; then pass; else fail "default profile has no credentials -> nothing in scope"; fi

expect R-POL-1c "the MITM test endpoint ($ALLOWED_MITM_HOST) is configured"
assert_contains "$SRC" "$ALLOWED_MITM_HOST"

expect R-CRED-bind "a credential binds the MITM endpoint into scope (enables injection)"
assert_match "$SRC" 'credential[[:space:]]+"[^"]+"[[:space:]]+"[^"]+"'

expect R-POL-rules "allow + deny (catch-all) rules exist for the in-scope endpoint"
if printf '%s' "$SRC" | grep -q 'verdict[[:space:]]*=[[:space:]]*"allow"' \
   && printf '%s' "$SRC" | grep -q 'verdict[[:space:]]*=[[:space:]]*"deny"'; then pass; else fail "need both allow and deny rules"; fi

# ---------------------------------------------------------------------------
# KNOWN GAPS (review.md F4, F6) — policy advertises enforcement it does not
# apply. Recorded as XFAIL (reported, do not fail the run) since the shipped
# stack exhibits them. Flip to PASS once the stack is corrected.
# ---------------------------------------------------------------------------
section "gateway.hcl — policy reachability lints (review.md F4 / F6)"

# F4: an `allow` rule only fires if its endpoint is actually in scope for a
# profile (profile -> credential -> endpoint). An endpoint named by an allow
# rule but bound by NO credential is a DEAD allow: enforcement that never runs;
# the host falls through to unknown_host handling (relay for HTTPS today).
# Shipped stack: `ghapi` (api.github.com) has an allow rule but no credential.
allow_eps="$(printf '%s' "$SRC" | awk '
  /rule[[:space:]]+"/ {inr=1; ep=""; v=""}
  inr && /endpoint[[:space:]]*=[[:space:]]*https\./ { match($0,/https\.[A-Za-z0-9_-]+/); ep=substr($0,RSTART+6,RLENGTH-6) }
  inr && /verdict[[:space:]]*=[[:space:]]*"allow"/ {v="allow"}
  inr && /}/ { if(v=="allow" && ep!="") print ep; inr=0 }
' | sort -u)"
cred_eps="$(printf '%s' "$SRC" | awk '
  /credential[[:space:]]+"/ {inc=1}
  inc && /endpoint[[:space:]]*=[[:space:]]*https\./ { match($0,/https\.[A-Za-z0-9_-]+/); print substr($0,RSTART+6,RLENGTH-6) }
  inc && /}/ {inc=0}
' | sort -u)"
dead=""
for e in $allow_eps; do printf '%s\n' "$cred_eps" | grep -qx "$e" || dead="$dead $e"; done
expect R-GAP-DEADRULE "every endpoint with an allow rule is bound by a credential (no dead allow rules)"
if [ -n "${dead// /}" ]; then
  xfail "dead allow rule(s): endpoint(s)$dead have an allow rule but no credential binds them into a profile (HTTPS host falls through to relay — review.md F4)"
else
  pass
fi

# F6: a credential bound to a HEADER-REFLECTING upstream echoes the gateway-
# injected secret back into the response body, where the agent can read it —
# defeating "secrets stay at the gateway". Benign in this stack (the secret
# is a test dummy) but the channel is real and unguarded.
reflect_hit=""
for h in $REFLECTING_HOSTS; do
  printf '%s' "$SRC" | grep -q "$h" && reflect_hit="$reflect_hit $h"
done
expect R-GAP-CRED-REFLECT "no endpoint host is a known header-reflecting upstream (would echo the injected secret to the agent)"
if [ -n "${reflect_hit// /}" ]; then
  xfail "policy references reflecting host(s):$reflect_hit — a credential bound here leaks the injected secret to the agent (benign with a dummy; a leak with a real secret — review.md F6)"
else
  pass
fi

section "gateway.hcl — defaults"

expect R-POL-5 "unknown_host=deny is set (documented dead-config for HTTPS; cage is real containment)"
assert_match "$SRC" 'unknown_host[[:space:]]*=[[:space:]]*"deny"'
note "Per the ep==nil -> g.splice branch in main.go handle() this is passthrough for HTTPS today — runtime test 30 confirms relay still happens. (Anchor on the name; the line drifts — ~1424 in v0.2.12, ~1495 in v0.3.2, ~1680 in v0.5.1.)"

# Optional: validate with the real binary if available on PATH.
if have clawpatrol; then
  section "gateway.hcl — clawpatrol validate"
  expect R-POL-valid "clawpatrol validate accepts gateway.hcl"
  assert_ok "clawpatrol validate '$HCL'"
else
  section "gateway.hcl — clawpatrol validate"
  expect R-POL-valid "clawpatrol validate accepts gateway.hcl"
  skip "clawpatrol not on PATH (runtime test validates inside the container)"
fi

finish
