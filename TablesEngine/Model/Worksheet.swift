import Foundation

/// One cell's stored content: either a literal value or a formula plus its cached result.
public struct Cell: Hashable, Sendable {
    public var value: CellValue = .empty
    public var formula: String?
    public var style: CellStyle = .default
    /// Set on a cell holding part of a neighbour's spilled array. The value is
    /// that formula's, not the cell's own: it does not block the spill, and it
    /// is cleared when the spill shrinks away.
    public var isSpilled = false
    /// For a legacy array formula, entered with Ctrl+Shift+Enter in Excel, the
    /// fixed block its result fills, counted from this cell.
    public var arrayExtent: ArrayExtent?
    /// For a formula whose function Tables can only approximate, a fingerprint
    /// of the inputs its saved result was worked out from. While they are
    /// unchanged that result — Excel's own — is kept.
    public var savedResultInputs: Int?

    public init(
        value: CellValue = .empty,
        formula: String? = nil,
        style: CellStyle = .default,
        isSpilled: Bool = false,
        arrayExtent: ArrayExtent? = nil,
        savedResultInputs: Int? = nil
    ) {
        self.value = value
        self.formula = formula
        self.style = style
        self.isSpilled = isSpilled
        self.arrayExtent = arrayExtent
        self.savedResultInputs = savedResultInputs
    }

    /// Marks a result read from a file, before its inputs have been seen.
    public static let unverifiedInputs = Int.min

    public var isBlank: Bool { value.isEmpty && formula == nil }
    public var isEmptyEntirely: Bool { isBlank && style.isDefault }

    /// What the formula bar shows and what the user edits.
    public var editableText: String {
        if let formula { return "=" + formula }
        switch value {
        case .empty: return ""
        case .number(let number): return CellValue.plainNumberString(number)
        case .text(let text): return text
        case .boolean(let flag): return flag ? "TRUE" : "FALSE"
        case .error(let error): return error.rawValue
        }
    }
}

/// The size of a legacy array formula's block.
public struct ArrayExtent: Hashable, Sendable {
    public var rows: Int
    public var columns: Int
}

/// The rows and columns at a Numbers table's edges: its header rows at the
/// top, its footer rows at the bottom and its header columns at the left.
public struct TableEdges: Hashable, Sendable {
    public var headerRows = 0
    public var footerRows = 0
    public var headerColumns = 0
}

/// A single sheet of a workbook. Row and column counts are explicit, Numbers-style:
/// the grid never grows on its own, the user adds and removes rows and columns.
public struct Worksheet: Identifiable, Hashable, Sendable {
    public static let defaultRowCount = 20
    public static let defaultColumnCount = 5
    /// Geometry is in points throughout, matching OOXML's own unit for row
    /// heights, so a sheet sized here renders at the same size in Excel.
    ///
    /// 72pt ≈ 10.7 of Excel's character widths — wider than Excel's own 8.43
    /// default because our default font is 12pt rather than Calibri 11.
    ///
    /// Rows are 28pt rather than the 20pt that merely clears a 12pt line: a row
    /// is a touch target here, not just a line box, and 20pt is well under the
    /// 44pt a finger expects even before the text needs room to breathe.
    public static let defaultColumnWidth: Double = 72
    public static let defaultRowHeight: Double = 28
    /// Floors for the resize handles only. Imported sheets keep whatever the
    /// file said, however thin, because Excel users make spacer rows that way.
    public static let minimumColumnWidth: Double = 24
    public static let minimumRowHeight: Double = 12
    public static let maximumRowCount = 100_000
    public static let maximumColumnCount = 4_096

    /// Width in 96-dpi pixels of the "0" glyph in Excel's default font, which
    /// is the unit an OOXML `width` attribute counts.
    private static let maximumDigitWidth: Double = 7
    /// Cell padding Excel adds either side of the text, also in pixels.
    private static let columnPadding: Double = 5

    /// Converts an OOXML column width in characters to points.
    public static func columnWidthPoints(characters: Double) -> Double {
        (characters * maximumDigitWidth + columnPadding) * 0.75
    }

    /// The exact inverse of `columnWidthPoints(characters:)`, so a width that
    /// survives one save/open cycle survives every later one unchanged.
    public static func columnWidthCharacters(points: Double) -> Double {
        (points / 0.75 - columnPadding) / maximumDigitWidth
    }

    /// Characters Excel forbids in a sheet name. A workbook containing one is
    /// not merely odd — conforming readers reject the whole file.
    public static let forbiddenNameCharacters = CharacterSet(charactersIn: "\\/?*[]:")
    public static let maximumNameLength = 31
    /// Reserved by Excel for the change-tracking sheet.
    public static let reservedName = "History"

    /// Coerces any string into a name Excel will accept.
    public static func sanitizedName(_ candidate: String) -> String {
        var cleaned = candidate
            .components(separatedBy: forbiddenNameCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Leading and trailing apostrophes break quoted sheet references.
        while cleaned.hasPrefix("'") { cleaned.removeFirst() }
        while cleaned.hasSuffix("'") { cleaned.removeLast() }

        if cleaned.count > maximumNameLength {
            cleaned = String(cleaned.prefix(maximumNameLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.isEmpty || cleaned.compare(reservedName, options: .caseInsensitive) == .orderedSame {
            return "Sheet"
        }
        return cleaned
    }

    public var id = UUID()
    public var name: String
    public var cells: [CellAddress: Cell] = [:]
    public var rowCount: Int = Worksheet.defaultRowCount
    public var columnCount: Int = Worksheet.defaultColumnCount
    public var columnWidths: [Int: Double] = [:]
    public var rowHeights: [Int: Double] = [:]
    /// Rows whose height in `rowHeights` is one Excel fitted to their text
    /// rather than one somebody set. Excel only writes those down when the
    /// text needs more room than usual, so they are honoured — and written
    /// back as fitted, so Excel goes on fitting them.
    public var fittedRows: Set<Int> = []
    public var hiddenRows: Set<Int> = []
    public var hiddenColumns: Set<Int> = []
    /// Rows at the top and columns at the left that stay in view while the
    /// rest of the sheet scrolls — Excel's frozen panes. Zero for none.
    public var frozenRows = 0
    public var frozenColumns = 0
    /// Rectangular regions drawn, selected and edited as a single cell. They
    /// never overlap, and only the top-left cell of each keeps its content.
    public var mergedRanges: [CellRange] = []
    /// Sheets Excel marks `state="hidden"`: kept in the document, kept out of
    /// the tab strip.
    public var isHidden = false
    public var tabColorHex: String?
    /// The name the workbook's macros know this sheet by — `Sheet1` in
    /// `Sheet1.Range("A1")` — which stays put when the tab is renamed. It is
    /// what ties the sheet to its document module, so it has to survive a save
    /// for the macros to keep working.
    public var codeName: String?
    /// Worksheet children we do not understand, in the order the file had them.
    public var preservedElements: [PreservedElement] = []
    /// Where rows and columns were in the file, kept for a file saved by
    /// patching it; nil for every other.
    public var origins: SheetOrigins?
    /// For a table read from Numbers, its header and footer rows and its
    /// header columns, which Numbers leaves out of a whole column or row:
    /// `SUM(B:B)` there adds up the body alone. Nil for every other sheet.
    public var tableEdges: TableEdges?
    /// Where each array formula spilled at the last recalculation, by the
    /// address of the formula. Recalculation starts from this so that cells
    /// reading a spilled range see it on the first pass.
    public var spills: [CellAddress: CellRange] = [:]
    /// Notes and threaded comments, by the cell they belong to.
    public var comments: [CellAddress: CellComment] = [:]
    /// Shapes from the file's VML drawing that are neither notes nor form
    /// controls, carried verbatim into the drawing written with the notes.
    public var preservedVMLShapes: String?
    /// That drawing's own relationships, for the pictures those shapes show.
    public var preservedVMLRelationships: Data?

    /// A chart sheet holds one chart and no cells — Excel's "Move Chart to New
    /// Sheet". It is still a sheet: it takes a tab and a position, and
    /// workbook-level indices like a defined name's scope count it.
    public enum Kind: Hashable, Sendable {
        case worksheet
        case chart
    }

    public var kind: Kind = .worksheet
    /// Charts floating over the grid; a chart sheet's single chart is the first.
    public var charts: [Chart] = []
    /// Everything else the sheet's drawing held — pictures, shapes, charts we
    /// cannot model — carried through untouched.
    public var preservedDrawingAnchors: [PreservedDrawingAnchor] = []
    /// Buttons, check boxes and the other Form Controls, in drawing order.
    public var formControls: [FormControl] = []

    public var isChartSheet: Bool { kind == .chart }

    public init(name: String) {
        self.name = Self.sanitizedName(name)
    }

    // MARK: - Cell access

    public subscript(address: CellAddress) -> Cell {
        get { cells[address] ?? Cell() }
        set {
            if newValue.isEmptyEntirely {
                cells.removeValue(forKey: address)
            } else {
                cells[address] = newValue
            }
        }
    }

    public func contains(_ address: CellAddress) -> Bool {
        address.row >= 0 && address.row < rowCount
            && address.column >= 0 && address.column < columnCount
    }

    /// The addresses inside `range` the sheet actually holds a cell for.
    ///
    /// Anything an edit does to an address that is not in the dictionary — a
    /// clear, a merge's discard — is by definition a no-op, so an edit that
    /// only touches stored cells can ask for these instead of walking a range
    /// that a whole-sheet selection makes millions of addresses wide.
    public func storedAddresses(in range: CellRange) -> [CellAddress] {
        let box = range.normalized
        // Below this the range is narrower than the sheet is full, and probing
        // it directly beats a sweep of every cell the sheet holds.
        if box.cellCount < cells.count {
            var result: [CellAddress] = []
            box.forEachAddress { if cells[$0] != nil { result.append($0) } }
            return result
        }
        return cells.keys.filter { box.contains($0) }
    }

    // MARK: - Merged regions

    /// The merge covering an address, if any.
    public func mergedRange(containing address: CellAddress) -> CellRange? {
        // Sheets usually carry no merges at all, so the scan never starts.
        guard !mergedRanges.isEmpty else { return nil }
        return mergedRanges.first { $0.contains(address) }
    }

    /// Grows a range until it wholly contains every merge it touches, so a
    /// selection can never cut a merged region in half. Growing can reach a
    /// further merge, hence the loop.
    public func expandedToMerges(_ range: CellRange) -> CellRange {
        var box = range.normalized
        guard !mergedRanges.isEmpty else { return box }
        var grew = true
        while grew {
            grew = false
            for merge in mergedRanges where merge.intersects(box) && !box.contains(merge) {
                box = box.union(merge)
                grew = true
            }
        }
        return box
    }

    /// Records a merged region.
    ///
    /// A range that wholly covers existing merges absorbs them; one that only
    /// partly overlaps is rejected, because a half-covered merge has no sane
    /// meaning and Excel would refuse to open the file.
    @discardableResult
    public mutating func merge(_ range: CellRange) -> Bool {
        let box = range.normalized
        guard !box.isSingleCell, contains(box.start), contains(box.end) else { return false }
        guard mergedRanges.allSatisfy({ !$0.intersects(box) || box.contains($0) }) else { return false }
        mergedRanges.removeAll { box.contains($0) }
        mergedRanges.append(box)
        return true
    }

    /// Drops every merge the range touches.
    public mutating func unmerge(_ range: CellRange) {
        let box = range.normalized
        mergedRanges.removeAll { $0.intersects(box) }
    }

    // MARK: - Geometry

    public func width(ofColumn column: Int) -> Double {
        hiddenColumns.contains(column) ? 0 : (columnWidths[column] ?? Self.defaultColumnWidth)
    }

    public func height(ofRow row: Int) -> Double {
        hiddenRows.contains(row) ? 0 : (rowHeights[row] ?? Self.defaultRowHeight)
    }

    /// True while nothing on the axis departs from the default size, which lets
    /// the grid's geometry be arithmetic rather than a running-total array as
    /// long as a sheet's rows or columns are all alike.
    public var hasUniformColumnWidths: Bool { columnWidths.isEmpty && hiddenColumns.isEmpty }
    public var hasUniformRowHeights: Bool { rowHeights.isEmpty && hiddenRows.isEmpty }

    public var totalWidth: Double {
        guard !hasUniformColumnWidths else { return Double(columnCount) * Self.defaultColumnWidth }
        return (0..<columnCount).reduce(0) { $0 + width(ofColumn: $1) }
    }

    public var totalHeight: Double {
        guard !hasUniformRowHeights else { return Double(rowCount) * Self.defaultRowHeight }
        return (0..<rowCount).reduce(0) { $0 + height(ofRow: $1) }
    }

    // MARK: - Structure editing

    public mutating func addRows(_ count: Int) {
        let added = min(Self.maximumRowCount, rowCount + max(1, count)) - rowCount
        origins?.appendRows(added)
        rowCount += added
    }

    public mutating func addColumns(_ count: Int) {
        let added = min(Self.maximumColumnCount, columnCount + max(1, count)) - columnCount
        origins?.appendColumns(added)
        columnCount += added
    }

    /// The sheet's own references, which follow its rows and columns: those
    /// naming no sheet or this one. Other sheets' follow through the
    /// workbook.
    private var ownScope: FormulaReferenceShifter.Scope {
        FormulaReferenceShifter.Scope(sheet: name, host: name)
    }

    public mutating func insertRows(_ count: Int, at index: Int) {
        let count = max(1, count)
        guard rowCount + count <= Self.maximumRowCount else { return }
        FormulaReferenceShifter.apply(.insert(index: index, count: count), axis: .row, to: &cells, scope: ownScope)
        remapCells { $0.row >= index ? CellAddress(row: $0.row + count, column: $0.column) : $0 }
        rowHeights = Self.shift(rowHeights, from: index, by: count)
        fittedRows = Self.shift(fittedRows, from: index, by: count)
        hiddenRows = Self.shift(hiddenRows, from: index, by: count)
        remapMerges(along: \.row) { Self.span($0, insertingAt: index, count: count) }
        moveDrawings(.insert(index: index, count: count), axis: .row)
        origins?.insertRows(count, at: index, rowCount: rowCount)
        rowCount += count
        // Rows inserted among the frozen ones join them, as in Excel.
        if index < frozenRows { frozenRows += count }
    }

    public mutating func insertColumns(_ count: Int, at index: Int) {
        let count = max(1, count)
        guard columnCount + count <= Self.maximumColumnCount else { return }
        FormulaReferenceShifter.apply(.insert(index: index, count: count), axis: .column, to: &cells, scope: ownScope)
        remapCells { $0.column >= index ? CellAddress(row: $0.row, column: $0.column + count) : $0 }
        columnWidths = Self.shift(columnWidths, from: index, by: count)
        hiddenColumns = Self.shift(hiddenColumns, from: index, by: count)
        remapMerges(along: \.column) { Self.span($0, insertingAt: index, count: count) }
        moveDrawings(.insert(index: index, count: count), axis: .column)
        origins?.insertColumns(count, at: index, columnCount: columnCount)
        columnCount += count
        if index < frozenColumns { frozenColumns += count }
    }

    public mutating func removeRows(_ range: ClosedRange<Int>) {
        let count = range.count
        guard rowCount - count >= 1 else { return }
        FormulaReferenceShifter.apply(.remove(range: range), axis: .row, to: &cells, scope: ownScope)
        cells = cells.filter { !range.contains($0.key.row) }
        comments = comments.filter { !range.contains($0.key.row) }
        remapCells { $0.row > range.upperBound ? CellAddress(row: $0.row - count, column: $0.column) : $0 }
        rowHeights = Self.shift(rowHeights.filter { !range.contains($0.key) }, from: range.upperBound + 1, by: -count)
        fittedRows = Self.shift(fittedRows.filter { !range.contains($0) }, from: range.upperBound + 1, by: -count)
        hiddenRows = Self.shift(hiddenRows.filter { !range.contains($0) }, from: range.upperBound + 1, by: -count)
        remapMerges(along: \.row) { Self.span($0, removing: range) }
        moveDrawings(.remove(range: range), axis: .row)
        origins?.removeRows(range, rowCount: rowCount)
        rowCount -= count
        frozenRows -= Self.overlap(of: range, withFirst: frozenRows)
    }

    public mutating func removeColumns(_ range: ClosedRange<Int>) {
        let count = range.count
        guard columnCount - count >= 1 else { return }
        FormulaReferenceShifter.apply(.remove(range: range), axis: .column, to: &cells, scope: ownScope)
        cells = cells.filter { !range.contains($0.key.column) }
        comments = comments.filter { !range.contains($0.key.column) }
        remapCells { $0.column > range.upperBound ? CellAddress(row: $0.row, column: $0.column - count) : $0 }
        columnWidths = Self.shift(columnWidths.filter { !range.contains($0.key) }, from: range.upperBound + 1, by: -count)
        hiddenColumns = Self.shift(hiddenColumns.filter { !range.contains($0) }, from: range.upperBound + 1, by: -count)
        remapMerges(along: \.column) { Self.span($0, removing: range) }
        moveDrawings(.remove(range: range), axis: .column)
        origins?.removeColumns(range, columnCount: columnCount)
        columnCount -= count
        frozenColumns -= Self.overlap(of: range, withFirst: frozenColumns)
    }

    /// How many of the first `count` lines a removed range takes away.
    private static func overlap(of range: ClosedRange<Int>, withFirst count: Int) -> Int {
        guard count > 0, range.lowerBound < count else { return 0 }
        return min(range.upperBound, count - 1) - range.lowerBound + 1
    }

    public mutating func setRows(_ range: ClosedRange<Int>, hidden: Bool) {
        if hidden {
            hiddenRows.formUnion(range)
        } else {
            hiddenRows.subtract(range)
        }
    }

    public mutating func setColumns(_ range: ClosedRange<Int>, hidden: Bool) {
        if hidden {
            hiddenColumns.formUnion(range)
        } else {
            hiddenColumns.subtract(range)
        }
    }

    /// Reveals every hidden row and column.
    public mutating func unhideAll() {
        hiddenRows.removeAll()
        hiddenColumns.removeAll()
    }

    /// Moves cells, and the comments on them, to new addresses.
    private mutating func remapCells(_ transform: (CellAddress) -> CellAddress) {
        var moved: [CellAddress: Cell] = [:]
        moved.reserveCapacity(cells.count)
        for (address, cell) in cells { moved[transform(address)] = cell }
        cells = moved
        var movedComments: [CellAddress: CellComment] = [:]
        for (address, comment) in comments { movedComments[transform(address)] = comment }
        comments = movedComments
        // Where arrays spilled is worked out again on the next recalculation.
        spills = [:]
    }

    private static func shift(_ values: [Int: Double], from index: Int, by delta: Int) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for (key, value) in values { result[key >= index ? key + delta : key] = value }
        return result
    }

    private static func shift(_ values: Set<Int>, from index: Int, by delta: Int) -> Set<Int> {
        Set(values.map { $0 >= index ? $0 + delta : $0 })
    }

    /// Moves one axis of every merge through a structural edit. A merge left
    /// spanning a single cell is no longer a merge, so it is dropped.
    private mutating func remapMerges(
        along axis: WritableKeyPath<CellAddress, Int>,
        _ transform: (ClosedRange<Int>) -> ClosedRange<Int>?
    ) {
        guard !mergedRanges.isEmpty else { return }
        mergedRanges = mergedRanges.compactMap { merge in
            let box = merge.normalized
            guard let span = transform(box.start[keyPath: axis]...box.end[keyPath: axis]) else { return nil }
            var start = box.start
            var end = box.end
            start[keyPath: axis] = span.lowerBound
            end[keyPath: axis] = span.upperBound
            let moved = CellRange(start: start, end: end)
            return moved.isSingleCell ? nil : moved
        }
    }

    /// Carries the charts floating over the sheet with the cells beneath them.
    /// What they read from is the workbook's business, since a chart can
    /// read from any sheet.
    private mutating func moveDrawings(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis
    ) {
        guard !isChartSheet else { return }
        for index in charts.indices {
            charts[index].placement = charts[index].placement.shifted(operation, axis: axis)
        }
        for index in preservedDrawingAnchors.indices {
            preservedDrawingAnchors[index].shift(operation, axis: axis)
        }
        for index in formControls.indices {
            formControls[index].placement = formControls[index].placement.shifted(operation, axis: axis)
        }
    }

    /// Where a span lands when lines are inserted. Inserting inside a merge
    /// stretches it, the way Excel widens a merged heading you insert into.
    public static func span(
        _ span: ClosedRange<Int>, insertingAt index: Int, count: Int
    ) -> ClosedRange<Int> {
        if span.lowerBound >= index { return (span.lowerBound + count)...(span.upperBound + count) }
        if span.upperBound >= index { return span.lowerBound...(span.upperBound + count) }
        return span
    }

    /// Where a span lands once `removed` disappears, or nil when the removal
    /// takes every line the span covered.
    public static func span(
        _ span: ClosedRange<Int>, removing removed: ClosedRange<Int>
    ) -> ClosedRange<Int>? {
        let count = removed.count
        let start: Int
        if span.lowerBound < removed.lowerBound {
            start = span.lowerBound
        } else if span.lowerBound > removed.upperBound {
            start = span.lowerBound - count
        } else {
            // The span's own start went; it now begins where the gap closed.
            start = removed.lowerBound
        }
        let end: Int
        if span.upperBound < removed.lowerBound {
            end = span.upperBound
        } else if span.upperBound > removed.upperBound {
            end = span.upperBound - count
        } else {
            end = removed.lowerBound - 1
        }
        return start <= end ? start...end : nil
    }
}

// MARK: - Range geometry

extension CellRange {
    /// Parses OOXML's "A9:C9" — and a bare "A9" as a one-cell range.
    public init?(a1Range reference: String) {
        let parts = reference.split(separator: ":", maxSplits: 1)
        guard let first = parts.first, let start = CellAddress(a1: String(first)) else { return nil }
        if parts.count == 1 {
            self.init(start)
            return
        }
        guard let end = CellAddress(a1: String(parts[1])) else { return nil }
        self.init(start: start, end: end)
    }

    public func intersects(_ other: CellRange) -> Bool {
        let box = normalized
        let candidate = other.normalized
        return box.start.row <= candidate.end.row && box.end.row >= candidate.start.row
            && box.start.column <= candidate.end.column && box.end.column >= candidate.start.column
    }

    public func contains(_ other: CellRange) -> Bool {
        let box = normalized
        let candidate = other.normalized
        return candidate.start.row >= box.start.row && candidate.end.row <= box.end.row
            && candidate.start.column >= box.start.column && candidate.end.column <= box.end.column
    }

    /// The smallest range covering both — a bounding box, not a set union.
    public func union(_ other: CellRange) -> CellRange {
        let box = normalized
        let candidate = other.normalized
        return CellRange(
            start: CellAddress(
                row: min(box.start.row, candidate.start.row),
                column: min(box.start.column, candidate.start.column)
            ),
            end: CellAddress(
                row: max(box.end.row, candidate.end.row),
                column: max(box.end.column, candidate.end.column)
            )
        )
    }
}
