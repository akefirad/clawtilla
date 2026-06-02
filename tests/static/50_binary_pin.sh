#!/usr/bin/env bash
# Supply-chain verification: the SHA256 pinned in the Dockerfile must match the
# published release artifact, and the oss/clawpatrol submodule must sit on the
# same tag (design "keep binary + submodule in lockstep"). Needs network + git.
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"

DF="$STACK_DIR/Dockerfile"
SRC="$(cat "$DF")"
VER="$(printf '%s' "$SRC" | grep -E 'ARG CLAWPATROL_VERSION=' | head -1 | sed 's/.*=//')"
SHA_AMD64="$(printf '%s' "$SRC" | grep -E 'ARG CLAWPATROL_SHA256_amd64=' | head -1 | sed 's/.*=//')"
SHA_ARM64="$(printf '%s' "$SRC" | grep -E 'ARG CLAWPATROL_SHA256_arm64=' | head -1 | sed 's/.*=//')"

info "pinned version: $VER"

section "submodule lockstep"

expect R-IMG-2 "oss/clawpatrol submodule is checked out at tag $VER"
sub="$CLAWTILLA_DIR/oss/clawpatrol"
if have git && { [ -d "$sub/.git" ] || [ -f "$sub/.git" ]; }; then
  desc="$(git -C "$sub" describe --tags --always 2>/dev/null)"
  if [ "$desc" = "$VER" ]; then pass; else fail "submodule at '$desc', Dockerfile pins '$VER'"; fi
else
  skip "git unavailable or submodule not initialised"
fi

section "release SHA256 matches the Dockerfile pin"

# Try the combined SHA256SUMS first; fall back to per-asset *.sha256 if present.
fetch_sums() { curl -fsSL "$CLAWPATROL_RELEASES/$VER/SHA256SUMS" 2>/dev/null; }

SUMS="$(fetch_sums)"
if [ -z "$SUMS" ]; then
  expect R-IMG-1e "fetch published checksums for $VER"
  skip "could not fetch SHA256SUMS (offline? release layout changed) — verify manually"
  finish; exit
fi

check_arch() {  # arch  pinned-sha
  local arch="$1" pinned="$2" published
  published="$(printf '%s' "$SUMS" | grep "clawpatrol-linux-$arch\$" | awk '{print $1}' | head -1)"
  expect "R-IMG-1-$arch" "published SHA256 for clawpatrol-linux-$arch matches Dockerfile pin"
  if [ -z "$published" ]; then
    fail "no checksum line for clawpatrol-linux-$arch in SHA256SUMS"
  else
    assert_eq "$pinned" "$published"
  fi
}

check_arch amd64 "$SHA_AMD64"
check_arch arm64 "$SHA_ARM64"

finish
