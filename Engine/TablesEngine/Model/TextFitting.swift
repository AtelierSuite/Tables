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
    public static func elided(_ text: String, stacked isStacked: Bool = false, fits: (String) -> Bool) -> String {
        let characters = Array(text)
        let render: ([Character], Bool) -> String = { glyphs, cut in
            let shown = glyphs.map(String.init) + (cut ? [ellipsis] : [])
            return shown.joined(separator: isStacked ? "\n" : "")
        }
        let whole = render(characters, false)
        if fits(whole) { return whole }
        var low = 0
        var high = characters.count - 1
        var best = ellipsis
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
}
