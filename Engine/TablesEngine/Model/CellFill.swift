import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// OOXML's `ST_PatternType` less `none` and `solid`, which are modelled as no
/// fill and a plain `fillColorHex`.
///
/// Raw values are the OOXML tokens, so reading and writing are a straight
/// `init(rawValue:)` / `rawValue`.
public enum FillPatternType: String, Hashable, Sendable, CaseIterable {
    case darkGray, mediumGray, lightGray, gray125, gray0625
    case darkHorizontal, darkVertical, darkDown, darkUp, darkGrid, darkTrellis
    case lightHorizontal, lightVertical, lightDown, lightUp, lightGrid, lightTrellis

    /// The pattern as Excel draws it: eight rows of eight bits, the most
    /// significant bit leftmost, a set bit drawn in the pattern colour and a
    /// clear one in the background colour. These are the legacy brushes
    /// Excel's patterns have always been, so every one repeats within 8×8.
    public var rows: [UInt8] {
        switch self {
        case .darkGray: return [0x77, 0xDD, 0x77, 0xDD, 0x77, 0xDD, 0x77, 0xDD]
        case .mediumGray: return [0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55]
        case .lightGray: return [0x88, 0x22, 0x88, 0x22, 0x88, 0x22, 0x88, 0x22]
        case .gray125: return [0x88, 0x00, 0x22, 0x00, 0x88, 0x00, 0x22, 0x00]
        case .gray0625: return [0x80, 0x00, 0x08, 0x00, 0x80, 0x00, 0x08, 0x00]
        case .darkHorizontal: return [0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00]
        case .darkVertical: return [0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC]
        // "Reverse diagonal stripe": falling from top left to bottom right.
        case .darkDown: return [0xCC, 0x66, 0x33, 0x99, 0xCC, 0x66, 0x33, 0x99]
        // "Diagonal stripe": rising from bottom left to top right.
        case .darkUp: return [0x33, 0x66, 0xCC, 0x99, 0x33, 0x66, 0xCC, 0x99]
        // "Diagonal crosshatch", which Excel draws as a fine checkerboard.
        case .darkGrid: return [0xCC, 0xCC, 0x33, 0x33, 0xCC, 0xCC, 0x33, 0x33]
        case .darkTrellis: return [0x99, 0xFF, 0x66, 0xFF, 0x99, 0xFF, 0x66, 0xFF]
        case .lightHorizontal: return [0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00]
        case .lightVertical: return [0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88]
        case .lightDown: return [0x88, 0x44, 0x22, 0x11, 0x88, 0x44, 0x22, 0x11]
        case .lightUp: return [0x11, 0x22, 0x44, 0x88, 0x11, 0x22, 0x44, 0x88]
        case .lightGrid: return [0xFF, 0x88, 0x88, 0x88, 0xFF, 0x88, 0x88, 0x88]
        case .lightTrellis: return [0x88, 0x55, 0x22, 0x55, 0x88, 0x55, 0x22, 0x55]
        }
    }

    /// Whether the bit at `column`, `row` of the repeating pattern is drawn
    /// in the pattern colour. Any integers work: the pattern repeats.
    public func isInked(column: Int, row: Int) -> Bool {
        let bits = rows[((row % 8) + 8) % 8]
        return bits & (0x80 >> UInt8(((column % 8) + 8) % 8)) != 0
    }

    /// The share of the pattern drawn in the pattern colour, 0–1.
    public var coverage: Double {
        Double(rows.reduce(0) { $0 + $1.nonzeroBitCount }) / 64
    }
}

/// A pattern drawn over a cell's fill colour, which is its background.
public struct FillPattern: Hashable, Sendable {
    public var type: FillPatternType
    /// OOXML "AARRGGBB" for the pattern's own colour, its `fgColor`. `nil`
    /// is Excel's automatic colour: black, or the text colour in dark mode.
    public var colorHex: String?

    public init(type: FillPatternType, colorHex: String? = nil) {
        self.type = type
        self.colorHex = colorHex
    }

    /// How big one bit of a pattern is, in points on screen.
    ///
    /// Excel draws its patterns a pixel per bit at every zoom, so a pattern
    /// stays the same size as the cells around it grow and shrink. A screen
    /// pixel is too fine to make out on a Retina display, so a bit here is a
    /// point instead: the 8×8 pattern is 8 points square, about the size it is
    /// in Excel at 100%, and stays that size at any zoom. Renderers working
    /// in unzoomed sheet coordinates divide this by the zoom.
    public static let bitSize = 1.0

    /// Bits on a side of the tile renderers repeat: several repeats of the
    /// pattern, so a cell takes a few draws of it rather than dozens.
    public static let tileBits = 32

    /// The colour automatic pattern ink stands for before appearance adapts it.
    public static let automaticColorHex = "FF000000"
}

/// One colour of a gradient and where along it the colour sits.
public struct GradientStop: Hashable, Sendable {
    /// 0 at the gradient's start, 1 at its end.
    public var position: Double
    /// OOXML "AARRGGBB". `nil` is an automatic colour, drawn as white.
    public var colorHex: String?

    public init(position: Double, colorHex: String?) {
        self.position = position
        self.colorHex = colorHex
    }
}

/// OOXML's `<gradientFill>`: colours blended across the cell, along a line
/// or outward from a rectangle within it.
public struct FillGradient: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Along a line at `degree`s clockwise from left to right, so 90 runs
        /// from the top of the cell to the bottom.
        case linear(degree: Double)
        /// Outward from the rectangle these fractions of the cell's width and
        /// height mark, all measured from its top-left corner, to its edges.
        /// All 0.5 is "from the centre"; all 0 is "from the top-left corner".
        case path(left: Double, right: Double, top: Double, bottom: Double)
    }

    public var kind: Kind
    /// In order of position. A gradient needs two to be one, but a file may
    /// carry fewer, and one is drawn as a solid colour.
    public var stops: [GradientStop]

    public init(kind: Kind, stops: [GradientStop]) {
        self.kind = kind
        self.stops = stops.sorted { $0.position < $1.position }
    }

    /// What white automatic stops are drawn in.
    public static let automaticColorHex = "FFFFFFFF"

    /// The same gradient with every stop's colour put through `transform`,
    /// as appearance adaptation does.
    public func mapColors(_ transform: (String?) -> String?) -> FillGradient {
        FillGradient(kind: kind, stops: stops.map {
            GradientStop(position: $0.position, colorHex: transform($0.colorHex))
        })
    }

    /// The blended colour at `position`, as "AARRGGBB": the stops either side
    /// mixed in sRGB, as Excel mixes them.
    public func colorHex(at position: Double) -> String {
        let resolved = stops.map { (position: $0.position, rgba: Self.components($0.colorHex ?? Self.automaticColorHex)) }
        guard let first = resolved.first, let last = resolved.last else { return Self.automaticColorHex }
        if position <= first.position { return Self.hex(first.rgba) }
        if position >= last.position { return Self.hex(last.rgba) }
        for (lower, upper) in zip(resolved, resolved.dropFirst()) where position <= upper.position {
            let span = upper.position - lower.position
            let t = span > 0 ? (position - lower.position) / span : 1
            return Self.hex(zip(lower.rgba, upper.rgba).map { $0 + ($1 - $0) * t })
        }
        return Self.hex(last.rgba)
    }

    /// Where a linear gradient starts and ends across `frame`: on a line
    /// through its centre at the gradient's angle, just long enough that the
    /// first and last colours reach its corners.
    public func linearEndpoints(in frame: CGRect) -> (start: CGPoint, end: CGPoint) {
        let degree: Double
        if case .linear(let angle) = kind { degree = angle } else { degree = 0 }
        let radians = degree * .pi / 180
        let dx = cos(radians), dy = sin(radians)
        let half = (Double(frame.width) * abs(dx) + Double(frame.height) * abs(dy)) / 2
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return (
            CGPoint(x: Double(centre.x) - dx * half, y: Double(centre.y) - dy * half),
            CGPoint(x: Double(centre.x) + dx * half, y: Double(centre.y) + dy * half)
        )
    }

    /// A path gradient as nested rectangles, outermost first, each to be
    /// filled over the one before: rings stepping from the cell's edges, in
    /// the last colour, in to its inner rectangle, in the first. `step` is
    /// how far apart the rings are, in the caller's units.
    public func pathBands(in frame: CGRect, step: Double) -> [(rect: CGRect, colorHex: String)] {
        guard case .path(let left, let right, let top, let bottom) = kind,
              frame.width > 0, frame.height > 0 else { return [] }
        func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
        let width = Double(frame.width), height = Double(frame.height)
        let minX = Double(frame.minX) + width * clamp(min(left, right))
        let maxX = Double(frame.minX) + width * clamp(max(left, right))
        let minY = Double(frame.minY) + height * clamp(min(top, bottom))
        let maxY = Double(frame.minY) + height * clamp(max(top, bottom))
        let reach = max(minX - Double(frame.minX), Double(frame.maxX) - maxX,
                        minY - Double(frame.minY), Double(frame.maxY) - maxY)
        let count = min(256, max(1, Int((reach / max(step, 0.01)).rounded(.up))))
        return (1...count).reversed().map { index in
            let t = Double(index) / Double(count)
            let rect = CGRect(
                x: minX + (Double(frame.minX) - minX) * t,
                y: minY + (Double(frame.minY) - minY) * t,
                width: (maxX - minX) + (width - (maxX - minX)) * t,
                height: (maxY - minY) + (height - (maxY - minY)) * t
            )
            return (rect, colorHex(at: (Double(index) - 0.5) / Double(count)))
        }
    }

    private static func components(_ hex: String) -> [Double] {
        var text = hex
        if text.count == 6 { text = "FF" + text }
        guard text.count == 8, let raw = UInt32(text, radix: 16) else { return [1, 1, 1, 1] }
        return [24, 16, 8, 0].map { Double((raw >> UInt32($0)) & 0xFF) / 255 }
    }

    private static func hex(_ components: [Double]) -> String {
        components.map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
    }
}

extension CellStyle {
    /// Whether the cell has any fill: a colour, a pattern or a gradient.
    public var hasFill: Bool { fillColorHex != nil || fillPattern != nil || fillGradient != nil }

    /// Fills the cell with one colour, or with nothing for `nil`, dropping any
    /// pattern or gradient: what choosing a fill colour in the app means.
    public mutating func setSolidFill(_ hex: String?) {
        fillColorHex = hex
        fillPattern = nil
        fillGradient = nil
    }
}

#if canImport(CoreGraphics)
extension FillPatternType {
    /// A transparent tile `FillPattern.tileBits` bits square with the set bits
    /// in `ink`, `scale` pixels to a bit. Drawn into a context whose y axis
    /// runs down (`flipped`), a bitmap lands upside down, so its rows are
    /// laid out the other way to come out the right way up.
    public func tileImage(ink: CGColor, scale: Int, flipped: Bool = false) -> CGImage? {
        let bits = FillPattern.tileBits
        let side = bits * max(scale, 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let pixel = CGFloat(max(scale, 1))
        context.setFillColor(ink)
        for row in 0..<bits {
            for column in 0..<bits where isInked(column: column, row: row) {
                // A bitmap context's origin is its bottom-left corner.
                let y = flipped ? row : bits - 1 - row
                context.fill(CGRect(x: CGFloat(column) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel))
            }
        }
        return context.makeImage()
    }
}
#endif
