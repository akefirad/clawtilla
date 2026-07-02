# shellcheck shell=bash
# Clawtilla verification — shared assertion / reporting library.
#
# Source this from every test script:
#   . "$(dirname "$0")/../lib/common.sh"
#
# It gives each script:
#   - path vars (CLAWTILLA_DIR, STACK_DIR, VERIFY_DIR)
#   - config (sourced from tests/config.env, overridable by env)
#   - an expect/pass/fail/skip/xfail reporting model that appends to RESULTS_TSV
#   - assert_* helpers that auto-pass/fail the current expectation
#   - finish() to print a per-script summary and exit non-zero on any fail
#
# Reporting model: call `expect <REQ-ID> "<description>"` then exactly one
# assertion (assert_eq / assert_ok / …) or a manual pass/fail/skip/xfail.
#
# Statuses: PASS / FAIL / SKIP (could not exercise here) / XFAIL (a KNOWN,
# unresolved security gap — the desired invariant is asserted but does not yet
# hold; recorded distinctly so it is reported, not faked-green, and an XFAIL
# does NOT fail the run). A test should call `pass` (not `xfail`) the moment the
# gap is closed, so the suite tightens automatically.

set -uo pipefail

# --- paths ------------------------------------------------------------------
# The repo root is located by walking up from this file until we find the
# deployable stack (stack/compose.yaml). This is independent of BOTH the
# root directory's NAME and how deep the harness is nested — relocating or
# renaming the checkout does not break path resolution. (Falls back to the
# conventional two-levels-up layout if the marker isn't found.)
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_DIR="$(dirname "$_COMMON_DIR")"
_find_repo_root() {  # start-dir
  local d="$1"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    [ -f "$d/stack/compose.yaml" ] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}
if ! CLAWTILLA_DIR="$(_find_repo_root "$VERIFY_DIR")"; then
  CLAWTILLA_DIR="$(cd "$VERIFY_DIR/../.." && pwd)"
fi
: "${STACK_DIR:=$CLAWTILLA_DIR/stack}"

# --- config -----------------------------------------------------------------
if [ -f "$VERIFY_DIR/config.env" ]; then
  # shellcheck disable=SC1091
  . "$VERIFY_DIR/config.env"
fi

: "${COMPOSE_FILE:=$STACK_DIR/compose.yaml}"
# Harness-only compose overlay: stamps every resource the harness creates with an
# ownership label (com.akefirad.clawtilla.harness=verify) so the harness can prove a
# project is its own before reusing or destroying it (collision safety). Merged
# into every `dc` invocation. See lib/docker.sh and verify.override.yaml.
: "${OVERRIDE_FILE:=$VERIFY_DIR/verify.override.yaml}"
# Docker Compose project name for the VERIFICATION stack. This is deliberately a
# TEST-SCOPED name — NOT the stack's own top-level `name:` — so the harness
# always runs in its own namespace: every network, volume, image and container
# it creates is prefixed with "$PROJECT". That guarantees it can never collide
# with or clobber a real deployment of the same stack (e.g. a production
# stack brought up as `clawtilla`). Every compose invocation in the harness
# passes `-p "$PROJECT"`, and net_name/built_image_id predict the same prefix.
# Override via config.env or the environment if you need a different namespace.
: "${PROJECT:=clawtilla-verify}"
: "${GATEWAY_SVC:=gateway}"
: "${TBOT_SVC:=clawbot-418}"
: "${TBOT_HOST:=clawbot-418}"
# DASH_HOST_PORT is the port the STACK publishes the dashboard on by default
# — used by the static port assertion to verify the deployable default
# (127.0.0.1:5182). The *running* verification stack instead publishes on a
# RANDOM loopback port: runtime/00_bringup.sh exports CLAWTILLA_DASH_PORT=0 (the
# stack's own port knob) before bring-up; its live URL is resolved into
# DASH_HOST_URL below.
: "${DASH_HOST_PORT:=5182}"
: "${GW_INTERNAL_URL:=http://gateway:8080}"
: "${DASH_PW:=clawtilla-verify-pw-1}"          # >=12 chars; TEST ONLY — override in config.env
: "${ALLOWED_MITM_HOST:=postman-echo.com}"
: "${ALLOWED_MITM_GET_URL:=https://postman-echo.com/get}"
: "${ALLOWED_MITM_POST_URL:=https://postman-echo.com/post}"
: "${RELAY_HOST:=example.com}"
: "${RELAY_URL:=https://example.com/}"
: "${SECRET_PLAINTEXT:=test-secret-123}"
# All run artifacts (logs, result ledgers, session cookies) live under one dir.
# Never write logs outside verify/logs.
: "${LOG_DIR:=$VERIFY_DIR/logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
# Resolve the dashboard URL of the *running* verification stack. Because the
# stack is published on a random loopback port (CLAWTILLA_DASH_PORT=0),
# runtime/00_bringup.sh records the port it actually got into logs/.dash_port;
# the later runtime scripts (each a separate process) read it here. Precedence:
# an explicit DASH_HOST_URL from the environment wins; else the recorded live
# port; else the stack default (so the var is always usable, e.g. during the
# static phase / before bring-up).
if [ -z "${DASH_HOST_URL:-}" ] && [ -f "$LOG_DIR/.dash_port" ]; then
  _dp="$(cat "$LOG_DIR/.dash_port" 2>/dev/null)"
  [ -n "$_dp" ] && DASH_HOST_URL="http://127.0.0.1:$_dp"
fi
: "${DASH_HOST_URL:=http://127.0.0.1:$DASH_HOST_PORT}"
: "${RESULTS_TSV:=$LOG_DIR/.results.tsv}"
: "${COOKIE_JAR:=$LOG_DIR/.cp_session.cookies}"
# Resilience: the client<->gateway link can be briefly unstable, so network
# checks retry transient failures before giving up. Tunable.
: "${RETRY_ATTEMPTS:=4}"   # total attempts for a flaky network check
: "${RETRY_DELAY:=3}"      # seconds between attempts
: "${CURL_MAX_TIME:=20}"   # per-request curl timeout

SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-$0}")"

# --- colors -----------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_BLD=; C_RST=
fi

# --- counters / current expectation ----------------------------------------
_PASS=0; _FAIL=0; _SKIP=0; _XFAIL=0
_REQ="-"; _DESC="-"

info()  { printf '%s%s%s\n' "$C_BLU" "$*" "$C_RST"; }
note()  { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RST"; }
warn()  { printf '%s%s%s\n' "$C_YEL" "$*" "$C_RST" >&2; }
die()   { printf '%sFATAL: %s%s\n' "$C_RED" "$*" "$C_RST" >&2; exit 2; }

section() { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_RST"; }

expect() {
  _REQ="$1"; _DESC="$2"
  printf '  %s[%s]%s %s ... ' "$C_DIM" "$_REQ" "$C_RST" "$_DESC"
}

_record() {  # status  reason
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$_REQ" "$_DESC" "$SCRIPT_NAME" "${2:-}" >>"$RESULTS_TSV"
}

pass() { _PASS=$((_PASS+1)); printf '%sPASS%s%s\n' "$C_GRN" "$C_RST" "${1:+  ($1)}"; _record PASS "${1:-}"; }
fail() { _FAIL=$((_FAIL+1)); printf '%sFAIL%s  %s\n' "$C_RED" "$C_RST" "${1:-}"; _record FAIL "${1:-}"; }
skip() { _SKIP=$((_SKIP+1)); printf '%sSKIP%s  %s\n' "$C_YEL" "$C_RST" "${1:-}"; _record SKIP "${1:-}"; }
# xfail: a KNOWN, unresolved security gap. The desired invariant was asserted
# and does NOT hold yet — recorded distinctly so it is reported, but it does
# NOT fail the run (unlike fail). Flip the test to `pass` once the gap closes.
xfail() { _XFAIL=$((_XFAIL+1)); printf '%sXFAIL%s %s\n' "$C_YEL" "$C_RST" "${1:+ ($1)}"; _record XFAIL "${1:-}"; }

# --- assertions (operate on the current expectation) ------------------------
assert_eq() {  # got want
  if [ "$1" = "$2" ]; then pass; else fail "expected '$2', got '$1'"; fi
}
assert_ne() {  # got notwant
  if [ "$1" != "$2" ]; then pass; else fail "value should not equal '$2'"; fi
}
assert_contains() {  # haystack needle
  case "$1" in *"$2"*) pass;; *) fail "expected to contain '$2'";; esac
}
assert_not_contains() {  # haystack needle
  case "$1" in *"$2"*) fail "should not contain '$2'";; *) pass;; esac
}
assert_match() {  # string ERE
  if printf '%s' "$1" | grep -Eq -- "$2"; then pass; else fail "no match for /$2/"; fi
}
assert_not_match() {  # string ERE
  if printf '%s' "$1" | grep -Eq -- "$2"; then fail "unexpected match for /$2/"; else pass; fi
}
assert_ok() {  # shell-cmd...
  if eval "$*" >/dev/null 2>&1; then pass; else fail "command failed: $*"; fi
}
assert_fail() {  # shell-cmd...
  if eval "$*" >/dev/null 2>&1; then fail "command unexpectedly succeeded: $*"; else pass; fi
}
assert_empty() {  # value
  if [ -z "$1" ]; then pass; else fail "expected empty, got '$1'"; fi
}
assert_nonempty() {  # value
  if [ -n "$1" ]; then pass; else fail "expected non-empty"; fi
}

# --- misc helpers -----------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Best-effort: open a URL in the operator's browser (macOS `open` / Linux xdg-open).
open_url() {
  if have open; then open "$1" >/dev/null 2>&1 || true
  elif have xdg-open; then xdg-open "$1" >/dev/null 2>&1 || true
  fi
}

# Retry a command (success == exit 0) up to RETRY_ATTEMPTS, sleeping RETRY_DELAY
# between tries. Use for flaky network checks; returns the last exit status.
retry() {  # cmd...
  local i=0
  while [ "$i" -lt "$RETRY_ATTEMPTS" ]; do
    if eval "$*"; then return 0; fi
    i=$((i+1)); [ "$i" -lt "$RETRY_ATTEMPTS" ] && sleep "$RETRY_DELAY"
  done
  return 1
}

require_tools() {
  local missing=
  for t in "$@"; do have "$t" || missing="$missing $t"; done
  [ -z "$missing" ] || die "missing required tools:$missing"
}

# json_get <json-string> <jq-filter>  — requires jq.
json_get() {
  have jq || die "need jq to parse JSON (brew install jq)"
  printf '%s' "$1" | jq -r "$2"
}

finish() {
  printf '\n%s%s%s: %s%d passed%s, %s%d failed%s, %s%d skipped%s, %s%d xfail%s\n' \
    "$C_BLD" "$SCRIPT_NAME" "$C_RST" \
    "$C_GRN" "$_PASS" "$C_RST" \
    "$C_RED" "$_FAIL" "$C_RST" \
    "$C_YEL" "$_SKIP" "$C_RST" \
    "$C_YEL" "$_XFAIL" "$C_RST"
  # XFAIL is a reported-but-tolerated known gap; only real FAILs fail the run.
  [ "$_FAIL" -eq 0 ]
}
