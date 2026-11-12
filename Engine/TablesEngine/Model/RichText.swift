import Foundation

/// A cell's text as stretches that each have their own font: the bold word in
/// a sentence, the subscript in H₂O.
///
/// It rides beside the cell's value, which stays the plain text, so formulas,
/// find, sort and everything else that reads a value sees what it always did.
/// A cell whose text is all in the cell's own font has none.
public struct RichText: Hashable, Sendable {
    public var runs: [TextRun]

    public init(runs: [TextRun]) {
        self.runs = runs
    }

    /// The runs' text end to end: what the cell's value holds.
    public var plainText: String {
        runs.count == 1 ? runs[0].text : runs.map(\.text).joined()
    }

    /// `displayed` cut into pieces by the run each part of it belongs to.
    ///
    /// `displayed` is the text a renderer is about to measure or draw: the
    /// plain text itself, or its glyphs stacked one to a line. Whatever was
    /// added takes the font of the text it follows, so a stacked glyph's
    /// line break is set like the glyph.
    public func pieces(of displayed: String) -> [(text: String, font: RunFont?)] {
        var result: [(text: String, font: RunFont?)] = []
        var runIndex = 0
        // Scalars of the current run not yet matched.
        var pending = Substring.UnicodeScalarView()
        func advance() {
            while pending.isEmpty, runIndex < runs.count - 1 {
                runIndex += 1
                pending = runs[runIndex].text.unicodeScalars[...]
            }
        }
        if let first = runs.first { pending = first.text.unicodeScalars[...] }
        advance()

        var current = String.UnicodeScalarView()
        var currentRun = runIndex
        func flush() {
            guard !current.isEmpty, runs.indices.contains(currentRun) else { return }
            result.append((String(current), runs[currentRun].font))
            current = String.UnicodeScalarView()
        }
        for scalar in displayed.unicodeScalars {
            if pending.first == scalar {
                if currentRun != runIndex {
                    flush()
                    currentRun = runIndex
                }
                current.append(scalar)
                pending.removeFirst()
                advance()
            } else {
                // Added by the renderer: it stays with the text before it,
                // or with the first run when it leads the line.
                current.append(scalar)
            }
        }
        flush()
        return result
    }
}

/// One stretch of a cell's text.
public struct TextRun: Hashable, Sendable {
    public var text: String
    /// The font the run is set in, or nil for the cell's own.
    public var font: RunFont?

    public init(text: String, font: RunFont? = nil) {
        self.text = text
        self.font = font
    }
}

/// Where a run sits against the line: on it, raised or lowered.
public enum RunVerticalAlignment: String, Hashable, Sendable {
    case baseline, superscript, `subscript`

    /// How much of the font's size a raised or lowered run keeps.
    public static let scale = 0.7
    /// How far up a raised run's baseline moves, as a part of the full size.
    public static let raise = 0.33
    /// How far down a lowered run's baseline moves, as a part of the full size.
    public static let drop = 0.14
}

/// The font of one run. A run with a font takes nothing from the cell's but
/// what it leaves unsaid: its family, its size and its colour.
public struct RunFont: Hashable, Sendable {
    public var isBold = false
    public var isItalic = false
    public var isUnderlined = false
    public var isStruckThrough = false
    /// The family, or nil for the cell's.
    public var fontName: String?
    /// The size in points, or nil for the cell's.
    public var fontSize: Double?
    /// The colour as `AARRGGBB`, or nil for the cell's.
    public var colorHex: String?
    public var verticalAlignment: RunVerticalAlignment = .baseline
    /// The `<rPr>` the file described this font with, written back as it
    /// was: it can say more than is modelled here, such as a theme colour,
    /// a font scheme or a double underline.
    public var preservedXML: String?

    public init() {}

    /// The style a run in this font is drawn in, inside a cell styled `style`.
    public func applied(to style: CellStyle) -> CellStyle {
        var result = style
        result.isBold = isBold
        result.isItalic = isItalic
        result.isUnderlined = isUnderlined
        result.isStruckThrough = isStruckThrough
        if let fontName { result.fontName = fontName }
        if let fontSize { result.fontSize = fontSize }
        if let colorHex { result.textColorHex = colorHex }
        return result
    }

    /// The size the run's glyphs are drawn at given the size of its font:
    /// smaller when raised or lowered.
    public func glyphSize(of fontSize: Double) -> Double {
        verticalAlignment == .baseline ? fontSize : fontSize * RunVerticalAlignment.scale
    }

    /// How far above the line the run's baseline sits given the size of its
    /// font; negative for a lowered run.
    public func baselineOffset(of fontSize: Double) -> Double {
        switch verticalAlignment {
        case .baseline: return 0
        case .superscript: return fontSize * RunVerticalAlignment.raise
        case .subscript: return -fontSize * RunVerticalAlignment.drop
        }
    }
}

extension Cell {
    /// The cell's text cut into the pieces `displayed` is drawn in, each with
    /// the style of its run, or nil when the cell's text is all in one font.
    ///
    /// `displayed` is what `RichText.pieces(of:)` takes. A cell whose number
    /// format changes what its text shows as is drawn plain, since the runs
    /// no longer say which part is which.
    public func styledPieces(of displayed: String) -> [(text: String, style: CellStyle, font: RunFont?)]? {
        guard let richText, drawsRuns else { return nil }
        return richText.pieces(of: displayed).map { piece in
            (piece.text, piece.font?.applied(to: style) ?? style, piece.font)
        }
    }

    /// Whether the cell's text is drawn in runs: it has them, and its number
    /// format shows the text as it is.
    public var drawsRuns: Bool {
        guard let richText else { return false }
        return CellFormatter.displayText(for: self) == richText.plainText
    }
}
