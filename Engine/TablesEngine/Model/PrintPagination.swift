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
        /// The title rows printed again above the page's cells, when the
        /// page starts below them.
        public var titleRows: Range<Int>?
        /// The title columns printed again to the left of the page's cells,
        /// when the page starts to their right.
        public var titleColumns: Range<Int>?
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

    /// Cuts each print area into pages of `pageSize`, one area after the
    /// other, as Excel prints several. A page that starts past the title
    /// rows or columns leaves room for them and names them, to be printed
    /// again beside its cells. A manual break starts a new page at its line.
    ///
    /// `range`, `rowBands` and `columnBands` describe the first area.
    public init(
        areas: [CellRange], metrics: SheetMetrics, pageSize: CGSize, titles: PrintTitles = PrintTitles(),
        rowBreaks: Set<Int> = [], columnBreaks: Set<Int> = []
    ) {
        let first = (areas.first ?? CellRange(CellAddress(row: 0, column: 0))).normalized
        range = first
        rowBands = []
        columnBands = []
        var pages: [Page] = []
        for (index, area) in (areas.isEmpty ? [first] : areas).enumerated() {
            let box = area.normalized
            let rows = Self.titledBands(
                of: box.start.row..<(box.end.row + 1), length: Double(pageSize.height), titles: titles.rows,
                breaks: rowBreaks, size: metrics.height(ofRow:))
            let columns = Self.titledBands(
                of: box.start.column..<(box.end.column + 1), length: Double(pageSize.width), titles: titles.columns,
                breaks: columnBreaks, size: metrics.width(ofColumn:))
            if index == 0 {
                rowBands = rows.bands
                columnBands = columns.bands
            }
            for columnBand in columns.bands {
                for rowBand in rows.bands {
                    let frame = metrics.frame(for: CellRange(
                        start: CellAddress(row: rowBand.lowerBound, column: columnBand.lowerBound),
                        end: CellAddress(row: rowBand.upperBound - 1, column: columnBand.upperBound - 1)))
                    pages.append(Page(
                        rows: rowBand, columns: columnBand, frame: frame,
                        titleRows: rows.titles.flatMap { rowBand.lowerBound >= $0.upperBound ? $0 : nil },
                        titleColumns: columns.titles.flatMap { columnBand.lowerBound >= $0.upperBound ? $0 : nil }))
                }
            }
        }
        self.pages = pages
    }

    /// The largest scale, of at most full size and in whole percent, at which
    /// every area fits `wide` pages across and `tall` pages down. Zero for
    /// either is as many pages as it takes. `pageSize` is one page at full
    /// size. Excel stops at 10%, and so does this.
    public static func fittedScale(
        areas: [CellRange], metrics: SheetMetrics, pageSize: CGSize, titles: PrintTitles = PrintTitles(),
        wide: Int, tall: Int
    ) -> Double {
        guard wide > 0 || tall > 0, pageSize.width > 0, pageSize.height > 0 else { return 1 }
        let boxes = areas.map(\.normalized)
        // No scale above this could fit: the lines' total length has to go
        // into the pages allowed.
        var percent = 100
        for box in boxes {
            let frame = metrics.frame(for: box)
            if wide > 0, frame.width > 0 {
                percent = min(percent, Int(Double(pageSize.width) * Double(wide) / Double(frame.width) * 100 + 1e-6))
            }
            if tall > 0, frame.height > 0 {
                percent = min(percent, Int(Double(pageSize.height) * Double(tall) / Double(frame.height) * 100 + 1e-6))
            }
        }
        percent = max(10, percent)
        while percent > 10 {
            let scale = Double(percent) / 100
            let fits = boxes.allSatisfy { box in
                let across = wide == 0 ? 0 : titledBands(
                    of: box.start.column..<(box.end.column + 1), length: Double(pageSize.width) / scale,
                    titles: titles.columns, breaks: [], size: metrics.width(ofColumn:)).bands.count
                let down = tall == 0 ? 0 : titledBands(
                    of: box.start.row..<(box.end.row + 1), length: Double(pageSize.height) / scale,
                    titles: titles.rows, breaks: [], size: metrics.height(ofRow:)).bands.count
                return across <= wide && down <= tall
            }
            if fits { break }
            percent -= 1
        }
        return Double(percent) / 100
    }

    /// Bands that leave room for the title lines on every page starting past
    /// them. Titles that would leave a page less than half its length are
    /// not repeated, and come back as nil.
    private static func titledBands(
        of lines: Range<Int>, length: Double, titles: ClosedRange<Int>?, breaks: Set<Int>, size: (Int) -> Double
    ) -> (bands: [Range<Int>], titles: Range<Int>?) {
        var repeated: Range<Int>?
        var extent = 0.0
        if let titles {
            let range = titles.lowerBound..<(titles.upperBound + 1)
            let total = range.reduce(0.0) { $0 + max(0, size($1)) }
            if total > 0, total <= length / 2 {
                repeated = range
                extent = total
            }
        }
        let bands = bands(of: lines, breaks: breaks, size: size) { start in
            if let repeated, start >= repeated.upperBound { return length - extent }
            return length
        }
        return (bands, repeated)
    }

    /// Gathers consecutive lines into runs no longer than `length`. A line
    /// longer than a page on its own gets a page to itself, cut off there;
    /// a hidden line, of no size, goes with the lines before it.
    public static func bands(of lines: Range<Int>, length: Double, size: (Int) -> Double) -> [Range<Int>] {
        bands(of: lines, breaks: [], size: size) { _ in length }
    }

    /// The same, with a new run started at each line in `breaks`, and each
    /// run's length asked for by the line it starts at.
    public static func bands(
        of lines: Range<Int>, breaks: Set<Int>, size: (Int) -> Double, length: (Int) -> Double
    ) -> [Range<Int>] {
        guard !lines.isEmpty else { return [] }
        var bands: [Range<Int>] = []
        var start = lines.lowerBound
        var used = 0.0
        var room = length(start)
        for line in lines {
            let extent = max(0, size(line))
            if line > start, (used + extent > room && extent > 0) || breaks.contains(line) {
                room = length(line)
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
