import Foundation

/// A sheet's filter: a header row with a button on each column, and the rows
/// below it, shown or hidden by what each column asks for.
public struct AutoFilter: Hashable, Sendable {
    /// The header row and the rows it filters.
    public var range: CellRange
    /// What each column asks for, keyed by its position in the range.
    public var columns: [Int: Criterion] = [:]
    /// Columns whose button the file hides, by position in the range.
    public var hiddenButtons: Set<Int> = []
    /// The rows this filter hides. They are in the sheet's `hiddenRows` too,
    /// which is what draws them hidden; being here is what tells them apart
    /// from rows hidden by hand.
    public var filteredRows: Set<Int> = []
    /// Those of `filteredRows` that were hidden by hand before the filter
    /// turned them away, and so stay hidden when it lets them back.
    public var rowsHiddenByHand: Set<Int> = []
    /// The filter's own `<sortState>`, as the file had it or as the last
    /// sort through the app left it.
    public var sortStateXML: String?
    /// The filter's `<extLst>`, kept as the file had it.
    public var extensionsXML: String?

    public init(range: CellRange) {
        self.range = range.normalized
    }

    /// How two values in a condition are compared.
    public enum Comparison: String, Hashable, Sendable, CaseIterable {
        case equal, notEqual, greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual
    }

    /// One comparison against a value. For `equal` and `notEqual` the value
    /// may hold Excel's wildcards, which is how "contains" is written.
    public struct Condition: Hashable, Sendable {
        public var comparison: Comparison
        public var value: String

        public init(_ comparison: Comparison, _ value: String) {
            self.comparison = comparison
            self.value = value
        }
    }

    /// A year, month, day or time a value list names in place of each date
    /// under it.
    public struct DateGroup: Hashable, Sendable {
        public enum Grouping: String, Hashable, Sendable {
            case year, month, day, hour, minute, second
        }

        public var grouping: Grouping
        public var year: Int
        public var month = 1
        public var day = 1
        public var hour = 0
        public var minute = 0
        public var second = 0
    }

    public enum Criterion: Hashable, Sendable {
        /// The values shown, as the cells display them, and whether blank
        /// cells are shown with them.
        case values(Set<String>, includesBlanks: Bool, dates: [DateGroup] = [])
        /// One or two conditions; both must hold, or either may.
        case conditions(Condition, Condition? = nil, matchesBoth: Bool = false)
        /// The largest or smallest values: so many of them, or so many percent.
        case top(count: Double, isPercent: Bool = false, isBottom: Bool = false)
        /// A filter Tables does not work out — by colour, by icon, or by a
        /// moving date — kept as the file had it.
        case kept(xml: String)
    }

    /// Whether any column asks for something.
    public var isFiltering: Bool { !columns.isEmpty }

    /// The rows under the header.
    public var dataRows: ClosedRange<Int>? {
        range.start.row < range.end.row ? (range.start.row + 1)...range.end.row : nil
    }

    /// The sheet column of a filter column, and back.
    public func sheetColumn(_ offset: Int) -> Int { range.start.column + offset }
    public func offset(ofSheetColumn column: Int) -> Int? {
        range.columnRange.contains(column) ? column - range.start.column : nil
    }

    /// Whether every criterion is one Tables can work out for itself.
    public var isEvaluable: Bool {
        columns.values.allSatisfy { if case .kept = $0 { false } else { true } }
    }
}

// MARK: - Matching

extension AutoFilter {
    /// What a cell shows, which is what a value list is matched against.
    static func text(of cell: Cell) -> String {
        CellFormatter.displayText(for: cell).trimmingCharacters(in: .whitespaces)
    }

    static func matches(_ condition: Condition, cell: Cell) -> Bool {
        let wanted = condition.value
        let shown = text(of: cell)
        // Excel writes "blank" as a single space.
        if wanted.trimmingCharacters(in: .whitespaces).isEmpty {
            switch condition.comparison {
            case .equal: return shown.isEmpty
            case .notEqual: return !shown.isEmpty
            default: return false
            }
        }
        let number = Double(wanted)
        switch condition.comparison {
        case .equal, .notEqual:
            let isEqual: Bool
            if let number, case .number(let value) = cell.value {
                isEqual = value == number || FormulaWildcard.matches(shown, pattern: wanted)
            } else {
                isEqual = FormulaWildcard.matches(shown, pattern: wanted)
            }
            return (condition.comparison == .equal) == isEqual
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            let order: ComparisonResult
            if let number {
                guard case .number(let value) = cell.value else { return false }
                order = value < number ? .orderedAscending : (value > number ? .orderedDescending : .orderedSame)
            } else {
                guard case .text(let value) = cell.value else { return false }
                order = FormulaComparison.compare(.text(value), .text(wanted))
            }
            switch condition.comparison {
            case .greaterThan: return order == .orderedDescending
            case .greaterThanOrEqual: return order != .orderedAscending
            case .lessThan: return order == .orderedAscending
            default: return order != .orderedDescending
            }
        }
    }

    static func matches(_ group: DateGroup, serial: Double) -> Bool {
        let date = FormulaDates.components(fromSerial: serial)
        let seconds = Int(((serial - serial.rounded(.down)) * 86_400).rounded())
        let parts = [date.year, date.month, date.day, seconds / 3_600, seconds / 60 % 60, seconds % 60]
        let wanted = [group.year, group.month, group.day, group.hour, group.minute, group.second]
        let depth: Int
        switch group.grouping {
        case .year: depth = 1
        case .month: depth = 2
        case .day: depth = 3
        case .hour: depth = 4
        case .minute: depth = 5
        case .second: depth = 6
        }
        return parts.prefix(depth).elementsEqual(wanted.prefix(depth))
    }

    /// The value the top or bottom so-many of a column reach down or up to.
    static func threshold(count: Double, isPercent: Bool, isBottom: Bool, among numbers: [Double]) -> Double? {
        guard !numbers.isEmpty else { return nil }
        let sorted = numbers.sorted(by: isBottom ? { $0 < $1 } : { $0 > $1 })
        let wanted = isPercent ? Int(Double(sorted.count) * count / 100) : Int(count)
        return sorted[min(max(wanted, 1), sorted.count) - 1]
    }
}

extension Worksheet {
    /// The rows of the filter's range that its columns turn away.
    func rowsFilteredOut(by filter: AutoFilter) -> Set<Int> {
        guard let rows = filter.dataRows else { return [] }
        var hidden: Set<Int> = []
        for (offset, criterion) in filter.columns {
            let column = filter.sheetColumn(offset)
            guard filter.range.columnRange.contains(column) else { continue }
            func cell(_ row: Int) -> Cell { self[CellAddress(row: row, column: column)] }
            switch criterion {
            case .values(let values, let includesBlanks, let dates):
                let wanted = Set(values.map { $0.lowercased() })
                for row in rows where !hidden.contains(row) {
                    let cell = cell(row)
                    let shown = AutoFilter.text(of: cell)
                    if shown.isEmpty {
                        if !includesBlanks { hidden.insert(row) }
                        continue
                    }
                    if wanted.contains(shown.lowercased()) { continue }
                    if case .number(let serial) = cell.value,
                       dates.contains(where: { AutoFilter.matches($0, serial: serial) }) { continue }
                    hidden.insert(row)
                }
            case .conditions(let first, let second, let matchesBoth):
                for row in rows where !hidden.contains(row) {
                    let cell = cell(row)
                    var passes = AutoFilter.matches(first, cell: cell)
                    if let second {
                        let other = AutoFilter.matches(second, cell: cell)
                        passes = matchesBoth ? passes && other : passes || other
                    }
                    if !passes { hidden.insert(row) }
                }
            case .top(let count, let isPercent, let isBottom):
                let numbers = rows.compactMap { row -> Double? in
                    if case .number(let value) = cell(row).value { return value }
                    return nil
                }
                let limit = AutoFilter.threshold(count: count, isPercent: isPercent, isBottom: isBottom, among: numbers)
                for row in rows where !hidden.contains(row) {
                    guard let limit, case .number(let value) = cell(row).value,
                          isBottom ? value <= limit : value >= limit else {
                        hidden.insert(row)
                        continue
                    }
                }
            case .kept:
                continue
            }
        }
        return hidden
    }

    /// Hides the rows the filter turns away and shows the ones it used to.
    /// Rows hidden by hand stay hidden.
    public mutating func applyAutoFilter() {
        guard var filter = autoFilter else { return }
        let byHand = hiddenRows.subtracting(filter.filteredRows)
            .union(filter.rowsHiddenByHand.intersection(hiddenRows))
        filter.filteredRows = rowsFilteredOut(by: filter)
        filter.rowsHiddenByHand = filter.filteredRows.intersection(byHand)
        hiddenRows = byHand.union(filter.filteredRows)
        autoFilter = filter
    }

    /// Puts a filter on `range`, its first row the header; nil takes the
    /// filter away and shows the rows it hid.
    public mutating func setAutoFilter(on range: CellRange?) {
        if let filter = autoFilter { hiddenRows.subtract(filter.filteredRows.subtracting(filter.rowsHiddenByHand)) }
        autoFilter = range.map { AutoFilter(range: $0) }
    }

    /// Sets what one filter column asks for, by sheet column; nil shows
    /// everything in it again.
    public mutating func setFilter(_ criterion: AutoFilter.Criterion?, forColumn column: Int) {
        guard let offset = autoFilter?.offset(ofSheetColumn: column) else { return }
        autoFilter?.columns[offset] = criterion
        applyAutoFilter()
    }

    /// Shows every row the filter hid, leaving its buttons in place.
    public mutating func clearFilterCriteria() {
        autoFilter?.columns = [:]
        applyAutoFilter()
    }

    /// The filter's criterion for a sheet column.
    public func filterCriterion(forColumn column: Int) -> AutoFilter.Criterion? {
        autoFilter.flatMap { filter in filter.offset(ofSheetColumn: column).flatMap { filter.columns[$0] } }
    }

    /// Whether a cell is one of the filter's header cells with a button.
    public func hasFilterButton(at address: CellAddress) -> Bool {
        guard let filter = autoFilter, address.row == filter.range.start.row,
              let offset = filter.offset(ofSheetColumn: address.column) else { return false }
        return !filter.hiddenButtons.contains(offset)
    }

    /// The distinct values a filter column shows in its list, in sorted
    /// order, and whether it has blank cells. Rows another column's
    /// criterion hides are left out, as in Excel.
    public func filterValues(forColumn column: Int) -> (values: [String], hasBlanks: Bool) {
        guard let filter = autoFilter, let rows = filter.dataRows,
              let offset = filter.offset(ofSheetColumn: column) else { return ([], false) }
        var others = filter
        others.columns[offset] = nil
        let hidden = rowsFilteredOut(by: others)
        var seen: Set<String> = []
        var found: [(key: CellValue, text: String)] = []
        var hasBlanks = false
        for row in rows where !hidden.contains(row) {
            let cell = self[CellAddress(row: row, column: column)]
            let shown = AutoFilter.text(of: cell)
            if shown.isEmpty {
                hasBlanks = true
            } else if seen.insert(shown.lowercased()).inserted {
                found.append((cell.value, shown))
            }
        }
        let order = FormulaArrays.stableSorted(
            found.indices.map { [CellValue.number(Double($0))] }, keys: [(found.map(\.key), 1)])
        let values = order.compactMap { line -> String? in
            guard case .number(let index) = line[0] else { return nil }
            return found[Int(index)].text
        }
        return (values, hasBlanks)
    }

    /// Moves the filter with rows or columns inserted or removed. A filter
    /// whose header row or every column went is dropped.
    mutating func shiftAutoFilter(
        _ operation: FormulaReferenceShifter.Operation, axis: FormulaReferenceShifter.Axis
    ) {
        guard var filter = autoFilter else { return }
        if case .translate = operation { return }
        let old = filter.range
        /// Where a set of rows lands; the sheet's own hidden rows have moved already.
        func moved(_ rows: Set<Int>) -> Set<Int> {
            guard axis == .row else { return rows }
            switch operation {
            case .insert(let index, let count): return Set(rows.map { $0 >= index ? $0 + count : $0 })
            case .remove(let removed):
                return Set(rows.filter { !removed.contains($0) }.map {
                    $0 > removed.upperBound ? $0 - removed.count : $0
                })
            case .translate: return rows
            }
        }
        filter.filteredRows = moved(filter.filteredRows)
        filter.rowsHiddenByHand = moved(filter.rowsHiddenByHand)
        if axis == .row, case .remove(let removed) = operation, removed.contains(old.start.row) {
            hiddenRows.subtract(filter.filteredRows.subtracting(filter.rowsHiddenByHand))
            autoFilter = nil
            return
        }
        guard let new = ConditionalRule.moved([old], operation, axis: axis).first else {
            hiddenRows.subtract(filter.filteredRows.subtracting(filter.rowsHiddenByHand))
            autoFilter = nil
            return
        }
        filter.range = new
        var lostCriterion = false
        if axis == .column, new.columnRange != old.columnRange {
            // Criteria follow their columns; one whose column went goes too.
            var columns: [Int: AutoFilter.Criterion] = [:]
            var hiddenButtons: Set<Int> = []
            for offset in 0..<old.columnRange.count {
                let column = old.start.column + offset
                let landed: Int?
                switch operation {
                case .insert(let index, let count): landed = column >= index ? column + count : column
                case .remove(let removed):
                    landed = removed.contains(column) ? nil : (column > removed.upperBound ? column - removed.count : column)
                case .translate: landed = column
                }
                guard let landed, new.columnRange.contains(landed) else {
                    if filter.columns[offset] != nil { lostCriterion = true }
                    continue
                }
                if let criterion = filter.columns[offset] { columns[landed - new.start.column] = criterion }
                if filter.hiddenButtons.contains(offset) { hiddenButtons.insert(landed - new.start.column) }
            }
            filter.columns = columns
            filter.hiddenButtons = hiddenButtons
        }
        if let xml = filter.sortStateXML, let root = try? XMLLite.parse(Data(xml.utf8)) {
            switch Self.shiftSortState(root, operation, axis: axis) {
            case nil: filter.sortStateXML = nil
            case true?: filter.sortStateXML = XMLLite.serialize(root) ?? xml
            case false?: break
            }
        }
        autoFilter = filter
        // A column that went takes its criterion with it, and the rows it hid show again.
        if lostCriterion { applyAutoFilter() }
    }
}
