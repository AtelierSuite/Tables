import Foundation

extension FormulaFunctions {
    public static let lookupFunctions: [String: FunctionSpec] = [
        "CHOOSE": FunctionSpec(2...255, lifts: .only([0]), reference: { call throws(CellError) in
            let position = try call.integer(0)
            guard position >= 1, position < call.count, let reference = call.reference(position) else {
                throw .valueError
            }
            return reference
        }, value: { call throws(CellError) in
            let position = try call.integer(0)
            guard position >= 1, position < call.count else { throw .valueError }
            return call.value(position)
        }),
        "ROW": FunctionSpec(0...1, lifts: .none) { call throws(CellError) in
            try FormulaLookup.position(call, rows: true)
        },
        "COLUMN": FunctionSpec(0...1, lifts: .none) { call throws(CellError) in
            try FormulaLookup.position(call, rows: false)
        },
        "INDEX": FunctionSpec(2...4, lifts: .only([1, 2, 3]), reference: { call throws(CellError) in
            try FormulaLookup.indexReference(call)
        }, value: { call throws(CellError) in
            // A union is indexed area by area, so it goes through the reference.
            if let areas = call.areas(0), areas.count > 1 {
                return call.evaluator.materialize(try FormulaLookup.indexReference(call))
            }
            if !call.isMissing(3), try call.integer(3) != 1 { throw .referenceError }
            let array = try call.matrix(0)
            let (row, column) = try FormulaLookup.indexPosition(
                call, rows: array.count, columns: array.first?.count ?? 0)
            let rows = row == 0 ? Array(array.indices) : [row - 1]
            let columns = column == 0 ? Array((array.first ?? []).indices) : [column - 1]
            return .block(FormulaArrays.columns(columns, of: rows.map { array[$0] }))
        }),
        "MATCH": FunctionSpec(2...3, lifts: .only([0])) { call throws(CellError) in
            let needle = call.scalar(0)
            if let error = needle.errorValue { throw error }
            let haystack = try FormulaLookup.vector(call.matrix(1))
            let type = try call.integer(2, default: 1)
            let found: Int?
            switch type {
            case 0: found = FormulaLookup.firstExact(needle, in: haystack, wildcards: true)
            case let positive where positive > 0: found = FormulaLookup.approximate(needle, in: haystack, descending: false)
            default: found = FormulaLookup.approximate(needle, in: haystack, descending: true)
            }
            guard let found else { throw .notAvailable }
            return .number(Double(found + 1))
        },
        "VLOOKUP": FunctionSpec(3...4, lifts: .only([0])) { call throws(CellError) in
            try FormulaLookup.tableLookup(call, vertical: true)
        },
        "HLOOKUP": FunctionSpec(3...4, lifts: .only([0])) { call throws(CellError) in
            try FormulaLookup.tableLookup(call, vertical: false)
        },
        "XLOOKUP": FunctionSpec(3...6, lifts: .only([0]), reference: { call throws(CellError) in
            guard let returned = call.reference(2) else { throw .valueError }
            let (position, vertical) = try FormulaLookup.crossLookupPosition(call)
            guard let position else { throw .notAvailable }
            let start = returned.range.start
            let range = vertical
                ? CellRange(start: CellAddress(row: start.row + position, column: start.column),
                            end: CellAddress(row: start.row + position, column: returned.range.end.column))
                : CellRange(start: CellAddress(row: start.row, column: start.column + position),
                            end: CellAddress(row: returned.range.end.row, column: start.column + position))
            return FormulaReference(sheet: returned.sheet, range: range)
        }, value: { call throws(CellError) in
            let returned = try call.matrix(2)
            let (position, vertical) = try FormulaLookup.crossLookupPosition(call)
            guard let position else {
                if !call.isMissing(3) { return call.value(3) }
                throw .notAvailable
            }
            if vertical {
                guard position < returned.count else { throw .valueError }
                return .block([returned[position]])
            }
            guard position < (returned.first?.count ?? 0) else { throw .valueError }
            return .block(returned.map { [$0[position]] })
        }),
    ]
}

public enum FormulaLookup {
    /// `ROW` and `COLUMN`: the position of a reference, every row or column of
    /// it as an array, or the calling cell's own with no argument.
    public static func position(_ call: FunctionCall, rows: Bool) throws(CellError) -> FormulaValue {
        guard call.count == 1, !call.isMissing(0) else {
            guard let address = call.evaluator.currentAddress else { throw .valueError }
            return .number(Double(rows ? address.row + 1 : address.column + 1))
        }
        guard let reference = call.reference(0) else { throw .valueError }
        let lines = rows ? reference.range.rowRange : reference.range.columnRange
        let values = lines.map { CellValue.number(Double($0 + 1)) }
        return .block(rows ? values.map { [$0] } : [values])
    }

    /// The row and column `INDEX` asks for, zero meaning the whole line. A
    /// single row or column takes its one index in either position.
    public static func indexPosition(_ call: FunctionCall, rows: Int, columns: Int) throws(CellError) -> (Int, Int) {
        var row = try call.integer(1, default: 0)
        var column = try call.integer(2, default: 0)
        if call.isMissing(2), rows == 1, columns > 1 {
            column = row
            row = 1
        } else if call.isMissing(2), columns == 1 {
            column = 1
        }
        guard row >= 0, column >= 0 else { throw .valueError }
        guard row <= rows, column <= columns else { throw .referenceError }
        return (row, column)
    }

    /// `INDEX` on a reference: the cell, row or column of the chosen area.
    public static func indexReference(_ call: FunctionCall) throws(CellError) -> FormulaReference {
        guard let areas = call.areas(0) else { throw .valueError }
        let area = try call.integer(3, default: 1)
        guard area >= 1, area <= areas.count else { throw .referenceError }
        let whole = areas[area - 1]
        let (row, column) = try indexPosition(call, rows: whole.rowCount, columns: whole.columnCount)
        let start = whole.range.start
        let rows = row == 0 ? whole.range.rowRange : (start.row + row - 1)...(start.row + row - 1)
        let columns = column == 0 ? whole.range.columnRange : (start.column + column - 1)...(start.column + column - 1)
        return FormulaReference(sheet: whole.sheet, range: CellRange(
            start: CellAddress(row: rows.lowerBound, column: columns.lowerBound),
            end: CellAddress(row: rows.upperBound, column: columns.upperBound)))
    }

    /// A one-dimensional range as a list. Two-dimensional ones are refused.
    public static func vector(_ matrix: [[CellValue]]) throws(CellError) -> [CellValue] {
        if matrix.count == 1 { return matrix[0] }
        guard matrix.allSatisfy({ $0.count == 1 }) else { throw .notAvailable }
        return matrix.map { $0[0] }
    }

    /// Whether `candidate` is what an exact lookup for `needle` wants: the same
    /// kind of value, text compared without case and, when allowed, by wildcard.
    public static func exactMatch(_ candidate: CellValue, _ needle: CellValue, wildcards: Bool) -> Bool {
        if wildcards, case .text(let pattern) = needle, case .text(let text) = candidate,
           FormulaWildcard.hasWildcards(pattern) {
            return FormulaWildcard.matches(text, pattern: pattern)
        }
        return FormulaComparison.equal(candidate, needle)
    }

    public static func firstExact(_ needle: CellValue, in values: [CellValue], wildcards: Bool) -> Int? {
        values.firstIndex { exactMatch($0, needle, wildcards: wildcards) }
    }

    /// Whether two values are of a kind that can be ordered against each other.
    public static func comparable(_ lhs: CellValue, _ rhs: CellValue) -> Bool {
        switch (lhs, rhs) {
        case (.number, .number), (.text, .text), (.boolean, .boolean): return true
        default: return false
        }
    }

    /// The position of the last value not past `needle` in sorted data, found
    /// by binary search as Excel finds it — so unsorted data gives the same
    /// unreliable answers it gives in Excel. Values of another kind are passed over.
    public static func approximate(_ needle: CellValue, in values: [CellValue], descending: Bool) -> Int? {
        var low = 0
        var high = values.count - 1
        var best: Int?
        while low <= high {
            let middle = (low + high) / 2
            var probe = middle
            while probe >= low, !comparable(values[probe], needle) { probe -= 1 }
            guard probe >= low else {
                low = middle + 1
                continue
            }
            let ordering = FormulaComparison.compare(values[probe], needle)
            let acceptable = descending ? ordering != .orderedAscending : ordering != .orderedDescending
            if acceptable {
                best = probe
                low = middle + 1
            } else {
                high = probe - 1
            }
        }
        return best
    }

    /// `VLOOKUP` and `HLOOKUP`.
    public static func tableLookup(_ call: FunctionCall, vertical: Bool) throws(CellError) -> FormulaValue {
        let needle = call.scalar(0)
        if let error = needle.errorValue { throw error }
        let table = try call.matrix(1)
        let offset = try call.integer(2)
        let approximateMatch = try call.boolean(3, default: true)
        guard offset >= 1 else { throw .valueError }
        let keys = vertical ? table.map { $0.first ?? .empty } : (table.first ?? [])
        guard offset <= (vertical ? (table.first?.count ?? 0) : table.count) else { throw .referenceError }

        let found = approximateMatch
            ? approximate(needle, in: keys, descending: false)
            : firstExact(needle, in: keys, wildcards: true)
        guard let found else { throw .notAvailable }
        return .scalar(vertical ? table[found][offset - 1] : table[offset - 1][found])
    }

    /// `XLOOKUP`'s match: the position in the lookup array, nil when nothing
    /// matches, and whether the array runs down a column.
    public static func crossLookupPosition(_ call: FunctionCall) throws(CellError) -> (Int?, Bool) {
        let needle = call.scalar(0)
        if let error = needle.errorValue { throw error }
        let lookup = try call.matrix(1)
        let returned = try call.matrix(2)
        let vertical = lookup.count > 1 || (lookup.first?.count ?? 0) == 1
        let keys = try vector(lookup)
        let length = vertical ? returned.count : (returned.first?.count ?? 0)
        guard length == keys.count else { throw .valueError }
        let position = try matchPosition(
            needle, in: keys, matchMode: try call.integer(4, default: 0), searchMode: try call.integer(5, default: 1))
        return (position, vertical)
    }

    /// The match modes `XLOOKUP` and `XMATCH` share: exact (0), exact or next
    /// smaller (−1), exact or next larger (1), wildcard (2) and regular
    /// expression (3); searching first to last (1), last to first (−1), or by
    /// binary search over ascending (2) or descending (−2) data.
    public static func matchPosition(_ needle: CellValue, in keys: [CellValue], matchMode: Int, searchMode: Int) throws(CellError) -> Int? {
        guard [-1, 0, 1, 2, 3].contains(matchMode), [-2, -1, 1, 2].contains(searchMode) else { throw .valueError }
        if abs(searchMode) == 2 {
            let descending = searchMode == -2
            if let found = approximate(needle, in: keys, descending: descending),
               FormulaComparison.equal(keys[found], needle) {
                return found
            }
            guard matchMode == -1 || matchMode == 1 else { return nil }
        }

        let order = searchMode == -1 ? Array(keys.indices.reversed()) : Array(keys.indices)
        if matchMode == 3 {
            guard case .text(let pattern) = needle else { return nil }
            let expression = try FormulaText.regex(pattern, insensitive: true)
            return order.first { index in
                let text = (try? keys[index].coercedText()) ?? ""
                return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
        if let exact = order.first(where: { exactMatch(keys[$0], needle, wildcards: matchMode == 2) }) {
            return exact
        }
        guard matchMode == -1 || matchMode == 1 else { return nil }
        // The nearest smaller (−1) or larger (1) value.
        var best: Int?
        for index in order where comparable(keys[index], needle) {
            let ordering = FormulaComparison.compare(keys[index], needle)
            guard matchMode == -1 ? ordering == .orderedAscending : ordering == .orderedDescending else { continue }
            if let current = best {
                let closer = FormulaComparison.compare(keys[index], keys[current])
                if matchMode == -1 ? closer == .orderedDescending : closer == .orderedAscending { best = index }
            } else {
                best = index
            }
        }
        return best
    }
}
