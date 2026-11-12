import Foundation

/// How a sheet is cut into printed pages: on row and column boundaries, so no
/// row or column is split between two pages, as Excel paginates.
///
/// The rows are gathered into bands that each fit the printable height, and
/// the columns into bands that each fit the printable width. Every pair of a
/// row band and a column band is a page, numbered down the rows first, then
/// across, which is Excel's default page order.
///
/// Sizes are in the metrics' own units, zoom applied, so the page size given
/// is what one page holds at the scale the sheet is printed at.
public struct PrintPagination: Equatable, Sendable {
    public struct Page: Equatable, Sendable {
        public var rows: Range<Int>
        public var columns: Range<Int>
        /// Where the page's cells lie on the sheet.
        public var frame: CGRect
    }

    /// The cells printed.
    public var range: CellRange
    /// The rows on each page, from the top.
    public var rowBands: [Range<Int>]
    /// The columns on each page, from the left.
    public var columnBands: [Range<Int>]
    /// Every page, in the order it prints.
    public var pages: [Page]

    /// Cuts `range` into pages of `pageSize`.
    public init(range: CellRange, metrics: SheetMetrics, pageSize: CGSize) {
        let box = range.normalized
        self.range = box
        rowBands = Self.bands(
            of: box.start.row..<(box.end.row + 1), length: Double(pageSize.height), size: metrics.height(ofRow:))
        columnBands = Self.bands(
            of: box.start.column..<(box.end.column + 1), length: Double(pageSize.width), size: metrics.width(ofColumn:))
        var pages: [Page] = []
        for columns in columnBands {
            for rows in rowBands {
                let frame = metrics.frame(for: CellRange(
                    start: CellAddress(row: rows.lowerBound, column: columns.lowerBound),
                    end: CellAddress(row: rows.upperBound - 1, column: columns.upperBound - 1)))
                pages.append(Page(rows: rows, columns: columns, frame: frame))
            }
        }
        self.pages = pages
    }

    /// Gathers consecutive lines into runs no longer than `length`. A line
    /// longer than a page on its own gets a page to itself, cut off there;
    /// a hidden line, of no size, goes with the lines before it.
    public static func bands(of lines: Range<Int>, length: Double, size: (Int) -> Double) -> [Range<Int>] {
        guard !lines.isEmpty else { return [] }
        var bands: [Range<Int>] = []
        var start = lines.lowerBound
        var used = 0.0
        for line in lines {
            let extent = max(0, size(line))
            if line > start, used + extent > length, extent > 0 {
                bands.append(start..<line)
                start = line
                used = 0
            }
            used += extent
        }
        bands.append(start..<lines.upperBound)
        return bands
    }

    /// What prints when no print area is set: from A1 to the last cell with
    /// anything in it, stretched to take in every object floating over the
    /// sheet, whose frames are given at the metrics' zoom. Nil for a sheet
    /// with nothing on it.
    public static func printedRange(of sheet: Worksheet, objectFrames: [CGRect], metrics: SheetMetrics) -> CellRange? {
        var last: CellAddress?
        for (address, cell) in sheet.cells where !cell.isEmptyEntirely {
            last = CellAddress(row: max(last?.row ?? 0, address.row), column: max(last?.column ?? 0, address.column))
        }
        for merge in sheet.mergedRanges {
            guard let end = last else { break }
            let box = merge.normalized
            if box.start.row <= end.row, box.start.column <= end.column {
                last = CellAddress(row: max(end.row, box.end.row), column: max(end.column, box.end.column))
            }
        }
        for frame in objectFrames where frame.width > 0 && frame.height > 0 {
            // The line an object's far edge sits on, not the one after it.
            let row = metrics.row(atY: max(0, Double(frame.maxY) - 0.5))
            let column = metrics.column(atX: max(0, Double(frame.maxX) - 0.5))
            last = CellAddress(row: max(last?.row ?? 0, row), column: max(last?.column ?? 0, column))
        }
        return last.map { CellRange(start: CellAddress(row: 0, column: 0), end: $0) }
    }
}
