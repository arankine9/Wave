#!/bin/bash
# Generate Resources/dmg-background.tiff — the branded background used by
# scripts/release.sh inside the DMG window. The TIFF is multi-resolution
# (1x + 2x via `tiffutil -cathidpicheck`) so Finder renders crisply on
# Retina displays. If the TIFF already exists this script is a no-op;
# delete the file to force regeneration. To use custom artwork, replace
# the TIFF with your own — easiest with `tiffutil -cathidpicheck
# bg-1x.png bg-2x.png -out Resources/dmg-background.tiff`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
TARGET="$RES/dmg-background.tiff"

mkdir -p "$RES"

if [ -f "$TARGET" ]; then
    echo "[dmg-bg] $TARGET already exists; skipping"
    exit 0
fi

echo "[dmg-bg] generating $TARGET"
TMP_DIR="$(mktemp -d -t beckdmgbg)"
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_SWIFT="$TMP_DIR/render.swift"
PNG_1X="$TMP_DIR/bg-1x.png"
PNG_2X="$TMP_DIR/bg-2x.png"

cat > "$TMP_SWIFT" <<'EOF'
import AppKit

func render(scale: CGFloat, to url: URL) throws {
    let W = Int(600 * scale)
    let H = Int(400 * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: W,
        pixelsHigh: H,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else { fputs("rep alloc failed\n", stderr); exit(1) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H))

    let bg = NSGradient(colors: [
        NSColor(calibratedRed: 0.985, green: 0.985, blue: 0.99, alpha: 1),
        NSColor(calibratedRed: 0.925, green: 0.935, blue: 0.95, alpha: 1)
    ])!
    bg.draw(in: rect, angle: -90)

    let inkColor = NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.22, alpha: 1)
    let accentColor = NSColor(calibratedRed: 0.18, green: 0.42, blue: 0.78, alpha: 1)
    let mutedColor = NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.22, alpha: 0.55)

    let captionFont = NSFont.systemFont(ofSize: 22 * scale, weight: .semibold)
    let captionAttrs: [NSAttributedString.Key: Any] = [
        .font: captionFont,
        .foregroundColor: inkColor,
        .kern: 0.2 * scale
    ]
    let attrCaption = NSAttributedString(string: "Drag Beck to Applications", attributes: captionAttrs)
    let capSize = attrCaption.size()
    attrCaption.draw(at: NSPoint(
        x: (CGFloat(W) - capSize.width) / 2,
        y: CGFloat(H) - 70 * scale
    ))

    let arrowFont = NSFont.systemFont(ofSize: 60 * scale, weight: .regular)
    let arrowAttrs: [NSAttributedString.Key: Any] = [
        .font: arrowFont,
        .foregroundColor: accentColor
    ]
    let attrArrow = NSAttributedString(string: "\u{279C}", attributes: arrowAttrs)
    let arrSize = attrArrow.size()
    attrArrow.draw(at: NSPoint(
        x: (CGFloat(W) - arrSize.width) / 2,
        y: CGFloat(H) / 2 - arrSize.height / 2
    ))

    let hintFont = NSFont.systemFont(ofSize: 12 * scale, weight: .regular)
    let hintAttrs: [NSAttributedString.Key: Any] = [
        .font: hintFont,
        .foregroundColor: mutedColor
    ]
    let attrHint = NSAttributedString(string: "Drop the Beck icon onto the Applications folder", attributes: hintAttrs)
    let hintSize = attrHint.size()
    attrHint.draw(at: NSPoint(
        x: (CGFloat(W) - hintSize.width) / 2,
        y: 40 * scale
    ))

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("png encode failed\n", stderr); exit(1)
    }
    try png.write(to: url)
}

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: render <1x.png> <2x.png>\n", stderr); exit(2)
}
try render(scale: 1.0, to: URL(fileURLWithPath: args[1]))
try render(scale: 2.0, to: URL(fileURLWithPath: args[2]))
EOF

swift "$TMP_SWIFT" "$PNG_1X" "$PNG_2X"
tiffutil -cathidpicheck "$PNG_1X" "$PNG_2X" -out "$TARGET" >/dev/null
echo "[dmg-bg] wrote $TARGET"
