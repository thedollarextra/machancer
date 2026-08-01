import AppKit

// Regenerates the app icon from the same SF Symbol the menu bar item uses, so the two
// can't drift apart. See Tools/README.md for the invocation.

let SYMBOL = "cursorarrow.click"
let TOP    = NSColor(calibratedRed: 0.42, green: 0.87, blue: 0.72, alpha: 1)
let BOTTOM = NSColor(calibratedRed: 0.20, green: 0.68, blue: 0.56, alpha: 1)

func render(_ px: Int) -> NSBitmapImageRep {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon proportions: ~10% margin, ~22.5% corner radius.
    let inset = size * 0.10
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tile = NSBezierPath(roundedRect: rect,
                            xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: TOP, ending: BOTTOM)!.draw(in: tile, angle: -90)

    let glyphBox = rect.insetBy(dx: rect.width * 0.24, dy: rect.height * 0.24)

    // Tint via palette configuration, not a sourceAtop fill: the tile already occupies
    // these pixels, so compositing white "on top of what is there" floods the whole box
    // instead of just the glyph.
    let config = NSImage.SymbolConfiguration(pointSize: glyphBox.height, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

    if let symbol = NSImage(systemSymbolName: SYMBOL, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        let scale = min(glyphBox.width / s.width, glyphBox.height / s.height)
        let drawn = NSSize(width: s.width * scale, height: s.height * scale)
        let target = NSRect(x: rect.midX - drawn.width / 2,
                            y: rect.midY - drawn.height / 2,
                            width: drawn.width, height: drawn.height)

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.010)
        shadow.shadowBlurRadius = size * 0.028
        shadow.set()
        symbol.draw(in: target)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard CommandLine.arguments.count > 1 else {
    print("usage: icongen <output.iconset directory>")
    exit(1)
}
let out = CommandLine.arguments[1]
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let data = render(px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote iconset to \(out)")
