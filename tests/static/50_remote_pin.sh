#!/usr/bin/env bash
# The default (src-remote) build clones a PINNED, resolvable upstream source —
# a bare `docker build` must be reproducible and must not depend on a moving
# branch. (This template vendors no clawpatrol submodule; a deployment that
# wants src-local drops its own checkout — see private/clawtilla.) The optional
# resolve check needs network.
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"

DF="$STACK_DIR/Dockerfile"
SRC="$(cat "$DF")"
repo="$(printf '%s' "$SRC" | grep -E 'ARG CLAWPATROL_REPO=' | head -1 | sed 's/.*=//')"
ref="$(printf '%s'  "$SRC" | grep -E 'ARG CLAWPATROL_REF='  | head -1 | sed 's/.*=//')"

section "src-remote default is pinned"

expect R-IMG-2 "default CLAWPATROL_REPO is an https git URL"
assert_match "$repo" '^https://[^ ]+/[^ ]+'

expect R-IMG-2b "default CLAWPATROL_REF is pinned (release tag or 40-hex SHA), not a branch"
# Accept vX.Y.Z[...] or a full 40-hex commit; reject bare branch names (main, …).
if printf '%s' "$ref" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+' \
   || printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then pass; else fail "ref '$ref' is not a pinned tag/SHA"; fi

section "the pinned ref resolves in the repo (network)"

expect R-IMG-2c "CLAWPATROL_REF resolves in CLAWPATROL_REPO"
if ! have git; then
  skip "git unavailable"
elif printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
  # ls-remote can't confirm a bare commit SHA; the pin-shape check (2b) covers it.
  skip "ref is a commit SHA; ls-remote can't confirm it — verify manually"
elif ls_out="$(git ls-remote "$repo" "$ref" "refs/tags/$ref" 2>/dev/null)"; then
  if [ -n "$ls_out" ]; then pass; else fail "ref '$ref' did not resolve in $repo"; fi
else
  skip "could not reach $repo (offline?) — verify the ref manually"
fi

finish
