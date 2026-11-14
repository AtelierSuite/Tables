import Foundation

/// One level of a sort: the sheet column to order by, and which way.
public struct SortKey: Hashable, Sendable {
    public var column: Int
    public var isAscending: Bool

    public init(column: Int, isAscending: Bool = true) {
        self.column = column
        self.isAscending = isAscending
    }
}

/// The sort a sheet remembers: the rows it covered and the columns it went by.
public struct SortState: Hashable, Sendable {
    /// The sorted rows, without their header.
    public var range: CellRange
    public var keys: [SortKey]

    public init(range: CellRange, keys: [SortKey]) {
        self.range = range.normalized
        self.keys = keys
    }
}

public enum SortFailure: Error, Hashable, Sendable {
    /// Rows holding merged cells cannot change places.
    case mergedCells
    /// Rows holding part of an array formula's block cannot change places.
    case arrayFormula
}

extension Worksheet {
    /// Sorts the rows of `range` by one or more of its columns, the first key
    /// counting most. Cells move whole, with their style and their note, and
    /// a formula's relative references follow it to its new row. Numbers come
    /// before text before booleans before errors, and blanks always last.
    /// Rows that tie keep their order.
    public mutating func sortRows(in range: CellRange, by keys: [SortKey], hasHeader: Bool) throws(SortFailure) {
        let box = range.normalized
        let firstRow = box.start.row + (hasHeader ? 1 : 0)
        let keys = keys.filter { box.columnRange.contains($0.column) }
        guard firstRow < box.end.row, !keys.isEmpty else { return }
        let body = CellRange(start: CellAddress(row: firstRow, column: box.start.column), end: box.end)
        guard !mergedRanges.contains(where: { $0.intersects(body) }) else { throw .mergedCells }
        let stored = storedAddresses(in: body)
        guard !stored.contains(where: { cells[$0]?.arrayExtent != nil }) else { throw .arrayFormula }

        let rows = Array(firstRow...box.end.row)
        let order = FormulaArrays.stableSorted(
            rows.indices.map { [CellValue.number(Double($0))] },
            keys: keys.map { key in
                (rows.map { self[CellAddress(row: $0, column: key.column)].value }, key.isAscending ? 1 : -1)
            }
        ).map { line -> Int in
            guard case .number(let index) = line[0] else { return 0 }
            return rows[Int(index)]
        }
        guard order != rows else {
            rememberSort(SortState(range: body, keys: keys))
            return
        }

        var movedCells: [CellAddress: Cell] = [:]
        var movedComments: [CellAddress: CellComment] = [:]
        // Where each stored cell's row lands.
        var destination: [Int: Int] = [:]
        for (offset, source) in order.enumerated() { destination[source] = firstRow + offset }
        for address in stored {
            guard var cell = cells.removeValue(forKey: address), let row = destination[address.row] else { continue }
            // A spilled value is its formula's, and is worked out again.
            guard !cell.isSpilled else { continue }
            if let formula = cell.formula, row != address.row {
                cell.formula = FormulaReferenceShifter.translated(formula, rowDelta: row - address.row, columnDelta: 0)
            }
            movedCells[CellAddress(row: row, column: address.column)] = cell
        }
        for (address, comment) in comments where body.contains(address) {
            guard let row = destination[address.row] else { continue }
            comments.removeValue(forKey: address)
            movedComments[CellAddress(row: row, column: address.column)] = comment
        }
        cells.merge(movedCells) { _, new in new }
        comments.merge(movedComments) { _, new in new }
        spills = [:]
        rememberSort(SortState(range: body, keys: keys))
        // The rows a filter hides are the ones its criteria turn away, wherever
        // the sort put them.
        if autoFilter != nil { applyAutoFilter() }
    }

    /// The block of filled cells around `address`: what Excel sorts when one
    /// cell is selected. It grows while a neighbouring row or column holds
    /// anything.
    public func currentRegion(around address: CellAddress) -> CellRange {
        var box = CellRange(address)
        let filled = cells.filter { !$0.value.isBlank }.map(\.key)
        guard !filled.isEmpty else { return box }
        var changed = true
        while changed {
            changed = false
            for cell in filled where !box.contains(cell) {
                guard cell.row >= box.start.row - 1, cell.row <= box.end.row + 1,
                      cell.column >= box.start.column - 1, cell.column <= box.end.column + 1 else { continue }
                box = box.union(CellRange(cell))
                changed = true
            }
        }
        return box
    }

    /// Whether the first row of `range` reads as headings: text in every
    /// filled cell, over a row that is not all text.
    public func looksLikeHeader(firstRowOf range: CellRange) -> Bool {
        let box = range.normalized
        guard box.start.row < box.end.row else { return false }
        func values(_ row: Int) -> [CellValue] {
            box.columnRange.map { self[CellAddress(row: row, column: $0)].value }.filter { !$0.isEmpty }
        }
        func isText(_ value: CellValue) -> Bool { if case .text = value { true } else { false } }
        let first = values(box.start.row)
        guard !first.isEmpty, first.allSatisfy(isText) else { return false }
        return !values(box.start.row + 1).allSatisfy(isText)
    }
}

extension Workbook {
    /// The range a sort or a new filter takes from a selection, and whether
    /// its first row is a header. One cell stands for the table, the filter
    /// or the block of data around it; anything larger is taken as given.
    public func dataRange(for selection: CellRange, onSheetAt index: Int) -> (range: CellRange, hasHeader: Bool) {
        let sheet = sheets[index]
        let box = selection.normalized
        if let table = tables.first(where: { $0.sheetID == sheet.id && $0.range.contains(box) }),
           box.isSingleCell || table.range.normalized == box {
            var range = table.range.normalized
            range.end.row -= table.totalsRowCount
            return (range, table.headerRowCount > 0)
        }
        if let filter = sheet.autoFilter, filter.range.contains(box), box.isSingleCell {
            return (filter.range, true)
        }
        let range = box.isSingleCell ? sheet.currentRegion(around: box.start) : box
        if let filter = sheet.autoFilter, filter.range == range { return (range, true) }
        return (range, sheet.looksLikeHeader(firstRowOf: range))
    }
}

// MARK: - Sort state

extension SortState {
    /// The sort a `<sortState>` element remembers, when it is a plain sort of
    /// rows by their values.
    init?(element: XMLElement) {
        guard let ref = element.attribute("ref"), let range = CellRange(a1Range: ref),
              !["1", "true"].contains(element.attribute("columnSort") ?? "") else { return nil }
        var keys: [SortKey] = []
        for condition in element.children(named: "sortCondition") {
            guard let column = condition.attribute("ref").flatMap(CellRange.init(a1Range:))?.normalized.start.column,
                  condition.attribute("sortBy") == nil || condition.attribute("sortBy") == "value" else { return nil }
            keys.append(SortKey(
                column: column, isAscending: !["1", "true"].contains(condition.attribute("descending") ?? "")))
        }
        guard !keys.isEmpty else { return nil }
        self.init(range: range, keys: keys)
    }

    var xml: String {
        var xml = "<sortState ref=\"\(range.a1)\">"
        for key in keys {
            let column = CellRange(
                start: CellAddress(row: range.start.row, column: key.column),
                end: CellAddress(row: range.end.row, column: key.column))
            xml += "<sortCondition" + (key.isAscending ? "" : " descending=\"1\"") + " ref=\"\(column.a1)\"/>"
        }
        return xml + "</sortState>"
    }
}

extension Worksheet {
    /// The sort the sheet remembers: its filter's, or its own.
    public var sortState: SortState? {
        let xml = autoFilter?.sortStateXML ?? preservedElements.first { $0.name == "sortState" }?.xml
        guard let xml, let root = try? XMLLite.parse(Data(xml.utf8)) else { return nil }
        return SortState(element: root)
    }

    /// Records a sort so it is saved with the sheet: inside the filter when
    /// the sorted rows are the filter's, as Excel does, and on the sheet
    /// itself otherwise.
    mutating func rememberSort(_ state: SortState) {
        if let filter = autoFilter, let rows = filter.dataRows, filter.range.columnRange == state.range.columnRange,
           rows == state.range.rowRange {
            autoFilter?.sortStateXML = state.xml
            return
        }
        preservedElements.removeAll { $0.name == "sortState" }
        preservedElements.append(PreservedElement(name: "sortState", xml: state.xml))
    }
}
