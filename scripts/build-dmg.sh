#!/bin/bash
# Builds a Release .app, signs it with the Developer ID Application
# identity, packages it into a DMG, then notarizes + staples that DMG —
# without this, the DMG opens fine on this Mac but shows "is damaged and
# can't be opened" for anyone else once Gatekeeper sees the quarantine
# flag a browser/Finder sets on a downloaded file.
# Usage: scripts/build-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# One-time setup, before this script can notarize anything:
#   xcrun notarytool store-credentials "notarytool-mysqlclient" \
#     --apple-id "<your Apple ID email>" --team-id 848JB749D8 \
#     --password "<an app-specific password from appleid.apple.com>"
NOTARY_PROFILE="notarytool-mysqlclient"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: no notarytool credentials stored under profile '$NOTARY_PROFILE'." >&2
    echo "Run this once first (see comment above for the exact command):" >&2
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <email> --team-id 848JB749D8 --password <app-specific-password>" >&2
    exit 1
fi

export TMPDIR="$ROOT/.scratch/tmp"
mkdir -p "$TMPDIR"
DERIVED_DATA="$ROOT/.scratch/DerivedData"

echo "==> xcodegen generate"
xcodegen generate

echo "==> DeveloperID build (Developer ID Application signing, for direct download)"
# A dedicated configuration, not `-configuration Release` — see project.yml's
# comment on the DeveloperID config for why a command-line signing override
# on top of Release doesn't work (it leaks into the SPM package targets).
xcodebuild -project MySQLMacClient.xcodeproj \
    -scheme MySQLMacClient \
    -configuration DeveloperID \
    -derivedDataPath "$DERIVED_DATA" \
    build

APP="$DERIVED_DATA/Build/Products/DeveloperID/MySQL Client.app"
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

echo "==> Notarizing (this calls out to Apple and can take a few minutes)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Done: $DMG_PATH"
