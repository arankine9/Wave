#!/bin/bash
# Build, codesign, notarize, staple, and DMG-package Beck.
# Usage: scripts/release.sh
#
# Required env for a notarized release:
#   BECK_SIGNING_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID                  Apple ID email
#   APPLE_APP_SPECIFIC_PASSWORD  App-specific password
#   APPLE_TEAM_ID             10-char team identifier
#
# If the signing identity is missing the script ad-hoc signs and skips
# notarization, producing a DMG that runs locally but trips Gatekeeper on
# fresh accounts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Beck"
DIST="$ROOT/dist"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "[release] building app bundle"
bash "$ROOT/scripts/build-app.sh" release

if [ -z "${BECK_SIGNING_IDENTITY:-}" ]; then
    echo "[release] BECK_SIGNING_IDENTITY not set; producing unsigned DMG"
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
RW_DMG="$DIST/$APP_NAME-rw.dmg"
STAGING="$DIST/staging"
VOL="$APP_NAME"

echo "[release] building $DMG (drag-to-Applications layout)"

bash "$ROOT/scripts/make-dmg-background.sh"

rm -rf "$STAGING"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/"
cp "$ROOT/Resources/dmg-background.tiff" "$STAGING/.background/background.tiff"
ln -s /Applications "$STAGING/Applications"

rm -f "$RW_DMG"
hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
MOUNT_DIR="$(echo "$ATTACH_OUTPUT" | grep -E '/Volumes/' | sed -E 's/^.*(\/Volumes\/[^[:space:]].*)$/\1/' | head -1)"
if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR" ]; then
    echo "[release] failed to locate mount point from hdiutil attach output" >&2
    exit 1
fi
cleanup_mount() {
    [ -d "$MOUNT_DIR" ] && hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
}
trap cleanup_mount EXIT

BG_POSIX="$MOUNT_DIR/.background/background.tiff"
if ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 800, 600}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        try
            set background picture of viewOptions to (POSIX file "$BG_POSIX" as alias)
        on error errMsg number errNum
            log "background picture assignment failed: " & errMsg & " (" & errNum & ")"
        end try
        set position of item "$APP_NAME.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "[release] Finder scripting failed — grant Terminal Automation access for Finder in System Settings → Privacy & Security → Automation, then re-run." >&2
    exit 1
fi

sync
hdiutil detach "$MOUNT_DIR" -force >/dev/null
trap - EXIT

rm -f "$DMG"
hdiutil convert "$RW_DMG" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGING"

if [ "$SIGNED" = "1" ]; then
    echo "[release] codesigning DMG"
    codesign --sign "$BECK_SIGNING_IDENTITY" --options runtime "$DMG"

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
