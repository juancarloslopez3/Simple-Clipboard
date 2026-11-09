#!/usr/bin/env swift
//
//  Renders the Simple Clipboard disk-image background at @1x and @2x.
//  Usage: swift dmg-background.swift <out-1x.png> <out-2x.png>
//
//  The geometry constants below MUST stay in sync with make-dmg.sh, which
//  positions the Finder icons on top of this artwork.
//

import AppKit

// Finder window content size, in points — the area below the title bar.
let W: CGFloat = 660
let H: CGFloat = 400

// Finder's path bar is a global user preference we cannot switch off from a
// disk image, and it covers the bottom 28pt of the content area. Nothing
// meaningful may sit below this line.
let safeBottom: CGFloat = H - 28

// Icon centres, in Finder coordinates (origin top-left).
let appSlot = CGPoint(x: 172, y: 196)
let applicationsSlot = CGPoint(x: 488, y: 196)
let arrowMidY: CGFloat = 188

let title = "Simple Clipboard"
let subtitle = "Drag the app into your Applications folder"

// The app is ad-hoc signed, not notarized, so Gatekeeper blocks the first
// launch. Control-click → Open stopped overriding that in macOS Sequoia; the
// only route left is System Settings. Drop this line once the app is notarized.
let footer = "First launch is blocked by macOS — allow it in System Settings › Privacy & Security."

// AppKit draws from the bottom-left; Finder positions from the top-left.
func flip(_ y: CGFloat) -> CGFloat { H - y }

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let accent = srgb(0.18, 0.49, 0.96)      // matches AccentColor.colorset
let backdropTop = srgb(0.973, 0.976, 0.988)
let backdropBottom = srgb(0.914, 0.925, 0.953)
let titleColor = srgb(0.165, 0.184, 0.235)
let subtitleColor = srgb(0.420, 0.447, 0.502)
let footerColor = srgb(0.604, 0.627, 0.675)

func drawCentered(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, topY: CGFloat) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let text = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ])
    let height = ceil(text.size().height)
    text.draw(in: NSRect(x: 0, y: flip(topY) - height, width: W, height: height))
}

func drawArrow() {
    let y = flip(arrowMidY)
    let startX = appSlot.x + 104          // just clear of the 128pt app icon
    let endX = applicationsSlot.x - 104

    accent.withAlphaComponent(0.45).setStroke()

    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: startX, y: y))
    shaft.line(to: NSPoint(x: endX - 4, y: y))
    shaft.lineWidth = 3
    shaft.lineCapStyle = .round
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: endX - 14, y: y + 11))
    head.line(to: NSPoint(x: endX, y: y))
    head.line(to: NSPoint(x: endX - 14, y: y - 11))
    head.lineWidth = 3
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()
}

func drawTargetGlow() {
    guard let glow = NSGradient(colors: [
        accent.withAlphaComponent(0.14),
        accent.withAlphaComponent(0.0),
    ]) else { return }
    let centre = NSPoint(x: applicationsSlot.x, y: flip(applicationsSlot.y) + 6)
    glow.draw(fromCenter: centre, radius: 0, toCenter: centre, radius: 104, options: [])
}

func render(scale: CGFloat, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(W * scale),
        pixelsHigh: Int(H * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }

    rep.size = NSSize(width: W, height: H)   // gives the context a point-based CTM

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    NSGradient(starting: backdropTop, ending: backdropBottom)?
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
    drawTargetGlow()
    drawArrow()
    let footerTopY: CGFloat = 330
    precondition(footerTopY + 16 <= safeBottom, "footer would hide under Finder's path bar")

    drawCentered(title, size: 22, weight: .semibold, color: titleColor, topY: 40)
    drawCentered(subtitle, size: 12.5, weight: .regular, color: subtitleColor, topY: 74)
    drawCentered(footer, size: 11, weight: .regular, color: footerColor, topY: footerTopY)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: dmg-background.swift <out-1x.png> <out-2x.png>\n".data(using: .utf8)!)
    exit(2)
}

do {
    try render(scale: 1, to: URL(fileURLWithPath: arguments[1]))
    try render(scale: 2, to: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write("failed to render background: \(error)\n".data(using: .utf8)!)
    exit(1)
}
