#!/bin/bash
# Builds a Debug .app and launches it in a chosen language, for verifying
# localization without waiting on the notarized DMG pipeline.
#
# `swift run` can't be used for this: the SwiftPM executable keeps its
# resources in Bundle.module, while SwiftUI's Text(...) and String(localized:)
# both read Bundle.main — so under `swift run` every lookup misses and falls
# back to the English key. Only a real .app bundle resolves the catalog.
#
# Usage: scripts/run-localized.sh [en|tr|es|de|hi|ru|pl|system]
set -euo pipefail

LANG_CODE="${1:-system}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export TMPDIR="$ROOT/.scratch/tmp"
mkdir -p "$TMPDIR"

xcodegen generate
xcodebuild -project MySQLMacClient.xcodeproj -scheme MySQLMacClient \
    -configuration Debug -derivedDataPath "$ROOT/.scratch/DerivedData" build

APP="$ROOT/.scratch/DerivedData/Build/Products/Debug/MySQL Client.app"
pkill -f "MySQL Client.app" 2>/dev/null || true
sleep 1

if [ "$LANG_CODE" = "system" ]; then
    echo "==> Launching with the system language"
    open "$APP"
else
    echo "==> Launching with -AppleLanguages ($LANG_CODE)"
    open "$APP" --args -AppleLanguages "($LANG_CODE)"
fi
