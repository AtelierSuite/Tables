import Foundation

/// The direction a cell's text reads in: OOXML's `readingOrder` on
/// `<alignment>`, whose raw values these are.
public enum ReadingOrder: Int, Hashable, Sendable, CaseIterable {
    /// Taken from the text itself: the direction of its first letter that
    /// has one, as the Unicode bidirectional algorithm finds it.
    case context = 0
    case leftToRight = 1
    case rightToLeft = 2

    /// The direction `text` is set in under this reading order.
    public func direction(of text: String) -> TextFitting.WritingDirection {
        switch self {
        case .context: return TextFitting.baseDirection(of: text)
        case .leftToRight: return .leftToRight
        case .rightToLeft: return .rightToLeft
        }
    }

    /// `text` as a renderer should be given it to set it in this reading
    /// order: each line led by the mark for its direction where the text
    /// would otherwise take the other one. Every renderer sets a line in
    /// the direction of its first strong character, which the mark is.
    public func directed(_ text: String) -> String {
        guard self != .context else { return text }
        let direction = self.direction(of: text)
        let mark = String(direction.mark)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                TextFitting.baseDirection(of: String(line)) == direction ? String(line) : mark + line
            }
            .joined(separator: "\n")
    }
}

extension Worksheet {
    /// Whether protecting the sheet keeps the cell at `address` from being
    /// changed. A cell with no format of its own is locked, as in Excel.
    public func isLocked(at address: CellAddress) -> Bool {
        cells[address]?.style.isLocked ?? true
    }

    /// Whether protecting the sheet hides the formula of the cell at `address`.
    public func isFormulaHidden(at address: CellAddress) -> Bool {
        cells[address]?.style.isFormulaHidden ?? false
    }
}
