import Foundation

/// Why a PivotTable could not be worked out again.
public enum PivotRefreshError: Error, Hashable, Sendable {
    /// The PivotTable or its cache is not in the workbook.
    case missing
    /// The source is not cells of this workbook.
    case externalSource
    /// The source range, name or table is no longer there.
    case sourceNotFound
    /// The source has a column without a heading.
    case headingMissing
    /// The PivotTable uses something a refresh does not work out.
    case unsupported(Feature)
    /// The PivotTable would grow over cells that hold something.
    case wouldOverwrite(CellRange)
    /// The PivotTable would grow past the edge of what a sheet can hold.
    case noRoom
    /// A part of the file could not be brought up to date.
    case unreadablePart

    public enum Feature: String, Hashable, Sendable {
        case calculatedFields, valuesOnRows, showValuesAs, customSubtotals
    }

    public var message: String {
        func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), bundle: .engine) }
        switch self {
        case .missing: return text("Pivot.Error.Missing")
        case .externalSource: return text("Pivot.Error.ExternalSource")
        case .sourceNotFound: return text("Pivot.Error.SourceNotFound")
        case .headingMissing: return text("Pivot.Error.HeadingMissing")
        case .unsupported: return text("Pivot.Error.Unsupported")
        case .wouldOverwrite(let range):
            return String(format: text("Pivot.Error.WouldOverwrite"), range.a1)
        case .noRoom: return text("Pivot.Error.NoRoom")
        case .unreadablePart: return text("Pivot.Error.UnreadablePart")
        }
    }
}

/// A PivotTable worked out from its cache: the cells it fills and the rows
/// and columns the file's definition lists.
public struct PivotLayout: Hashable, Sendable {
    /// The cells, row by row, from the PivotTable's top left corner.
    public var cells: [[PivotValue]]
    public var firstHeaderRow: Int
    public var firstDataRow: Int
    public var firstDataColumn: Int
    public var rowItems: [PivotParts.AxisItem]
    public var columnItems: [PivotParts.AxisItem]

    public var rowCount: Int { cells.count }
    public var columnCount: Int { cells.first?.count ?? 0 }
}

/// The running totals of one cell of a PivotTable.
struct PivotAccumulator {
    var count = 0
    var numbers = 0
    var sum = 0.0
    var squares = 0.0
    var product = 1.0
    var low = Double.infinity
    var high = -Double.infinity

    mutating func add(_ value: PivotValue) {
        if value != .blank { count += 1 }
        guard let number = value.number else { return }
        numbers += 1
        sum += number
        squares += number * number
        product *= number
        low = Swift.min(low, number)
        high = Swift.max(high, number)
    }

    func result(_ aggregation: PivotAggregation) -> PivotValue {
        let n = Double(numbers)
        func variance(sample: Bool) -> PivotValue {
            let divisor = sample ? n - 1 : n
            guard divisor > 0 else { return .error(CellError.divideByZero.rawValue) }
            return .number(Swift.max(0, (squares - sum * sum / n) / divisor))
        }
        func root(_ value: PivotValue) -> PivotValue {
            if case .number(let number) = value { return .number(number.squareRoot()) }
            return value
        }
        switch aggregation {
        case .sum: return .number(sum)
        case .count: return .number(Double(count))
        case .countNums: return .number(n)
        case .average: return numbers > 0 ? .number(sum / n) : .error(CellError.divideByZero.rawValue)
        case .max: return .number(numbers > 0 ? high : 0)
        case .min: return .number(numbers > 0 ? low : 0)
        case .product: return .number(numbers > 0 ? product : 0)
        case .var: return variance(sample: true)
        case .varp: return variance(sample: false)
        case .stdDev: return root(variance(sample: true))
        case .stdDevp: return root(variance(sample: false))
        }
    }
}

extension PivotValue {
    /// Whether `self` comes before `other` among a field's items: numbers,
    /// then text whatever its case, then true and false, then blanks.
    func isOrdered(before other: PivotValue) -> Bool {
        func rank(_ value: PivotValue) -> Int {
            switch value {
            case .number, .date: return 0
            case .text: return 1
            case .boolean: return 2
            case .error: return 3
            case .blank: return 4
            }
        }
        switch (self, other) {
        case (.text(let left), .text(let right)):
            let lower = left.lowercased(), upper = right.lowercased()
            return lower == upper ? left < right : lower < upper
        case (.boolean(let left), .boolean(let right)): return !left && right
        case (.error(let left), .error(let right)): return left < right
        default:
            if let left = number, let right = other.number { return left < right }
            return rank(self) < rank(other)
        }
    }
}

extension PivotTable {
    /// What stops the PivotTable being worked out, if anything does.
    public func blocker(in cache: PivotCache) -> PivotRefreshError? {
        guard case .worksheet = cache.source else { return .externalSource }
        if cache.fields.contains(where: \.isDerived) { return .unsupported(.calculatedFields) }
        if rowFields.contains(Self.valuesField) { return .unsupported(.valuesOnRows) }
        if dataFields.contains(where: { $0.showDataAs != nil }) { return .unsupported(.showValuesAs) }
        let placed = rowFields + columnFields
        if placed.contains(where: { fields.indices.contains($0) && fields[$0].hasCustomSubtotals }) {
            return .unsupported(.customSubtotals)
        }
        return nil
    }

    /// The value an item of a field stands for.
    func value(ofItem position: Int, field: Int, in cache: PivotCache) -> PivotValue {
        guard fields.indices.contains(field), fields[field].items.indices.contains(position),
              let shared = fields[field].items[position].sharedIndex,
              cache.fields[field].sharedItems.indices.contains(shared) else { return .blank }
        return cache.fields[field].sharedItems[shared]
    }

    /// Works the PivotTable out from the cache's records. The cache has to
    /// hold every placed field's values as shared items, and the fields'
    /// item lists have to cover them, as `Workbook.refreshPivotTable` sees to.
    public func layout(from cache: PivotCache) -> PivotLayout {
        let rows = rowFields.filter { $0 >= 0 }, columns = columnFields.filter { $0 >= 0 }
        let n = rows.count, m = columns.count, valueCount = dataFields.count
        let spread = Swift.max(valueCount, 1)
        let grandCaption = grandTotalCaption ?? "Grand Total"

        // Each field's items, by the value they stand for.
        var positions: [Int: [PivotValue: Int]] = [:]
        var hidden: [Int: Set<Int>] = [:]
        for (index, field) in fields.enumerated() where index < cache.fields.count {
            var lookup: [PivotValue: Int] = [:]
            for (position, item) in field.items.enumerated() {
                guard let shared = item.sharedIndex, cache.fields[index].sharedItems.indices.contains(shared) else { continue }
                lookup[cache.fields[index].sharedItems[shared].groupingKey] = position
                if item.isHidden { hidden[index, default: []].insert(position) }
            }
            positions[index] = lookup
        }
        var selected: [Int: Int] = [:]
        for filter in filters { if let item = filter.selectedItem { selected[filter.field] = item } }

        struct Key: Hashable {
            var row: [Int]
            var column: [Int]
        }
        var totals: [Key: [PivotAccumulator]] = [:]
        var rowPaths: Set<[Int]> = [], columnPaths: Set<[Int]> = []
        records: for record in cache.records {
            for (field, items) in hidden {
                if let position = positions[field]?[record[field].groupingKey], items.contains(position) { continue records }
            }
            for (field, item) in selected where positions[field]?[record[field].groupingKey] != item { continue records }
            var rowPath: [Int] = [], columnPath: [Int] = []
            for field in rows {
                guard let position = positions[field]?[record[field].groupingKey] else { continue records }
                rowPath.append(position)
            }
            for field in columns {
                guard let position = positions[field]?[record[field].groupingKey] else { continue records }
                columnPath.append(position)
            }
            rowPaths.insert(rowPath)
            columnPaths.insert(columnPath)
            for rowDepth in 0...n {
                for columnDepth in 0...m {
                    let key = Key(row: Array(rowPath[..<rowDepth]), column: Array(columnPath[..<columnDepth]))
                    var cell = totals[key] ?? [PivotAccumulator](repeating: PivotAccumulator(), count: valueCount)
                    for (index, data) in dataFields.enumerated() where record.indices.contains(data.field) {
                        cell[index].add(record[data.field])
                    }
                    totals[key] = cell
                }
            }
        }
        func sorted(_ paths: Set<[Int]>) -> [[Int]] { paths.sorted { $0.lexicographicallyPrecedes($1) } }
        func shared(_ left: [Int], _ right: [Int]) -> Int {
            var count = 0
            while count < left.count, count < right.count, left[count] == right[count] { count += 1 }
            return count
        }
        func label(_ field: Int, _ position: Int) -> PivotValue {
            let value = value(ofItem: position, field: field, in: cache)
            return value == .blank ? .text(Self.blankCaption) : value
        }
        func totalLabel(_ field: Int, _ position: Int, suffix: String = "Total") -> PivotValue {
            .text(label(field, position).label + " " + suffix)
        }

        // MARK: Rows

        struct Line {
            var path: [Int]
            var labels: [(column: Int, value: PivotValue)]
            var hasValues: Bool
            var item: PivotParts.AxisItem
        }
        /// The column each row field's labels are in: a compact field's
        /// successor shares its column.
        var labelColumn: [Int] = []
        for depth in 0..<n {
            guard depth > 0 else {
                labelColumn.append(0)
                continue
            }
            let outer = fields[rows[depth - 1]]
            labelColumn.append(labelColumn[depth - 1] + (outer.isCompact && outer.isOutline ? 0 : 1))
        }
        let labelColumns = n > 0 ? (labelColumn.last ?? 0) + 1 : (m > 0 ? 1 : 0)

        var lines: [Line] = []
        var pending: [(column: Int, value: PivotValue)] = []
        var previous: [Int] = []
        func emitRows(_ paths: ArraySlice<[Int]>, depth: Int) {
            var start = paths.startIndex
            while start < paths.endIndex {
                var end = start
                while end < paths.endIndex, paths[end][depth] == paths[start][depth] { end += 1 }
                let path = Array(paths[start][...depth])
                let field = fields[rows[depth]]
                let own = (column: labelColumn[depth], value: label(rows[depth], path[depth]))
                func item() -> PivotParts.AxisItem {
                    let repeated = Swift.min(shared(previous, path), path.count - 1)
                    previous = path
                    return PivotParts.AxisItem(repeated: repeated, indexes: Array(path[repeated...]))
                }
                func subtotal() {
                    lines.append(Line(
                        path: path, labels: [(labelColumn[depth], totalLabel(rows[depth], path[depth]))], hasValues: true,
                        item: PivotParts.AxisItem(kind: "default", repeated: depth, indexes: [path[depth]])))
                    previous = path
                }
                if depth == n - 1 {
                    lines.append(Line(path: path, labels: pending + [own], hasValues: true, item: item()))
                    pending = []
                } else if field.isOutline {
                    let onTop = field.hasDefaultSubtotal && field.subtotalOnTop
                    lines.append(Line(path: path, labels: pending + [own], hasValues: onTop, item: item()))
                    pending = []
                    emitRows(paths[start..<end], depth: depth + 1)
                    if field.hasDefaultSubtotal && !field.subtotalOnTop { subtotal() }
                } else {
                    pending.append(own)
                    emitRows(paths[start..<end], depth: depth + 1)
                    if field.hasDefaultSubtotal { subtotal() }
                }
                start = end
            }
        }
        if n > 0 {
            let paths = sorted(rowPaths)
            emitRows(paths[...], depth: 0)
            if showsColumnGrandTotals {
                lines.append(Line(
                    path: [], labels: [(0, .text(grandCaption))], hasValues: true,
                    item: PivotParts.AxisItem(kind: "grand", indexes: [0])))
            }
        } else {
            let name = valueCount == 1 ? dataFields[0].name : "Total"
            lines.append(Line(
                path: [], labels: labelColumns > 0 ? [(0, .text(name))] : [], hasValues: true, item: PivotParts.AxisItem()))
        }

        // MARK: Columns

        struct Entry {
            var path: [Int]
            var dataIndex: Int
            var headers: [(row: Int, value: PivotValue)]
            var item: PivotParts.AxisItem
        }
        /// The rows above the data: a row of captions and one for each
        /// column field when there are any, and the value fields' names
        /// when there are several.
        let itemRow = m > 0 ? 1 : 0
        let namesRow = itemRow + m
        let headerRows = m > 0 ? 1 + m + (valueCount > 1 ? 1 : 0) : 1
        var entries: [Entry] = []
        var pendingHeaders: [(row: Int, value: PivotValue)] = []
        previous = []
        func emitColumns(_ paths: ArraySlice<[Int]>, depth: Int) {
            var start = paths.startIndex
            while start < paths.endIndex {
                var end = start
                while end < paths.endIndex, paths[end][depth] == paths[start][depth] { end += 1 }
                let path = Array(paths[start][...depth])
                let own = (row: itemRow + depth, value: label(columns[depth], path[depth]))
                if depth == m - 1 {
                    let repeated = Swift.min(shared(previous, path), path.count - 1)
                    previous = path
                    for index in 0..<spread {
                        var headers = index == 0 ? pendingHeaders + [own] : []
                        var item = PivotParts.AxisItem(repeated: repeated, indexes: Array(path[repeated...]))
                        if valueCount > 1 {
                            headers.append((namesRow, .text(dataFields[index].name)))
                            item = index == 0
                                ? PivotParts.AxisItem(repeated: repeated, indexes: Array(path[repeated...]) + [0])
                                : PivotParts.AxisItem(repeated: m, indexes: [index], dataIndex: index)
                        }
                        entries.append(Entry(path: path, dataIndex: index, headers: headers, item: item))
                    }
                    pendingHeaders = []
                } else {
                    pendingHeaders.append(own)
                    emitColumns(paths[start..<end], depth: depth + 1)
                    if fields[columns[depth]].hasDefaultSubtotal {
                        for index in 0..<spread {
                            let header = valueCount > 1
                                ? totalLabel(columns[depth], path[depth], suffix: dataFields[index].name)
                                : totalLabel(columns[depth], path[depth])
                            entries.append(Entry(
                                path: path, dataIndex: index, headers: [(itemRow + depth, header)],
                                item: PivotParts.AxisItem(
                                    kind: "default", repeated: depth, indexes: [path[depth]], dataIndex: index)))
                        }
                        previous = path
                    }
                }
                start = end
            }
        }
        if m > 0 {
            let paths = sorted(columnPaths)
            emitColumns(paths[...], depth: 0)
            if showsRowGrandTotals {
                for index in 0..<spread {
                    let header = valueCount > 1 ? "Total " + dataFields[index].name : grandCaption
                    entries.append(Entry(
                        path: [], dataIndex: index, headers: [(itemRow, .text(header))],
                        item: PivotParts.AxisItem(kind: "grand", indexes: [0], dataIndex: index)))
                }
            }
        } else {
            for index in 0..<spread {
                entries.append(Entry(
                    path: [], dataIndex: index,
                    headers: valueCount > 0 ? [(0, .text(dataFields[index].name))] : [],
                    item: valueCount > 1 ? PivotParts.AxisItem(indexes: [index], dataIndex: index) : PivotParts.AxisItem()))
            }
        }

        // MARK: Cells

        var cells = [[PivotValue]](
            repeating: [PivotValue](repeating: .blank, count: labelColumns + entries.count),
            count: headerRows + lines.count)
        if m > 0 {
            if valueCount == 1, n > 0 { cells[0][0] = .text(dataFields[0].name) }
            if fields[columns[0]].isCompact {
                if labelColumns < cells[0].count { cells[0][labelColumns] = .text(columnHeaderCaption ?? "Column Labels") }
            } else {
                for (offset, field) in columns.enumerated() where labelColumns + offset < cells[0].count {
                    cells[0][labelColumns + offset] = .text(fields[field].name)
                }
            }
        }
        for depth in (0..<n).reversed() {
            let field = fields[rows[depth]]
            let isCompact = field.isCompact && field.isOutline
            // A column several compact fields share is headed once.
            if isCompact, depth > 0, labelColumn[depth - 1] == labelColumn[depth] { continue }
            cells[headerRows - 1][labelColumn[depth]] = .text(isCompact ? rowHeaderCaption ?? "Row Labels" : field.name)
        }
        for (offset, entry) in entries.enumerated() {
            for header in entry.headers { cells[header.row][labelColumns + offset] = header.value }
        }
        for (offset, line) in lines.enumerated() {
            let row = headerRows + offset
            for label in line.labels { cells[row][label.column] = label.value }
            guard line.hasValues, valueCount > 0 else { continue }
            for (column, entry) in entries.enumerated() {
                guard let cell = totals[Key(row: line.path, column: entry.path)] else { continue }
                cells[row][labelColumns + column] = cell[entry.dataIndex].result(dataFields[entry.dataIndex].aggregation)
            }
        }
        return PivotLayout(
            cells: cells, firstHeaderRow: m == 0 && valueCount > 1 ? 0 : 1, firstDataRow: headerRows,
            firstDataColumn: labelColumns, rowItems: lines.map(\.item), columnItems: entries.map(\.item))
    }
}

extension Workbook {
    /// The cells a pivot cache reads: the sheet and the range, headings
    /// included.
    public func pivotSourceRange(of cache: PivotCache) -> (sheetID: Worksheet.ID, range: CellRange)? {
        guard case .worksheet(let sheetName, let reference, let name) = cache.source else { return nil }
        if let reference, let sheetName, let sheet = sheet(named: sheetName),
           let range = CellRange(a1Range: reference)?.normalized {
            return (sheet.id, range)
        }
        guard let name else { return nil }
        if let table = tables.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            var range = table.range
            range.end.row -= table.totalsRowCount
            return (table.sheetID, range)
        }
        if let defined = definedName(name, visibleFrom: nil),
           let found = ChartReference(formula: defined.formula, in: self) {
            return (found.sheetID, found.range.normalized)
        }
        return nil
    }

    /// What stops a PivotTable being refreshed, if anything does.
    public func pivotRefreshBlocker(for pivot: PivotTable) -> PivotRefreshError? {
        guard let cache = pivotCache(pivot.cacheID) else { return .missing }
        if let blocker = pivot.blocker(in: cache) { return blocker }
        return pivotSourceRange(of: cache) == nil ? .sourceNotFound : nil
    }

    /// Reads a PivotTable's source again and works out every PivotTable
    /// that shares its cache, as Excel's Refresh does. Nothing changes when
    /// it throws.
    public mutating func refreshPivotTable(_ id: PivotTable.ID) throws {
        guard let pivot = pivotTable(id), let at = pivotCaches.firstIndex(where: { $0.cacheID == pivot.cacheID })
        else { throw PivotRefreshError.missing }
        var copy = self
        for other in pivotTables where other.cacheID == pivot.cacheID {
            if let blocker = other.blocker(in: pivotCaches[at]) { throw blocker }
        }
        try copy.readPivotSource(cacheAt: at)
        for index in copy.pivotTables.indices where copy.pivotTables[index].cacheID == pivot.cacheID {
            try copy.applySlicers(toPivotAt: index, cacheAt: at)
            try copy.layOutPivotTable(at: index, rewritesFilters: copy.pivotTables[index].hasChangedLayout)
        }
        try copy.writePivotCacheParts(at: at)
        copy.recalculate()
        self = copy
    }

    /// Refreshes every PivotTable, a cache at a time. Nothing changes when
    /// any of them can't be refreshed.
    public mutating func refreshAllPivotTables() throws {
        var copy = self
        var seen: Set<Int> = []
        for pivot in pivotTables where seen.insert(pivot.cacheID).inserted {
            try copy.refreshPivotTable(pivot.id)
        }
        self = copy
    }

    /// Changes a PivotTable's layout — its areas, its value fields, its
    /// filters, its totals — and works it out again from the cache's records.
    /// Nothing changes when it throws.
    public mutating func updatePivotTable(_ id: PivotTable.ID, _ change: (inout PivotTable) -> Void) throws {
        guard let index = pivotTables.firstIndex(where: { $0.id == id }),
              let at = pivotCaches.firstIndex(where: { $0.cacheID == pivotTables[index].cacheID })
        else { throw PivotRefreshError.missing }
        var copy = self
        let before = copy.pivotTables[index]
        copy.adoptPivotCaptions(at: index)
        change(&copy.pivotTables[index])
        copy.pivotTables[index].normalizeAreas()
        if let blocker = copy.pivotTables[index].blocker(in: copy.pivotCaches[at]) { throw blocker }
        let areasChanged = before.rowFields != copy.pivotTables[index].rowFields
            || before.columnFields != copy.pivotTables[index].columnFields
            || before.filters.map(\.field) != copy.pivotTables[index].filters.map(\.field)
            || before.dataFields != copy.pivotTables[index].dataFields
        if areasChanged { copy.pivotTables[index].hasChangedLayout = true }
        // A file saved without its records has nothing to lay out from.
        if copy.pivotCaches[at].recordsPath == nil { try copy.readPivotSource(cacheAt: at) }
        try copy.layOutPivotTable(at: index, rewritesFilters: true, previous: before)
        try copy.writePivotCacheParts(at: at)
        copy.recalculate()
        self = copy
    }

    /// Turns a slicer's buttons on and off, and filters its PivotTables to
    /// match.
    public mutating func setSlicerSelection(_ cacheID: SlicerCache.ID, selected: Set<Int>) throws {
        guard let at = slicerCaches.firstIndex(where: { $0.id == cacheID }) else { throw PivotRefreshError.missing }
        var copy = self
        for index in copy.slicerCaches[at].items.indices {
            let item = copy.slicerCaches[at].items[index]
            copy.slicerCaches[at].items[index].isSelected = selected.contains(item.sharedIndex)
        }
        let slicer = copy.slicerCaches[at]
        let chosen = Set(slicer.items.filter(\.isSelected).map(\.sharedIndex))
        for index in copy.pivotTables.indices
        where copy.slicerCaches(for: copy.pivotTables[index]).contains(where: { $0.id == cacheID }) {
            guard let cacheAt = copy.pivotCaches.firstIndex(where: { $0.cacheID == copy.pivotTables[index].cacheID }),
                  let field = copy.pivotTables[index].fields.firstIndex(where: {
                      $0.name.caseInsensitiveCompare(slicer.sourceName) == .orderedSame
                  }) else { continue }
            if let blocker = copy.pivotTables[index].blocker(in: copy.pivotCaches[cacheAt]) { throw blocker }
            let before = copy.pivotTables[index]
            copy.adoptPivotCaptions(at: index)
            copy.pivotCaches[cacheAt].fields[field].usesSharedItems = true
            copy.syncPivotItems(cacheAt: cacheAt, pivotAt: index, alsoFields: [field])
            for item in copy.pivotTables[index].fields[field].items.indices {
                guard let shared = copy.pivotTables[index].fields[field].items[item].sharedIndex else { continue }
                copy.pivotTables[index].fields[field].items[item].isHidden = !chosen.contains(shared)
            }
            try copy.layOutPivotTable(at: index, rewritesFilters: true, previous: before)
            try copy.writePivotCacheParts(at: cacheAt)
        }
        if let data = copy.preservedPackage.parts[slicer.partPath] {
            guard let updated = PivotParts.slicerCacheDefinition(data, for: slicer) else {
                throw PivotRefreshError.unreadablePart
            }
            copy.preservedPackage.parts[slicer.partPath] = updated
        }
        copy.recalculate()
        self = copy
    }

    // MARK: - Steps

    /// Reads the source's rows into the cache, matching its columns to the
    /// cache's fields by their headings.
    private mutating func readPivotSource(cacheAt at: Int) throws {
        let cache = pivotCaches[at]
        guard case .worksheet = cache.source else { throw PivotRefreshError.externalSource }
        guard let source = pivotSourceRange(of: cache), let sheet = self[source.sheetID] else {
            throw PivotRefreshError.sourceNotFound
        }
        let range = source.range
        var headings: [String] = []
        for column in range.columnRange {
            let heading = sheet[CellAddress(row: range.start.row, column: column)].value.stringValue
            guard !heading.trimmed.isEmpty else { throw PivotRefreshError.headingMissing }
            headings.append(heading)
        }

        // Fields keep their items, wherever their columns now are.
        var fields: [PivotCacheField] = []
        var origin: [Int?] = []
        var taken: Set<Int> = []
        for heading in headings {
            let old = cache.fields.indices.first {
                !taken.contains($0) && cache.fields[$0].name.caseInsensitiveCompare(heading) == .orderedSame
            }
            if let old {
                taken.insert(old)
                var field = cache.fields[old]
                field.name = heading
                fields.append(field)
            } else {
                fields.append(PivotCacheField(name: heading))
            }
            origin.append(old)
        }
        var records: [[PivotValue]] = []
        if range.start.row < range.end.row {
            for row in (range.start.row + 1)...range.end.row {
                let record = range.columnRange.map { column -> PivotValue in
                    let cell = sheet[CellAddress(row: row, column: column)]
                    switch cell.value {
                    case .empty: return .blank
                    case .number(let number):
                        return CellFormatter.isDateFormat(cell.style.numberFormat) ? .date(number) : .number(number)
                    case .text(let text): return text.isEmpty ? .blank : .text(text)
                    case .boolean(let flag): return .boolean(flag)
                    case .error(let error): return .error(error.rawValue)
                    }
                }
                // A row with nothing in it is not a record.
                if record.contains(where: { $0 != .blank }) { records.append(record) }
            }
        }
        pivotCaches[at].fields = fields
        pivotCaches[at].records = records

        let moved = origin.count != cache.fields.count || origin.enumerated().contains { $0.offset != $0.element }
        for index in pivotTables.indices where pivotTables[index].cacheID == cache.cacheID {
            adoptPivotCaptions(at: index)
            if moved { pivotTables[index].remapFields(origin: origin, names: headings) }
            for field in pivotTables[index].fields.indices { pivotTables[index].fields[field].name = headings[field] }
        }
    }

    /// Keeps the captions the file's cells have — "Row Labels", "Grand
    /// Total" — when the definition does not say them, so a PivotTable made
    /// in another language keeps its words.
    private mutating func adoptPivotCaptions(at index: Int) {
        let pivot = pivotTables[index]
        guard let sheet = self[pivot.sheetID] else { return }
        let range = pivot.location
        func text(_ row: Int, _ column: Int) -> String? {
            guard range.contains(CellAddress(row: row, column: column)),
                  case .text(let text) = sheet[CellAddress(row: row, column: column)].value else { return nil }
            return text
        }
        let rows = pivot.rowFields.filter { $0 >= 0 }, columns = pivot.columnFields.filter { $0 >= 0 }
        func isCompact(_ field: Int) -> Bool { pivot.fields[field].isCompact && pivot.fields[field].isOutline }
        if pivot.rowHeaderCaption == nil, let first = rows.first, isCompact(first) {
            pivotTables[index].rowHeaderCaption = text(range.start.row + pivot.firstDataRow - 1, range.start.column)
        }
        if pivot.columnHeaderCaption == nil, let first = columns.first, pivot.fields[first].isCompact {
            pivotTables[index].columnHeaderCaption = text(range.start.row, range.start.column + pivot.firstDataColumn)
        }
        if pivot.grandTotalCaption == nil {
            if !rows.isEmpty, pivot.showsColumnGrandTotals {
                pivotTables[index].grandTotalCaption = text(range.end.row, range.start.column)
            } else if !columns.isEmpty, pivot.showsRowGrandTotals, pivot.dataFields.count <= 1 {
                pivotTables[index].grandTotalCaption = text(range.start.row + pivot.firstHeaderRow, range.end.column)
            }
        }
    }

    /// Sees that the cache holds the values of every field the PivotTable
    /// places as shared items, and that the PivotTable's item lists name
    /// all of them.
    private mutating func syncPivotItems(cacheAt at: Int, pivotAt index: Int, alsoFields: Set<Int> = []) {
        let pivot = pivotTables[index]
        let placed = Set(pivot.rowFields + pivot.columnFields + pivot.filters.map(\.field)).union(alsoFields)
        for field in pivotCaches[at].fields.indices {
            if placed.contains(field) { pivotCaches[at].fields[field].usesSharedItems = true }
            guard pivotCaches[at].fields[field].usesSharedItems else { continue }
            var known = Set(pivotCaches[at].fields[field].sharedItems.map(\.groupingKey))
            for record in pivotCaches[at].records where known.insert(record[field].groupingKey).inserted {
                pivotCaches[at].fields[field].sharedItems.append(record[field])
            }
        }
        for field in pivot.fields.indices where field < pivotCaches[at].fields.count {
            let shared = pivotCaches[at].fields[field].sharedItems
            var items = pivot.fields[field].items
            guard placed.contains(field) || !items.isEmpty else { continue }
            // Indexes past what the cache now holds name nothing.
            items.removeAll { ($0.sharedIndex ?? 0) >= shared.count }
            let selectedShared = pivot.filters.first { $0.field == field }?.selectedItem
                .flatMap { pivot.fields[field].items.indices.contains($0) ? pivot.fields[field].items[$0].sharedIndex : nil }
            let isNew = !items.contains { $0.sharedIndex != nil }
            let known = Set(items.compactMap(\.sharedIndex))
            var data = items.filter { $0.sharedIndex != nil }
            let subtotals = items.filter { $0.sharedIndex == nil }
            data += shared.indices.filter { !known.contains($0) }.map { PivotItem(sharedIndex: $0) }
            func value(_ item: PivotItem) -> PivotValue { shared[item.sharedIndex ?? 0] }
            if isNew || pivot.fields[field].sortType == "ascending" {
                data.sort { value($0).isOrdered(before: value($1)) }
            } else if pivot.fields[field].sortType == "descending" {
                data.sort { value($1).isOrdered(before: value($0)) }
            }
            var tail = subtotals
            if tail.isEmpty, pivot.fields[field].hasDefaultSubtotal { tail = [PivotItem(sharedIndex: nil, kind: "default")] }
            pivotTables[index].fields[field].items = data + tail
            if let filter = pivotTables[index].filters.firstIndex(where: { $0.field == field }) {
                pivotTables[index].filters[filter].selectedItem = selectedShared.flatMap { shared in
                    data.firstIndex { $0.sharedIndex == shared }
                }
            }
        }
    }

    /// Gives the PivotTable's slicers a button for each item their field
    /// now has, and leaves out the items whose buttons are off.
    private mutating func applySlicers(toPivotAt index: Int, cacheAt at: Int) throws {
        for slicer in slicerCaches(for: pivotTables[index]) {
            guard let slicerAt = slicerCaches.firstIndex(where: { $0.id == slicer.id }),
                  let field = pivotTables[index].fields.firstIndex(where: {
                      $0.name.caseInsensitiveCompare(slicer.sourceName) == .orderedSame
                  }) else { continue }
            pivotCaches[at].fields[field].usesSharedItems = true
            syncPivotItems(cacheAt: at, pivotAt: index, alsoFields: [field])
            let known = Set(slicer.items.map(\.sharedIndex))
            let isFiltering = slicer.items.contains { !$0.isSelected }
            let added = pivotCaches[at].fields[field].sharedItems.indices.filter { !known.contains($0) }
            guard !added.isEmpty else { continue }
            slicerCaches[slicerAt].items += added.map { SlicerCache.Item(sharedIndex: $0, isSelected: !isFiltering) }
            if isFiltering {
                for item in pivotTables[index].fields[field].items.indices {
                    guard let shared = pivotTables[index].fields[field].items[item].sharedIndex,
                          added.contains(shared) else { continue }
                    pivotTables[index].fields[field].items[item].isHidden = true
                }
            }
            if let data = preservedPackage.parts[slicer.partPath] {
                guard let updated = PivotParts.slicerCacheDefinition(data, for: slicerCaches[slicerAt]) else {
                    throw PivotRefreshError.unreadablePart
                }
                preservedPackage.parts[slicer.partPath] = updated
            }
        }
    }

    /// Works one PivotTable out and puts it on its sheet and into its part.
    private mutating func layOutPivotTable(at index: Int, rewritesFilters: Bool, previous: PivotTable? = nil) throws {
        guard let at = pivotCaches.firstIndex(where: { $0.cacheID == pivotTables[index].cacheID }),
              let sheetIndex = self.index(of: pivotTables[index].sheetID) else { throw PivotRefreshError.missing }
        pivotTables[index].normalizeAreas()
        syncPivotItems(cacheAt: at, pivotAt: index)
        let old = previous ?? pivotTables[index]
        var pivot = pivotTables[index]
        let cache = pivotCaches[at]
        let layout = pivot.layout(from: cache)

        // Filters sit above the PivotTable with a row between; a PivotTable
        // too near the top moves down to make room for them.
        var origin = old.location.start
        if !pivot.filters.isEmpty { origin.row = Swift.max(origin.row, pivot.filters.count + 1) }
        let end = CellAddress(row: origin.row + layout.rowCount - 1, column: origin.column + layout.columnCount - 1)
        guard end.row < Worksheet.maximumRowCount, end.column < Worksheet.maximumColumnCount else {
            throw PivotRefreshError.noRoom
        }
        pivot.location = CellRange(start: origin, end: end)
        pivot.firstHeaderRow = layout.firstHeaderRow
        pivot.firstDataRow = layout.firstDataRow
        pivot.firstDataColumn = layout.firstDataColumn

        var writes: [(address: CellAddress, value: PivotValue, isData: Bool)] = []
        for (row, values) in layout.cells.enumerated() {
            for (column, value) in values.enumerated() {
                writes.append((
                    CellAddress(row: origin.row + row, column: origin.column + column), value,
                    row >= layout.firstDataRow && column >= layout.firstDataColumn))
            }
        }
        var cleared = [old.location]
        if rewritesFilters {
            if let range = old.filterRange { cleared.append(range) }
            for (offset, filter) in pivot.filters.enumerated() {
                let row = origin.row - pivot.filters.count - 1 + offset
                let field = pivot.fields[filter.field]
                let shown: String
                if let item = filter.selectedItem {
                    shown = pivot.value(ofItem: item, field: filter.field, in: cache).label
                } else {
                    shown = field.items.contains(where: \.isHidden) ? "(Multiple Items)" : "(All)"
                }
                writes.append((CellAddress(row: row, column: origin.column), .text(field.name), false))
                writes.append((CellAddress(row: row, column: origin.column + 1), .text(shown), false))
            }
        }

        var sheet = sheets[sheetIndex]
        func isOwn(_ address: CellAddress) -> Bool { cleared.contains { $0.contains(address) } }
        for write in writes where !isOwn(write.address) {
            let inOther = pivotTables.enumerated().contains { other in
                other.offset != index && other.element.sheetID == pivot.sheetID
                    && (other.element.location.contains(write.address)
                        || other.element.filterRange?.contains(write.address) == true)
            }
            if inOther || sheet.cells[write.address]?.isBlank == false {
                throw PivotRefreshError.wouldOverwrite(pivot.location)
            }
        }

        // New cells of numbers take the look of the ones there already.
        let firstData = CellAddress(
            row: old.location.start.row + old.firstDataRow, column: old.location.start.column + old.firstDataColumn)
        let template = old.location.contains(firstData) ? sheet[firstData].style : nil
        let dateFormat = pivotDateFormats(of: cache)
        for range in cleared {
            for address in sheet.storedAddresses(in: range) {
                var cell = sheet[address]
                cell.value = .empty
                cell.formula = nil
                cell.isSpilled = false
                sheet[address] = cell
            }
        }
        sheet.rowCount = Swift.max(sheet.rowCount, end.row + 1)
        sheet.columnCount = Swift.max(sheet.columnCount, end.column + 1)
        for write in writes where write.value != .blank {
            var cell = sheet[write.address]
            cell.value = write.value.cellValue
            cell.formula = nil
            if write.isData, let template, cell.style.isDefault { cell.style = template }
            if case .date = write.value, !CellFormatter.isDateFormat(cell.style.numberFormat) {
                cell.style.numberFormat = dateFormat
            }
            sheet[write.address] = cell
        }
        sheets[sheetIndex] = sheet

        guard let data = preservedPackage.parts[pivot.partPath],
              let updated = PivotParts.tableDefinition(
                data, for: pivot, rowItems: layout.rowItems, columnItems: layout.columnItems)
        else { throw PivotRefreshError.unreadablePart }
        preservedPackage.parts[pivot.partPath] = updated
        // The part now says what the model does.
        pivot.hasChangedLayout = false
        for field in pivot.fields.indices { pivot.fields[field].fileIndex = field }
        pivotTables[index] = pivot
    }

    /// The format of the first date in the cache's source, for the dates a
    /// PivotTable shows as labels.
    private func pivotDateFormats(of cache: PivotCache) -> String {
        let fallback = "yyyy-mm-dd"
        guard let source = pivotSourceRange(of: cache), let sheet = self[source.sheetID] else { return fallback }
        for address in sheet.storedAddresses(in: source.range) where address.row > source.range.start.row {
            let format = sheet[address].style.numberFormat
            if CellFormatter.isDateFormat(format) { return format }
        }
        return fallback
    }

    /// Brings the cache's definition and records in the kept package up to
    /// date with the model.
    private mutating func writePivotCacheParts(at: Int) throws {
        let cache = pivotCaches[at]
        guard let data = preservedPackage.parts[cache.partPath],
              let definition = PivotParts.cacheDefinition(data, for: cache) else { throw PivotRefreshError.unreadablePart }
        preservedPackage.parts[cache.partPath] = definition
        if let recordsPath = cache.recordsPath { preservedPackage.parts[recordsPath] = PivotParts.cacheRecords(for: cache) }
    }
}

extension PivotTable {
    /// Keeps the stand-in for the value fields where a layout needs it: last
    /// among the column fields when there are several value fields, and
    /// nowhere otherwise. Values placed on rows are left as they are.
    mutating func normalizeAreas() {
        guard !rowFields.contains(Self.valuesField) else { return }
        columnFields.removeAll { $0 == Self.valuesField }
        if dataFields.count > 1 { columnFields.append(Self.valuesField) }
    }

    /// Follows the cache's fields to their new places. `origin` gives, for
    /// each field now, the place it had before, or nil for a new one.
    mutating func remapFields(origin: [Int?], names: [String]) {
        var moved: [Int: Int] = [:]
        for (new, old) in origin.enumerated() { if let old { moved[old] = new } }
        let before = self
        fields = origin.enumerated().map { new, old in
            if let old, before.fields.indices.contains(old) { return before.fields[old] }
            return PivotField(name: names[new])
        }
        func follow(_ list: [Int]) -> [Int] { list.compactMap { $0 < 0 ? $0 : moved[$0] } }
        rowFields = follow(before.rowFields)
        columnFields = follow(before.columnFields)
        filters = before.filters.compactMap { filter in
            moved[filter.field].map { PivotFilter(field: $0, selectedItem: filter.selectedItem) }
        }
        dataFields = before.dataFields.compactMap { data in
            guard let field = moved[data.field] else { return nil }
            var data = data
            data.field = field
            return data
        }
        // What the file's formats pointed at may have moved or gone.
        hasChangedLayout = true
    }

    // MARK: - Changing the layout

    /// "Sum of Amount", as Excel names a value field.
    public func defaultName(for field: Int, aggregation: PivotAggregation) -> String {
        "\(aggregation.label) of \(fields.indices.contains(field) ? fields[field].name : "")"
    }

    /// Takes a field out of every area. `valueIndex` takes out one value
    /// field alone, which is how a field in the values area is named: the
    /// same field can be there more than once.
    public mutating func remove(field: Int, valueIndex: Int? = nil) {
        if let valueIndex {
            if dataFields.indices.contains(valueIndex) { dataFields.remove(at: valueIndex) }
            return
        }
        rowFields.removeAll { $0 == field }
        columnFields.removeAll { $0 == field }
        filters.removeAll { $0.field == field }
    }

    /// Puts a field in an area, at `position` or at its end. A field moves
    /// between rows, columns and filters; the values area takes it as well
    /// as wherever else it is, summed if its values are numbers and counted
    /// if not.
    public mutating func place(field: Int, in area: PivotArea, at position: Int? = nil, cache: PivotCache? = nil) {
        guard fields.indices.contains(field) else { return }
        func slot(_ count: Int) -> Int { Swift.min(Swift.max(position ?? count, 0), count) }
        switch area {
        case .values:
            let isNumeric = cache.map { cache in
                cache.records.contains { $0.indices.contains(field) && $0[field].number != nil }
                    && !cache.records.contains { record in
                        guard record.indices.contains(field) else { return false }
                        if case .text = record[field] { return true }
                        return false
                    }
            } ?? true
            let aggregation: PivotAggregation = isNumeric ? .sum : .count
            dataFields.insert(
                PivotDataField(name: defaultName(for: field, aggregation: aggregation), field: field, aggregation: aggregation),
                at: slot(dataFields.count))
        case .rows:
            remove(field: field)
            let real = rowFields.filter { $0 >= 0 }.count
            rowFields.insert(field, at: slot(real))
        case .columns:
            remove(field: field)
            let real = columnFields.filter { $0 >= 0 }.count
            columnFields.insert(field, at: slot(real))
        case .filters:
            remove(field: field)
            filters.insert(PivotFilter(field: field), at: slot(filters.count))
            // A filter shows everything until an item is chosen.
            for item in fields[field].items.indices { fields[field].items[item].isHidden = false }
        }
    }

    /// Changes how a value field summarizes, renaming it when it has the
    /// name Excel gave it.
    public mutating func setAggregation(_ aggregation: PivotAggregation, forValueAt index: Int) {
        guard dataFields.indices.contains(index) else { return }
        let data = dataFields[index]
        if data.name == defaultName(for: data.field, aggregation: data.aggregation) {
            dataFields[index].name = defaultName(for: data.field, aggregation: aggregation)
        }
        dataFields[index].aggregation = aggregation
    }
}
