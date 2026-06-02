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

# Pick how we authenticate notarytool. Use the keychain profile by default
# (set up locally with `xcrun notarytool store-credentials`); fall back to
# Apple ID + app-specific password env vars when the profile is unset
# (set WAVE_NOTARY_PROFILE="" in CI to force the env-var path).
NOTARY_PROFILE="${WAVE_NOTARY_PROFILE-wave-notary}"
NOTARY_ARGS=()
if [ -n "$NOTARY_PROFILE" ]; then
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
VOL="$APP_NAME"
BG="$ROOT/Resources/dmg-background.png"

echo "[release] building $DMG (drag-to-Applications layout)"

# The committed, hand-tuned background is the source of truth; only render it
# if it has gone missing. Changing the artwork = re-run make-dmg-background.sh
# and commit the PNG (see that script's header).
if [ ! -f "$BG" ]; then
    echo "[release] $BG missing; rendering it"
    bash "$ROOT/scripts/make-dmg-background.sh"
fi

# dmgbuild writes the window's .DS_Store directly (drag-to-Applications layout,
# background, icon positions) WITHOUT driving Finder over AppleScript — so this
# produces the same styled window locally and on a headless CI runner. Prefer a
# dmgbuild already on PATH; otherwise keep a private venv under .build/ (which
# is gitignored).
if command -v dmgbuild >/dev/null 2>&1; then
    DMGBUILD="$(command -v dmgbuild)"
else
    VENV="$ROOT/.build/dmg-venv"
    if [ ! -x "$VENV/bin/dmgbuild" ]; then
        echo "[release] installing dmgbuild into $VENV"
        python3 -m venv "$VENV"
        "$VENV/bin/pip" install --quiet --upgrade pip
        "$VENV/bin/pip" install --quiet dmgbuild
    fi
    DMGBUILD="$VENV/bin/dmgbuild"
fi

rm -f "$DMG"
"$DMGBUILD" \
    -s "$ROOT/scripts/dmg-settings.py" \
    -D app="$APP" \
    -D background="$BG" \
    "$VOL" "$DMG"

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
