#!/usr/bin/env bash
#
# make-icon.sh — regenerate Resources/AppIcon.icns from design/icon/source.png.
#
# The source is a 1024²+ "squircle on white" app-icon render (e.g. from an image
# model). This re-masks it into a clean macOS icon plate with transparent corners
# (design/icon/iconmask.swift detects the squircle by colour saturation, so it
# excludes the white background and the baked drop shadow), then builds the .icns.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="${1:-design/icon/source.png}"
OUT="Resources/AppIcon.icns"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
log() { printf '\033[1;34m[make-icon]\033[0m %s\n' "$*"; }

[ -f "$SRC" ] || { echo "source not found: $SRC" >&2; exit 1; }

log "compiling masker"
swiftc design/icon/iconmask.swift -o "$WORK/iconmask"

log "masking → 1024 master"
"$WORK/iconmask" "$SRC" "$WORK/master.png" 1024

log "building iconset"
ICONSET="$WORK/AppIcon.iconset"; mkdir -p "$ICONSET"
gen() { sips -z "$2" "$2" "$WORK/master.png" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png 16;       gen icon_16x16@2x.png 32
gen icon_32x32.png 32;       gen icon_32x32@2x.png 64
gen icon_128x128.png 128;    gen icon_128x128@2x.png 256
gen icon_256x256.png 256;    gen icon_256x256@2x.png 512
gen icon_512x512.png 512;    cp "$WORK/master.png" "$ICONSET/icon_512x512@2x.png"

log "iconutil → $OUT"
iconutil -c icns "$ICONSET" -o "$OUT"
log "done → $OUT"
