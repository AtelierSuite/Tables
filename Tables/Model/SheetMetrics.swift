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
struct SheetMetrics: Equatable {
    /// Running offsets with a final entry equal to the total, or nil while the
    /// axis is uniform.
    private var columnOffsets: [Double]?
    private var rowOffsets: [Double]?
    /// The size every line on a uniform axis has, zoom already applied.
    private var uniformColumnWidth: Double = 0
    private var uniformRowHeight: Double = 0

    private(set) var columnCount = 0
    private(set) var rowCount = 0

    var totalWidth: Double { columnOffsets?.last ?? Double(columnCount) * uniformColumnWidth }
    var totalHeight: Double { rowOffsets?.last ?? Double(rowCount) * uniformRowHeight }

    /// The pinch-zoom factor already baked into these offsets.
    private(set) var zoom: Double = 1

    init() {}

    init(sheet: Worksheet, zoom: Double = 1) {
        self.zoom = zoom
        columnCount = sheet.columnCount
        rowCount = sheet.rowCount

        if sheet.hasUniformColumnWidths {
            uniformColumnWidth = Worksheet.defaultColumnWidth * zoom
        } else {
            columnOffsets = Self.offsets(count: sheet.columnCount, zoom: zoom, size: sheet.width(ofColumn:))
        }
        if sheet.hasUniformRowHeights {
            uniformRowHeight = Worksheet.defaultRowHeight * zoom
        } else {
            rowOffsets = Self.offsets(count: sheet.rowCount, zoom: zoom, size: sheet.height(ofRow:))
        }
    }

    /// Running totals with the zoom folded in as they are built, rather than
    /// mapped over a second array afterwards.
    private static func offsets(count: Int, zoom: Double, size: (Int) -> Double) -> [Double] {
        var offsets: [Double] = [0]
        offsets.reserveCapacity(count + 1)
        var running: Double = 0
        for index in 0..<count {
            running += size(index) * zoom
            offsets.append(running)
        }
        return offsets
    }

    func x(ofColumn column: Int) -> Double {
        let index = min(max(0, column), columnCount)
        guard let columnOffsets else { return Double(index) * uniformColumnWidth }
        return columnOffsets[min(index, columnOffsets.count - 1)]
    }

    func y(ofRow row: Int) -> Double {
        let index = min(max(0, row), rowCount)
        guard let rowOffsets else { return Double(index) * uniformRowHeight }
        return rowOffsets[min(index, rowOffsets.count - 1)]
    }

    func width(ofColumn column: Int) -> Double {
        guard column >= 0, column < columnCount else { return 0 }
        guard let columnOffsets else { return uniformColumnWidth }
        return columnOffsets[column + 1] - columnOffsets[column]
    }

    func height(ofRow row: Int) -> Double {
        guard row >= 0, row < rowCount else { return 0 }
        guard let rowOffsets else { return uniformRowHeight }
        return rowOffsets[row + 1] - rowOffsets[row]
    }

    func frame(for address: CellAddress) -> CGRect {
        CGRect(
            x: x(ofColumn: address.column), y: y(ofRow: address.row),
            width: width(ofColumn: address.column), height: height(ofRow: address.row)
        )
    }

    func frame(for range: CellRange) -> CGRect {
        let box = range.normalized
        let origin = CGPoint(x: x(ofColumn: box.start.column), y: y(ofRow: box.start.row))
        let corner = CGPoint(x: x(ofColumn: box.end.column) + width(ofColumn: box.end.column),
                             y: y(ofRow: box.end.row) + height(ofRow: box.end.row))
        return CGRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y)
    }

    /// Columns intersecting a horizontal span, with a little overscan.
    func columns(in span: ClosedRange<Double>, overscan: Int = 2) -> Range<Int> {
        guard columnCount > 0 else { return 0..<0 }
        let first = max(0, columnIndex(at: span.lowerBound) - overscan)
        let last = min(columnCount - 1, columnIndex(at: span.upperBound) + overscan)
        return first <= last ? first..<(last + 1) : 0..<0
    }

    /// Rows intersecting a vertical span, with a little overscan.
    func rows(in span: ClosedRange<Double>, overscan: Int = 2) -> Range<Int> {
        guard rowCount > 0 else { return 0..<0 }
        let first = max(0, rowIndex(at: span.lowerBound) - overscan)
        let last = min(rowCount - 1, rowIndex(at: span.upperBound) + overscan)
        return first <= last ? first..<(last + 1) : 0..<0
    }

    func column(atX position: Double) -> Int {
        min(max(0, columnIndex(at: position)), max(0, columnCount - 1))
    }

    func row(atY position: Double) -> Int {
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
        return Int(position / size)
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
