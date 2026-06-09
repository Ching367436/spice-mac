#!/usr/bin/env bash
#
# check-version.sh — assert the version is consistent across the sources that drift:
#   * Resources/Info.plist  CFBundleShortVersionString
#   * CHANGELOG.md          the newest released `## [x.y.z]` heading
#   * CHANGELOG.md          a matching `[x.y.z]: <url>` footer compare-link
# Optionally (when $1 is given, e.g. a pushed tag "v0.1.7") also assert it matches.
# Dependency-free; exits non-zero with a precise message on mismatch. Used by CI
# and by scripts/release.sh as a final sanity check.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
CHANGELOG="$ROOT/CHANGELOG.md"
die() { printf '\033[1;31m[check-version] FAIL:\033[0m %s\n' "$*" >&2; exit 1; }

plist_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)" \
    || die "could not read CFBundleShortVersionString from $PLIST"

# Newest released changelog version = first `## [x.y.z]` that is not [Unreleased].
cl_ver="$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
[ -n "$cl_ver" ] || die "no released '## [x.y.z]' heading found in $CHANGELOG"

[ "$plist_ver" = "$cl_ver" ] \
    || die "Info.plist version ($plist_ver) != newest CHANGELOG entry ($cl_ver)"

grep -qE "^\[$cl_ver\]: " "$CHANGELOG" \
    || die "CHANGELOG has '## [$cl_ver]' but no '[$cl_ver]: <url>' footer compare-link"

if [ "${1:-}" != "" ]; then
    tag_ver="${1#v}"
    [ "$tag_ver" = "$plist_ver" ] \
        || die "tag $1 (=$tag_ver) != Info.plist/CHANGELOG version ($plist_ver)"
fi

printf '\033[1;32m[check-version] OK\033[0m — Info.plist, CHANGELOG, and links agree on %s\n' "$plist_ver"
