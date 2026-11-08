import Foundation

extension Worksheet {
    /// How far a cell's text may spill past its own edges, as Excel lets it:
    /// the columns it may draw across, its own included, or `nil` when it
    /// stays inside its cell.
    ///
    /// Only text spills — Excel shows a number too wide for its cell as `###`
    /// rather than letting it run on — and only text set on one line: wrapped,
    /// rotated or stacked text, and anything merged, keep to their box.
    /// Left-aligned text runs right, right-aligned text left, centred text
    /// both ways, each across empty cells until something is in the way.
    /// A cell holding only formatting counts as empty, as in Excel.
    ///
    /// `reach` bounds the search, so a long title on an empty sheet does not
    /// walk across thousands of columns; past a screen's width there is
    /// nothing left to show anyway.
    public func overflowSpan(of address: CellAddress, reach: Int = 24) -> ClosedRange<Int>? {
        guard let cell = cells[address], case .text(let text) = cell.value, !text.isEmpty else { return nil }
        let style = cell.style
        guard !style.wrapsText, !style.isTextStacked, style.rotationDegrees == 0,
              !isMerged(address) else { return nil }

        func open(_ column: Int) -> Bool {
            guard column >= 0, column < columnCount else { return false }
            let neighbour = CellAddress(row: address.row, column: column)
            if let other = cells[neighbour], !other.isBlank { return false }
            return !isMerged(neighbour)
        }

        let alignment = style.horizontalAlignment == .automatic ? .leading : style.horizontalAlignment
        var lower = address.column
        var upper = address.column
        if alignment != .trailing {
            while upper - address.column < reach, open(upper + 1) { upper += 1 }
        }
        if alignment != .leading {
            while address.column - lower < reach, open(lower - 1) { lower -= 1 }
        }
        return lower == upper ? nil : lower...upper
    }

    private func isMerged(_ address: CellAddress) -> Bool {
        mergedRanges.contains { $0.contains(address) }
    }
}
