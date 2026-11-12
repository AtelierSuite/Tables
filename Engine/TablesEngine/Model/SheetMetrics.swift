import Foundation

/// Precomputed row and column offsets for a sheet, so scrolling and hit-testing
/// never walk the whole grid.
///
/// An axis whose lines are all the same size carries no offsets at all: a
/// hundred-thousand-row sheet is the ordinary case, and a running-total array
/// for it is close to a megabyte that pinch-zoom would rebuild on every frame.
/// Arithmetic answers the same questions there, and in O(1) rather than by
/// binary search. Offsets are only materialized once a sheet actually has
/// custom sizes or hidden lines on that axis.
///
/// Given the display's pixel scale, every row and column edge is rounded to
/// the nearest device pixel, so fills and lines land on whole pixels at any
/// zoom. Each edge is rounded on its own rather than each size, so the
/// rounding never adds up along a sheet.
public struct SheetMetrics: Equatable, Sendable {
    /// Running offsets with a final entry equal to the total, or nil while the
    /// axis is uniform.
    private var columnOffsets: [Double]?
    private var rowOffsets: [Double]?
    /// The size every line on a uniform axis has, zoom already applied.
    private var uniformColumnWidth: Double = 0
    private var uniformRowHeight: Double = 0

    public private(set) var columnCount = 0
    public private(set) var rowCount = 0

    public var totalWidth: Double { columnOffsets?.last ?? uniformOffset(columnCount, size: uniformColumnWidth) }
    public var totalHeight: Double { rowOffsets?.last ?? uniformOffset(rowCount, size: uniformRowHeight) }

    /// The pinch-zoom factor already baked into these offsets.
    public private(set) var zoom: Double = 1

    /// Device pixels to a point of these offsets, which edges and lines are
    /// snapped to, or nil to leave them where they fall, as on paper or
    /// when working out where something sits in a file.
    public private(set) var pixelScale: Double?

    public init() {}

    public init(sheet: Worksheet, zoom: Double = 1, pixelScale: Double? = nil) {
        self.zoom = zoom
        self.pixelScale = pixelScale.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        columnCount = sheet.columnCount
        rowCount = sheet.rowCount

        if sheet.hasUniformColumnWidths {
            uniformColumnWidth = Worksheet.defaultColumnWidth * zoom
        } else {
            columnOffsets = offsets(count: sheet.columnCount, zoom: zoom, size: sheet.width(ofColumn:))
        }
        if sheet.hasUniformRowHeights {
            uniformRowHeight = sheet.standardRowHeight * zoom
        } else {
            rowOffsets = offsets(count: sheet.rowCount, zoom: zoom, size: sheet.height(ofRow:))
        }
    }

    /// Running totals with the zoom folded in as they are built, rather than
    /// mapped over a second array afterwards. The total runs on unrounded,
    /// and only the offset stored is snapped.
    private func offsets(count: Int, zoom: Double, size: (Int) -> Double) -> [Double] {
        var offsets: [Double] = [0]
        offsets.reserveCapacity(count + 1)
        var running: Double = 0
        for index in 0..<count {
            running += size(index) * zoom
            offsets.append(snapped(running))
        }
        return offsets
    }

    /// A position rounded to the nearest device pixel, or as it is when
    /// nothing is snapped.
    public func snapped(_ position: Double) -> Double {
        guard let pixelScale else { return position }
        return (position * pixelScale).rounded() / pixelScale
    }

    /// The start of line `index` on a uniform axis.
    private func uniformOffset(_ index: Int, size: Double) -> Double {
        snapped(Double(index) * size)
    }

    public func x(ofColumn column: Int) -> Double {
        let index = min(max(0, column), columnCount)
        guard let columnOffsets else { return uniformOffset(index, size: uniformColumnWidth) }
        return columnOffsets[min(index, columnOffsets.count - 1)]
    }

    public func y(ofRow row: Int) -> Double {
        let index = min(max(0, row), rowCount)
        guard let rowOffsets else { return uniformOffset(index, size: uniformRowHeight) }
        return rowOffsets[min(index, rowOffsets.count - 1)]
    }

    public func width(ofColumn column: Int) -> Double {
        guard column >= 0, column < columnCount else { return 0 }
        guard let columnOffsets else {
            return uniformOffset(column + 1, size: uniformColumnWidth) - uniformOffset(column, size: uniformColumnWidth)
        }
        return columnOffsets[column + 1] - columnOffsets[column]
    }

    public func height(ofRow row: Int) -> Double {
        guard row >= 0, row < rowCount else { return 0 }
        guard let rowOffsets else {
            return uniformOffset(row + 1, size: uniformRowHeight) - uniformOffset(row, size: uniformRowHeight)
        }
        return rowOffsets[row + 1] - rowOffsets[row]
    }

    public func frame(for address: CellAddress) -> CGRect {
        CGRect(
            x: x(ofColumn: address.column), y: y(ofRow: address.row),
            width: width(ofColumn: address.column), height: height(ofRow: address.row)
        )
    }

    public func frame(for range: CellRange) -> CGRect {
        let box = range.normalized
        let origin = CGPoint(x: x(ofColumn: box.start.column), y: y(ofRow: box.start.row))
        let corner = CGPoint(x: x(ofColumn: box.end.column) + width(ofColumn: box.end.column),
                             y: y(ofRow: box.end.row) + height(ofRow: box.end.row))
        return CGRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
    }

    /// Columns intersecting a horizontal span, with a little overscan.
    public func columns(in span: ClosedRange<Double>, overscan: Int = 2) -> Range<Int> {
        guard columnCount > 0 else { return 0..<0 }
        let first = max(0, columnIndex(at: span.lowerBound) - overscan)
        let last = min(columnCount - 1, columnIndex(at: span.upperBound) + overscan)
        return first <= last ? first..<(last + 1) : 0..<0
    }

    /// Rows intersecting a vertical span, with a little overscan.
    public func rows(in span: ClosedRange<Double>, overscan: Int = 2) -> Range<Int> {
        guard rowCount > 0 else { return 0..<0 }
        let first = max(0, rowIndex(at: span.lowerBound) - overscan)
        let last = min(rowCount - 1, rowIndex(at: span.upperBound) + overscan)
        return first <= last ? first..<(last + 1) : 0..<0
    }

    /// Whether a point lies on the grid itself, rather than past its last
    /// row or column, where `row(atY:)` and `column(atX:)` would only clamp.
    public func contains(_ point: CGPoint) -> Bool {
        (0..<totalWidth).contains(point.x) && (0..<totalHeight).contains(point.y)
    }

    public func column(atX position: Double) -> Int {
        min(max(0, columnIndex(at: position)), max(0, columnCount - 1))
    }

    public func row(atY position: Double) -> Int {
        min(max(0, rowIndex(at: position)), max(0, rowCount - 1))
    }

    private func columnIndex(at position: Double) -> Int {
        guard let columnOffsets else { return uniformIndex(at: position, size: uniformColumnWidth) }
        return index(in: columnOffsets, at: position)
    }

    private func rowIndex(at position: Double) -> Int {
        guard let rowOffsets else { return uniformIndex(at: position, size: uniformRowHeight) }
        return index(in: rowOffsets, at: position)
    }

    private func uniformIndex(at position: Double, size: Double) -> Int {
        guard size > 0, position > 0 else { return 0 }
        var index = Int(position / size)
        // A snapped edge is up to half a pixel from where it would fall.
        guard pixelScale != nil else { return index }
        while index > 0, uniformOffset(index, size: size) > position { index -= 1 }
        while uniformOffset(index + 1, size: size) <= position { index += 1 }
        return index
    }

    /// Index of the last offset less than or equal to `position`.
    private func index(in offsets: [Double], at position: Double) -> Int {
        var low = 0
        var high = offsets.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= position { low = middle } else { high = middle - 1 }
        }
        return low
    }
}
