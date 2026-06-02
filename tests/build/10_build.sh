#!/usr/bin/env bash
# Build both images from the single multi-stage Dockerfile and confirm the
# gateway/client targets are produced. Proves the SHA-pinned download + the
# stage layout actually build (covers the supply-chain pin end-to-end).
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
. "$VERIFY_DIR/lib/docker.sh"

require_tools docker

section "build — multi-stage Dockerfile (gateway + client)"

expect R-BUILD-1 "docker compose build succeeds (SHA-verified clawpatrol download)"
BUILD_LOG="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
if dc build >"$BUILD_LOG" 2>&1; then
  pass
else
  fail "build failed — see $BUILD_LOG"
  tail -20 "$BUILD_LOG" | sed 's/^/    /'
  finish; exit
fi

expect R-BUILD-2 "gateway image built and tagged for service $GATEWAY_SVC"
assert_nonempty "$(built_image_id "$GATEWAY_SVC")"

expect R-BUILD-3 "client image built and tagged for service $TBOT_SVC"
assert_nonempty "$(built_image_id "$TBOT_SVC")"

finish
