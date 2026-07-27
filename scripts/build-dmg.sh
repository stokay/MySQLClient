#!/bin/bash
# Builds a Release .app and packages it into a simple (non-notarized) DMG.
# Usage: scripts/build-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export TMPDIR="$ROOT/.scratch/tmp"
mkdir -p "$TMPDIR"
DERIVED_DATA="$ROOT/.scratch/DerivedData"

echo "==> xcodegen generate"
xcodegen generate

echo "==> Release build"
xcodebuild -project MySQLMacClient.xcodeproj \
    -scheme MySQLMacClient \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    build

APP="$DERIVED_DATA/Build/Products/Release/MySQL Client.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

echo "==> Staging DMG contents (version $VERSION)"
STAGE="$ROOT/.scratch/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG_PATH="$ROOT/MySQLMacClient-$VERSION.dmg"
rm -f "$DMG_PATH"

# A previous DMG (this one, an older version, or the pre-rename "MySQLMacClient"
# volume name) left mounted under /Volumes/MySQL Client[, 1, 2, ...] or
# /Volumes/MySQLMacClient[, 1, 2, ...] blocks `hdiutil create -ov` with
# "Resource busy" — eject every such leftover mount before (re)creating it.
echo "==> Ejecting any mounted MySQL Client volumes"
for mount in "/Volumes/MySQL Client"* /Volumes/MySQLMacClient*; do
    [ -d "$mount" ] || continue
    hdiutil detach "$mount" -quiet 2>/dev/null || hdiutil detach "$mount" -force -quiet 2>/dev/null || true
done

echo "==> Creating DMG"
hdiutil create -volname "MySQL Client" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"

echo "==> Done: $DMG_PATH"
