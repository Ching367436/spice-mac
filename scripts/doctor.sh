#!/usr/bin/env bash
#
# doctor.sh — preflight: is this Mac ready to build SpiceMac? Reports PASS/FAIL
# with a fix for each check. Run it before your first build (or `make doctor`).
# Does NOT use `set -e` — it runs every check so you see the full picture.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

fails=0
pass() { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[1;31m✗\033[0m %s\n     ↳ %s\n' "$1" "$2"; fails=$((fails+1)); }

printf '\033[1;34m[doctor]\033[0m checking the SpiceMac build environment\n'

# 1. Apple Silicon
if [ "$(uname -m)" = "arm64" ]; then pass "Apple Silicon (arm64)"
else fail "not arm64 (got $(uname -m))" "SpiceMac is Apple-Silicon only."; fi

# 2. Full Xcode selected (Command Line Tools alone can't build this)
xc="$(xcode-select -p 2>/dev/null)"
if printf '%s' "$xc" | grep -q "Xcode.app"; then pass "full Xcode selected ($xc)"
else fail "full Xcode not selected (got: ${xc:-none})" "sudo xcode-select -s /Applications/Xcode.app"; fi

# 3. Swift toolchain
if command -v swift >/dev/null 2>&1; then pass "swift present ($(swift --version 2>/dev/null | head -1))"
else fail "swift not found" "install Xcode."; fi

# 4. Metal toolchain (separate component on Xcode 26 — the #1 first-build blocker)
if xcrun -sdk macosx metal --version >/dev/null 2>&1; then pass "Metal toolchain present"
else fail "Metal toolchain missing (xcrun metal failed)" "xcodebuild -downloadComponent MetalToolchain"; fi

# 5. Native SPICE frameworks staged
if [ -d "$ROOT/Frameworks/glib-2.0.0.framework" ]; then
    ssl="$(strings "$ROOT/Frameworks/crypto.1.1.framework/crypto.1.1" 2>/dev/null | grep -m1 -iE '^OpenSSL [0-9.]+' || true)"
    pass "Frameworks/ staged${ssl:+ ($ssl)}"
else fail "Frameworks/ not staged" "make setup   (or ./scripts/fetch-sysroot.sh)"; fi

echo
if [ "$fails" -eq 0 ]; then
    printf '\033[1;32m[doctor] ready to build — run: make build\033[0m\n'
else
    printf '\033[1;31m[doctor] %d issue(s) above — fix them, then re-run scripts/doctor.sh\033[0m\n' "$fails"
    exit 1
fi
