import Foundation

/// How much room a cell's text has, shared by every renderer so the grid,
/// printing, Quick Look and the web app clip text in the same place.
///
/// The renderers measure; this decides what to measure against and where a
/// line too long for its room is drawn.
public enum TextFitting {
    /// The length a single line of text may run along its own baseline in a
    /// `box` it is turned `rotationDegrees` counter-clockwise inside.
    ///
    /// Upright text has the box's width. Turned a quarter either way it has
    /// the box's height. Between the two, the line and its `lineHeight` are
    /// turned together, and the line may be as long as keeps the box they
    /// cover inside `box` both across and down.
    public static func runLength(in box: CGSize, rotationDegrees: Double, lineHeight: Double) -> Double {
        let angle = rotationDegrees * .pi / 180
        // Snapped so 90° does not leave a cosine of 6e-17 to divide by.
        let snapped = { (value: Double) in abs(value) < 1e-12 ? 0 : abs(value) }
        let cosine = snapped(cos(angle))
        let sine = snapped(sin(angle))
        var length = Double.infinity
        if cosine > 0 { length = min(length, (box.width - lineHeight * sine) / cosine) }
        if sine > 0 { length = min(length, (box.height - lineHeight * cosine) / sine) }
        return max(length, 0)
    }

    /// The length the text of a cell styled `style` may run in `box`: along
    /// its baseline for upright or turned text, down the box for stacked text.
    public static func runLength(of style: CellStyle, in box: CGSize, lineHeight: Double) -> Double {
        style.isTextStacked ? box.height
            : runLength(in: box, rotationDegrees: style.rotationDegrees, lineHeight: lineHeight)
    }

    /// The glyphs of `text` one above the next, as stacked text is set.
    public static func stacked(_ text: String) -> String {
        text.map(String.init).joined(separator: "\n")
    }

    /// Where a line `length` long is drawn when only `shown` of it fits,
    /// `shown` being where the renderer aligned the part that does.
    ///
    /// Text too long for its cell is not cut short with an ellipsis but runs
    /// on and is clipped at the cell's edge, as Excel and Numbers clip it. So
    /// the line keeps the edge it is aligned to and runs past the other one:
    /// left-aligned text loses its right end, right-aligned text (and text
    /// read right to left, which sits right) its left, and centred text both.
    /// Turned text runs along its own baseline, so the renderer turns the
    /// result about the centre of `shown`.
    public static func clippedLine(
        _ shown: CGRect, length: Double, alignment: HorizontalTextAlignment
    ) -> CGRect {
        guard length > shown.width else { return shown }
        var line = shown
        line.size.width = length
        switch alignment {
        case .trailing: line.origin.x = shown.maxX - length
        case .center: line.origin.x = shown.midX - length / 2
        case .automatic, .leading: break
        }
        return line
    }

    // MARK: - Indent

    /// `box` with a cell's indent taken off it, `indent` wide: from the edge
    /// the text is aligned to, from both edges for distributed text, and not
    /// at all for centred or justified text, which Excel indents nowhere.
    public static func indented(
        _ box: CGRect, by indent: Double, alignment: HorizontalTextAlignment, spread: HorizontalTextSpread?
    ) -> CGRect {
        guard indent > 0 else { return box }
        var box = box
        switch spread {
        case .distributed: return box.insetBy(dx: indent, dy: 0)
        case .justify, .centerAcrossSelection: return box
        case nil: break
        }
        switch alignment {
        case .center: return box
        case .trailing: box.size.width -= indent
        case .automatic, .leading:
            box.origin.x += indent
            box.size.width -= indent
        }
        return box
    }

    /// The scale shrink to fit sets text `width` wide in a box `room` wide
    /// at: 1 when it fits or the cell does not shrink its text.
    public static func shrinkScale(of style: CellStyle, width: Double, room: Double) -> Double {
        guard style.shrinksToFit, !style.wrapsText, !style.spreadsText, width > room, room > 0 else { return 1 }
        return room / width
    }

    // MARK: - Spread text

    /// A line of wrapped text: the UTF-16 range of `text` it shows, without
    /// the spaces it was broken at.
    public struct WrappedLine: Equatable, Sendable {
        public var range: Range<Int>
        /// Whether a line break or the end of the text follows it.
        public var endsParagraph: Bool
    }

    /// A stretch of text drawn on its own: its UTF-16 range and where its
    /// top-left corner goes, from the top-left of the cell's text box.
    public struct PlacedPiece: Equatable, Sendable {
        public var range: Range<Int>
        public var origin: CGPoint
    }

    /// `text` wrapped to `width`, broken at spaces and, for a word wider
    /// than the line, between characters. `measure` gives the width of a
    /// UTF-16 range of `text` as it is drawn. The web app's `wrapLines`
    /// breaks lines the same way.
    public static func wrappedLines(
        of text: String, width: Double, measure: (Range<Int>) -> Double
    ) -> [WrappedLine] {
        // Each character's UTF-16 start, with one past the last at the end.
        var starts: [Int] = []
        var kinds: [Character] = []
        var offset = 0
        for character in text {
            starts.append(offset)
            kinds.append(character)
            offset += character.utf16.count
        }
        starts.append(offset)

        var lines: [WrappedLine] = []
        var index = 0
        while index <= kinds.count {
            // One paragraph: up to the next line break.
            var end = index
            while end < kinds.count, !kinds[end].isNewline { end += 1 }
            var lineStart: Int?
            var lineEnd = index
            var cursor = index
            func push(_ start: Int, _ end: Int, last: Bool) {
                lines.append(WrappedLine(range: starts[start]..<starts[end], endsParagraph: last))
            }
            while cursor < end {
                if kinds[cursor].isWhitespace { cursor += 1; continue }
                var wordEnd = cursor
                while wordEnd < end, !kinds[wordEnd].isWhitespace { wordEnd += 1 }
                if let start = lineStart, measure(starts[start]..<starts[wordEnd]) > width {
                    push(start, lineEnd, last: false)
                    lineStart = cursor
                } else if lineStart == nil {
                    lineStart = cursor
                }
                lineEnd = wordEnd
                // A word wider than the line breaks between characters.
                while var start = lineStart, lineEnd - start > 1, measure(starts[start]..<starts[lineEnd]) > width {
                    var cut = lineEnd - 1
                    while cut > start + 1, measure(starts[start]..<starts[cut]) > width { cut -= 1 }
                    push(start, cut, last: false)
                    start = cut
                    lineStart = start
                }
                cursor = wordEnd
            }
            push(lineStart ?? index, lineStart == nil ? index : lineEnd, last: true)
            index = end + 1
        }
        return lines
    }

    /// Where each piece of `text` is drawn when its cell justifies or
    /// distributes it, across or down, in a text box `size` big: the text
    /// wrapped to the box's width, and its lines spread to its edges or set
    /// by `alignment` and `verticalAlignment` as `style` says.
    ///
    /// A line stretched across is drawn a word at a time, or for a single
    /// word a character at a time, with the space it is short of the box
    /// shared out evenly between them. Lines spread down share the height
    /// they do not fill between them. `alignment` is where the cell's text
    /// sits, as `CellFormatter.alignment(for:)` resolves it, and
    /// `rightToLeft` sets the words of a line from the right.
    public static func spreadPieces(
        of text: String, in size: CGSize, lineHeight: Double, style: CellStyle,
        alignment: HorizontalTextAlignment, rightToLeft: Bool, measure: (Range<Int>) -> Double
    ) -> [PlacedPiece] {
        let lines = wrappedLines(of: text, width: size.width, measure: measure)
        let count = Double(lines.count)
        let total = count * lineHeight
        var top: Double
        var leading = 0.0
        if style.verticalSpread != nil, lines.count > 1, size.height > total {
            top = 0
            leading = (size.height - total) / (count - 1)
        } else {
            switch style.verticalAlignment {
            case .top: top = 0
            case .middle: top = (size.height - total) / 2
            case .bottom: top = size.height - total
            }
            if style.verticalSpread != nil { top = max(top, 0) }
        }

        let characters = Array(text.utf16)
        var pieces: [PlacedPiece] = []
        for line in lines {
            defer { top += lineHeight + leading }
            guard !line.range.isEmpty else { continue }
            let width = measure(line.range)
            let parts = spreadParts(of: line, in: text, characters: characters, spread: style.horizontalSpread)
            if parts.count > 1, width < size.width {
                let extra = (size.width - width) / Double(parts.count - 1)
                for (index, part) in parts.enumerated() {
                    let before = measure(line.range.lowerBound..<part.lowerBound) + extra * Double(index)
                    let x = rightToLeft ? size.width - before - measure(part) : before
                    pieces.append(PlacedPiece(range: part, origin: CGPoint(x: x, y: top)))
                }
                continue
            }
            let x: Double
            switch lineAlignment(of: line, spread: style.horizontalSpread, alignment: alignment, rightToLeft: rightToLeft) {
            case .trailing: x = size.width - width
            case .center: x = (size.width - width) / 2
            case .automatic, .leading: x = 0
            }
            pieces.append(PlacedPiece(range: line.range, origin: CGPoint(x: x, y: top)))
        }
        return pieces
    }

    /// Where a line that is not stretched sits: a justified paragraph's last
    /// line at the side it is read from, a distributed line with nothing to
    /// spread in the middle, and anything else as its cell is aligned.
    private static func lineAlignment(
        of line: WrappedLine, spread: HorizontalTextSpread?, alignment: HorizontalTextAlignment, rightToLeft: Bool
    ) -> HorizontalTextAlignment {
        switch spread {
        case .justify: return rightToLeft ? .trailing : .leading
        case .distributed: return .center
        case .centerAcrossSelection: return .center
        case nil: return alignment
        }
    }

    /// The UTF-16 ranges a line is stretched between: its words, or the
    /// characters of a single word when distributed. A single range when
    /// the line is not stretched.
    private static func spreadParts(
        of line: WrappedLine, in text: String, characters: [UInt16], spread: HorizontalTextSpread?
    ) -> [Range<Int>] {
        let stretches = spread == .distributed || (spread == .justify && !line.endsParagraph)
        guard stretches else { return [line.range] }
        let lineText = String(decoding: characters[line.range], as: UTF16.self)
        var words: [Range<Int>] = []
        var letters: [Range<Int>] = []
        var offset = line.range.lowerBound
        var wordStart: Int?
        for character in lineText {
            let length = character.utf16.count
            if character.isWhitespace {
                if let start = wordStart { words.append(start..<offset) }
                wordStart = nil
            } else {
                if wordStart == nil { wordStart = offset }
                letters.append(offset..<offset + length)
            }
            offset += length
        }
        if let start = wordStart { words.append(start..<offset) }
        if words.count > 1 { return words }
        return spread == .distributed && letters.count > 1 ? letters : [line.range]
    }

    // MARK: - Direction

    /// Which way a run of text reads.
    public enum WritingDirection: Sendable {
        case leftToRight, rightToLeft

        /// The invisible mark that sets a line's direction when it leads it.
        var mark: Unicode.Scalar {
            self == .rightToLeft ? "\u{200F}" : "\u{200E}"
        }
    }

    /// The direction `text` reads in as a whole: that of its first letter
    /// with a direction of its own, as the Unicode bidirectional algorithm
    /// finds a paragraph's (rules P2 and P3). Digits, spaces and punctuation
    /// have none, and text with no letter at all reads left to right.
    ///
    /// Arabic and Hebrew read right to left, so a cell of either is set from
    /// the right the way Excel sets it under General alignment, and a line
    /// that opens in Hebrew stays right to left with English inside it.
    public static func baseDirection(of text: String) -> WritingDirection {
        var isolates = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            // Text inside an isolate does not set the paragraph's direction.
            case 0x2066...0x2068: isolates += 1; continue
            case 0x2069: isolates = max(isolates - 1, 0); continue
            default: break
            }
            guard isolates == 0, let direction = strongDirection(of: scalar) else { continue }
            return direction
        }
        return .leftToRight
    }

    /// The direction `scalar` sets, or `nil` for one that takes it from the
    /// text around it.
    ///
    /// The bidirectional classes are not in the standard library, so this
    /// takes letters as strong and reads their direction from the blocks the
    /// right-to-left scripts are encoded in: Hebrew, Arabic, Syriac, Thaana,
    /// N'Ko and their neighbours, their presentation forms, and the
    /// right-to-left ranges of the supplementary planes. Arabic-Indic digits
    /// are numbers there, so take their direction from the text around them.
    static func strongDirection(of scalar: Unicode.Scalar) -> WritingDirection? {
        switch scalar.value {
        case 0x200E: return .leftToRight
        case 0x200F, 0x061C: return .rightToLeft
        default: break
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: break
        default: return nil
        }
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
            return .rightToLeft
        default:
            return .leftToRight
        }
    }
}
