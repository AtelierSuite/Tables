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
