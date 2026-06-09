#!/usr/bin/env bash
#
# run-as-root.sh — launch SpiceMac as root so libusb can CAPTURE (seize) USB
# devices that macOS kernel drivers claim (mass storage, HID, audio, serial,
# iOS, …). On a personal/ad-hoc-signed build this is the only entitlement-free
# way to redirect such devices — the alternative, the Apple-restricted
# `com.apple.vm.device-access` entitlement, cannot be carried by an ad-hoc signature.
#
# ⚠️  TRUST BOUNDARY. This runs the ENTIRE app as root — including the SPICE/TLS/
# glib/gstreamer/clipboard/agent parsers that consume data from the (remote) SPICE
# server. A bug in any of them becomes root-impact. Run this ONLY against a VM and
# a Proxmox node you TRUST, and ONLY when you actually need a kernel-claimed device.
# (A dedicated root USB helper that would keep the SPICE stack unprivileged was
# scoped and deferred — see SECURITY.md, residual risk #2. The clean long-term fix
# is the device-access entitlement, which needs a Developer ID.)
#
# You do NOT need this for "driverless" devices (vendor-specific class 0xFF, FTDI on
# macOS 12+, many JTAG/printer dongles) — those redirect unprivileged. Check FIRST,
# so you don't run as root needlessly:
#   ioreg -p IOUSB -l | grep -i IOUSBHostInterface     (no class driver bound → OK)
#
# Other caveats: capture is WHOLE-DEVICE (all interfaces of a composite device are
# taken); HID may not detach even as root; clipboard/TCC/Full-Disk-Access behave
# differently as root. (The "Move .vv to Trash after connecting" preference is
# skipped under root, so your .vv is left in place rather than moved to root's Trash.)
#
# Usage: ./scripts/run-as-root.sh [-y] <connection.vv>
#   -y  (or SPICEMAC_ASSUME_YES=1)   skip the confirmation prompt
set -euo pipefail

ASSUME_YES="${SPICEMAC_ASSUME_YES:-0}"
[ "${1:-}" = "-y" ] && { ASSUME_YES=1; shift; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/SpiceMac.app/Contents/MacOS/SpiceMac"
VV="${1:?usage: run-as-root.sh [-y] <connection.vv>}"

[ -x "$APP" ] || { echo "build first: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh" >&2; exit 1; }
[ -f "$VV" ]  || { echo "no such .vv: $VV" >&2; exit 1; }
# Resolve to an absolute path — the root process may not share this working dir.
VV="$(cd "$(dirname "$VV")" && pwd)/$(basename "$VV")"

cat >&2 <<'WARN'
⚠️  SpiceMac will run as ROOT for USB capture.
    The WHOLE app runs as root — including the parsers that read data from the SPICE
    server — so do this only against a VM/node you TRUST, and only when you need a
    device a macOS kernel driver owns (driverless devices don't need root).
WARN

if [ "$ASSUME_YES" != "1" ]; then
    printf 'Continue? [y/N] ' >&2
    read -r reply || { echo "aborted." >&2; exit 1; }
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "aborted." >&2; exit 1 ;;
    esac
fi

echo "Launching as root (you'll be prompted for your password). Quit with ⌘Q." >&2
# sudo's default env_reset drops DYLD_*/library-injection vars from the root process;
# we deliberately do NOT pass -E. `--` stops sudo option parsing before the command.
exec sudo -- "$APP" "$VV"
