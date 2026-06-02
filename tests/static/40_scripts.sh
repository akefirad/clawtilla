#!/usr/bin/env bash
# Static checks on the POC entrypoints (client.sh / gateway.sh): shellcheck +
# the load-bearing logic decisions from the design (Table=off, plain join, etc.).
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"

CLIENT="$STACK_DIR/client.sh"
GATEWAY="$STACK_DIR/gateway.sh"
[ -f "$CLIENT" ]  || die "client.sh not found at $CLIENT"
[ -f "$GATEWAY" ] || die "gateway.sh not found at $GATEWAY"
CSRC="$(cat "$CLIENT")"; GSRC="$(cat "$GATEWAY")"

section "entrypoints — shellcheck"

if have shellcheck; then
  for f in "$CLIENT" "$GATEWAY"; do
    expect SH-lint "shellcheck clean: $(basename "$f")"
    assert_ok "shellcheck -s sh '$f'"
  done
else
  expect SH-lint "shellcheck available"
  skip "shellcheck not installed (brew install shellcheck)"
fi

section "client.sh — tunnel bring-up decisions"

expect R-WG-4 "client uses plain 'clawpatrol join' (NOT --whole-machine)"
# Assert on executable lines only: the file's header comment explains *why* we
# avoid --whole-machine, and that explanation must not trip the assertion.
CCODE="$(printf '%s' "$CSRC" | grep -v '^[[:space:]]*#')"
if printf '%s' "$CCODE" | grep -q 'clawpatrol join' \
   && ! printf '%s' "$CCODE" | grep -q -- '--whole-machine'; then pass; else fail "uses --whole-machine or no join"; fi

expect R-WG-4b "client never invokes a (nonexistent) 'clawpatrol up' subcommand"
assert_not_match "$CSRC" 'clawpatrol[[:space:]]+up'

expect R-WG-2 "client forces 'Table = off' before wg-quick up (avoids src_valid_mark write)"
assert_match "$CSRC" 'Table[[:space:]]*=[[:space:]]*off'

expect R-WG-2b "client adds a manual default route via the tunnel iface"
assert_match "$CSRC" 'ip route add default dev'

expect R-LIFE-4 "entrypoint is enrollment-aware (join only when no persisted conf)"
if printf '%s' "$CSRC" | grep -q 'wg.conf' \
   && printf '%s' "$CSRC" | grep -Eq 'if \[ ! -f .*CONF'; then pass; else fail "no 'join once' guard on persisted conf"; fi

expect R-LIFE-1b "PID 1 stays alive without running the agent (exec sleep infinity)"
assert_match "$CSRC" 'exec sleep infinity'

expect R-LIFE-decouple "entrypoint's final action holds the tunnel open (does not run an agent)"
# The last executable line must be the hold-open, proving PID 1 never launches the agent.
last_line="$(printf '%s' "$CSRC" | grep -v '^[[:space:]]*$' | grep -v '^[[:space:]]*#' | tail -1)"
assert_eq "$last_line" "exec sleep infinity"

section "gateway.sh — state-dir hygiene"

expect R-GW-3a "gateway wrapper chmod 700s the state dir before launch"
assert_match "$GSRC" 'chmod 700 /opt/clawpatrol'

expect R-GW-exec "gateway wrapper exec's clawpatrol (PID is the binary, not the shell)"
assert_match "$GSRC" 'exec /usr/local/bin/clawpatrol'

finish
