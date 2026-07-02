#!/usr/bin/env bash
# Source-build lockstep: clawpatrol is compiled from the vendored submodule
# (src-local, the default) rather than a published binary. This checks the
# submodule is present and that the remote fallback (src-remote) defaults to
# the SAME repo the submodule tracks, so both source modes build one codebase.
# Pure git/text — no network.
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"

DF="$STACK_DIR/Dockerfile"
SRC="$(cat "$DF")"
sub="$CLAWTILLA_DIR/stack/clawpatrol"

section "vendored source (src-local default)"

expect R-IMG-2 "clawpatrol submodule is initialised at stack/clawpatrol"
if have git && { [ -d "$sub/.git" ] || [ -f "$sub/.git" ]; }; then
  if [ -f "$sub/go.mod" ] && [ -f "$sub/Makefile" ]; then pass; else fail "submodule present but missing go.mod/Makefile (not checked out?)"; fi
else
  skip "git unavailable or submodule not initialised"
fi

expect R-IMG-2b "src-local mode builds the vendored tree (COPY clawpatrol /src)"
assert_match "$SRC" 'COPY clawpatrol /src'

section "remote fallback tracks the same repo"

expect R-IMG-2c "Dockerfile CLAWPATROL_REPO default == submodule origin"
repo="$(printf '%s' "$SRC" | grep -E 'ARG CLAWPATROL_REPO=' | head -1 | sed 's/.*=//')"
if have git && { [ -d "$sub/.git" ] || [ -f "$sub/.git" ]; }; then
  origin="$(git -C "$sub" remote get-url origin 2>/dev/null)"
  # Tolerate a trailing .git on either side.
  if [ "${repo%.git}" = "${origin%.git}" ]; then pass; else fail "Dockerfile pins '$repo', submodule origin is '$origin'"; fi
else
  skip "git unavailable or submodule not initialised"
fi

expect R-IMG-2d "Dockerfile CLAWPATROL_REF default == submodule commit (lockstep, not a floating branch)"
ref="$(printf '%s' "$SRC" | grep -E 'ARG CLAWPATROL_REF=' | head -1 | sed 's/.*=//')"
if have git && { [ -d "$sub/.git" ] || [ -f "$sub/.git" ]; }; then
  head="$(git -C "$sub" rev-parse HEAD 2>/dev/null)"
  tag="$(git -C "$sub" describe --tags --exact-match HEAD 2>/dev/null || true)"
  # Accept an exact tag, the full commit SHA, or a short-SHA prefix of HEAD.
  if [ -n "$ref" ] && { [ "$ref" = "$tag" ] || [ "$ref" = "$head" ] || case "$head" in "$ref"*) [ "${#ref}" -ge 7 ] ;; *) false ;; esac; }; then
    pass
  else
    fail "Dockerfile ref '$ref' is not the submodule's tag ('$tag') or commit ('$head') — a moving branch is not allowed"
  fi
else
  skip "git unavailable or submodule not initialised"
fi

finish
