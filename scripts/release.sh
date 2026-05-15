#!/bin/bash
# Build, codesign, notarize, staple, and DMG-package Wave.
# Usage: scripts/release.sh
#
# Required env for a notarized release:
#   WAVE_SIGNING_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID)"
#   WAVE_NOTARY_PROFILE    Keychain profile name (default: wave-notary).
#                          Set up once with:
#                            xcrun notarytool store-credentials wave-notary \
#                              --apple-id <email> --team-id <TEAMID> --password <app-specific-pw>
#
# CI override (used when no keychain profile is available, e.g. GitHub Actions):
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD
#
# If the signing identity is missing the script ad-hoc signs and skips
# notarization, producing a DMG that runs locally but trips Gatekeeper on
# fresh accounts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Wave"
DIST="$ROOT/dist"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "[release] building app bundle"
bash "$ROOT/scripts/build-app.sh" release

if [ -z "${WAVE_SIGNING_IDENTITY:-}" ]; then
    echo "[release] WAVE_SIGNING_IDENTITY not set; producing unsigned DMG"
    SIGNED=0
else
    SIGNED=1
fi

mkdir -p "$DIST"

# Pick how we authenticate notarytool. Prefer a keychain profile (local dev),
# fall back to Apple ID + app-specific password (CI).
NOTARY_PROFILE="${WAVE_NOTARY_PROFILE:-wave-notary}"
NOTARY_ARGS=()
if security find-generic-password -s "com.apple.gke.notary.tool" -a "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
fi

if [ "$SIGNED" = "1" ]; then
    echo "[release] verifying signature"
    codesign --verify --deep --strict --verbose=2 "$APP"

    if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
        ZIP="$DIST/$APP_NAME-notarize.zip"
        echo "[release] zipping for notarization"
        ditto -c -k --keepParent "$APP" "$ZIP"

        echo "[release] submitting to notarytool"
        xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

        echo "[release] stapling"
        xcrun stapler staple "$APP"
        rm "$ZIP"
    else
        echo "[release] no notarytool credentials (keychain profile '$NOTARY_PROFILE' missing and APPLE_* env vars unset); skipping notarization"
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

# If a stale /Volumes/Wave is hanging around, hdiutil silently mounts at
# "/Volumes/Wave 1" and the AppleScript below — keyed on disk name $VOL —
# binds to the wrong (read-only) volume and the .DS_Store never gets written.
if [ -d "/Volumes/$VOL" ]; then
    echo "[release] detaching stale /Volumes/$VOL before mounting build DMG"
    hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
fi

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
MOUNT_DIR="$(echo "$ATTACH_OUTPUT" | grep -E '/Volumes/' | sed -E 's/^.*(\/Volumes\/[^[:space:]].*)$/\1/' | head -1)"
if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR" ]; then
    echo "[release] failed to locate mount point from hdiutil attach output" >&2
    exit 1
fi
# Use the *actual* mounted volume name in the AppleScript so the script keeps
# working even if hdiutil disambiguated the mount with a " 1" suffix.
MOUNT_VOL="$(basename "$MOUNT_DIR")"
cleanup_mount() {
    [ -d "$MOUNT_DIR" ] && hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
}
trap cleanup_mount EXIT

if [ -n "${WAVE_SKIP_DMG_LAYOUT:-}" ]; then
    echo "[release] WAVE_SKIP_DMG_LAYOUT set; skipping Finder window styling"
elif ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$MOUNT_VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 800, 600}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        try
            set background picture of viewOptions to file ".background:background.tiff"
        on error errMsg number errNum
            log "background picture assignment failed: " & errMsg & " (" & errNum & ")"
        end try
        set position of item "$APP_NAME.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        update without registering applications
        delay 5
        close
    end tell
end tell
APPLESCRIPT
then
    echo "[release] Finder scripting failed — grant Terminal Automation access for Finder in System Settings → Privacy & Security → Automation, then re-run." >&2
    exit 1
fi

# Finder writes .DS_Store asynchronously after `close`. Give it time to flush,
# normalize permissions so the file is readable when the DMG is opened later,
# then sync before detach.
sleep 2
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
sync
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
    codesign --sign "$WAVE_SIGNING_IDENTITY" --options runtime "$DMG"

    if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
        echo "[release] notarizing DMG"
        xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
        xcrun stapler staple "$DMG"
    fi
fi

echo "[release] done: $DMG"
