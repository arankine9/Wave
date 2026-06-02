#!/bin/bash
# Render Resources/dmg-background.png — the branded backdrop for the Wave
# installer window (the "drag the app to Applications" screen). The colours,
# the waveform mark, and the Hokusai-wave motif mirror the marketing site.
#
# This is an *authoring* tool. It always regenerates the PNG, so when you tweak
# the design here, re-run it and commit the result:
#
#     bash scripts/make-dmg-background.sh
#     git add Resources/dmg-background.png
#
# scripts/release.sh uses the committed PNG as-is (it only invokes this script
# if the file is missing), so the DMG that ships is exactly the one you eyeball
# here — no surprises from differing fonts on a CI runner.
#
# Two non-obvious constraints, both learned by mounting real DMGs:
#   * LIGHT background. Finder draws the icon labels ("Wave", "Applications")
#     in dark text regardless of the background, so a dark canvas makes them
#     unreadable. A light canvas keeps them crisp and lets the navy app icon pop.
#   * SINGLE 660x440 PNG, not a multi-resolution (retina) TIFF. Finder sizes a
#     DMG background from its *largest pixel* representation and ignores the
#     hidpi/DPI tagging, so a 2x TIFF gets rendered at 2x and the layout breaks.
#     A plain 660x440 PNG renders at the right size (and is fine on Retina).
# The 660x440 canvas and the icon coordinates must stay in lock-step with
# scripts/dmg-settings.py, which drops the icons either side of the arrow.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
TARGET="$RES/dmg-background.png"

mkdir -p "$RES"

echo "[dmg-bg] rendering $TARGET"
TMP_DIR="$(mktemp -d -t wavedmgbg)"
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_SWIFT="$TMP_DIR/render.swift"

cat > "$TMP_SWIFT" <<'EOF'
import AppKit

// LIGHT installer backdrop, on-brand with the site (site/index.html):
//   ink #15273b  ink-dim #5f7793  navy(mark) #13294a  sand(accent) #ca842f
//   foam-whites + sky-blues for the wave motif.

func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let top   = col(244, 249, 253)   // near-white, cool
let bottom = col(214, 230, 243)  // soft sky
let ink   = col(21, 39, 59)
let inkDim = col(95, 119, 147)
let navy  = col(19, 41, 74)       // app-icon navy for the mark
let sand  = col(202, 132, 47)     // deepened Hokusai sand — the accent/arrow
let wave1 = col(168, 201, 230)
let wave2 = col(126, 174, 217)
let foam  = col(255, 255, 255)

func serif(_ size: CGFloat) -> NSFont {
    for name in ["Hoefler Text", "Didot", "Baskerville", "Georgia"] {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return NSFont.systemFont(ofSize: size, weight: .medium)
}

func render(to url: URL) throws {
    let W = 660.0, H = 440.0
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
    ) else { fputs("rep alloc failed\n", stderr); exit(1) }
    rep.size = NSSize(width: W, height: H)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    let rect = NSRect(x: 0, y: 0, width: W, height: H)

    // vertical wash + a faint warm glow up-top (the Hokusai sky)
    NSGradient(colors: [top, bottom])!.draw(in: rect, angle: -90)
    NSGradient(colors: [col(246, 228, 200, 0.45), col(246, 228, 200, 0)])!
        .draw(in: rect, relativeCenterPosition: NSPoint(x: 0.55, y: 0.7))

    // layered Hokusai-style waves along the bottom edge
    func waveBand(baseY: CGFloat, amp: CGFloat, wavelength: CGFloat, phase: CGFloat, color: NSColor) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: 0)); p.line(to: NSPoint(x: 0, y: baseY))
        var x = 0.0
        while x <= W { p.line(to: NSPoint(x: x, y: baseY + amp * sin(x/wavelength * 2 * .pi + phase))); x += 2 }
        p.line(to: NSPoint(x: W, y: 0)); p.close()
        color.setFill(); p.fill()
    }
    waveBand(baseY: 62, amp: 16, wavelength: 360, phase: 0.4, color: wave1.withAlphaComponent(0.55))
    waveBand(baseY: 44, amp: 13, wavelength: 300, phase: 2.4, color: wave2.withAlphaComponent(0.50))
    waveBand(baseY: 26, amp:  9, wavelength: 250, phase: 4.2, color: foam.withAlphaComponent(0.55))

    // top lockup: navy waveform mark + serif "Install Wave"
    func drawMark(centerX: CGFloat, centerY: CGFloat) {
        let bars: [CGFloat] = [0.30, 0.70, 1.0, 0.50, 0.80]
        let barW = 2.4, gap = 4.5, maxH = 20.0
        let total = CGFloat(bars.count) * barW + CGFloat(bars.count - 1) * gap
        var x = centerX - total/2
        navy.setFill()
        for h in bars {
            let r = NSRect(x: x, y: centerY - maxH*h/2, width: barW, height: maxH*h)
            NSBezierPath(roundedRect: r, xRadius: barW/2, yRadius: barW/2).fill()
            x += barW + gap
        }
    }
    let tStr = NSAttributedString(string: "Install Wave",
        attributes: [.font: serif(30), .foregroundColor: ink])
    let tSize = tStr.size()
    let titleY = H - 66, markW = 30.0, markGap = 13.0
    let lockupStartX = (W - (markW + markGap + tSize.width))/2
    drawMark(centerX: lockupStartX + markW/2, centerY: titleY + tSize.height*0.42)
    tStr.draw(at: NSPoint(x: lockupStartX + markW + markGap, y: titleY))

    sand.setFill()
    NSBezierPath(rect: NSRect(x: (W - 26)/2, y: titleY - 14, width: 26, height: 1.5)).fill()

    let sStr = NSAttributedString(string: "Drag the app into your Applications folder",
        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: inkDim])
    sStr.draw(at: NSPoint(x: (W - sStr.size().width)/2, y: titleY - 38))

    // gentle sand arrow from the app toward Applications (ay = 440 - 220).
    // The curve arrives HORIZONTAL (c2 sits on the baseline) so the head points
    // straight right. Crucially the shaft STOPS at the arrowhead's base, not at
    // the tip — otherwise the rounded line end pokes a stub past the point.
    let ay = 220.0
    let tip = NSPoint(x: 398, y: ay)
    let barbLen = 16.0, spread = 0.44
    let baseInset = barbLen * cos(spread)            // tip -> base distance along the axis
    let shaftEnd = NSPoint(x: tip.x - baseInset + 1, y: ay)  // end just inside the head
    let p0 = NSPoint(x: 270, y: ay)
    let c1 = NSPoint(x: 314, y: ay + 16), c2 = NSPoint(x: 358, y: ay)
    sand.setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: p0)
    shaft.curve(to: shaftEnd, controlPoint1: c1, controlPoint2: c2)
    shaft.lineWidth = 3.2; shaft.lineCapStyle = .round; shaft.stroke()
    // filled triangular head, tip at `tip`, barbs splayed about the horizontal axis
    func barb(_ d: Double) -> NSPoint {
        NSPoint(x: tip.x + barbLen * cos(.pi + d), y: tip.y + barbLen * sin(.pi + d))
    }
    let head = NSBezierPath()
    head.move(to: tip); head.line(to: barb(spread)); head.line(to: barb(-spread)); head.close()
    head.lineJoinStyle = .round
    sand.setFill(); head.fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("png encode failed\n", stderr); exit(1)
    }
    try png.write(to: url)
}

let args = CommandLine.arguments
guard args.count == 2 else { fputs("usage: render <out.png>\n", stderr); exit(2) }
try render(to: URL(fileURLWithPath: args[1]))
EOF

swift "$TMP_SWIFT" "$TARGET"
echo "[dmg-bg] wrote $TARGET"
