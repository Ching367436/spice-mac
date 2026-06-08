#!/usr/bin/env bash
#
# fetch-sysroot.sh — stage the native SPICE dependency stack (arm64) into
# ./Frameworks, matching what Package.swift links.
#
# CocoaSpice (utmapp) is only the Objective-C bridge; it does NOT bundle the
# native libraries (spice-client-glib, glib, gstreamer, libusb, ...). UTM builds
# these and publishes a "Sysroot" of @rpath-relocatable .framework bundles. We
# link/embed those frameworks (the sysroot's lib/*.dylib have absolute CI install
# names and are NOT relocatable), plus the static GStreamer plugin archives that
# CocoaSpice's gst_ios_init.m registers.
#
# Sources, in order of preference:
#   1) $SPICEMAC_SYSROOT_URL  — direct URL to a (re-hosted, pinned) sysroot tarball.
#      Set $SPICEMAC_SYSROOT_SHA256 to verify it.
#   2) gh download of a UTM CI "Sysroot-macos-arm64" artifact (needs `gh auth login`;
#      artifacts expire, so pin/re-host one for reproducibility). Override the
#      artifact id with $SPICEMAC_SYSROOT_ARTIFACT_ID, else the latest by name.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORKS_DIR="$ROOT/Frameworks"
PLUGINS_DIR="$FRAMEWORKS_DIR/gstreamer-1.0"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

UTM_REPO="${SPICEMAC_UTM_REPO:-utmapp/UTM}"
SYSROOT_ARTIFACT="${SPICEMAC_SYSROOT_ARTIFACT:-Sysroot-macos-arm64}"

# Static GStreamer plugin archives CocoaSpice registers — must match Package.swift.
GST_PLUGINS=(adder app audioconvert audiorate audioresample audiotestsrc autodetect
             coreelements gio jpeg osxaudio playback typefindfunctions videoconvert
             videofilter videorate videoscale videotestsrc volume)

log() { printf '\033[1;34m[fetch-sysroot]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fetch-sysroot] error:\033[0m %s\n' "$*" >&2; exit 1; }

# Locate the extracted sysroot root (the dir containing Frameworks/ + lib/).
find_sysroot_root() {
    local base="$1"
    # The artifact wraps a sysroot.tgz; extract it if present.
    local tgz
    tgz="$(find "$base" -maxdepth 2 -name 'sysroot*.tgz' | head -1 || true)"
    if [ -n "$tgz" ]; then
        mkdir -p "$base/unpacked"
        tar -xzf "$tgz" -C "$base/unpacked"
        base="$base/unpacked"
    fi
    local fw
    fw="$(find "$base" -maxdepth 3 -type d -name Frameworks | head -1 || true)"
    [ -n "$fw" ] || die "could not find a Frameworks/ dir in the sysroot"
    dirname "$fw"
}

stage() {
    local sysroot="$1"
    [ -d "$sysroot/Frameworks" ] || die "no Frameworks/ under $sysroot"
    mkdir -p "$FRAMEWORKS_DIR" "$PLUGINS_DIR"

    log "copying frameworks"
    cp -R "$sysroot/Frameworks/"*.framework "$FRAMEWORKS_DIR/"

    log "copying GStreamer plugin archives"
    for p in "${GST_PLUGINS[@]}"; do
        local a="$sysroot/lib/gstreamer-1.0/libgst${p}.a"
        [ -f "$a" ] || die "missing plugin archive libgst${p}.a"
        cp "$a" "$PLUGINS_DIR/"
    done

    log "staged $(ls -d "$FRAMEWORKS_DIR"/*.framework | wc -l | tr -d ' ') frameworks + ${#GST_PLUGINS[@]} plugin archives"
}

from_url() {
    local url="$1" out="$WORK/sysroot.tgz"
    # The sysroot is the entire native TLS + parser stack; a tampered download is
    # game over. Require a pinned SHA256 and fail closed (set SPICEMAC_SYSROOT_SHA256_INSECURE=1
    # to deliberately bypass for a one-off local test).
    if [ -z "${SPICEMAC_SYSROOT_SHA256:-}" ] && [ "${SPICEMAC_SYSROOT_SHA256_INSECURE:-}" != "1" ]; then
        die "refusing to download an unverified sysroot — set SPICEMAC_SYSROOT_SHA256 to the pinned digest"
    fi
    log "downloading $url"
    curl -fL --retry 3 -o "$out" "$url" || die "download failed"
    if [ -n "${SPICEMAC_SYSROOT_SHA256:-}" ]; then
        echo "${SPICEMAC_SYSROOT_SHA256}  $out" | shasum -a 256 -c - || die "checksum mismatch"
    else
        log "WARNING: SPICEMAC_SYSROOT_SHA256_INSECURE=1 — skipping integrity check (unsafe)"
    fi
    mkdir -p "$WORK/x"; tar -xzf "$out" -C "$WORK/x"
    stage "$(find_sysroot_root "$WORK/x")"
}

from_gh() {
    command -v gh >/dev/null 2>&1 || die "gh not found; set SPICEMAC_SYSROOT_URL"
    gh auth status >/dev/null 2>&1 || die "gh not authenticated; run 'gh auth login' or set SPICEMAC_SYSROOT_URL"
    local id="${SPICEMAC_SYSROOT_ARTIFACT_ID:-}"
    if [ -z "$id" ]; then
        log "finding latest '$SYSROOT_ARTIFACT' artifact in $UTM_REPO"
        id="$(gh api -X GET "repos/$UTM_REPO/actions/artifacts?per_page=100" \
              --jq ".artifacts[] | select(.name==\"$SYSROOT_ARTIFACT\" and .expired==false) | .id" 2>/dev/null | head -1 || true)"
        [ -n "$id" ] || die "no non-expired '$SYSROOT_ARTIFACT' artifact found; set SPICEMAC_SYSROOT_URL"
    fi
    log "downloading artifact id $id (large; retrying on flaky network)"
    local zip="$WORK/artifact.zip" ok=
    for i in 1 2 3 4 5; do
        if gh api "repos/$UTM_REPO/actions/artifacts/$id/zip" > "$zip" 2>/dev/null \
           && [ "$(stat -f%z "$zip" 2>/dev/null || echo 0)" -gt 1000000 ]; then ok=1; break; fi
        log "  attempt $i failed; retrying"
    done
    [ -n "$ok" ] || die "artifact download failed; set SPICEMAC_SYSROOT_URL"
    mkdir -p "$WORK/x"; unzip -q "$zip" -d "$WORK/x"
    stage "$(find_sysroot_root "$WORK/x")"
}

main() {
    log "target: $FRAMEWORKS_DIR (arm64)"
    if [ -n "${SPICEMAC_SYSROOT_URL:-}" ]; then from_url "$SPICEMAC_SYSROOT_URL"; else from_gh; fi
    log "done. Build with: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh"
}

main "$@"
