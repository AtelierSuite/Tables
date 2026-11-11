import Foundation

// Which border is drawn on an edge two cells share, shared by every grid.
//
// A file can give both sides of one edge a border, A1 a bottom one and A2 a
// top one, as Excel's "All Borders" does. The two land on the same gridline,
// so drawing both doubles the line, and draws a thin rule over a thick one
// or through the gap of a double one when they differ. Each edge is resolved
// to one border instead, drawn by whichever of the two cells it came from.
//
// As in Excel, the heavier border wins. Between two of the same weight, the
// later cell's wins: the one below, or to the right.

extension BorderLineStyle {
    /// How heavy the rule reads, for deciding which of two borders on an edge
    /// wins: thickness first, then a double or solid rule over a broken one.
    public var weight: Int {
        switch self {
        case .hair: return 0
        case .dotted: return 1
        case .dashDotDot: return 2
        case .dashDot: return 3
        case .dashed: return 4
        case .thin: return 5
        case .slantDashDot: return 6
        case .mediumDashDotDot: return 7
        case .mediumDashDot: return 8
        case .mediumDashed: return 9
        case .medium: return 10
        case .double: return 11
        case .thick: return 12
        }
    }
}

extension BorderEdge {
    /// The edge across from this one, which a neighbour shares it as.
    public var opposite: BorderEdge {
        switch self {
        case .top: return .bottom
        case .leading: return .trailing
        case .bottom: return .top
        case .trailing: return .leading
        }
    }

    /// Whether the edge runs across the sheet, along a row.
    public var isHorizontal: Bool { self == .top || self == .bottom }
}

/// A stretch of border a cell or merge draws.
public struct DrawnBorder: Hashable, Sendable {
    public var edge: BorderEdge
    public var side: BorderSide
    /// The cells the stretch is an edge of: the whole cell or merge, or the
    /// columns of a merge a top or bottom stretch runs along, the rows of a
    /// leading or trailing one. Its frame is where `borderSegment` draws it.
    public var range: CellRange

    public init(edge: BorderEdge, side: BorderSide, range: CellRange) {
        self.edge = edge
        self.side = side
        self.range = range
    }
}

/// Resolves the borders of a part of a sheet, edge by edge.
///
/// Every edge is resolved a cell's length at a time: a merge's bottom edge
/// may meet a different neighbour under each of its columns. Where the edge
/// is a merge's, the merge as a whole is the cell on that side.
public struct BorderResolver: Sendable {
    public let sheet: Worksheet
    public let metrics: SheetMetrics
    /// The merges a cell asked about, or its neighbour, can be part of.
    private let merges: [CellRange]

    /// A resolver for the cells and merges in `area`, or in the whole sheet.
    /// Only the merges near `area` are looked through, so asking about a cell
    /// further away than its neighbours gives the wrong answer for a merge.
    public init(sheet: Worksheet, metrics: SheetMetrics, near area: CellRange? = nil) {
        self.sheet = sheet
        self.metrics = metrics
        let all = sheet.mergedRanges.map(\.normalized)
        if let area = area?.normalized, !all.isEmpty {
            let rows = metrics.rowsBordering(area.start.row..<(area.end.row + 1))
            let columns = metrics.columnsBordering(area.start.column..<(area.end.column + 1))
            if rows.isEmpty || columns.isEmpty {
                merges = all.filter { $0.intersects(area) }
            } else {
                let reach = CellRange(
                    start: CellAddress(row: rows.lowerBound, column: columns.lowerBound),
                    end: CellAddress(row: rows.upperBound - 1, column: columns.upperBound - 1)
                )
                merges = all.filter { $0.intersects(reach) }
            }
        } else {
            merges = all
        }
    }

    /// The cell or merge `address` is part of.
    public func region(containing address: CellAddress) -> CellRange {
        merges.first { $0.contains(address) } ?? CellRange(address)
    }

    /// The border a cell or merge gives its own `edge` where it runs along
    /// `line`, a column for a top or bottom edge and a row otherwise, before
    /// the neighbour across it has a say. A merge takes its borders from its
    /// top-left cell.
    public func assignedSide(_ edge: BorderEdge, of region: CellRange, at line: Int) -> BorderSide? {
        sheet.cells[region.start]?.style.borderSides[edge]
    }

    /// The border drawn on one cell's `edge` once its neighbour's is weighed
    /// against it, whichever of the two it came from.
    public func resolvedSide(_ edge: BorderEdge, of address: CellAddress) -> BorderSide? {
        let line = edge.isHorizontal ? address.column : address.row
        return resolve(edge, of: region(containing: address), at: line)?.side
    }

    /// The stretches of its edges a cell or merge draws: those where its
    /// border wins, joined where one border runs on across several lines.
    public func drawnBorders(of region: CellRange) -> [DrawnBorder] {
        let region = region.normalized
        var drawn: [DrawnBorder] = []
        for edge in BorderEdge.allCases {
            var run: (side: BorderSide, lines: ClosedRange<Int>)?
            func finish() {
                guard let current = run else { return }
                drawn.append(DrawnBorder(edge: edge, side: current.side, range: slice(of: region, along: edge, current.lines)))
                run = nil
            }
            for line in edge.isHorizontal ? region.columnRange : region.rowRange {
                // A hidden line has no length to draw, and doesn't break a run.
                guard size(of: line, across: edge) > 0 else { continue }
                // Without a border of its own, the region has nothing to draw.
                guard assignedSide(edge, of: region, at: line) != nil else {
                    finish()
                    continue
                }
                guard let resolved = resolve(edge, of: region, at: line), resolved.isOwn else {
                    finish()
                    continue
                }
                if let current = run, current.side == resolved.side {
                    run = (current.side, current.lines.lowerBound...line)
                } else {
                    finish()
                    run = (resolved.side, line...line)
                }
            }
            finish()
        }
        return drawn
    }

    /// The winning border on `region`'s `edge` along `line`, and whether it
    /// is `region`'s own, so `region` draws it.
    private func resolve(_ edge: BorderEdge, of region: CellRange, at line: Int) -> (side: BorderSide, isOwn: Bool)? {
        let own = assignedSide(edge, of: region, at: line)
        guard let across = neighbour(across: edge, of: region, at: line) else {
            return own.map { ($0, true) }
        }
        let other = assignedSide(edge.opposite, of: self.region(containing: across), at: line)
        switch (own, other) {
        case (nil, nil):
            return nil
        case let (own?, nil):
            return (own, true)
        case let (nil, other?):
            return (other, false)
        case let (own?, other?):
            if own.lineStyle.weight != other.lineStyle.weight {
                return own.lineStyle.weight > other.lineStyle.weight ? (own, true) : (other, false)
            }
            // The later cell wins: the neighbour across a bottom or trailing edge.
            return edge == .top || edge == .leading ? (own, true) : (other, false)
        }
    }

    /// The nearest cell with any size across `edge` from `region` along
    /// `line`, past hidden rows and columns, or nil at the sheet's end.
    private func neighbour(across edge: BorderEdge, of region: CellRange, at line: Int) -> CellAddress? {
        switch edge {
        case .top:
            var row = region.start.row - 1
            while row >= 0, metrics.height(ofRow: row) <= 0 { row -= 1 }
            return row >= 0 ? CellAddress(row: row, column: line) : nil
        case .bottom:
            var row = region.end.row + 1
            while row < metrics.rowCount, metrics.height(ofRow: row) <= 0 { row += 1 }
            return row < metrics.rowCount ? CellAddress(row: row, column: line) : nil
        case .leading:
            var column = region.start.column - 1
            while column >= 0, metrics.width(ofColumn: column) <= 0 { column -= 1 }
            return column >= 0 ? CellAddress(row: line, column: column) : nil
        case .trailing:
            var column = region.end.column + 1
            while column < metrics.columnCount, metrics.width(ofColumn: column) <= 0 { column += 1 }
            return column < metrics.columnCount ? CellAddress(row: line, column: column) : nil
        }
    }

    private func size(of line: Int, across edge: BorderEdge) -> Double {
        edge.isHorizontal ? metrics.width(ofColumn: line) : metrics.height(ofRow: line)
    }

    /// The part of `region` a stretch of its `edge` along `lines` belongs to.
    private func slice(of region: CellRange, along edge: BorderEdge, _ lines: ClosedRange<Int>) -> CellRange {
        edge.isHorizontal
            ? CellRange(
                start: CellAddress(row: region.start.row, column: lines.lowerBound),
                end: CellAddress(row: region.end.row, column: lines.upperBound)
            )
            : CellRange(
                start: CellAddress(row: lines.lowerBound, column: region.start.column),
                end: CellAddress(row: lines.upperBound, column: region.end.column)
            )
    }
}
