// Renders SwiftUsage's brand into brand/: swift scripts/make-brand.swift [output folder]
// The name is set in Google Sans Flex at full roundness (github.com/googlefonts/googlesans-flex, SIL Open
// Font License), from brand/fonts. Its outlines are baked into the SVGs, so they look the same everywhere
// without it.
import AppKit
import CoreText

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "brand")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

struct Ink {
    let hex: UInt32
    init(_ hex: UInt32) { self.hex = hex }
    var svg: String { String(format: "#%06X", hex) }
    func cg(_ opacity: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: opacity)
    }
}

/// Black and white, with one gray for secondary text and one for hairlines.
struct Palette {
    let background, ink, secondary, border: Ink
    static let light = Palette(background: Ink(0xFFFFFF), ink: Ink(0x000000), secondary: Ink(0x737373), border: Ink(0xE5E5E5))
    static let dark = Palette(background: Ink(0x000000), ink: Ink(0xFFFFFF), secondary: Ink(0x8C8C8C), border: Ink(0x262626))
}

/// One filled or stroked shape, in SVG's top-down coordinates.
struct Shape {
    enum Geometry {
        case rect(CGRect, radius: CGFloat)
        case outline(CGPath)
    }
    var geometry: Geometry
    var ink: Ink
    var opacity: CGFloat = 1
    var lineWidth: CGFloat?
    var dash: CGFloat?

    var path: CGPath {
        switch geometry {
        case .rect(let rect, let radius): CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .outline(let path): path
        }
    }

    func offset(_ dx: CGFloat, _ dy: CGFloat) -> Shape {
        var moved = self
        switch geometry {
        case .rect(let rect, let radius):
            moved.geometry = .rect(rect.offsetBy(dx: dx, dy: dy), radius: radius)
        case .outline(let path):
            var shift = CGAffineTransform(translationX: dx, y: dy)
            moved.geometry = .outline(path.copy(using: &shift)!)
        }
        return moved
    }

    var svg: String {
        let paint = lineWidth.map { "fill=\"none\" stroke=\"\(ink.svg)\" stroke-width=\"\(number($0))\"" } ?? "fill=\"\(ink.svg)\""
        let alpha = (opacity < 1 ? " opacity=\"\(number(opacity))\"" : "") + (dash.map { " stroke-dasharray=\"\(number($0))\"" } ?? "")
        switch geometry {
        case .rect(let r, let radius):
            return "<rect x=\"\(number(r.minX))\" y=\"\(number(r.minY))\" width=\"\(number(r.width))\" height=\"\(number(r.height))\" rx=\"\(number(radius))\" \(paint)\(alpha)/>"
        case .outline(let path):
            return "<path d=\"\(pathData(path))\" \(paint)\(alpha)/>"
        }
    }
}

func number(_ value: CGFloat) -> String {
    let rounded = (value * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
}

func pathData(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { element in
        let p = element.pointee.points
        func pt(_ i: Int) -> String { "\(number(p[i].x)) \(number(p[i].y))" }
        switch element.pointee.type {
        case .moveToPoint: d += "M\(pt(0))"
        case .addLineToPoint: d += "L\(pt(0))"
        case .addQuadCurveToPoint: d += "Q\(pt(0)) \(pt(1))"
        case .addCurveToPoint: d += "C\(pt(0)) \(pt(1)) \(pt(2))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func bounds(_ shapes: [Shape]) -> CGRect {
    shapes.map { $0.path.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
}

// MARK: Type

let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../brand/fonts").standardized

/// Google Sans Flex from brand/fonts, its roundness fixed at 100 and its optical size following the size.
/// Weights: 400 Regular, 600 Semibold.
func googleSans(_ size: CGFloat, weight: CGFloat) -> CTFont {
    let file = fonts.appendingPathComponent("GoogleSansFlex-Rounded.woff2")
    guard let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor])?.first else {
        FileHandle.standardError.write(Data("Couldn't load \(file.path)\n".utf8))
        exit(1)
    }
    func axis(_ tag: String) -> Int { tag.unicodeScalars.reduce(0) { $0 << 8 | Int($1.value) } }
    let axes = [axis("wght"): weight, axis("opsz"): size]
    let variation = CTFontDescriptorCreateCopyWithAttributes(descriptor, [kCTFontVariationAttribute: axes] as CFDictionary)
    return CTFontCreateWithFontDescriptor(variation, size, nil)
}

/// Text as one outline, its baseline at y = 0 and its pen starting at x = 0.
func outline(_ string: String, _ font: CTFont) -> CGPath {
    let text = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                               NSAttributedString.Key(kCTLigatureAttributeName as String): 0])
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(CTLineCreateWithAttributedString(text)) as! [CTRun] {
        // A character the font lacks comes from a fallback font, in a run of its own.
        let font = (CTRunGetAttributes(run) as! [String: Any])[kCTFontAttributeName as String] as! CTFont
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &positions)
        for (glyph, position) in zip(glyphs, positions) {
            guard let shape = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
            // Font outlines go up from the baseline; SVG's y goes down.
            path.addPath(shape, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: position.x, ty: -position.y))
        }
    }
    return path
}

// MARK: Mark and logo

/// The mark: a tilde, the way the app says its numbers are estimates ("~$18.3K"). It's also an S on its
/// side. One stroke 24 wide with round caps, on a 120 grid where it fills the width and sits on the
/// middle; it turns about the center, so its two halves are the same shape.
func mark(size: CGFloat, ink: Ink) -> [Shape] {
    let line = CGMutablePath()
    line.move(to: CGPoint(x: 12, y: 74))
    line.addCurve(to: CGPoint(x: 60, y: 60), control1: CGPoint(x: 24, y: 36), control2: CGPoint(x: 52, y: 36))
    line.addCurve(to: CGPoint(x: 108, y: 46), control1: CGPoint(x: 68, y: 84), control2: CGPoint(x: 96, y: 84))
    var scale = CGAffineTransform(scaleX: size / 120, y: size / 120)
    let stroke = line.copy(using: &scale)!.copy(strokingWithWidth: 24 * size / 120, lineCap: .round, lineJoin: .round, miterLimit: 10)
    return [Shape(geometry: .outline(stroke.normalized()), ink: ink)]
}

/// The mark, then the name in Semibold at the font's own spacing. The mark is as wide as the name is tall
/// (from the dot of the i to the bottom of the g) and centered on the x-height, where a typeset ~ sits.
func logo(fontSize: CGFloat, ink: Ink) -> [Shape] {
    let font = googleSans(fontSize, weight: 600)
    let name = outline("SwiftUsage", font)
    let box = name.boundingBoxOfPath
    let width = box.height
    let gap = width * 0.3
    return mark(size: width, ink: ink).map { $0.offset(0, -CTFontGetXHeight(font) / 2 - width / 2) }
        + [Shape(geometry: .outline(name), ink: ink).offset(width + gap - box.minX, 0)]
}

/// Moves shapes so their bounds start at the origin.
func placed(_ shapes: [Shape], at origin: CGPoint = .zero) -> [Shape] {
    let box = bounds(shapes)
    return shapes.map { $0.offset(origin.x - box.minX, origin.y - box.minY) }
}

let tagline = "Coding agent usage, limits and costs, in your menu bar."

/// The logo over the tagline, centered on a card.
func banner(_ palette: Palette, size: CGSize, fontSize: CGFloat, taglineSize: CGFloat, card: Bool) -> [Shape] {
    let lockup = placed(logo(fontSize: fontSize, ink: palette.ink))
    let line = placed([Shape(geometry: .outline(outline(tagline, googleSans(taglineSize, weight: 400))), ink: palette.secondary)])
    let lockupSize = bounds(lockup).size, lineSize = bounds(line).size
    let gap = fontSize * 0.42
    let top = (size.height - lockupSize.height - gap - lineSize.height) / 2
    var shapes: [Shape] = []
    if card {
        let edge = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        shapes.append(Shape(geometry: .rect(edge, radius: 24), ink: palette.background))
        shapes.append(Shape(geometry: .rect(edge, radius: 24), ink: palette.border, lineWidth: 2))
    } else {
        shapes.append(Shape(geometry: .rect(CGRect(origin: .zero, size: size), radius: 0), ink: palette.background))
    }
    shapes += lockup.map { $0.offset((size.width - lockupSize.width) / 2, top) }
    shapes += line.map { $0.offset((size.width - lineSize.width) / 2, top + lockupSize.height + gap) }
    return shapes
}

// MARK: Brand kit sheets

func text(_ string: String, size: CGFloat, weight: CGFloat, ink: Ink, x: CGFloat, baseline: CGFloat, align: CGFloat = 0) -> Shape {
    let path = outline(string, googleSans(size, weight: weight))
    let box = path.boundingBoxOfPath
    return Shape(geometry: .outline(path), ink: ink).offset(align == 0 ? x : x - box.minX - box.width * align, baseline)
}

func card(_ palette: Palette, _ frame: CGRect) -> [Shape] {
    let edge = frame.insetBy(dx: 1, dy: 1)
    return [Shape(geometry: .rect(edge, radius: 24), ink: palette.background),
            Shape(geometry: .rect(edge, radius: 24), ink: palette.border, lineWidth: 2)]
}

func paletteSheet() -> [Shape] {
    let size = CGSize(width: 616, height: 392)
    return [(Palette.light, "Light"), (Palette.dark, "Dark")].enumerated().flatMap { index, entry in
        let (palette, title) = entry
        let x = CGFloat(index) * (size.width + 48)
        var shapes = card(palette, CGRect(origin: CGPoint(x: x, y: 0), size: size))
        shapes.append(text(title, size: 28, weight: 600, ink: palette.ink, x: x + 40, baseline: 64))
        let roles = [("Background", palette.background), ("Ink", palette.ink), ("Secondary text", palette.secondary), ("Hairline", palette.border)]
        for (row, (name, ink)) in roles.enumerated() {
            let swatch = CGRect(x: x + 40, y: 96 + CGFloat(row) * 68, width: 52, height: 52)
            shapes.append(Shape(geometry: .rect(swatch, radius: 13), ink: ink))
            shapes.append(Shape(geometry: .rect(swatch.insetBy(dx: 0.75, dy: 0.75), radius: 12.25), ink: palette.border, lineWidth: 1.5))
            shapes.append(text(name, size: 22, weight: 600, ink: palette.ink, x: x + 116, baseline: swatch.midY + 8))
            shapes.append(text(ink.svg, size: 22, weight: 400, ink: palette.secondary, x: x + size.width - 40, baseline: swatch.midY + 8, align: 1))
        }
        return shapes
    }
}

func typeSheet(_ palette: Palette) -> [Shape] {
    let size = CGSize(width: 1280, height: 480), right = size.width - 64
    return card(palette, CGRect(origin: .zero, size: size)) + [
        text("Semibold 600, for the name", size: 20, weight: 400, ink: palette.secondary, x: 64, baseline: 84),
        text("Google Sans Flex, roundness 100", size: 20, weight: 400, ink: palette.secondary, x: right, baseline: 84, align: 1),
        text("SwiftUsage", size: 120, weight: 600, ink: palette.ink, x: 60, baseline: 210),
        text("Regular 400, for everything else", size: 20, weight: 400, ink: palette.secondary, x: 64, baseline: 300),
        text(tagline, size: 40, weight: 400, ink: palette.ink, x: 62, baseline: 358),
        text("ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789", size: 28, weight: 400, ink: palette.secondary, x: 63, baseline: 420),
    ]
}

func clearSpaceSheet(_ palette: Palette) -> [Shape] {
    let size = CGSize(width: 1280, height: 400)
    let lockup = placed(logo(fontSize: 96, ink: palette.ink))
    let lockupSize = bounds(lockup).size
    // The logo's mark is as wide as the logo is tall; the clear space is its height.
    let unitMark = placed(mark(size: lockupSize.height, ink: palette.ink))
    let unit = bounds(unitMark).height
    let labelGap: CGFloat = 64
    let zoneTop = (size.height - lockupSize.height - unit * 2 - labelGap) / 2
    let origin = CGPoint(x: (size.width - lockupSize.width) / 2, y: zoneTop + unit)
    let zone = CGRect(origin: origin, size: lockupSize).insetBy(dx: -unit, dy: -unit)
    return card(palette, CGRect(origin: .zero, size: size)) + [
        Shape(geometry: .rect(zone, radius: 0), ink: palette.ink, opacity: 0.04),
        Shape(geometry: .rect(zone, radius: 0), ink: palette.secondary, lineWidth: 1.5, dash: 6),
    ] + unitMark.map { var faint = $0.offset(origin.x, zone.minY); faint.opacity = 0.18; return faint }
        + lockup.map { $0.offset(origin.x, origin.y) } + [
        text("Keep the height of the mark clear on every side.", size: 22, weight: 400, ink: palette.secondary,
             x: size.width / 2, baseline: zone.maxY + labelGap, align: 0.5),
    ]
}

// MARK: Output

func writeSVG(_ name: String, _ shapes: [Shape], size: CGSize? = nil) throws {
    let size = size ?? bounds(shapes).size
    let svg = ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(number(size.width))\" height=\"\(number(size.height))\" viewBox=\"0 0 \(number(size.width)) \(number(size.height))\" role=\"img\" aria-label=\"SwiftUsage\">",
               "<title>SwiftUsage</title>"] + shapes.map(\.svg) + ["</svg>", ""]
    try svg.joined(separator: "\n").write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

func writePNG(_ name: String, _ shapes: [Shape], size: CGSize, scale: CGFloat = 1) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.translateBy(x: 0, y: size.height * scale)
    context.scaleBy(x: scale, y: -scale)
    for shape in shapes {
        context.addPath(shape.path)
        if let lineWidth = shape.lineWidth {
            context.setStrokeColor(shape.ink.cg(shape.opacity))
            context.setLineWidth(lineWidth)
            context.strokePath()
        } else {
            context.setFillColor(shape.ink.cg(shape.opacity))
            context.fillPath()
        }
    }
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

// Square, so it fits avatars and favicons as is.
try writeSVG("mark.svg", mark(size: 120, ink: Palette.light.ink), size: CGSize(width: 120, height: 120))
try writeSVG("mark-white.svg", mark(size: 120, ink: Palette.dark.ink), size: CGSize(width: 120, height: 120))
try writeSVG("logo.svg", placed(logo(fontSize: 96, ink: Palette.light.ink)))
try writeSVG("logo-white.svg", placed(logo(fontSize: 96, ink: Palette.dark.ink)))

let bannerSize = CGSize(width: 1280, height: 400)
try writeSVG("banner-light.svg", banner(.light, size: bannerSize, fontSize: 88, taglineSize: 22, card: true), size: bannerSize)
try writeSVG("banner-dark.svg", banner(.dark, size: bannerSize, fontSize: 88, taglineSize: 22, card: true), size: bannerSize)

// GitHub's social preview size.
let socialSize = CGSize(width: 1280, height: 640)
try writePNG("social.png", banner(.dark, size: socialSize, fontSize: 112, taglineSize: 27, card: false), size: socialSize)

try writeSVG("palette.svg", paletteSheet(), size: CGSize(width: 1280, height: 392))
try writeSVG("type-light.svg", typeSheet(.light), size: CGSize(width: 1280, height: 480))
try writeSVG("type-dark.svg", typeSheet(.dark), size: CGSize(width: 1280, height: 480))
try writeSVG("clear-space-light.svg", clearSpaceSheet(.light), size: CGSize(width: 1280, height: 400))
try writeSVG("clear-space-dark.svg", clearSpaceSheet(.dark), size: CGSize(width: 1280, height: 400))
print("Wrote \(output.path)")
