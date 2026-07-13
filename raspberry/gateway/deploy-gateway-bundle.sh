#!/usr/bin/env bash
#
# deploy-gateway-bundle.sh — stage the clawpatrol gateway bundle onto a
# freshly-flashed Raspberry Pi boot (FAT) partition, so cloud-init installs and
# starts the gateway on first boot.
#
# It copies gateway.hcl + clawpatrol-gateway.service + gateway.env (secret) into
# <boot>/clawgateway/. The user-data runcmd picks them up, moves them into place,
# wipes the secret off the FAT partition, and starts clawpatrol-gateway.
#
# This does NOT flash — flash first with rpi-imager, then run this on the card.
#
# Usage:
#   ./deploy-gateway-bundle.sh <disk>     e.g. ./deploy-gateway-bundle.sh disk4
#   ./deploy-gateway-bundle.sh --list     list removable/SD disks (candidates)
#   ./deploy-gateway-bundle.sh -h
#
# Options:
#   -y, --yes      don't prompt for confirmation
#   -e, --eject    cleanly eject the card when done
#
# Safety: refuses the system disk, requires removable/SD media, and verifies the
# target really is a Raspberry Pi cloud-init boot partition before copying.
#
# macOS-only (uses diskutil). On Linux, mount the FAT boot partition and copy the
# three BUNDLE_FILES into <mountpoint>/clawgateway/ yourself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_FILES=(gateway.hcl clawpatrol-gateway.service gateway.env)

die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ "$(uname)" == "Darwin" ]] || die "this script is macOS-only (uses diskutil)."

# Pull one field out of `diskutil info`. awk (not sed) so field names containing
# "/" (e.g. "Device / Media Name") and values with spaces/paths stay safe.
di_field() {
  diskutil info "$1" 2>/dev/null | awk -v k="$2" '
    { l=$0; sub(/^[ \t]+/,"",l)
      if (substr(l,1,length(k)+1)==k":") { v=substr(l,length(k)+2); sub(/^[ \t]+/,"",v); print v; exit } }'
}

# A disk is a plausible SD/removable target (never the internal system disk).
is_removable_sd() {
  local dev="$1" proto removable
  proto="$(di_field "$dev" 'Protocol')"
  removable="$(di_field "$dev" 'Removable Media')"
  [[ "$proto" == *"Secure Digital"* || "$removable" == *"Removable"* || "$removable" == "Yes" ]]
}

list_candidates() {
  info "Removable / SD disks (candidates):"
  local d
  for d in $(diskutil list | awk '/^\/dev\/disk[0-9]+ \(/{print $1}'); do
    is_removable_sd "$d" || continue
    printf '  %-12s %s — %s\n' "$d" \
      "$(di_field "$d" 'Device / Media Name')" "$(di_field "$d" 'Disk Size')"
  done
}

# ---- args ---------------------------------------------------------------
ASSUME_YES=0 DO_EJECT=0 DISK_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)  usage 0 ;;
    --list)     list_candidates; exit 0 ;;
    -y|--yes)   ASSUME_YES=1 ;;
    -e|--eject) DO_EJECT=1 ;;
    -*)         die "unknown option: $1 (see --help)" ;;
    *)          [[ -z "$DISK_ARG" ]] || die "unexpected extra argument: $1"; DISK_ARG="$1" ;;
  esac
  shift
done
[[ -n "$DISK_ARG" ]] || { usage 1; }

# ---- bundle present locally (fail fast, before touching the card) -------
for f in "${BUNDLE_FILES[@]}"; do
  [[ -f "$SCRIPT_DIR/$f" ]] && continue
  if [[ "$f" == gateway.env ]]; then
    die "missing $SCRIPT_DIR/gateway.env — create it from gateway.env.example (holds the TS secrets)."
  fi
  die "missing bundle file: $SCRIPT_DIR/$f"
done

# ---- normalise + validate the target disk -------------------------------
DISK="${DISK_ARG#/dev/}"        # accept "disk4" or "/dev/disk4"
DEV="/dev/$DISK"
[[ "$DISK" =~ ^disk[0-9]+$ ]] || die "not a whole-disk identifier: '$DISK_ARG' (want e.g. disk4)"
diskutil info "$DEV" >/dev/null 2>&1 || die "no such disk: $DEV (try: $0 --list)"

# Never the disk backing / (the running macOS system).
ROOT_WHOLE="$(diskutil info / 2>/dev/null | awk -F: '/Part of Whole/{gsub(/ /,"",$2);print $2}')"
[[ "$DISK" == "disk0" || "$DISK" == "$ROOT_WHOLE" ]] && die "refusing to touch the system disk ($DEV)."
is_removable_sd "$DEV" || die "$DEV is not removable/SD media — refusing (is that the right disk? try: $0 --list)."

# ---- find + mount the FAT boot partition --------------------------------
BOOT_SLICE="$(diskutil list "$DEV" | awk '/Windows_FAT_32|DOS_FAT_32|FAT_?32/{print $NF; exit}')"
[[ -n "$BOOT_SLICE" ]] || die "no FAT boot partition on $DEV — is this a flashed Raspberry Pi card?"

if [[ "$(di_field "/dev/$BOOT_SLICE" 'Mounted')" != "Yes" ]]; then
  info "mounting /dev/$BOOT_SLICE"
  diskutil mount "/dev/$BOOT_SLICE" >/dev/null || die "could not mount /dev/$BOOT_SLICE"
fi
MP="$(di_field "/dev/$BOOT_SLICE" 'Mount Point')"
[[ -n "$MP" && -d "$MP" ]] || die "could not determine mount point for /dev/$BOOT_SLICE"

# ---- verify it's really a Raspberry Pi cloud-init boot partition --------
for hallmark in config.txt cmdline.txt; do
  [[ -e "$MP/$hallmark" ]] || die "$MP does not look like a Raspberry Pi boot partition (missing $hallmark) — refusing."
done
[[ -e "$MP/user-data" ]] || warn "no cloud-init 'user-data' on $MP — is this card flashed with our user-data? Continuing, but the bundle won't be consumed without it."

# ---- confirm + copy -----------------------------------------------------
info "Target : $DEV ($(di_field "$DEV" 'Device / Media Name'), $(di_field "$DEV" 'Disk Size'))"
info "Boot   : /dev/$BOOT_SLICE  mounted at  $MP"
info "Will copy into $MP/clawgateway/:"
printf '           %s\n' "${BUNDLE_FILES[@]}"
warn "gateway.env holds secrets; cloud-init wipes it off the FAT partition on first boot."

if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]] || die "aborted."
fi

DEST="$MP/clawgateway"
rm -rf "$DEST"          # clear any stale/mismatched bundle (e.g. a manual Finder copy)
mkdir -p "$DEST"
for f in "${BUNDLE_FILES[@]}"; do
  COPYFILE_DISABLE=1 cp "$SCRIPT_DIR/$f" "$DEST/$f"   # COPYFILE_DISABLE: no ._AppleDouble sidecars
done
sync
info "copied:"; ls -l "$DEST"

if [[ "$DO_EJECT" -eq 1 ]]; then
  info "ejecting $DEV"
  diskutil eject "$DEV" >/dev/null && info "safe to remove the card."
else
  info "done. Eject before removing:  diskutil eject $DEV"
fi
