import AppKit
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct V3 {
    var x, y, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: V3, k: Double) -> V3 { V3(a.x * k, a.y * k, a.z * k) }
    static func * (a: V3, b: V3) -> V3 { V3(a.x * b.x, a.y * b.y, a.z * b.z) }
    func dot(_ b: V3) -> Double { x * b.x + y * b.y + z * b.z }
    var normalized: V3 { let l = (x * x + y * y + z * z).squareRoot(); return V3(x / l, y / l, z / l) }
}

@inline(__always) func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(max(v, lo), hi) }
@inline(__always) func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inline(__always) func mix(_ a: V3, _ b: V3, _ t: Double) -> V3 { a + (b - a) * t }
@inline(__always) func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clamp((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t)
}

func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 0xff) / 255, green: CGFloat((h >> 8) & 0xff) / 255,
            blue: CGFloat(h & 0xff) / 255, alpha: a)
}
func hexV(_ h: UInt32) -> V3 {
    V3(Double((h >> 16) & 0xff) / 255, Double((h >> 8) & 0xff) / 255, Double(h & 0xff) / 255)
}

@inline(__always) func hash2(_ x: Int, _ y: Int) -> Double {
    var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Double(h & 0xffffff) / Double(0xffffff)
}
func vnoise(_ x: Double, _ y: Double) -> Double {
    let xi = Int(floor(x)), yi = Int(floor(y))
    let xf = x - floor(x), yf = y - floor(y)
    let u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf)
    let a = hash2(xi, yi), b = hash2(xi + 1, yi), c = hash2(xi, yi + 1), d = hash2(xi + 1, yi + 1)
    return mix(mix(a, b, u), mix(c, d, u), v)
}
func fbm(_ x: Double, _ y: Double, octaves: Int = 4) -> Double {
    var sum = 0.0, amp = 0.5, f = 1.0, norm = 0.0
    for _ in 0..<octaves { sum += vnoise(x * f, y * f) * amp; norm += amp; amp *= 0.5; f *= 2.03 }
    return sum / norm
}

enum Detail: Int { case full = 0, small = 1, tiny = 2 }

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

final class Bitmap {
    let w: Int, h: Int
    let ctx: CGContext
    let px: UnsafeMutablePointer<UInt8>
    /// The number of pixels per scene unit.
    let s: Double

    init(_ size: Int) {
        w = size; h = size
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        s = Double(size) / 1024
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(s), y: CGFloat(-s))
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
    }

    /// Writes a straight-alpha color, premultiplying it.
    @inline(__always) func put(_ i: Int, _ j: Int, _ c: V3, _ a: Double) {
        let o = (j * w + i) * 4
        let aa = clamp(a)
        px[o] = UInt8(clamp(c.x) * aa * 255 + 0.5)
        px[o + 1] = UInt8(clamp(c.y) * aa * 255 + 0.5)
        px[o + 2] = UInt8(clamp(c.z) * aa * 255 + 0.5)
        px[o + 3] = UInt8(aa * 255 + 0.5)
    }

    /// Samples bilinearly at a point in device pixels.
    ///
    /// - Returns: Premultiplied RGBA components in 0...1.
    @inline(__always) func sample(_ x: Double, _ y: Double) -> (Double, Double, Double, Double) {
        let fx = clamp(x - 0.5, 0, Double(w - 1)), fy = clamp(y - 0.5, 0, Double(h - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        var out = [0.0, 0.0, 0.0, 0.0]
        for k in 0..<4 {
            let a = Double(px[(y0 * w + x0) * 4 + k]), b = Double(px[(y0 * w + x1) * 4 + k])
            let c = Double(px[(y1 * w + x0) * 4 + k]), d = Double(px[(y1 * w + x1) * 4 + k])
            out[k] = mix(mix(a, b, tx), mix(c, d, tx), ty) / 255
        }
        return (out[0], out[1], out[2], out[3])
    }

    func image() -> CGImage { ctx.makeImage()! }

    /// Draws another bitmap of the same size over this one, in device space.
    func composite(_ other: Bitmap, alpha: CGFloat = 1, blend: CGBlendMode = .normal) {
        ctx.saveGState()
        ctx.concatenate(ctx.ctm.inverted())
        ctx.setAlpha(alpha)
        ctx.setBlendMode(blend)
        ctx.draw(other.image(), in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    /// Calls `body` for each device pixel whose center falls inside a scene-space rect.
    ///
    /// - Parameter body: Receives the pixel's device coordinates, then its center in scene units.
    func forEachPixel(in r: CGRect, _ body: (Int, Int, Double, Double) -> Void) {
        let i0 = max(0, Int(floor(Double(r.minX) * s))), i1 = min(w - 1, Int(ceil(Double(r.maxX) * s)))
        let j0 = max(0, Int(floor(Double(r.minY) * s))), j1 = min(h - 1, Int(ceil(Double(r.maxY) * s)))
        if i0 > i1 || j0 > j1 { return }
        for j in j0...j1 {
            for i in i0...i1 {
                body(i, j, (Double(i) + 0.5) / s, (Double(j) + 0.5) / s)
            }
        }
    }
}

/// Fills `draw`'s shapes as a blurred shadow only.
///
/// The shapes themselves are drawn far outside the canvas. The offset and blur are in scene
/// units.
func shadowOnly(_ b: Bitmap, offset: CGPoint, blur: CGFloat, color: CGColor, _ draw: (CGContext) -> Void) {
    let ctx = b.ctx, m = ctx.ctm
    let far: CGFloat = 3000
    ctx.saveGState()
    let v = CGPoint(x: offset.x - far, y: offset.y)
    ctx.setShadow(offset: CGSize(width: m.a * v.x + m.c * v.y, height: m.b * v.x + m.d * v.y),
                  blur: blur * (m.a * m.a + m.b * m.b).squareRoot(), color: color)
    ctx.translateBy(x: far, y: 0)
    draw(ctx)
    ctx.restoreGState()
}

let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath: CGPath = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: bodyRect).cgPath

struct Geometry {
    var detail: Detail
    var c = CGPoint(x: 404, y: 404)
    var ri: Double = 164
    var ro: Double = 212
    var angle: Double = .pi / 4
    var mag: Double = 2.05
    var barrel: Double = 0.30
    var paperSize = CGSize(width: 470, height: 610)
    var paperAngle: Double = -5.5 * .pi / 180
    var paperCenter = CGPoint(x: 516, y: 528)
    var fontSize: CGFloat = 14
    var lineHeight: CGFloat = 24
    var headerHeight: CGFloat = 46

    init(_ d: Detail) {
        detail = d
        switch d {
        case .full: break
        case .small:
            c = CGPoint(x: 400, y: 400)
            ri = 160; ro = 224; mag = 1.6; barrel = 0.2
            lineHeight = 52; headerHeight = 70
            metalTint = V3(0.80, 0.82, 0.86)
        case .tiny:
            c = CGPoint(x: 416, y: 416)
            ri = 220; ro = 288; mag = 1.4; barrel = 0.05
            lineHeight = 180; headerHeight = 96
            paperAngle = 0
            metalTint = V3(0.9, 0.92, 0.95)
        }
    }

    var metalTint = V3(0.96, 0.97, 1.0)

    /// The point of the page that sits under the lens center, in page coordinates.
    var focus: CGPoint { c.applying(paperTransform.inverted()) }

    var axis: CGPoint { CGPoint(x: cos(angle), y: sin(angle)) }
    func along(_ d: Double) -> CGPoint { CGPoint(x: c.x + axis.x * d, y: c.y + axis.y * d) }

    var paperTransform: CGAffineTransform {
        CGAffineTransform(translationX: paperCenter.x, y: paperCenter.y)
            .rotated(by: paperAngle)
            .translatedBy(x: -paperSize.width / 2, y: -paperSize.height / 2)
    }

    var neck: (Double, Double, Double) {
        switch detail {
        case .full: (ro - 8, ro + 26, 17)
        case .small: (ro - 8, ro + 26, 26)
        case .tiny: (ro - 8, ro + 20, 34)
        }
    }
    var ferrule: (Double, Double, Double) {
        switch detail {
        case .full: (ro + 24, ro + 86, 35)
        case .small: (ro + 24, ro + 86, 44)
        case .tiny: (ro + 16, ro + 64, 54)
        }
    }
    var grip: (Double, Double, Double, Double) {
        switch detail {
        case .full: (ro + 84, ro + 318, 37, 44)
        case .small: (ro + 84, ro + 300, 46, 52)
        case .tiny: (ro + 60, 590, 58, 62)
        }
    }
}

enum LineKind { case header, hunk, context, deletion, addition }

struct DiffLine {
    var kind: LineKind
    var old: Int?
    var new: Int?
    var text: String
    /// The character ranges with a word-level highlight.
    var marks: [Range<Int>] = []
}

let diff: [DiffLine] = [
    DiffLine(kind: .hunk, text: "@@ -18,9 +18,11 @@ final class ReviewSession {"),
    DiffLine(kind: .context, old: 18, new: 18, text: "  private(set) var reviewed: Set<String>"),
    DiffLine(kind: .context, old: 19, new: 19, text: ""),
    DiffLine(kind: .deletion, old: 20, text: "  func markReviewed(_ path: String) {", marks: [19..<31]),
    DiffLine(kind: .deletion, old: 21, text: "    reviewed.insert(path)", marks: [20..<24]),
    DiffLine(kind: .addition, new: 20, text: "  func markReviewed(_ file: FileDiff) {", marks: [19..<33]),
    DiffLine(kind: .addition, new: 21, text: "    reviewed.insert(file.path)", marks: [20..<29]),
    DiffLine(kind: .addition, new: 22, text: "    store.save(reviewed)", marks: [4..<24]),
    DiffLine(kind: .context, old: 22, new: 23, text: "  }"),
    DiffLine(kind: .context, old: 23, new: 24, text: ""),
    DiffLine(kind: .context, old: 24, new: 25, text: "  func isReviewed(_ file: FileDiff) -> Bool {"),
    DiffLine(kind: .context, old: 25, new: 26, text: "    reviewed.contains(file.path)"),
    DiffLine(kind: .context, old: 26, new: 27, text: "  }"),
    DiffLine(kind: .hunk, text: "@@ -41,6 +43,8 @@ extension ReviewSession {"),
    DiffLine(kind: .context, old: 41, new: 43, text: "  var progress: Double {"),
    DiffLine(kind: .deletion, old: 42, text: "    0", marks: [4..<5]),
    DiffLine(kind: .addition, new: 44, text: "    guard !files.isEmpty else { return 1 }", marks: [4..<42]),
    DiffLine(kind: .addition, new: 45, text: "    return Double(reviewed.count) / Double(files.count)", marks: [4..<51]),
    DiffLine(kind: .context, old: 43, new: 46, text: "  }"),
    DiffLine(kind: .context, old: 44, new: 47, text: "}"),
]

let smallRows: [(LineKind, Int, Int)] = [
    (.context, 1, 14), (.deletion, 1, 16), (.addition, 1, 18), (.addition, 2, 12),
    (.context, 1, 3), (.context, 0, 0), (.context, 1, 17), (.context, 2, 13), (.context, 1, 3),
]
let tinyRows: [(LineKind, Int, Int)] = [
    (.deletion, 1, 0), (.addition, 1, 0), (.context, 1, 9), (.context, 1, 14), (.context, 1, 10), (.context, 1, 12),
]

let keywords: Set<String> = ["final", "class", "private", "set", "var", "func", "let", "guard", "else", "return",
                             "extension", "struct", "self"]

struct Palette {
    static let text = hex(0x1f2328)
    static let muted = hex(0x59636e)
    static let keyword = hex(0x8250df)
    static let type = hex(0x0550ae)
    static let fn = hex(0x6639ba)
    static let delBg = hex(0xffebe9)
    static let delMark = hex(0xffcecb)
    static let delNum = hex(0xffd7d5)
    static let addBg = hex(0xdafbe1)
    static let addMark = hex(0xaceebb)
    static let addNum = hex(0xccffd8)
    static let delFg = hex(0xd1242f)
    static let addFg = hex(0x1a7f37)
    static let hunkBg = hex(0xddf4ff)
    static let border = hex(0xd0d7de)
    static let headerBg = hex(0xf6f8fa)
    static let accent = hex(0x0969da)
}

func monoFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CTFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight) as CTFont
}

func drawText(_ ctx: CGContext, _ str: NSAttributedString, at p: CGPoint) {
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = p
    CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
    ctx.restoreGState()
}

func highlightCode(_ s: String, font: CTFont) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let chars = Array(s)
    var i = 0
    func add(_ t: String, _ color: CGColor) {
        out.append(NSAttributedString(string: t, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    }
    while i < chars.count {
        let ch = chars[i]
        if ch.isLetter || ch == "_" {
            var j = i
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
            let word = String(chars[i..<j])
            let next = j < chars.count ? chars[j] : " "
            let color: CGColor
            if keywords.contains(word) { color = Palette.keyword }
            else if word.first!.isUppercase { color = Palette.type }
            else if next == "(" { color = Palette.fn }
            else { color = Palette.text }
            add(word, color)
            i = j
        } else if ch.isNumber {
            add(String(ch), Palette.type); i += 1
        } else {
            add(String(ch), Palette.text); i += 1
        }
    }
    return out
}

func paperPath(_ g: Geometry) -> CGPath {
    var t = g.paperTransform
    return CGPath(rect: CGRect(origin: .zero, size: g.paperSize), transform: &t)
}

/// Draws the paper (without its shadow) in scene space.
func drawPaper(_ ctx: CGContext, _ g: Geometry) {
    ctx.saveGState()
    ctx.concatenate(g.paperTransform)
    let W = g.paperSize.width, H = g.paperSize.height
    let full = g.detail == .full
    ctx.addRect(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.clip()

    let grad = CGGradient(colorsSpace: sRGB, colors: [hex(0xffffff), hex(0xf7f6f1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W * 0.3, y: H),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let hh = g.headerHeight
    ctx.setFillColor(Palette.headerBg)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: hh))
    ctx.setFillColor(Palette.border)
    ctx.fill(CGRect(x: 0, y: hh - (full ? 1.5 : 4), width: W, height: full ? 1.5 : 4))

    let lh = g.lineHeight
    let numW: CGFloat = full ? 34 : 0
    let gutter: CGFloat = full ? numW * 2 : 26
    let codeX: CGFloat = full ? gutter + 26 : gutter + 30

    let box: CGFloat = full ? 18 : (g.detail == .small ? 34 : 44)
    let boxRect = CGRect(x: W - (full ? 92 : 24) - box, y: (hh - box) / 2, width: box, height: box)
    ctx.addPath(CGPath(roundedRect: boxRect, cornerWidth: box * 0.24, cornerHeight: box * 0.24, transform: nil))
    ctx.setFillColor(Palette.accent)
    ctx.fillPath()
    ctx.setStrokeColor(hex(0xffffff))
    ctx.setLineWidth(box * 0.15)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: boxRect.minX + box * 0.25, y: boxRect.minY + box * 0.53))
    ctx.addLine(to: CGPoint(x: boxRect.minX + box * 0.43, y: boxRect.minY + box * 0.71))
    ctx.addLine(to: CGPoint(x: boxRect.minX + box * 0.76, y: boxRect.minY + box * 0.31))
    ctx.strokePath()

    if full {
        let f = monoFont(12.5, .semibold)
        let name = NSAttributedString(string: "Sources/Revue/Session.swift", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.text,
        ])
        ctx.setStrokeColor(Palette.muted); ctx.setLineWidth(1.6)
        ctx.move(to: CGPoint(x: 13, y: 19)); ctx.addLine(to: CGPoint(x: 17, y: 23)); ctx.addLine(to: CGPoint(x: 21, y: 19))
        ctx.strokePath()
        drawText(ctx, name, at: CGPoint(x: 30, y: 28))
        let sf = monoFont(11.5, .semibold)
        let plus = NSAttributedString(string: "+5", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): sf,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.addFg])
        let minus = NSAttributedString(string: "−3", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): sf,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.delFg])
        drawText(ctx, plus, at: CGPoint(x: 246, y: 28))
        drawText(ctx, minus, at: CGPoint(x: 266, y: 28))
        let blocks: [CGColor] = [hex(0x1f883d), hex(0x1f883d), hex(0x1f883d), hex(0xcf222e), hex(0xcf222e)]
        for (k, col) in blocks.enumerated() {
            ctx.setFillColor(col)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 290 + CGFloat(k) * 10, y: 19, width: 8, height: 8),
                               cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
        }
        let viewed = NSAttributedString(string: "Viewed", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): NSFont.systemFont(ofSize: 12.5, weight: .medium) as CTFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.text])
        drawText(ctx, viewed, at: CGPoint(x: boxRect.maxX + 7, y: 28))
    } else {
        ctx.setFillColor(hex(0x8c959f))
        let bh = hh * 0.26
        ctx.addPath(CGPath(roundedRect: CGRect(x: 26, y: (hh - bh) / 2, width: W * 0.5, height: bh),
                           cornerWidth: bh / 2, cornerHeight: bh / 2, transform: nil))
        ctx.fillPath()
    }

    var y = hh
    if full {
        let font = monoFont(g.fontSize)
        let cw = CTFontGetAdvancesForGlyphs(font, .horizontal, [CTFontGetGlyphWithName(font, "zero" as CFString)], nil, 1)
        let numFont = monoFont(11.5)
        for line in diff {
            let rowRect = CGRect(x: 0, y: y, width: W, height: lh)
            let base = y + lh * 0.5 + g.fontSize * 0.36
            switch line.kind {
            case .hunk:
                ctx.setFillColor(Palette.hunkBg); ctx.fill(rowRect)
                drawText(ctx, NSAttributedString(string: line.text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): monoFont(12.5),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.muted]),
                         at: CGPoint(x: codeX - 14, y: base - 0.5))
            default:
                let (bg, numBg, markBg, sign, signColor): (CGColor?, CGColor?, CGColor?, String, CGColor) = {
                    switch line.kind {
                    case .deletion: return (Palette.delBg, Palette.delNum, Palette.delMark, "-", Palette.delFg)
                    case .addition: return (Palette.addBg, Palette.addNum, Palette.addMark, "+", Palette.addFg)
                    default: return (nil, nil, nil, " ", Palette.text)
                    }
                }()
                if let bg { ctx.setFillColor(bg); ctx.fill(rowRect) }
                if let numBg { ctx.setFillColor(numBg); ctx.fill(CGRect(x: 0, y: y, width: gutter, height: lh)) }
                if let markBg {
                    ctx.setFillColor(markBg)
                    for m in line.marks {
                        ctx.fill(CGRect(x: codeX + CGFloat(m.lowerBound) * cw, y: y + 2,
                                        width: CGFloat(m.count) * cw, height: lh - 4))
                    }
                }
                let numAttrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): numFont,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): hex(0x6e7781)]
                if let o = line.old {
                    let a = NSAttributedString(string: "\(o)", attributes: numAttrs)
                    drawText(ctx, a, at: CGPoint(x: numW - 8 - CGFloat(a.length) * 7, y: base))
                }
                if let n = line.new {
                    let a = NSAttributedString(string: "\(n)", attributes: numAttrs)
                    drawText(ctx, a, at: CGPoint(x: numW * 2 - 8 - CGFloat(a.length) * 7, y: base))
                }
                drawText(ctx, NSAttributedString(string: sign, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): monoFont(g.fontSize, .bold),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): signColor]),
                         at: CGPoint(x: gutter + 8, y: base))
                drawText(ctx, highlightCode(line.text, font: font), at: CGPoint(x: codeX, y: base))
            }
            y += lh
        }
        ctx.setFillColor(hex(0xd8dee4, 0.7))
        ctx.fill(CGRect(x: gutter - 0.5, y: hh, width: 1, height: H - hh))
    } else {
        let rows = g.detail == .small ? smallRows : tinyRows
        let cell: CGFloat = g.detail == .small ? 16 : 22
        let barH = lh * 0.36
        let focus = g.focus
        let firstAdd = CGFloat(rows.firstIndex { $0.0 == .addition }!)
        let edgeShift: CGFloat = g.detail == .tiny ? 32 / CGFloat(g.mag) : 0
        y = focus.y + edgeShift - firstAdd * lh
        let colorW = focus.x + CGFloat(g.ri) * 0.95
        let tiny = g.detail == .tiny
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: hh, width: W, height: H - hh))
        defer { ctx.restoreGState() }
        for (kind, indent, len) in rows {
            switch kind {
            case .deletion:
                ctx.setFillColor(tiny ? hex(0xf0525c) : hex(0xffb8b3)); ctx.fill(CGRect(x: 0, y: y, width: colorW, height: lh))
                ctx.setFillColor(Palette.delFg); ctx.fill(CGRect(x: 0, y: y, width: gutter, height: lh))
            case .addition:
                ctx.setFillColor(tiny ? hex(0x2fb14f) : hex(0x9be9ad)); ctx.fill(CGRect(x: 0, y: y, width: colorW, height: lh))
                ctx.setFillColor(Palette.addFg); ctx.fill(CGRect(x: 0, y: y, width: gutter, height: lh))
            default: break
            }
            if len > 0 {
                let color: CGColor = kind == .deletion ? hex(0x82071e) : kind == .addition ? hex(0x044f1e) : hex(0x6e7781)
                ctx.setFillColor(color)
                let x0 = codeX + CGFloat(indent) * cell
                var bw = CGFloat(len) * cell
                if kind != .context { bw = min(bw, colorW - x0 - 10) }
                let r = CGRect(x: x0, y: y + (lh - barH) / 2, width: bw, height: barH)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: barH / 2, cornerHeight: barH / 2, transform: nil))
                ctx.fillPath()
            }
            y += lh
        }
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(paperPath(g))
    ctx.setStrokeColor(hex(0x000000, 0.12))
    ctx.setLineWidth(g.detail == .full ? 1.2 : 3)
    ctx.strokePath()
    ctx.restoreGState()
}

func backSheetTransform(_ g: Geometry) -> CGAffineTransform {
    CGAffineTransform(translationX: g.paperCenter.x - 34, y: g.paperCenter.y + 20)
        .rotated(by: 3.0 * .pi / 180)
        .translatedBy(x: -g.paperSize.width / 2, y: -g.paperSize.height / 2)
}

func backSheetPath(_ g: Geometry) -> CGPath {
    var t = backSheetTransform(g)
    return CGPath(rect: CGRect(origin: .zero, size: g.paperSize), transform: &t)
}

/// Draws the next file in the review: mostly hidden, slightly greyer, with faint rows.
func drawBackSheet(_ ctx: CGContext, _ g: Geometry) {
    ctx.saveGState()
    ctx.concatenate(backSheetTransform(g))
    let W = g.paperSize.width, H = g.paperSize.height
    ctx.addRect(CGRect(x: 0, y: 0, width: W, height: H)); ctx.clip()
    let grad = CGGradient(colorsSpace: sRGB, colors: [hex(0xf2f1ec), hex(0xe4e3dd)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: H), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.setFillColor(hex(0xe9ecef)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: g.headerHeight))
    var y = g.headerHeight + 10
    var k = 0
    while y < H - 70 {
        let len = 80 + (hash2(k, 7) * 220)
        let indent = Double((k * 7) % 3) * 22
        ctx.setFillColor(hex(0x9aa4ae, 0.55))
        ctx.fill(CGRect(x: 94 + indent, y: y + 8, width: len, height: 7))
        ctx.setFillColor(hex(0xc4cad0, 0.6))
        ctx.fill(CGRect(x: 14, y: y + 8, width: 40, height: 7))
        y += g.lineHeight; k += 1
    }
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(backSheetPath(g)); ctx.setStrokeColor(hex(0x000000, 0.12)); ctx.setLineWidth(1.2); ctx.strokePath()
    ctx.restoreGState()
}

func drawDesk(_ ctx: CGContext, _ g: Geometry) {
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let grad = CGGradient(colorsSpace: sRGB, colors: [hex(0x24395c), hex(0x152238), hex(0x0b1322)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    let pool = CGGradient(colorsSpace: sRGB, colors: [hex(0x5b86c4, 0.38), hex(0x5b86c4, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(pool, startCenter: CGPoint(x: 360, y: 300), startRadius: 0,
                           endCenter: CGPoint(x: 360, y: 300), endRadius: 620, options: [])
    ctx.restoreGState()
}

/// Renders felt texture and vignette as a per-pixel pass inside the body.
func feltTexture(_ b: Bitmap) -> Bitmap {
    let t = Bitmap(b.w)
    t.forEachPixel(in: bodyRect) { i, j, x, y in
        let n = fbm(x * 0.09, y * 0.09, octaves: 3) - 0.5
        let fine = hash2(Int(x * 2.2), Int(y * 2.2)) - 0.5
        let v = n * 0.10 + fine * 0.035
        let dx = (x - 512) / 412, dy = (y - 470) / 412
        let vig = smoothstep(0.55, 1.35, (dx * dx + dy * dy).squareRoot()) * 0.35
        let m = (1 - vig) * (1 + v)
        if m >= 1 { t.put(i, j, V3(0.75, 0.82, 1.0), (m - 1) * 0.5) } else { t.put(i, j, V3(0, 0, 0.02), 1 - m) }
    }
    return t
}

/// Shades chrome by reflecting a simple studio environment.
///
/// The studio has a bright softbox overhead and a dark desk below.
func chrome(_ n: V3, tint: V3) -> V3 {
    let r = V3(2 * n.z * n.x, 2 * n.z * n.y, 2 * n.z * n.z - 1)
    let up = -r.y
    let studio = mix(V3(0.30, 0.33, 0.38), V3(0.52, 0.55, 0.60), smoothstep(-0.6, 0.6, up - 0.4 * r.x))
    let graze = 1 - smoothstep(0.35, 0.85, r.z)
    let sky = mix(V3(0.80, 0.84, 0.90), V3(1.0, 1.0, 1.0), smoothstep(0.1, 0.8, up))
    let desk = mix(V3(0.03, 0.05, 0.09), V3(0.12, 0.16, 0.24), smoothstep(-1.0, -0.2, up))
    let horizon = smoothstep(-0.06, 0.06, up - 0.1 * r.x + 0.05)
    var col = mix(studio, mix(desk, sky, horizon), graze)
    let l = V3(-0.5, -0.72, 0.48).normalized
    let rl = max(0, r.dot(l))
    col = col + V3(1, 1, 1) * (smoothstep(0.90, 0.94, rl) * 0.9 + pow(rl, 10) * 0.22)
    let l2 = V3(0.75, 0.55, 0.35).normalized
    col = col + V3(0.45, 0.62, 0.95) * smoothstep(0.86, 0.95, max(0, r.dot(l2))) * 0.45
    return col * tint
}

func woodAlbedo(_ s: Double, _ w: Double) -> V3 {
    let wobble = fbm(s * 0.012, w * 1.3, octaves: 3) * 2.2
    let rings = w * 4.5 + wobble + s * 0.0025
    let band = 0.5 + 0.5 * sin(rings * 2 * .pi)
    let fine = fbm(s * 0.004, w * 18, octaves: 2)
    let pores = hash2(Int(s * 0.7), Int((w + 1) * 60)) > 0.93 ? 0.75 : 1.0
    let dark = hexV(0x3b2214), light = hexV(0x7a4a2a)
    let t = clamp(band * 0.55 + fine * 0.6 - 0.15)
    return mix(dark, light, t) * pores
}

/// Shades the handle, ferrule and neck into `b`.
func drawHandle(_ b: Bitmap, _ g: Geometry) {
    let a = g.axis
    let perp = CGPoint(x: -a.y, y: a.x)
    let light = V3(-0.45, -0.7, 0.55).normalized
    let (ns, ne, nw) = g.neck
    let (fs, fe, fw) = g.ferrule
    let (gs, ge, gw0, gw1) = g.grip
    let p0 = g.along(ns - 10), p1 = g.along(ge + 2)
    let bounds = CGRect(x: min(p0.x, p1.x) - 80, y: min(p0.y, p1.y) - 80,
                        width: abs(p1.x - p0.x) + 160, height: abs(p1.y - p0.y) + 160)
    let aaw = 1.0 / b.s
    b.forEachPixel(in: bounds) { i, j, x, y in
        let dx = x - g.c.x, dy = y - g.c.y
        let s = dx * a.x + dy * a.y
        let t = dx * perp.x + dy * perp.y
        var best: (V3, Double)? = nil

        let capR = gw1
        let gw = mix(gw0, gw1, clamp((s - gs) / (ge - capR - gs)))
        if s > gs - 1 {
            var cov = 0.0, nAcross = 0.0, nAlong = 0.0
            if s < ge - capR {
                cov = clamp((gw - abs(t)) / aaw + 0.5) * clamp((s - gs) / aaw + 0.5)
                nAcross = t / gw
            } else {
                let ds = s - (ge - capR)
                let d = (ds * ds + t * t).squareRoot()
                cov = clamp((capR - d) / aaw + 0.5)
                nAcross = t / capR
                nAlong = ds / capR
            }
            if cov > 0 {
                let q = clamp(nAcross * nAcross + nAlong * nAlong, 0, 0.999)
                let nz = (1 - q).squareRoot()
                let n = V3(perp.x * nAcross + a.x * nAlong, perp.y * nAcross + a.y * nAlong, nz).normalized
                let alb = woodAlbedo(s, t / gw) * (g.detail == .full ? 1.0 : 1.45)
                let diff = 0.22 + 0.95 * max(0, n.dot(light))
                let r = V3(2 * n.z * n.x, 2 * n.z * n.y, 2 * n.z * n.z - 1)
                let spec = pow(max(0, r.dot(light)), 45) * 0.55 + pow(max(0, r.dot(light)), 6) * 0.05
                let fres = pow(1 - nz, 3) * 0.25
                let skyRefl = smoothstep(-0.2, 0.6, -r.y) * 0.12
                var col = alb * diff + V3(1, 0.97, 0.92) * (spec + skyRefl) + V3(0.4, 0.5, 0.7) * fres * 0.4
                col = col * (0.6 + 0.4 * smoothstep(gs, gs + 10, s))
                best = (col, cov)
            }
        }

        if s > fs - 2 && s < fe + 2 {
            let cov = clamp((fw - abs(t)) / aaw + 0.5) * clamp((s - fs) / aaw + 0.5) * clamp((fe - s) / aaw + 0.5)
            if cov > 0 {
                var nAcross = t / fw
                var nAlong = 0.0
                let lip = 7.0
                if s - fs < lip { nAlong = -(1 - (s - fs) / lip) * 0.7 }
                if fe - s < lip { nAlong = (1 - (fe - s) / lip) * 0.7 }
                nAcross = clamp(nAcross * 0.98, -0.98, 0.98)
                var col = chrome(V3(perp.x * nAcross + a.x * nAlong, perp.y * nAcross + a.y * nAlong,
                                    (max(0.02, 1 - nAcross * nAcross - nAlong * nAlong)).squareRoot()).normalized, tint: g.metalTint)
                if g.detail == .full {
                    for gpos in [fs + 0.38 * (fe - fs), fs + 0.62 * (fe - fs)] {
                        let d = abs(s - gpos)
                        if d < 3 { col = col * (0.35 + 0.65 * smoothstep(0.5, 3, d)) }
                        if s - gpos > 3 && s - gpos < 5 { col = col + V3(0.2, 0.2, 0.2) }
                    }
                }
                best = blendOver(best, (col, cov))
            }
        }

        if s > ns - 2 && s < ne + 2 {
            let flare = smoothstep(ne - 12, ne, s) * 6
            let w = nw + flare
            let cov = clamp((w - abs(t)) / aaw + 0.5) * clamp((ne - s) / aaw + 0.5)
            if cov > 0 {
                let nAcross = clamp(t / w, -0.98, 0.98)
                let col = chrome(V3(perp.x * nAcross, perp.y * nAcross, (1 - nAcross * nAcross).squareRoot()), tint: g.metalTint)
                best = blendOver(best, (col * 0.92, cov))
            }
        }
        if let (col, cov) = best { b.put(i, j, col, cov) }
    }
}

func blendOver(_ under: (V3, Double)?, _ over: (V3, Double)) -> (V3, Double) {
    guard let under else { return over }
    let a = over.1 + under.1 * (1 - over.1)
    if a <= 0 { return over }
    let c = (over.0 * over.1 + under.0 * (under.1 * (1 - over.1))) * (1 / a)
    return (c, a)
}

/// Shades the metal rim ring.
func drawRim(_ b: Bitmap, _ g: Geometry) {
    let aaw = 1.0 / b.s
    let mid = (g.ri + g.ro) / 2, half = (g.ro - g.ri) / 2
    let r = CGRect(x: g.c.x - g.ro - 2, y: g.c.y - g.ro - 2, width: g.ro * 2 + 4, height: g.ro * 2 + 4)
    b.forEachPixel(in: r) { i, j, x, y in
        let dx = x - g.c.x, dy = y - g.c.y
        let rho = (dx * dx + dy * dy).squareRoot()
        let cov = clamp((g.ro - rho) / aaw + 0.5) * clamp((rho - g.ri) / aaw + 0.5)
        if cov <= 0 { return }
        let ux = dx / rho, uy = dy / rho
        let t = clamp((rho - mid) / half, -1, 1)
        var nr = 0.55 * t + 0.45 * t * t * t
        nr = clamp(nr, -0.985, 0.985)
        var col = chrome(V3(ux * nr, uy * nr, (1 - nr * nr).squareRoot()), tint: g.metalTint)
        if g.detail == .full {
            let brush = fbm(rho * 0.9, atan2(dy, dx) * 6, octaves: 2) - 0.5
            col = col * (1 + brush * 0.10)
            let gt = abs(t + 0.42)
            if gt < 0.04 { col = col * (0.45 + 0.55 * smoothstep(0.0, 0.04, gt)) }
        }
        if g.detail == .tiny {
            let lit = clamp(0.5 - 0.5 * (ux + uy) * 0.7071)
            col = mix(V3(0.50, 0.55, 0.63), V3(0.93, 0.95, 0.98), lit)
        } else {
            col = col * (0.45 + 0.55 * smoothstep(-1.0, -0.84, t))
            col = col * (0.55 + 0.45 * (1 - smoothstep(0.86, 1.0, t)))
        }
        b.put(i, j, col, cov)
    }
}

/// Renders the scene under the glass, magnified and barrel-distorted, with glass tint.
func drawLens(_ b: Bitmap, under: Bitmap, _ g: Geometry) {
    let aaw = 1.0 / b.s
    let r = CGRect(x: g.c.x - g.ri - 2, y: g.c.y - g.ri - 2, width: g.ri * 2 + 4, height: g.ri * 2 + 4)
    let s = b.s
    b.forEachPixel(in: r) { i, j, x, y in
        let dx = x - g.c.x, dy = y - g.c.y
        let rho = (dx * dx + dy * dy).squareRoot()
        let cov = clamp((g.ri + 1 - rho) / aaw + 0.5)
        if cov <= 0 { return }
        let rn = min(rho / g.ri, 1)
        let k = 1 + g.barrel * rn * rn
        let ca = 0.012 * pow(rn, 3)
        func at(_ kk: Double) -> (Double, Double, Double, Double) {
            under.sample((g.c.x + dx * kk) * s, (g.c.y + dy * kk) * s)
        }
        let sr = at(k * (1 + ca)), sg = at(k), sb = at(k * (1 - ca))
        var col = V3(sr.0, sg.1, sb.2)
        col = col * V3(0.92, 0.95, 0.955)
        let edge = smoothstep(0.80, 1.0, rn)
        col = mix(col, col * V3(0.82, 0.92, 0.93), edge * 0.55)
        col = col * (1 - 0.35 * pow(edge, 2))
        b.put(i, j, col, cov)
    }
}

func drawGlassHighlights(_ b: Bitmap, _ g: Geometry) {
    let ctx = b.ctx
    let c = g.c, ri = CGFloat(g.ri)
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - ri, y: c.y - ri, width: ri * 2, height: ri * 2))
    ctx.clip()

    let full = g.detail == .full
    let crescent = CGMutablePath()
    crescent.addEllipse(in: CGRect(x: c.x - ri * 0.97, y: c.y - ri * 0.97, width: ri * 1.94, height: ri * 1.94))
    let off = CGPoint(x: c.x + ri * 0.07, y: c.y + ri * 0.10)
    crescent.addEllipse(in: CGRect(x: off.x - ri * 0.99, y: off.y - ri * 0.99, width: ri * 1.98, height: ri * 1.98))
    shadowOnly(b, offset: .zero, blur: full ? 4 : 12, color: hex(0xffffff, 0.50)) { cx in
        cx.addPath(crescent); cx.fillPath(using: .evenOdd)
    }

    let sheen = CGGradient(colorsSpace: sRGB, colors: [hex(0xffffff, 0.10), hex(0xffffff, 0.0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: c.x, y: c.y - ri), end: CGPoint(x: c.x, y: c.y + ri * 0.1), options: [])

    let window = CGMutablePath()
    let wc = CGPoint(x: c.x - ri * 0.30, y: c.y - ri * 0.62)
    let wr = CGRect(x: -ri * 0.26, y: -ri * 0.11, width: ri * 0.52, height: ri * 0.22)
    var wt = CGAffineTransform(translationX: wc.x, y: wc.y).rotated(by: -.pi / 6.5)
    window.addRoundedRect(in: wr, cornerWidth: ri * 0.09, cornerHeight: ri * 0.09, transform: wt)
    shadowOnly(b, offset: .zero, blur: full ? 3 : 10, color: hex(0xffffff, 0.85)) { cx in
        cx.addPath(window); cx.fillPath()
    }
    wt = CGAffineTransform(translationX: c.x + ri * 0.30, y: c.y + ri * 0.36).rotated(by: -.pi / 4).scaledBy(x: 0.6, y: 0.5)
    let window2 = CGPath(roundedRect: wr, cornerWidth: ri * 0.09, cornerHeight: ri * 0.09, transform: &wt)
    shadowOnly(b, offset: .zero, blur: full ? 8 : 14, color: hex(0xffffff, 0.30)) { cx in
        cx.addPath(window2); cx.fillPath()
    }

    ctx.setLineCap(.round)
    ctx.setStrokeColor(hex(0xffffff, 0.75))
    ctx.setLineWidth(full ? 2.5 : 8)
    ctx.addArc(center: c, radius: ri - 3, startAngle: 1.08 * .pi, endAngle: 1.42 * .pi, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(hex(0xffffff, 0.45))
    ctx.setLineWidth(full ? 5 : 10)
    ctx.addArc(center: c, radius: ri - 4, startAngle: 0.12 * .pi, endAngle: 0.62 * .pi, clockwise: false)
    ctx.strokePath()
    let inner = CGGradient(colorsSpace: sRGB, colors: [hex(0x0b1322, 0.0), hex(0x0b1322, 0.30)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(inner, startCenter: CGPoint(x: c.x + 6, y: c.y + 10), startRadius: ri * 0.82,
                           endCenter: c, endRadius: ri, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

func magnifierShadowShapes(_ ctx: CGContext, _ g: Geometry, includeGlass: Bool) {
    let c = g.c
    ctx.addEllipse(in: CGRect(x: c.x - g.ro, y: c.y - g.ro, width: g.ro * 2, height: g.ro * 2))
    if !includeGlass {
        ctx.addEllipse(in: CGRect(x: c.x - g.ri, y: c.y - g.ri, width: g.ri * 2, height: g.ri * 2))
    }
    ctx.fillPath(using: .evenOdd)
    let a = g.axis, perp = CGPoint(x: -a.y, y: a.x)
    let (_, ge, _, gw1) = g.grip
    let (_, _, fw) = g.ferrule
    let p0 = g.along(g.ro - 10), p1 = g.along(ge - gw1)
    let w = CGFloat(max(fw, gw1))
    ctx.move(to: CGPoint(x: p0.x + perp.x * w * 0.6, y: p0.y + perp.y * w * 0.6))
    ctx.addLine(to: CGPoint(x: p1.x + perp.x * w, y: p1.y + perp.y * w))
    ctx.addLine(to: CGPoint(x: p1.x - perp.x * w, y: p1.y - perp.y * w))
    ctx.addLine(to: CGPoint(x: p0.x - perp.x * w * 0.6, y: p0.y - perp.y * w * 0.6))
    ctx.closePath()
    ctx.addEllipse(in: CGRect(x: p1.x - w, y: p1.y - w, width: w * 2, height: w * 2))
    ctx.fillPath()
}

/// Draws the pages and the magnifier's shadow on them.
///
/// This is drawn once for the icon and once more, magnified, for the view through the glass,
/// so the shadow of the rim shows up (magnified) inside the lens just as it would in life.
func drawTabletop(_ b: Bitmap, _ g: Geometry) {
    let ctx = b.ctx
    if g.detail == .full {
        shadowOnly(b, offset: CGPoint(x: 2, y: 12), blur: 26, color: hex(0x000000, 0.45)) { $0.addPath(backSheetPath(g)); $0.fillPath() }
        drawBackSheet(ctx, g)
    }
    shadowOnly(b, offset: CGPoint(x: 4, y: 18), blur: 34, color: hex(0x000000, 0.55)) { $0.addPath(paperPath(g)); $0.fillPath() }
    shadowOnly(b, offset: CGPoint(x: 0, y: 3), blur: 5, color: hex(0x000000, 0.35)) { $0.addPath(paperPath(g)); $0.fillPath() }
    drawPaper(ctx, g)

    let shOff = CGPoint(x: 30, y: 48)
    shadowOnly(b, offset: shOff, blur: g.detail == .full ? 24 : 30, color: hex(0x000000, 0.5)) {
        magnifierShadowShapes($0, g, includeGlass: false)
    }
    shadowOnly(b, offset: shOff, blur: 30, color: hex(0x000000, 0.10)) { cx in
        cx.addEllipse(in: CGRect(x: g.c.x - g.ri, y: g.c.y - g.ri, width: g.ri * 2, height: g.ri * 2)); cx.fillPath()
    }
    if g.detail == .full {
        let fc = CGPoint(x: g.c.x + shOff.x + 10, y: g.c.y + shOff.y + 16)
        let caustic = CGGradient(colorsSpace: sRGB, colors: [hex(0xfffbe8, 0.55), hex(0xfffbe8, 0.0)] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.setBlendMode(.screen)
        ctx.drawRadialGradient(caustic, startCenter: fc, startRadius: 0, endCenter: fc, endRadius: 60, options: [])
        ctx.restoreGState()
    }
}

func render(size: Int, detail: Detail) -> Bitmap {
    let g = Geometry(detail)
    let b = Bitmap(size)
    let ctx = b.ctx

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * b.s), blur: 22 * b.s, color: hex(0x000000, 0.42))
    ctx.addPath(bodyPath); ctx.setFillColor(hex(0x0b1322)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()

    drawDesk(ctx, g)
    if detail == .full { b.composite(feltTexture(b)) }

    drawTabletop(b, g)

    let under = Bitmap(size)
    under.ctx.translateBy(x: g.c.x, y: g.c.y)
    under.ctx.scaleBy(x: CGFloat(g.mag), y: CGFloat(g.mag))
    under.ctx.translateBy(x: -g.c.x, y: -g.c.y)
    drawDesk(under.ctx, g)
    drawTabletop(under, g)
    let lens = Bitmap(size)
    drawLens(lens, under: under, g)
    b.composite(lens)
    drawGlassHighlights(b, g)

    let metal = Bitmap(size)
    drawHandle(metal, g)
    drawRim(metal, g)
    b.composite(metal)

    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.addPath(bodyPath)
    ctx.setLineWidth(detail == .full ? 5 : 10)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let edge = CGGradient(colorsSpace: sRGB, colors: [hex(0xffffff, 0.35), hex(0xffffff, 0.04), hex(0x000000, 0.25)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(edge, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()
    return b
}

/// Downsamples exactly with a box filter by an integer factor.
///
/// Works on premultiplied pixels, so edges stay clean.
func downsample(_ src: Bitmap, to size: Int) -> CGImage {
    let f = src.w / size
    precondition(f * size == src.w)
    let dst = Bitmap(size)
    let n = Double(f * f)
    for j in 0..<size {
        for i in 0..<size {
            var acc = [0.0, 0.0, 0.0, 0.0]
            for y in (j * f)..<(j * f + f) {
                for x in (i * f)..<(i * f + f) {
                    let o = (y * src.w + x) * 4
                    for k in 0..<4 { acc[k] += Double(src.px[o + k]) }
                }
            }
            let o = (j * size + i) * 4
            for k in 0..<4 { dst.px[o + k] = UInt8(min(255, acc[k] / n + 0.5)) }
        }
    }
    return dst.image()
}

func pngData(_ img: CGImage) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

/// Run-length codes one channel the way ICNS expects.
///
/// A control byte below 0x80 copies that many plus one literal bytes; 0x80 and up repeats
/// the next byte (control - 0x80 + 3) times.
func icnsRLE(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [], literal: [UInt8] = []
    func flush() {
        var k = 0
        while k < literal.count {
            let n = min(128, literal.count - k)
            out.append(UInt8(n - 1)); out += literal[k..<(k + n)]; k += n
        }
        literal.removeAll()
    }
    var i = 0
    while i < bytes.count {
        var run = 1
        while i + run < bytes.count, bytes[i + run] == bytes[i], run < 130 { run += 1 }
        if run >= 3 {
            flush(); out.append(UInt8(0x80 + run - 3)); out.append(bytes[i]); i += run
        } else {
            literal.append(bytes[i]); i += 1
        }
    }
    flush()
    return out
}

/// Encodes the 'ARGB' payload that Apple's iconutil writes for ic04 and ic05.
///
/// The payload is straight-alpha planes A, R, G, B, each run-length coded.
func argbData(_ img: CGImage) -> Data {
    let n = img.width
    let bm = Bitmap(n)
    bm.ctx.saveGState()
    bm.ctx.concatenate(bm.ctx.ctm.inverted())
    bm.ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
    bm.ctx.restoreGState()
    var planes = [[UInt8]](repeating: [], count: 4)
    for p in 0..<(n * n) {
        let a = Int(bm.px[p * 4 + 3])
        planes[0].append(UInt8(a))
        for k in 0..<3 {
            let v = Int(bm.px[p * 4 + k])
            planes[k + 1].append(a == 0 ? 0 : UInt8(min(255, (v * 255 + a / 2) / a)))
        }
    }
    var data = Data("ARGB".utf8)
    for plane in planes { data.append(contentsOf: icnsRLE(plane)) }
    return data
}

func writeICNS(_ entries: [(String, Data)], to url: URL) throws {
    func be32(_ v: Int) -> Data { var x = UInt32(v).bigEndian; return Data(bytes: &x, count: 4) }
    var body = Data()
    for (type, payload) in entries {
        body.append(type.data(using: .ascii)!)
        body.append(be32(payload.count + 8))
        body.append(payload)
    }
    var file = Data("icns".utf8)
    file.append(be32(body.count + 8))
    file.append(body)
    try file.write(to: url)
}

let iconDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

var images: [Int: CGImage] = [:]
let master = render(size: 2048, detail: .full)
for px in [1024, 512, 256, 128] { images[px] = downsample(master, to: px) }
let small = render(size: 512, detail: .small)
for px in [64, 32] { images[px] = downsample(small, to: px) }
images[16] = downsample(render(size: 512, detail: .tiny), to: 16)

let entries: [(String, Int)] = [
    ("ic04", 16), ("ic05", 32), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
    ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512),
]
let chunks = entries.map { type, px in (type, type == "ic04" || type == "ic05" ? argbData(images[px]!) : pngData(images[px]!)) }
try writeICNS(chunks, to: iconDir.appendingPathComponent("AppIcon.icns"))
try pngData(images[1024]!).write(to: iconDir.appendingPathComponent("preview-1024.png"))

do {
    let W = 1214, H = 916
    let sheet = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: sRGB,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.interpolationQuality = .none
    for (row, bg) in [(0, hex(0xececec)), (1, hex(0x1e1e1e))] {
        let y0 = H - (row + 1) * 300
        sheet.setFillColor(bg)
        sheet.fill(CGRect(x: 0, y: y0, width: W, height: 300))
        var x = 30
        for sz in [16, 32, 64, 128, 256] {
            sheet.draw(images[sz]!, in: CGRect(x: x, y: y0 + 22, width: sz, height: sz))
            x += sz + 30
        }
    }
    sheet.setFillColor(hex(0x808080))
    sheet.fill(CGRect(x: 0, y: 0, width: W, height: H - 600))
    for (k, sz) in [16, 32, 64, 128].enumerated() {
        sheet.draw(images[sz]!, in: CGRect(x: 30 + k * 296, y: 30, width: 256, height: 256))
    }
    try pngData(sheet.makeImage()!).write(to: iconDir.appendingPathComponent("preview-sizes.png"))
}
print("wrote AppIcon.icns, preview-1024.png, preview-sizes.png")
