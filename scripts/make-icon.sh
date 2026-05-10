#!/bin/bash
# Generate Resources/AppIcon.icns from a single source PNG (or, when no
# source is given, render a simple SF-Symbol-style waveform glyph via
# system tools so the bundle stops shipping the generic placeholder).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
ICONSET="$RES/AppIcon.iconset"
TARGET="$RES/AppIcon.icns"
SOURCE="${1:-}"

mkdir -p "$RES"
rm -rf "$ICONSET" "$TARGET"
mkdir -p "$ICONSET"

if [ -z "$SOURCE" ]; then
    SOURCE="$RES/AppIcon-source.png"
    if [ ! -f "$SOURCE" ]; then
        echo "[icon] no source supplied; rendering placeholder via SF Symbol"
        # Emit a 1024x1024 PNG using the macOS SF Symbol "waveform" via
        # Core Graphics through a tiny inline Swift script.
        TMP_SWIFT="$(mktemp -t voxicon).swift"
        cat > "$TMP_SWIFT" <<'EOF'
import AppKit

let size = 1024
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let image = NSImage(size: rect.size)
image.lockFocus()

let bg = NSGradient(colors: [NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.16, alpha: 1),
                              NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.34, alpha: 1)])!
bg.draw(in: rect, angle: -90)

let symbolConfig = NSImage.SymbolConfiguration(pointSize: 580, weight: .semibold, scale: .large)
    .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfig) {
    let r = NSRect(x: (CGFloat(size) - sym.size.width) / 2,
                   y: (CGFloat(size) - sym.size.height) / 2,
                   width: sym.size.width, height: sym.size.height)
    sym.draw(in: r)
}

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to render\n", stderr); exit(1)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try png.write(to: url)
EOF
        swift "$TMP_SWIFT" "$SOURCE"
        rm "$TMP_SWIFT"
    fi
fi

echo "[icon] rendering icon set from $SOURCE"
for sz in 16 32 64 128 256 512; do
    sips -Z $sz "$SOURCE" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -Z $((sz*2)) "$SOURCE" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
sips -Z 1024 "$SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$TARGET"
rm -rf "$ICONSET"
echo "[icon] wrote $TARGET"
