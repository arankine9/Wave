#!/bin/bash
# Build a runnable Voxflow.app bundle from the SPM executable.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Voxflow"
APP_DIR="$ROOT/build/$APP_NAME.app"
BIN="$ROOT/.build/${CONFIG}/$APP_NAME"

cd "$ROOT"

echo "[build-app] swift build -c $CONFIG"
swift build -c "$CONFIG"

if [ ! -f "$BIN" ]; then
    echo "[build-app] expected binary at $BIN, not found" >&2
    exit 1
fi

echo "[build-app] assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Optional code-signing.
if [ -n "${VOXFLOW_SIGNING_IDENTITY:-}" ]; then
    echo "[build-app] codesigning with identity: $VOXFLOW_SIGNING_IDENTITY"
    codesign --force --options runtime \
        --entitlements "$ROOT/Resources/Voxflow.entitlements" \
        --sign "$VOXFLOW_SIGNING_IDENTITY" \
        "$APP_DIR"
else
    echo "[build-app] no VOXFLOW_SIGNING_IDENTITY set; ad-hoc signing for local run"
    codesign --force --sign - \
        --entitlements "$ROOT/Resources/Voxflow.entitlements" \
        "$APP_DIR" || true
fi

echo "[build-app] done: $APP_DIR"
