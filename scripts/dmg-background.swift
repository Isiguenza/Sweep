// Renders the DMG window background (660×400 pt) at 1x and 2x.
// Usage: swift scripts/dmg-background.swift <out-dir>
// Icon positions must match make-dmg.sh: app at (180,190), Applications at (480,190).
import AppKit

let size = NSSize(width: 660, height: 400)
let accent = NSColor(srgbRed: 0.08, green: 0.43, blue: 0.98, alpha: 1)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Soft vertical gradient.
    NSGradient(colors: [
        NSColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.93, blue: 0.99, alpha: 1),
    ])!.draw(in: NSRect(origin: .zero, size: size), angle: -90)

    // Finder's y axis is top-down; AppKit's is bottom-up. Icon centres sit at y=190 from the top.
    let iconY = size.height - 190

    // Dashed arrow between the two icons.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: iconY))
    arrow.line(to: NSPoint(x: 392, y: iconY))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.setLineDash([2, 10], count: 2, phase: 0)
    accent.withAlphaComponent(0.55).setStroke()
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: 384, y: iconY + 12))
    head.line(to: NSPoint(x: 400, y: iconY))
    head.line(to: NSPoint(x: 384, y: iconY - 12))
    head.lineWidth = 4
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
