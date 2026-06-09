#!/usr/bin/env bash
#
# release.sh — cut a SpiceMac release in one command.
#
#   ./scripts/release.sh X.Y.Z          # prepare + build, then ask before publishing
#   ./scripts/release.sh X.Y.Z --yes    # skip the confirmation (for automation)
#
# It bumps Resources/Info.plist (both version fields), rolls CHANGELOG.md
# (Unreleased -> [X.Y.Z], fresh Unreleased, compare-links), builds the .app +
# .zip + .sha256, verifies version consistency, shows you the diff, and ONLY THEN
# — after a y/N confirm — does the irreversible part (commit, tag, push, GitHub
# release). Say no and nothing is published; roll back with:
#   git checkout Resources/Info.plist CHANGELOG.md
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PLIST="Resources/Info.plist"; CHANGELOG="CHANGELOG.md"
log() { printf '\033[1;34m[release]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[release] error:\033[0m %s\n' "$*" >&2; exit 1; }

VER="${1:-}"
[ -n "$VER" ] || die "usage: release.sh X.Y.Z [--yes]"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be semver X.Y.Z (got '$VER')"
ASSUME_YES=0
[ "${2:-}" = "--yes" ] && ASSUME_YES=1
[ "${SPICEMAC_ASSUME_YES:-0}" = "1" ] && ASSUME_YES=1

# --- Preflight (all reversible to here) ------------------------------------
log "preflight"
if ! git diff --quiet || ! git diff --cached --quiet; then die "working tree is dirty — commit or stash first"; fi
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "not on 'main' (on $(git rev-parse --abbrev-ref HEAD))"
git rev-parse "v$VER" >/dev/null 2>&1 && die "tag v$VER already exists"
CUR="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
[ "$VER" != "$CUR" ] && [ "$(printf '%s\n%s\n' "$CUR" "$VER" | sort -V | tail -1)" = "$VER" ] \
    || die "version $VER must be greater than current ($CUR)"
# [Unreleased] must have content (lines between it and the next '## [')
unrel="$(awk '/^## \[Unreleased\]/{f=1;next} /^## \[/{f=0} f' "$CHANGELOG" | grep -v '^[[:space:]]*$' || true)"
[ -n "$unrel" ] || die "CHANGELOG '## [Unreleased]' is empty — add notes for $VER first"
command -v gh >/dev/null 2>&1 || die "gh CLI not found (needed to publish)"

PREV="$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
BASEURL="$(grep -m1 '^\[Unreleased\]: ' "$CHANGELOG" | sed -E 's|^\[Unreleased\]: (.*)/compare/.*|\1|')"
[ -n "$PREV" ] && [ -n "$BASEURL" ] || die "could not parse previous version / base URL from CHANGELOG footer"
TODAY="$(date +%F)"
log "preparing $PREV -> $VER ($TODAY)"

# --- Mutate (local, reversible) --------------------------------------------
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$PLIST"
CURBUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURBUILD+1))" "$PLIST"
log "Info.plist -> $VER (build $((CURBUILD+1)))"

tmp="$(mktemp)"
awk -v v="$VER" -v d="$TODAY" -v prev="$PREV" -v base="$BASEURL" '
  $0 == "## [Unreleased]" { print "## [Unreleased]"; print ""; print "## [" v "] — " d; next }
  $0 ~ /^\[Unreleased\]: / { print "[Unreleased]: " base "/compare/v" v "...HEAD";
                             print "[" v "]: " base "/compare/v" prev "...v" v; next }
  { print }
' "$CHANGELOG" > "$tmp" && mv "$tmp" "$CHANGELOG"
log "CHANGELOG rolled (Unreleased -> [$VER], links updated)"

# --- Build + verify --------------------------------------------------------
log "building"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" ./scripts/build-app.sh
./scripts/check-version.sh "v$VER"
ZIP="build/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST" 2>/dev/null || echo SpiceMac).app.zip"
[ -f "$ZIP" ] || ZIP="build/SpiceMac.app.zip"
SHA="$(awk '{print $1}' "$ZIP.sha256" 2>/dev/null)"

# --- Review + confirm (publish is irreversible) ----------------------------
echo; log "prepared. changes:"; git --no-pager diff --stat; echo
log "SHA-256: ${SHA:-<none>}"
if [ "$ASSUME_YES" != 1 ]; then
    printf '\033[1;33mPublish v%s — commit, tag, push, and create the GitHub release? [y/N] \033[0m' "$VER" >&2
    read -r reply || reply=n
    case "$reply" in [yY]|[yY][eE][sS]) ;; *)
        echo "Not published. Roll back with: git checkout $PLIST $CHANGELOG" >&2; exit 0 ;;
    esac
fi

# --- Publish (irreversible) ------------------------------------------------
notes="$(mktemp)"
awk -v v="$VER" '$0 ~ "^## \\[" v "\\]"{f=1;next} f&&/^## \[/{f=0} f' "$CHANGELOG" > "$notes"
printf '\n### Download\n`SpiceMac.app.zip` — Apple Silicon, macOS 12+. Ad-hoc signed; to open: right-click ▸ **Open** (macOS 14) or **System Settings ▸ Privacy & Security ▸ Open Anyway** (macOS 15+), or `xattr -dr com.apple.quarantine /Applications/SpiceMac.app`.\n\nSHA-256: `%s`\n' "${SHA:-see asset}" >> "$notes"

git add "$PLIST" "$CHANGELOG"
git commit -q -m "Release $VER"
git tag -a "v$VER" -m "SpiceMac $VER"
log "pushing"
git push origin main
git push origin "v$VER"
log "creating GitHub release"
gh release create "v$VER" "$ZIP" "$ZIP.sha256" --title "SpiceMac $VER" --verify-tag --notes-file "$notes"
rm -f "$notes"
log "released v$VER ✓  https://github.com/Ching367436/spice-mac/releases/tag/v$VER"
