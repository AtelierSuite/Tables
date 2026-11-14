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
    /// Under automatic alignment text runs the way it reads, so Arabic or
    /// Hebrew, set from the right, runs left.
    /// A cell holding only formatting counts as empty, as in Excel.
    ///
    /// `reach` bounds the search, so a long title on an empty sheet does not
    /// walk across thousands of columns; past a screen's width there is
    /// nothing left to show anyway.
    public func overflowSpan(of address: CellAddress, reach: Int = 24) -> ClosedRange<Int>? {
        overflowSpan(of: address, reach: reach, isMerged: isMerged)
    }

    /// `overflowSpan(of:reach:)`, finding merges through a lookup built from
    /// this version of the sheet rather than walking them at every step.
    public func overflowSpan(of address: CellAddress, reach: Int = 24, lookup: SheetLookup) -> ClosedRange<Int>? {
        overflowSpan(of: address, reach: reach, isMerged: lookup.merges.contains)
    }

    private func overflowSpan(
        of address: CellAddress, reach: Int, isMerged: (CellAddress) -> Bool
    ) -> ClosedRange<Int>? {
        guard let cell = cells[address], !cell.value.isEmpty else { return nil }
        let style = cell.style
        guard !style.wrapsText, !style.spreadsText, !style.isTextStacked, style.rotationDegrees == 0,
              !isMerged(address) else { return nil }
        // Text centred across a selection runs over that selection, numbers
        // included, and on from it like any centred text.
        let selection = centerAcrossSpan(of: address, isMerged: isMerged)
        guard case .text(let text) = cell.value, !text.isEmpty, !style.shrinksToFit else { return selection }

        func open(_ column: Int) -> Bool {
            guard column >= 0, column < columnCount else { return false }
            let neighbour = CellAddress(row: address.row, column: column)
            if let other = cells[neighbour], !other.isBlank { return false }
            return !isMerged(neighbour)
        }

        let alignment = CellFormatter.alignment(for: cell)
        var lower = address.column
        var upper = selection?.upperBound ?? address.column
        if alignment != .trailing {
            while upper - address.column < reach, open(upper + 1) { upper += 1 }
        }
        if alignment != .leading {
            while address.column - lower < reach, open(lower - 1) { lower -= 1 }
        }
        return lower == upper ? nil : lower...upper
    }

    /// The columns a cell set to centre across selection centres its text
    /// across: its own and the empty cells after it set the same way, or
    /// `nil` when it is not set so or has nothing to centre.
    ///
    /// Excel centres the value over the cells the alignment was given to,
    /// as far as the next cell that holds something.
    public func centerAcrossSpan(of address: CellAddress, reach: Int = 24) -> ClosedRange<Int>? {
        centerAcrossSpan(of: address, reach: reach, isMerged: isMerged)
    }

    private func centerAcrossSpan(
        of address: CellAddress, reach: Int = 24, isMerged: (CellAddress) -> Bool
    ) -> ClosedRange<Int>? {
        let cell = self[address]
        guard cell.style.horizontalSpread == .centerAcrossSelection, !cell.value.isEmpty,
              !isMerged(address) else { return nil }
        var upper = address.column
        while upper - address.column < reach, upper + 1 < columnCount {
            let next = CellAddress(row: address.row, column: upper + 1)
            let other = self[next]
            guard other.isBlank, other.style.horizontalSpread == .centerAcrossSelection, !isMerged(next) else { break }
            upper += 1
        }
        return address.column...upper
    }

    /// The columns of `span` that text `textWidth` wide actually crosses,
    /// or `nil` when it stays inside its own cell.
    ///
    /// `overflowSpan` is only how far the text may run; a short word in a
    /// cell with empty neighbours fits where it is and leaves their
    /// gridlines alone. The text is placed in `column` as the renderers set
    /// it: inset by `padding` on both sides, `indent` more on the edge it is
    /// aligned to, and aligned to its own cell however far it runs.
    /// `alignment` is where the text actually sits, as
    /// `CellFormatter.alignment(for:)` resolves it; `.automatic` is taken
    /// as left.
    /// `columnWidth` gives the drawn width of each column of the span.
    /// Text centred across a selection is centred on `selection`, the
    /// columns `centerAcrossSpan` gives, rather than on `column`.
    /// Centred text takes no indent, as in Excel.
    public static func overflowReach(
        of column: Int, within span: ClosedRange<Int>, textWidth: Double,
        alignment: HorizontalTextAlignment, padding: Double, indent: Double = 0,
        selection: ClosedRange<Int>? = nil, columnWidth: (Int) -> Double
    ) -> ClosedRange<Int>? {
        guard span.contains(column) else { return nil }
        if let selection, selection.count > 1, span.contains(selection.lowerBound), span.contains(selection.upperBound) {
            return centeredReach(across: selection, within: span, textWidth: textWidth, padding: padding,
                                 columnWidth: columnWidth)
        }
        let width = columnWidth(column)
        let indent = alignment == .center ? 0 : indent
        let boxMin = padding + (alignment == .trailing ? 0 : indent)
        let boxMax = width - padding - (alignment == .trailing ? indent : 0)
        let textMin: Double
        let textMax: Double
        switch alignment {
        case .trailing:
            textMin = boxMax - textWidth
            textMax = boxMax
        case .center:
            textMin = (boxMin + boxMax - textWidth) / 2
            textMax = (boxMin + boxMax + textWidth) / 2
        case .automatic, .leading:
            textMin = boxMin
            textMax = boxMin + textWidth
        }

        // Out from the cell's own edges, one gridline at a time, for as long
        // as the text still reaches past the next one.
        var upper = column
        var edge = width
        while upper < span.upperBound, textMax > edge {
            upper += 1
            edge += columnWidth(upper)
        }
        var lower = column
        edge = 0
        while lower > span.lowerBound, textMin < edge {
            lower -= 1
            edge -= columnWidth(lower)
        }
        return lower == upper ? nil : lower...upper
    }

    /// `overflowReach` for text centred across `selection`: the columns
    /// from the first the text reaches into to the last.
    private static func centeredReach(
        across selection: ClosedRange<Int>, within span: ClosedRange<Int>, textWidth: Double, padding: Double,
        columnWidth: (Int) -> Double
    ) -> ClosedRange<Int>? {
        // Edges measured from the left of the span's first column.
        var lefts: [Int: Double] = [:]
        var edge = 0.0
        for column in span {
            lefts[column] = edge
            edge += columnWidth(column)
        }
        let selectionMin = lefts[selection.lowerBound]! + padding
        let selectionMax = lefts[selection.upperBound]! + columnWidth(selection.upperBound) - padding
        let middle = (selectionMin + selectionMax) / 2
        let textMin = middle - textWidth / 2
        let textMax = middle + textWidth / 2
        let reached = span.filter { column in
            let left = lefts[column]!
            return textMax > left && textMin < left + columnWidth(column)
        }
        guard let lower = reached.first, let upper = reached.last, lower != upper else { return nil }
        return lower...upper
    }

    private func isMerged(_ address: CellAddress) -> Bool {
        mergedRanges.contains { $0.contains(address) }
    }
}
