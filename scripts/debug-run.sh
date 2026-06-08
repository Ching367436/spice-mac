#!/usr/bin/env bash
#
# debug-run.sh — run SpiceMac with input tracing for debugging keyboard/mouse.
# Usage: ./scripts/debug-run.sh <connection.vv>
#
# Connect with a FRESH .vv (the ticket lasts ~30s), try the keyboard and mouse in
# the guest, then quit (Cmd-Q). Share the [SpiceInput] lines from the log file.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/SpiceMac.app/Contents/MacOS/SpiceMac"
VV="${1:?usage: debug-run.sh <connection.vv>}"
LOG="${SPICEMAC_LOG:-/tmp/spicemac-input.log}"

[ -x "$APP" ] || { echo "build first: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh"; exit 1; }

echo "running with input + SPICE channel tracing → $LOG"
echo "In the guest: move the mouse, click, and type a few keys. Then press Cmd-Q."
# Capture our [SpiceInput] traces AND the SPICE channel lifecycle (so we can see
# if/when the inputs channel is torn down or migrated).
SPICEMAC_INPUT_DEBUG=1 SPICE_DEBUG=1 G_MESSAGES_DEBUG=all "$APP" "$VV" 2>&1 \
    | tee "$LOG" \
    | grep -iE "\[SpiceInput\]|inputs channel|zap|switching|migrat|reset|error" || true
echo ""
echo "Full log: $LOG  (channel events: grep -iE 'inputs|zap|switch|migrat' \"$LOG\")"
