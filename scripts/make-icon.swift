// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024

    // Body on Apple's 1024 grid: 824pt square, 100pt margin.
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186 * scale, yRadius: 186 * scale)
    NSGradient(starting: color(0x1C1C1C), ending: color(0x050505))!.draw(in: shape, angle: -90)
    color(0xFFFFFF).withAlphaComponent(0.08).setStroke()
    shape.lineWidth = max(1, 3 * scale)
    shape.stroke()

    // The mark (see scripts/make-brand.swift): a tilde, one round-capped stroke on a 120 grid, here 520pt
    // wide and turned about the body's center. The grid's y goes down, AppKit's up.
    let unit = 520 / 120 * scale
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: body.midX + (x - 60) * unit, y: body.midY - (y - 60) * unit) }
    let tilde = NSBezierPath()
    tilde.move(to: point(12, 74))
    tilde.curve(to: point(60, 60), controlPoint1: point(24, 36), controlPoint2: point(52, 36))
    tilde.curve(to: point(108, 46), controlPoint1: point(68, 84), controlPoint2: point(96, 84))
    tilde.lineWidth = 24 * unit
    tilde.lineCapStyle = .round
    color(0xFFFFFF).setStroke()
    tilde.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
