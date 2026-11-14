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
    /// The width gridlines are drawn at: a point, as a whole number of
    /// device pixels when they are snapped.
    public var gridLineWidth: Double { lineWidth(1) }

    /// A line width as a whole number of device pixels, and at least one, so
    /// a line is crisp and a hairline never fades at a low zoom. As it is
    /// when nothing is snapped.
    public func lineWidth(_ width: Double) -> Double {
        guard let pixelScale else { return width }
        return max(1, (width * pixelScale).rounded()) / pixelScale
    }

    /// The width a border's line is drawn at, at this zoom.
    public func lineWidth(of style: BorderLineStyle) -> Double {
        lineWidth(style.lineWidth * zoom)
    }

    /// How far each pass of a border is moved off its gridline: none for a
    /// single line, and either side for a double rule, kept at least a
    /// pixel apart so the two never run together.
    public func passOffsets(of style: BorderLineStyle) -> [Double] {
        guard let gap = style.doubleLineGap else { return [0] }
        var spread = gap * zoom
        if let pixelScale {
            let width = lineWidth(of: style) * pixelScale
            spread = max((spread * pixelScale).rounded(), width + 1) / pixelScale
        }
        return [-spread / 2, spread / 2]
    }

    /// The trailing and bottom gridlines of a cell or merge, as pairs of
    /// ends, held a half-width inside it so a line on the edge of a part
    /// drawn is drawn whole by the part that owns it. Text running on into
    /// the next cell leaves out the trailing one. None at all on a sheet
    /// whose gridlines are turned off.
    public func gridLines(of frame: CGRect, openEdge: Bool = false) -> [(CGPoint, CGPoint)] {
        guard showsGridLines else { return [] }
        let width = gridLineWidth
        let inset = width / 2
        let minX = snapped(frame.minX), maxX = snapped(frame.maxX)
        let minY = snapped(frame.minY), maxY = snapped(frame.maxY)
        let bottom = (CGPoint(x: minX, y: maxY - inset), CGPoint(x: openEdge ? maxX : maxX - width, y: maxY - inset))
        guard !openEdge else { return [bottom] }
        return [(CGPoint(x: maxX - inset, y: minY), CGPoint(x: maxX - inset, y: maxY)), bottom]
    }

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
    ///
    /// When edges are snapped, the line is moved by under a pixel so both its
    /// sides fall on whole device pixels; `lineWidth` should then be one
    /// `lineWidth(_:)` gave.
    public func borderSegment(
        _ edge: BorderEdge, of frame: CGRect, lineWidth: Double, offset: Double = 0, shown: CGRect? = nil
    ) -> (CGPoint, CGPoint) {
        // Worked in device pixels, from edges rounded to whole ones, so the
        // two cells either side of an edge come to exactly the same line.
        let unit = pixelScale ?? 1
        let snaps = pixelScale != nil
        func pixels(_ position: Double) -> Double { snaps ? (position * unit).rounded() : position * unit }
        let half = lineWidth * unit / 2
        let inset = gridLineWidth * unit / 2
        let offset = offset * unit
        /// Where a line meant to be centred on `centre` goes, so that both
        /// its sides land on pixel boundaries.
        func centred(_ centre: Double) -> Double { snaps ? (centre - half).rounded() + half : centre }

        // A double rule's passes sit either side of the line, unless the line
        // is held inside the cell, which pushes both of them in.
        let inward = half + offset + abs(offset)
        let outward = -half + offset - abs(offset)
        let shown = shown ?? CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight)
        let minX = pixels(frame.minX), maxX = pixels(frame.maxX)
        let minY = pixels(frame.minY), maxY = pixels(frame.maxY)
        let atTop = minY <= pixels(shown.minY), atLeft = minX <= pixels(shown.minX)
        let atBottom = maxY >= pixels(shown.maxY), atRight = maxX >= pixels(shown.maxX)

        let left = atLeft ? minX : centred(minX - inset) - half
        let right = atRight ? maxX : centred(maxX - inset) + half
        let top = atTop ? minY : centred(minY - inset) - half
        let bottom = atBottom ? maxY : centred(maxY - inset) + half

        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x / unit, y: y / unit) }
        switch edge {
        case .top:
            let y = centred(atTop ? minY + inward : minY - inset + offset)
            return (point(left, y), point(right, y))
        case .bottom:
            let y = centred(atBottom ? maxY + outward : maxY - inset + offset)
            return (point(left, y), point(right, y))
        case .leading:
            let x = centred(atLeft ? minX + inward : minX - inset + offset)
            return (point(x, top), point(x, bottom))
        case .trailing:
            let x = centred(atRight ? maxX + outward : maxX - inset + offset)
            return (point(x, top), point(x, bottom))
        }
    }
}
