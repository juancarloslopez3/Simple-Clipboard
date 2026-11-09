#!/usr/bin/env swift
//
//  Renders the Simple Clipboard disk-image background at @1x and @2x.
//  Usage: swift dmg-background.swift <out-1x.png> <out-2x.png> [version]
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
let appSlot = CGPoint(x: 172, y: 206)
let applicationsSlot = CGPoint(x: 488, y: 206)

// The card behind each icon also has to hold the label Finder draws under it
// (12pt text, starting a few points below the 128pt icon).
let cardSize = CGSize(width: 184, height: 184)
let cardTop: CGFloat = 114
let cardRadius: CGFloat = 32

let title = "Simple Clipboard"
let subtitle = "Drag the app onto the Applications folder to install it."

// The app is ad-hoc signed, not notarized, so Gatekeeper blocks the first
// launch. Control-click → Open stopped overriding that in macOS Sequoia; the
// only route left is System Settings. Drop the footer once the app is notarized.
let footerLead = "Blocked on first launch? Open "
let footerPath = "System Settings › Privacy & Security"
let footerMid = " and click "
let footerButton = "Open Anyway"

// AppKit draws from the bottom-left; Finder positions from the top-left.
func flip(_ y: CGFloat) -> CGFloat { H - y }

/// A rect given in Finder coordinates, converted to AppKit's.
func finderRect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: x, y: flip(top) - height, width: width, height: height)
}

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let accent = srgb(0.18, 0.49, 0.96)      // matches AccentColor.colorset
let violet = srgb(0.52, 0.40, 0.95)
let slate = srgb(0.165, 0.184, 0.235)    // the app icon's backdrop
let backdropTop = srgb(0.976, 0.980, 0.992)
let backdropBottom = srgb(0.906, 0.922, 0.957)
let subtitleColor = srgb(0.400, 0.427, 0.490)
let footerColor = srgb(0.455, 0.482, 0.541)

func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    NSFont.systemFont(ofSize: size, weight: weight)
}

func text(_ string: String, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: kern])
}

func drawCentered(_ string: NSAttributedString, topY: CGFloat, centreX: CGFloat = W / 2) {
    let size = string.size()
    string.draw(at: NSPoint(x: (centreX - size.width / 2).rounded(), y: flip(topY) - ceil(size.height)))
}

// ---------------------------------------------------------------- backdrop

func drawBackdrop() {
    NSGradient(starting: backdropTop, ending: backdropBottom)?
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Two soft washes of colour, so the window doesn't read as flat grey.
    func wash(_ color: NSColor, at centre: CGPoint, radius: CGFloat) {
        let point = NSPoint(x: centre.x, y: flip(centre.y))
        NSGradient(colors: [color, color.withAlphaComponent(0)])?
            .draw(fromCenter: point, radius: 0, toCenter: point, radius: radius, options: [])
    }
    wash(accent.withAlphaComponent(0.13), at: CGPoint(x: W - 40, y: -20), radius: 340)
    wash(violet.withAlphaComponent(0.08), at: CGPoint(x: 30, y: H + 10), radius: 320)

    // A faint dot grid for texture; the cards cover it where the icons sit.
    let spacing: CGFloat = 16
    slate.withAlphaComponent(0.07).setFill()
    var y = spacing / 2
    while y < H {
        var x = spacing / 2
        while x < W {
            NSBezierPath(ovalIn: NSRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)).fill()
            x += spacing
        }
        y += spacing
    }
}

// ---------------------------------------------------------------- header

func drawHeader(version: String?) {
    let titleText = text(title, font(26, .bold), slate, kern: -0.3)
    let titleSize = titleText.size()
    let titleTop: CGFloat = 30

    // The title is centred on its own, so the version pill goes below the
    // subtitle rather than beside the title, which would pull the title off-centre.
    drawCentered(titleText, topY: titleTop)
    let subtitleTop = titleTop + titleSize.height + 4
    drawSubtitle(below: titleTop + titleSize.height)

    guard let version, !version.isEmpty else { return }

    let badgeText = text(version, font(11, .semibold), accent)
    let badgeTextSize = badgeText.size()
    let badgeSize = CGSize(width: ceil(badgeTextSize.width) + 14, height: 20)
    let badgeTop = subtitleTop + 22
    let badgeRect = finderRect(
        x: ((W - badgeSize.width) / 2).rounded(),
        top: badgeTop,
        width: badgeSize.width,
        height: badgeSize.height
    )
    let badge = NSBezierPath(roundedRect: badgeRect, xRadius: badgeSize.height / 2, yRadius: badgeSize.height / 2)
    accent.withAlphaComponent(0.12).setFill()
    badge.fill()
    accent.withAlphaComponent(0.22).setStroke()
    badge.lineWidth = 1
    badge.stroke()
    badgeText.draw(at: NSPoint(
        x: badgeRect.midX - badgeTextSize.width / 2,
        y: badgeRect.midY - badgeTextSize.height / 2
    ))
}

func drawSubtitle(below y: CGFloat) {
    drawCentered(text(subtitle, font(13, .regular), subtitleColor), topY: y + 4)
}

// ---------------------------------------------------------------- icon cards

func cardRect(for slot: CGPoint) -> NSRect {
    finderRect(x: slot.x - cardSize.width / 2, top: cardTop, width: cardSize.width, height: cardSize.height)
}

func drawCard(at slot: CGPoint, isTarget: Bool) {
    let rect = cardRect(for: slot)
    let path = NSBezierPath(roundedRect: rect, xRadius: cardRadius, yRadius: cardRadius)

    // Soft drop shadow, then a frosted-glass fill.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = slate.withAlphaComponent(0.10)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    NSColor.white.withAlphaComponent(0.62).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    if isTarget {
        accent.withAlphaComponent(0.05).setFill()
        path.fill()
    }

    // A bright top edge fading out towards the bottom, like light on glass.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)])?
        .draw(in: NSRect(x: rect.minX, y: rect.maxY - 60, width: rect.width, height: 60), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    if isTarget {
        // The drop target gets a dashed outline: "put it here".
        let inset = NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: cardRadius - 6, yRadius: cardRadius - 6)
        inset.lineWidth = 1.5
        inset.setLineDash([6, 5], count: 2, phase: 0)
        inset.lineCapStyle = .round
        accent.withAlphaComponent(0.40).setStroke()
        inset.stroke()
    }

    path.lineWidth = 1
    (isTarget ? accent.withAlphaComponent(0.16) : slate.withAlphaComponent(0.08)).setStroke()
    path.stroke()
}

// Three chevrons that brighten towards the Applications folder.
func drawChevrons() {
    let gapStart = cardRect(for: appSlot).maxX
    let gapEnd = cardRect(for: applicationsSlot).minX
    let centreX = (gapStart + gapEnd) / 2
    let y = flip(appSlot.y)
    let width: CGFloat = 10
    let halfHeight: CGFloat = 11
    let spacing: CGFloat = 17
    let alphas: [CGFloat] = [0.28, 0.55, 0.92]

    for (index, alpha) in alphas.enumerated() {
        let tipX = centreX + CGFloat(index - 1) * spacing + width / 2
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: tipX - width, y: y + halfHeight))
        chevron.line(to: NSPoint(x: tipX, y: y))
        chevron.line(to: NSPoint(x: tipX - width, y: y - halfHeight))
        chevron.lineWidth = 3.5
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        accent.withAlphaComponent(alpha).setStroke()
        chevron.stroke()
    }
}

// ---------------------------------------------------------------- footer

/// Returns the footer's bottom edge in Finder coordinates.
func drawFooter() -> CGFloat {
    let body = font(11, .regular)
    let emphasis = font(11, .semibold)
    let line = NSMutableAttributedString()
    line.append(text(footerLead, body, footerColor))
    line.append(text(footerPath, emphasis, slate.withAlphaComponent(0.85)))
    line.append(text(footerMid, body, footerColor))
    line.append(text(footerButton, emphasis, slate.withAlphaComponent(0.85)))
    line.append(text(".", body, footerColor))
    let lineSize = line.size()

    let symbolSide: CGFloat = 13
    let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: symbolSide, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [accent]))
        )
    let symbolGap: CGFloat = symbol == nil ? 0 : 7
    let symbolWidth: CGFloat = symbol.map { $0.size.width * symbolSide / max($0.size.height, 1) } ?? 0

    let height: CGFloat = 28
    let width = ceil(symbolWidth + symbolGap + lineSize.width) + 30
    let top: CGFloat = 322
    let capsule = finderRect(x: ((W - width) / 2).rounded(), top: top, width: width, height: height)

    let path = NSBezierPath(roundedRect: capsule, xRadius: height / 2, yRadius: height / 2)
    NSColor.white.withAlphaComponent(0.58).setFill()
    path.fill()
    slate.withAlphaComponent(0.08).setStroke()
    path.lineWidth = 1
    path.stroke()

    var x = capsule.minX + 15
    if let symbol {
        symbol.draw(in: NSRect(x: x, y: capsule.midY - symbolSide / 2, width: symbolWidth, height: symbolSide))
        x += symbolWidth + symbolGap
    }
    line.draw(at: NSPoint(x: x, y: capsule.midY - lineSize.height / 2))

    return top + height
}

// ---------------------------------------------------------------- render

func render(scale: CGFloat, version: String?, to url: URL) throws {
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

    drawBackdrop()
    drawHeader(version: version)
    drawCard(at: appSlot, isTarget: false)
    drawCard(at: applicationsSlot, isTarget: true)
    drawChevrons()
    let footerBottom = drawFooter()
    precondition(footerBottom <= safeBottom, "footer would hide under Finder's path bar")

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 4 else {
    FileHandle.standardError.write("usage: dmg-background.swift <out-1x.png> <out-2x.png> [version]\n".data(using: .utf8)!)
    exit(2)
}
let version = arguments.count == 4 ? arguments[3] : nil

do {
    try render(scale: 1, version: version, to: URL(fileURLWithPath: arguments[1]))
    try render(scale: 2, version: version, to: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write("failed to render background: \(error)\n".data(using: .utf8)!)
    exit(1)
}
