// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// The mark (see scripts/make-brand.swift): a 3×3 grid whose filled cells rise like a bar chart, rows from the top.
let rising = [[false, false, true], [false, true, true], [true, true, true]]

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

    // The mark's 120 grid (32 cells, 12 gaps) at 432pt, centered.
    let unit = 432 / 120 * scale
    let origin = NSPoint(x: body.midX - 60 * unit, y: body.midY + 60 * unit)
    for (row, cells) in rising.enumerated() {
        for (column, filled) in cells.enumerated() {
            let rect = NSRect(x: origin.x + CGFloat(column) * 44 * unit, y: origin.y - CGFloat(row) * 44 * unit - 32 * unit,
                              width: 32 * unit, height: 32 * unit)
            color(0xFFFFFF).withAlphaComponent(filled ? 1 : 0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6.4 * unit, yRadius: 6.4 * unit).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
