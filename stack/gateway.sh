#!/bin/sh
# Gateway entrypoint.
#
# clawpatrol creates state_dir with MkdirAll(0700) (main.go), but MkdirAll
# NO-OPs on an already-existing dir — and Docker pre-creates the named-volume
# mountpoint as root:root 0755, which trips clawpatrol's "state loosely
# permissioned" startup warning (main.go warnIfStateLooselyPermissioned).
# The secrets themselves are safe (the sqlite db holding the CA key + tokens
# is chmod 0600 on every open, db.go), so this is the dir bits only — but
# tighten the mountpoint anyway so the warning stays quiet and a future second
# principal in the container can't enumerate state_dir.
#
# This chmod targets the /opt/clawpatrol *volume* mount, which stays writable
# under the read-only rootfs (read_only: true in compose) — only `/` itself is
# read-only.
set -eu
chmod 700 /opt/clawpatrol 2>/dev/null || true
exec /usr/local/bin/clawpatrol "$@"
