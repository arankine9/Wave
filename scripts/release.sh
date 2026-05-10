#!/bin/bash
# Build, codesign, notarize, staple, and DMG-package Voxflow.
# Usage: scripts/release.sh
#
# Required env for a notarized release:
#   VOXFLOW_SIGNING_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID                  Apple ID email
#   APPLE_APP_SPECIFIC_PASSWORD  App-specific password
#   APPLE_TEAM_ID             10-char team identifier
#
# If the signing identity is missing the script ad-hoc signs and skips
# notarization, producing a DMG that runs locally but trips Gatekeeper on
# fresh accounts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Voxflow"
DIST="$ROOT/dist"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "[release] building app bundle"
bash "$ROOT/scripts/build-app.sh" release

if [ -z "${VOXFLOW_SIGNING_IDENTITY:-}" ]; then
    echo "[release] VOXFLOW_SIGNING_IDENTITY not set; producing unsigned DMG"
    SIGNED=0
else
    SIGNED=1
fi

mkdir -p "$DIST"

if [ "$SIGNED" = "1" ]; then
    echo "[release] verifying signature"
    codesign --verify --deep --strict --verbose=2 "$APP"

    if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
        ZIP="$DIST/$APP_NAME-notarize.zip"
        echo "[release] zipping for notarization"
        ditto -c -k --keepParent "$APP" "$ZIP"

        echo "[release] submitting to notarytool"
        xcrun notarytool submit "$ZIP" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_SPECIFIC_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" \
            --wait

        echo "[release] stapling"
        xcrun stapler staple "$APP"
        rm "$ZIP"
    else
        echo "[release] APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID not all set; skipping notarization"
    fi
fi

DMG="$DIST/$APP_NAME.dmg"
echo "[release] building $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$APP" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

if [ "$SIGNED" = "1" ]; then
    echo "[release] codesigning DMG"
    codesign --sign "$VOXFLOW_SIGNING_IDENTITY" --options runtime "$DMG"

    if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
        echo "[release] notarizing DMG"
        xcrun notarytool submit "$DMG" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_SPECIFIC_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" \
            --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "[release] done: $DMG"
