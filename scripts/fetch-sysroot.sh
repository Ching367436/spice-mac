#!/usr/bin/env bash
#
# fetch-sysroot.sh — obtain the prebuilt native SPICE dependency stack that
# CocoaSpice links against, and stage the needed frameworks under ./Frameworks.
#
# CocoaSpice (utmapp) is only the Objective-C bridge; it does NOT bundle the
# heavy native libraries (spice-client-glib, glib, gstreamer, libusb, ...). UTM
# builds these and publishes them as a "Sysroot" of @rpath-relocatable
# .framework bundles. We reuse that here (arm64).
#
# Sources, in order of preference:
#   1) $SPICEMAC_SYSROOT_URL  — a direct URL to a (re-hosted, pinned) sysroot
#      tarball. Recommended for reproducibility; set $SPICEMAC_SYSROOT_SHA256 to
#      verify it.
#   2) gh CLI download of a UTM CI "Sysroot-macos-arm64" artifact (needs
#      `gh auth login`; CI artifacts expire ~90 days, so pin a UTM release tag).
#
# Fallback (not automated here): build from source with UTM's
# scripts/build_dependencies.sh -p macos -a arm64 && pack_dependencies.sh.
# See README.md → "Dependencies".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORKS_DIR="$ROOT/Frameworks"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# UTM pin: bump these together when updating the dependency stack.
UTM_REPO="${SPICEMAC_UTM_REPO:-utmapp/UTM}"
SYSROOT_ARTIFACT="${SPICEMAC_SYSROOT_ARTIFACT:-Sysroot-macos-arm64}"

# The subset of the sysroot we actually need (SPICE + its transitive deps).
# Everything else in a UTM sysroot (QEMU, MoltenVK, mesa, virgl, slirp, swtpm,
# angle, vulkan, ...) is stripped to shrink the app and the signing surface.
KEEP_FRAMEWORKS=(
  spice-client-glib-2.0 spice-protocol
  glib-2.0 gobject-2.0 gio-2.0 gmodule-2.0 girepository-2.0
  gstreamer-1.0 gstbase-1.0 gstapp-1.0 gstaudio-1.0 gstvideo-1.0
  gstreamer-plugins
  opus libusb-1.0 usbredirparser usbredirhost
  soup-3.0 soup-2.4 phodav-3.0
  ssl crypto                    # openssl
  pixman-1 json-glib-1.0 ffi intl
  gpg-error gcrypt
  png16 jpeg z zstd lz4
)

log() { printf '\033[1;34m[fetch-sysroot]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fetch-sysroot] error:\033[0m %s\n' "$*" >&2; exit 1; }

extract_subset() {
  local sysroot_dir="$1"
  mkdir -p "$FRAMEWORKS_DIR"
  local copied=0
  # UTM sysroots ship .framework bundles (preferred) and/or lib*.dylib + include/.
  for name in "${KEEP_FRAMEWORKS[@]}"; do
    # Match Foo.framework or libFoo*.framework loosely.
    while IFS= read -r fw; do
      [ -z "$fw" ] && continue
      cp -R "$fw" "$FRAMEWORKS_DIR/"
      copied=$((copied + 1))
    done < <(find "$sysroot_dir" -type d \( -name "${name}.framework" -o -name "lib${name}.framework" -o -name "${name}*.framework" \) 2>/dev/null)
  done
  [ "$copied" -gt 0 ] || die "no matching frameworks found in $sysroot_dir (is this a .framework sysroot?)"
  log "staged $copied framework bundle(s) into Frameworks/"
}

fetch_from_url() {
  local url="$1" out="$WORK/sysroot.tgz"
  log "downloading $url"
  curl -fL --retry 3 -o "$out" "$url" || die "download failed"
  if [ -n "${SPICEMAC_SYSROOT_SHA256:-}" ]; then
    log "verifying sha256"
    echo "${SPICEMAC_SYSROOT_SHA256}  $out" | shasum -a 256 -c - || die "checksum mismatch"
  else
    log "WARNING: SPICEMAC_SYSROOT_SHA256 not set; skipping integrity check"
  fi
  mkdir -p "$WORK/extracted"
  tar -xzf "$out" -C "$WORK/extracted"
  extract_subset "$WORK/extracted"
}

fetch_from_gh() {
  command -v gh >/dev/null 2>&1 || die "gh CLI not found; set SPICEMAC_SYSROOT_URL instead"
  gh auth status >/dev/null 2>&1 || die "gh not authenticated; run 'gh auth login' or set SPICEMAC_SYSROOT_URL"
  log "locating latest successful build with artifact '$SYSROOT_ARTIFACT' in $UTM_REPO"
  local run_id
  run_id="$(gh run list -R "$UTM_REPO" --status success --limit 30 \
            --json databaseId,name --jq '.[0].databaseId' 2>/dev/null || true)"
  [ -n "$run_id" ] || die "could not find a successful UTM CI run; set SPICEMAC_SYSROOT_URL"
  log "downloading artifact from run $run_id (this is large)"
  gh run download "$run_id" -R "$UTM_REPO" -n "$SYSROOT_ARTIFACT" -D "$WORK/extracted" \
    || die "gh run download failed (artifact may have expired); set SPICEMAC_SYSROOT_URL"
  extract_subset "$WORK/extracted"
}

main() {
  log "target: $FRAMEWORKS_DIR (arm64)"
  if [ -n "${SPICEMAC_SYSROOT_URL:-}" ]; then
    fetch_from_url "$SPICEMAC_SYSROOT_URL"
  else
    log "SPICEMAC_SYSROOT_URL not set; trying gh CI artifact"
    fetch_from_gh
  fi
  log "done. Review Frameworks/, then build with scripts/build-app.sh"
}

main "$@"
