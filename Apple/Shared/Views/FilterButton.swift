import CoreGraphics
import TablesEngine

/// The button a filter puts on each of its header cells: where it sits in
/// the cell, and the arrow drawn in it.
enum FilterButton {
    /// The button's square, at the trailing end of the cell and against its
    /// bottom edge, as in Excel.
    static func frame(in cell: CGRect, zoom: Double) -> CGRect {
        let side = min(16 * zoom, cell.width - 2, cell.height - 2)
        guard side > 4 else { return .null }
        let inset = min(2 * zoom, (cell.height - side) / 2)
        return CGRect(x: cell.maxX - side - inset, y: cell.maxY - side - inset, width: side, height: side)
    }

    /// The downward arrow, for a view whose y axis runs down.
    static func arrow(in frame: CGRect) -> [CGPoint] {
        let half = frame.width * 0.22
        return [
            CGPoint(x: frame.midX - half, y: frame.midY - half / 2),
            CGPoint(x: frame.midX, y: frame.midY + half / 2),
            CGPoint(x: frame.midX + half, y: frame.midY - half / 2),
        ]
    }

    /// The cells of a sheet's filter that carry a button, among the given
    /// rows and columns, and whether each one's column is filtering.
    static func buttons(
        in sheet: Worksheet, rows: Range<Int>, columns: Range<Int>
    ) -> [(address: CellAddress, isActive: Bool)] {
        guard let filter = sheet.autoFilter, rows.contains(filter.range.start.row),
              !sheet.hiddenRows.contains(filter.range.start.row) else { return [] }
        return filter.range.columnRange.compactMap { column in
            let address = CellAddress(row: filter.range.start.row, column: column)
            guard columns.contains(column), !sheet.hiddenColumns.contains(column),
                  sheet.hasFilterButton(at: address) else { return nil }
            return (address, filter.columns[column - filter.range.start.column] != nil)
        }
    }
}
