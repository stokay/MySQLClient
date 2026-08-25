#!/bin/bash
# Resizes the "MySQL Client" window to an exact point size, then captures
# *exactly* that screen rectangle — no window drop shadow, no relying on
# holding ⌥ correctly during a manual ⌘⇧4 capture. `screencapture -R`
# grabs raw pixels in a region, it doesn't render window chrome/shadow at
# all, so the output is always exactly the requested size (or its Retina
# 2x multiple — both are valid Mac App Store resolutions).
#
# Usage: scripts/capture-screenshot.sh <output-name> [width] [height]
#   scripts/capture-screenshot.sh general-light
#   scripts/capture-screenshot.sh general-light 1280 800
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <output-name> [width] [height]" >&2
    exit 1
fi

NAME="$1"
WIDTH="${2:-1280}"
HEIGHT="${3:-800}"
APP_NAME="MySQL Client"
ORIGIN_X=80
ORIGIN_Y=80
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docs/appstore-screenshots"
mkdir -p "$OUT_DIR"
OUT_PATH="$OUT_DIR/$NAME.png"

if ! osascript -e "tell application \"System Events\" to (name of processes) contains \"$APP_NAME\"" | grep -q true; then
    echo "error: '$APP_NAME' is not running — launch it first." >&2
    exit 1
fi

osascript <<APPLESCRIPT
tell application "System Events"
    tell process "$APP_NAME"
        set frontmost to true
        delay 0.3
        set position of window 1 to {$ORIGIN_X, $ORIGIN_Y}
        set size of window 1 to {$WIDTH, $HEIGHT}
    end tell
end tell
APPLESCRIPT

sleep 0.4
screencapture -R"$ORIGIN_X,$ORIGIN_Y,$WIDTH,$HEIGHT" -t png "$OUT_PATH"

DIMS=$(sips -g pixelWidth -g pixelHeight "$OUT_PATH" | awk '/pixel/{print $2}' | paste -sd x -)
echo "==> Saved: $OUT_PATH  (${DIMS}px)"
