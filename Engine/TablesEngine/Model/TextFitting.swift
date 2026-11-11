import Foundation

/// How much of a cell's text fits in the box it is drawn in, shared by every
/// renderer so the grid, printing, Quick Look and the web app cut text short
/// in the same place.
///
/// The renderers measure; this decides what to measure against and which
/// candidates to try.
public enum TextFitting {
    /// What text cut short ends with.
    public static let ellipsis = "…"

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

    /// The longest start of `text` that `fits`, with an ellipsis, or `text`
    /// itself when it fits whole.
    ///
    /// Stacked text keeps one glyph per line, the ellipsis taking the last.
    /// Text cut short reads as longer than it shows, where text simply clipped
    /// reads as a shorter value. A binary search keeps this to a handful of
    /// measurements; `fits` is given each candidate as it would be drawn.
    ///
    /// The ellipsis follows the kept text in reading order, so text read
    /// right to left ends in one on its left. Each renderer sets a line in
    /// the direction of its first strong character, which a cut can take
    /// away — `"123 שלום"` cut to `"12…"` would turn to read left to right,
    /// its ellipsis on the right — so such a cut starts with the mark that
    /// keeps the direction of the whole text.
    public static func elided(_ text: String, stacked isStacked: Bool = false, fits: (String) -> Bool) -> String {
        let characters = Array(text)
        let direction = baseDirection(of: text)
        let render: ([Character], Bool) -> String = { glyphs, cut in
            let shown = glyphs.map(String.init) + (cut ? [ellipsis] : [])
            let joined = shown.joined(separator: isStacked ? "\n" : "")
            guard cut, !isStacked, baseDirection(of: joined) != direction else { return joined }
            return String(direction.mark) + joined
        }
        let whole = render(characters, false)
        if fits(whole) { return whole }
        var low = 0
        var high = characters.count - 1
        var best = render([], true)
        while low <= high {
            let middle = (low + high) / 2
            let candidate = render(Array(characters[0..<middle]), true)
            if fits(candidate) {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
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
