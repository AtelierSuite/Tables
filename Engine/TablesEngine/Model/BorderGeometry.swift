import Foundation

/// Where cell borders are drawn, shared by the iOS and Mac grids.
///
/// Excel draws a border centred on the gridline it replaces, so the borders
/// two neighbours give their shared edge land on the same line and read as
/// one. Gridlines run along each cell's trailing and bottom edge, a hairline's
/// half-width inside it, and borders follow them there.
///
/// Half of a centred border falls in the neighbouring cell, so whatever draws
/// part of the grid has to draw the borders of the cells around it too, and
/// draw them after every fill.
extension SheetMetrics {
    /// The width of the gridlines borders are centred on.
    public static let gridLineWidth: Double = 1

    /// `rows` widened by the nearest row with any height on either side: the
    /// rows whose borders reach into them.
    public func rowsBordering(_ rows: Range<Int>) -> Range<Int> {
        widened(rows, count: rowCount, size: height(ofRow:))
    }

    /// `columns` widened by the nearest column with any width on either side:
    /// the columns whose borders reach into them.
    public func columnsBordering(_ columns: Range<Int>) -> Range<Int> {
        widened(columns, count: columnCount, size: width(ofColumn:))
    }

    private func widened(_ lines: Range<Int>, count: Int, size: (Int) -> Double) -> Range<Int> {
        guard !lines.isEmpty else { return lines }
        var lower = lines.lowerBound - 1
        while lower >= 0, size(lower) <= 0 { lower -= 1 }
        var upper = lines.upperBound
        while upper < count, size(upper) <= 0 { upper += 1 }
        return max(lower, 0)..<min(upper + 1, count)
    }

    /// The two ends of a border along one edge of `frame`, a cell or a merge.
    ///
    /// The line is centred on the edge's gridline, and runs on across the
    /// gridlines at either end so the borders meeting at a corner close it.
    /// At the outside of the table, or of `shown` when only part of it is
    /// drawn, there is no neighbour to share the edge with, and the line is
    /// kept inside the cell. `offset` moves one pass of a double rule to
    /// either side.
    public func borderSegment(
        _ edge: BorderEdge, of frame: CGRect, lineWidth: Double, offset: Double = 0, shown: CGRect? = nil
    ) -> (CGPoint, CGPoint) {
        let half = lineWidth / 2
        let inset = Self.gridLineWidth / 2
        // A double rule's passes sit either side of the line, unless the line
        // is held inside the cell, which pushes both of them in.
        let inward = half + offset + abs(offset)
        let outward = -half + offset - abs(offset)
        let shown = shown ?? CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        let atTop = frame.minY <= shown.minY, atLeft = frame.minX <= shown.minX
        let atBottom = frame.maxY >= shown.maxY, atRight = frame.maxX >= shown.maxX

        let left = atLeft ? frame.minX : frame.minX - inset - half
        let right = atRight ? frame.maxX : frame.maxX - inset + half
        let top = atTop ? frame.minY : frame.minY - inset - half
        let bottom = atBottom ? frame.maxY : frame.maxY - inset + half

        switch edge {
        case .top:
            let y = atTop ? frame.minY + inward : frame.minY - inset + offset
            return (CGPoint(x: left, y: y), CGPoint(x: right, y: y))
        case .bottom:
            let y = atBottom ? frame.maxY + outward : frame.maxY - inset + offset
            return (CGPoint(x: left, y: y), CGPoint(x: right, y: y))
        case .leading:
            let x = atLeft ? frame.minX + inward : frame.minX - inset + offset
            return (CGPoint(x: x, y: top), CGPoint(x: x, y: bottom))
        case .trailing:
            let x = atRight ? frame.maxX + outward : frame.maxX - inset + offset
            return (CGPoint(x: x, y: top), CGPoint(x: x, y: bottom))
        }
    }
}
