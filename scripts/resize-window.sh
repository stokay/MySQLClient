#!/bin/bash
# Resizes the running "MySQL Client" app window to an exact point size and
# repositions it near the top-left, ready for a manual App Store screenshot.
#
# Usage: scripts/resize-window.sh [width] [height]
#   Defaults to 1280x800 (a valid Mac App Store screenshot resolution).
#
# Why a script instead of dragging: dragging a window edge has no pixel
# readout, so hitting an exact 1280x800 by hand is close to impossible.
# AppleScript can set a window's frame precisely via Accessibility.
set -euo pipefail

WIDTH="${1:-1280}"
HEIGHT="${2:-800}"
APP_NAME="MySQL Client"

if ! osascript -e "tell application \"System Events\" to (name of processes) contains \"$APP_NAME\"" | grep -q true; then
    echo "error: '$APP_NAME' is not running — launch it first." >&2
    exit 1
fi

osascript <<APPLESCRIPT
tell application "System Events"
    tell process "$APP_NAME"
        set frontmost to true
        delay 0.3
        set position of window 1 to {80, 80}
        set size of window 1 to {$WIDTH, $HEIGHT}
    end tell
end tell
APPLESCRIPT

echo "==> '$APP_NAME' window set to ${WIDTH}x${HEIGHT} at (80, 80)."
echo "==> To capture without a drop shadow: press ⌘⇧4, then Space, then hold ⌥ (Option) while clicking the window."
