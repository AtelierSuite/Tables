import Foundation

extension FormulaFunctions {
    public static let referenceFunctions: [String: FunctionSpec] = [
        "OFFSET": FunctionSpec(3...5, reference: { call throws(CellError) in
            guard let base = call.reference(0) else { throw .valueError }
            let rows = try call.integer(1)
            let columns = try call.integer(2)
            let height = try call.integer(3, default: base.rowCount)
            let width = try call.integer(4, default: base.columnCount)
            guard height != 0, width != 0 else { throw .referenceError }
            // A negative height or width reaches up or left from the moved corner.
            let top = base.range.start.row + rows + (height < 0 ? height + 1 : 0)
            let left = base.range.start.column + columns + (width < 0 ? width + 1 : 0)
            let bottom = top + abs(height) - 1
            let right = left + abs(width) - 1
            guard top >= 0, left >= 0, bottom <= SheetLimits.maxRow, right <= SheetLimits.maxColumn else {
                throw .referenceError
            }
            return FormulaReference(sheet: base.sheet, range: CellRange(
                start: CellAddress(row: top, column: left), end: CellAddress(row: bottom, column: right)))
        }),
        "INDIRECT": FunctionSpec(1...2, reference: { call throws(CellError) in
            let text = try call.text(0).trimmingCharacters(in: .whitespaces)
            let a1 = try call.boolean(1, default: true)
            guard let reference = a1
                    ? FormulaReferenceText.a1(text, evaluator: call.evaluator)
                    : FormulaReferenceText.r1c1(text, relativeTo: call.evaluator.currentAddress) else {
                throw .referenceError
            }
            return reference
        }),
        "TRIMRANGE": FunctionSpec(1...3, reference: { call throws(CellError) in
            guard let whole = call.reference(0) else { throw .valueError }
            let trimRows = try call.integer(1, default: 3)
            let trimColumns = try call.integer(2, default: 3)
            guard (0...3).contains(trimRows), (0...3).contains(trimColumns) else { throw .valueError }
            let rows = call.evaluator.materialize(whole).rows
            func blankRow(_ index: Int) -> Bool { rows[index].allSatisfy(\.isEmpty) }
            func blankColumn(_ index: Int) -> Bool { rows.allSatisfy { $0[index].isEmpty } }
            var top = 0
            var bottom = rows.count - 1
            var left = 0
            var right = (rows.first?.count ?? 1) - 1
            if trimRows & 1 != 0 { while top < bottom, blankRow(top) { top += 1 } }
            if trimRows & 2 != 0 { while bottom > top, blankRow(bottom) { bottom -= 1 } }
            if trimColumns & 1 != 0 { while left < right, blankColumn(left) { left += 1 } }
            if trimColumns & 2 != 0 { while right > left, blankColumn(right) { right -= 1 } }
            let origin = whole.range.start
            return FormulaReference(sheet: whole.sheet, range: CellRange(
                start: CellAddress(row: origin.row + top, column: origin.column + left),
                end: CellAddress(row: origin.row + bottom, column: origin.column + right)))
        }),
        "ADDRESS": FunctionSpec(2...5) { call throws(CellError) in
            let row = try call.integer(0)
            let column = try call.integer(1)
            let style = try call.integer(2, default: 1)
            let a1 = try call.boolean(3, default: true)
            guard row >= 1, row <= SheetLimits.maxRow + 1, column >= 1, column <= SheetLimits.maxColumn + 1,
                  (1...4).contains(style) else { throw .valueError }
            let absoluteRow = style == 1 || style == 2
            let absoluteColumn = style == 1 || style == 3
            var text: String
            if a1 {
                text = (absoluteColumn ? "$" : "") + CellAddress.columnName(column - 1) + (absoluteRow ? "$" : "") + String(row)
            } else {
                text = (absoluteRow ? "R\(row)" : "R[\(row)]") + (absoluteColumn ? "C\(column)" : "C[\(column)]")
            }
            if !call.isMissing(4) {
                let sheet = try call.text(4)
                if !sheet.isEmpty { text = FormulaReferenceText.quotedSheet(sheet) + "!" + text }
            }
            return .text(text)
        },
        "AREAS": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            guard let areas = call.areas(0) else { throw .valueError }
            return .number(Double(areas.count))
        },
        "ROWS": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            if let areas = call.areas(0) {
                guard areas.count == 1 else { throw .referenceError }
                return .number(Double(areas[0].rowCount))
            }
            return .number(Double(try call.matrix(0).count))
        },
        "COLUMNS": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            if let areas = call.areas(0) {
                guard areas.count == 1 else { throw .referenceError }
                return .number(Double(areas[0].columnCount))
            }
            return .number(Double(try call.matrix(0).first?.count ?? 0))
        },
        "FORMULATEXT": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            guard let reference = call.reference(0) else { throw .valueError }
            guard let formula = call.context.cell(at: reference.range.start, sheetName: reference.sheet)?.formula else {
                throw .notAvailable
            }
            return .text("=" + formula)
        },
        "HYPERLINK": FunctionSpec(1...2) { call throws(CellError) in
            call.isMissing(1) ? .text(try call.text(0)) : call.value(1)
        },
        "LOOKUP": FunctionSpec(2...3, lifts: .only([0])) { call throws(CellError) in
            let needle = call.scalar(0)
            if let error = needle.errorValue { throw error }
            let table = try call.matrix(1)
            let keys: [CellValue]
            let results: [CellValue]
            if call.isMissing(2) {
                // A block is searched along its longer side and answers from its last line.
                let wide = (table.first?.count ?? 0) > table.count
                keys = wide ? table[0] : table.map { $0[0] }
                results = wide ? table[table.count - 1] : table.map { $0[$0.count - 1] }
            } else {
                keys = try FormulaLookup.vector(table)
                results = try FormulaLookup.vector(call.matrix(2))
            }
            guard let found = FormulaLookup.approximate(needle, in: keys, descending: false) else { throw .notAvailable }
            guard found < results.count else { throw .notAvailable }
            return .scalar(results[found])
        },
        "XMATCH": FunctionSpec(2...4, lifts: .only([0])) { call throws(CellError) in
            let needle = call.scalar(0)
            if let error = needle.errorValue { throw error }
            let keys = try FormulaLookup.vector(call.matrix(1))
            guard let position = try FormulaLookup.matchPosition(
                needle, in: keys, matchMode: try call.integer(2, default: 0), searchMode: try call.integer(3, default: 1)
            ) else { throw .notAvailable }
            return .number(Double(position + 1))
        },
    ]

    public static let arrayFunctions: [String: FunctionSpec] = [
        "TRANSPOSE": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            .block(FormulaArrays.transposed(try call.matrix(0)))
        },
        "FILTER": FunctionSpec(2...3, lifts: .none) { call throws(CellError) in
            let rows = try call.matrix(0)
            let include = try call.matrix(1)
            let width = rows.first?.count ?? 0
            var flags: [Bool] = []
            for cell in include.flatMap({ $0 }) {
                if case .error(let error) = cell { throw error }
                flags.append(try cell.coercedBoolean())
            }
            let result: [[CellValue]]
            if include.count == rows.count, include.first?.count == 1 {
                result = rows.enumerated().filter { flags[$0.offset] }.map(\.element)
            } else if include.count == 1, include.first?.count == width {
                let kept = (0..<width).filter { flags[$0] }
                result = kept.isEmpty ? [] : FormulaArrays.columns(kept, of: rows)
            } else {
                throw .valueError
            }
            guard !result.isEmpty else {
                if !call.isMissing(2) { return call.value(2) }
                throw .calc
            }
            return .block(result)
        },
        "SORT": FunctionSpec(1...4, lifts: .none) { call throws(CellError) in
            var rows = try call.matrix(0)
            let byColumn = try call.boolean(3, default: false)
            if byColumn { rows = FormulaArrays.transposed(rows) }
            let indices = call.isMissing(1) ? [1] : try call.numbers([1]).map { Int($0) }
            let orders = call.isMissing(2) ? [1] : try call.numbers([2]).map { Int($0) }
            let width = rows.first?.count ?? 0
            guard indices.allSatisfy({ $0 >= 1 && $0 <= width }),
                  orders.allSatisfy({ $0 == 1 || $0 == -1 }),
                  orders.count == 1 || orders.count == indices.count else { throw .valueError }
            let keys = indices.enumerated().map { position, column in
                (FormulaArrays.column(column - 1, of: rows), orders.count == 1 ? orders[0] : orders[position])
            }
            let sorted = FormulaArrays.stableSorted(rows, keys: keys)
            return .block(byColumn ? FormulaArrays.transposed(sorted) : sorted)
        },
        "SORTBY": FunctionSpec(2...255, lifts: .none) { call throws(CellError) in
            let rows = try call.matrix(0)
            var keys: [([CellValue], Int)] = []
            var byColumn: Bool?
            var index = 1
            while index < call.count {
                let by = try call.matrix(index)
                let order = index + 1 < call.count ? try call.integer(index + 1, default: 1) : 1
                guard order == 1 || order == -1 else { throw .valueError }
                let vertical = by.first?.count == 1 && by.count == rows.count
                let horizontal = by.count == 1 && by.first?.count == rows.first?.count
                guard vertical || horizontal else { throw .valueError }
                if byColumn == nil { byColumn = !vertical }
                guard byColumn == !vertical else { throw .valueError }
                keys.append((by.flatMap { $0 }, order))
                index += 2
            }
            if byColumn == true {
                let sorted = FormulaArrays.stableSorted(FormulaArrays.transposed(rows), keys: keys)
                return .block(FormulaArrays.transposed(sorted))
            }
            return .block(FormulaArrays.stableSorted(rows, keys: keys))
        },
        "UNIQUE": FunctionSpec(1...3, lifts: .none) { call throws(CellError) in
            var rows = try call.matrix(0)
            let byColumn = try call.boolean(1, default: false)
            let exactlyOnce = try call.boolean(2, default: false)
            if byColumn { rows = FormulaArrays.transposed(rows) }
            var groups: [(row: [CellValue], count: Int)] = []
            for row in rows {
                if let index = groups.firstIndex(where: { FormulaArrays.sameRow($0.row, row) }) {
                    groups[index].count += 1
                } else {
                    groups.append((row, 1))
                }
            }
            let kept = groups.filter { !exactlyOnce || $0.count == 1 }.map(\.row)
            guard !kept.isEmpty else { throw .calc }
            return .block(byColumn ? FormulaArrays.transposed(kept) : kept)
        },
        "TAKE": FunctionSpec(2...3, lifts: .none) { call throws(CellError) in
            let rows = try call.matrix(0)
            let height = try call.integer(1, default: rows.count)
            let width = try call.integer(2, default: rows.first?.count ?? 0)
            guard height != 0, width != 0 else { throw .calc }
            return .block(FormulaArrays.slice(rows, rows: height, columns: width, keeping: true))
        },
        "DROP": FunctionSpec(2...3, lifts: .none) { call throws(CellError) in
            let rows = try call.matrix(0)
            let height = try call.integer(1, default: 0)
            let width = try call.integer(2, default: 0)
            let result = FormulaArrays.slice(rows, rows: height, columns: width, keeping: false)
            guard !result.isEmpty, !(result.first?.isEmpty ?? true) else { throw .calc }
            return .block(result)
        },
        "CHOOSEROWS": FunctionSpec(2...255, lifts: .none) { call throws(CellError) in
            let rows = try call.matrix(0)
            let picks = try FormulaArrays.positions(call, from: 1, count: rows.count)
            return .block(picks.map { rows[$0] })
        },
        "CHOOSECOLS": FunctionSpec(2...255, lifts: .none) { call throws(CellError) in
            let rows = try call.matrix(0)
            let picks = try FormulaArrays.positions(call, from: 1, count: rows.first?.count ?? 0)
            return .block(FormulaArrays.columns(picks, of: rows))
        },
        "EXPAND": FunctionSpec(2...4, lifts: .none) { call throws(CellError) in
            let rows = try call.matrix(0)
            let height = try call.integer(1, default: rows.count)
            let width = try call.integer(2, default: rows.first?.count ?? 0)
            guard height >= rows.count, width >= (rows.first?.count ?? 0) else { throw .valueError }
            let pad = call.isMissing(3) ? CellValue.error(.notAvailable) : call.scalar(3)
            return .block(FormulaArrays.grid(rows: height, columns: width) { row, column in
                row < rows.count && column < rows[row].count ? rows[row][column] : pad
            })
        },
        "VSTACK": FunctionSpec(1...254, lifts: .none) { call throws(CellError) in
            let blocks = try (0..<call.count).map { index throws(CellError) in try call.matrix(index) }
            let width = blocks.map { $0.first?.count ?? 0 }.max() ?? 0
            return .block(blocks.joined().map { $0 + [CellValue](repeating: .error(.notAvailable), count: width - $0.count) })
        },
        "HSTACK": FunctionSpec(1...254, lifts: .none) { call throws(CellError) in
            let blocks = try (0..<call.count).map { index throws(CellError) in try call.matrix(index) }
            let height = blocks.map(\.count).max() ?? 0
            var rows: [[CellValue]] = []
            for row in 0..<height {
                rows.append(blocks.flatMap { block in
                    row < block.count ? block[row]
                        : [CellValue](repeating: .error(.notAvailable), count: block.first?.count ?? 0)
                })
            }
            return .block(rows)
        },
        "TOCOL": FunctionSpec(1...3, lifts: .none) { call throws(CellError) in
            try .block(FormulaArrays.flattened(call).map { [$0] })
        },
        "TOROW": FunctionSpec(1...3, lifts: .none) { call throws(CellError) in
            try .block([FormulaArrays.flattened(call)])
        },
        "WRAPROWS": FunctionSpec(2...3, lifts: .none) { call throws(CellError) in
            try .block(FormulaArrays.wrapped(call))
        },
        "WRAPCOLS": FunctionSpec(2...3, lifts: .none) { call throws(CellError) in
            try .block(FormulaArrays.transposed(FormulaArrays.wrapped(call)))
        },
    ]
}

/// Reshaping helpers for the dynamic array functions.
public enum FormulaArrays {
    public static func transposed(_ rows: [[CellValue]]) -> [[CellValue]] {
        let width = rows.first?.count ?? 0
        return (0..<width).map { column($0, of: rows) }
    }

    /// The cells in one column, top to bottom.
    public static func column(_ index: Int, of rows: [[CellValue]]) -> [CellValue] {
        rows.map { $0[index] }
    }

    /// Each row cut down to the cells at `picks`, in that order.
    public static func columns(_ picks: [Int], of rows: [[CellValue]]) -> [[CellValue]] {
        rows.map { row in picks.map { row[$0] } }
    }

    /// A block `rows` high and `columns` wide, each cell from `value`.
    public static func grid<Value>(rows: Int, columns: Int, _ value: (_ row: Int, _ column: Int) -> Value) -> [[Value]] {
        var block: [[Value]] = []
        block.reserveCapacity(rows)
        for row in 0..<rows {
            var line: [Value] = []
            line.reserveCapacity(columns)
            for column in 0..<columns { line.append(value(row, column)) }
            block.append(line)
        }
        return block
    }

    /// Rows sorted by successive keys, ties keeping their order. Numbers come
    /// before text before booleans before errors, and blanks always last.
    public static func stableSorted(_ rows: [[CellValue]], keys: [([CellValue], Int)]) -> [[CellValue]] {
        func rank(_ value: CellValue) -> Int {
            switch value {
            case .number: return 0
            case .text: return 1
            case .boolean: return 2
            case .error: return 3
            case .empty: return 4
            }
        }
        let order = rows.indices.sorted { a, b in
            for (values, direction) in keys {
                let left = values[a]
                let right = values[b]
                if left.isEmpty != right.isEmpty { return right.isEmpty }
                let ordering: ComparisonResult
                if rank(left) != rank(right) {
                    ordering = rank(left) < rank(right) ? .orderedAscending : .orderedDescending
                } else if case .error = left {
                    ordering = .orderedSame
                } else {
                    ordering = FormulaComparison.compare(left, right)
                }
                if ordering == .orderedSame { continue }
                return direction > 0 ? ordering == .orderedAscending : ordering == .orderedDescending
            }
            return a < b
        }
        return order.map { rows[$0] }
    }

    public static func sameRow(_ lhs: [CellValue], _ rhs: [CellValue]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { FormulaComparison.equal($0, $1) }
    }

    /// `TAKE` keeps, and `DROP` removes, rows and columns from the start for
    /// positive counts and from the end for negative ones.
    public static func slice(_ rows: [[CellValue]], rows count: Int, columns width: Int, keeping: Bool) -> [[CellValue]] {
        func range(_ total: Int, _ amount: Int) -> Range<Int> {
            let size = min(total, abs(amount))
            if keeping { return amount >= 0 ? 0..<size : (total - size)..<total }
            return amount >= 0 ? size..<total : 0..<(total - size)
        }
        let rowRange = range(rows.count, count)
        let columnRange = range(rows.first?.count ?? 0, width)
        return rowRange.map { row in Array(rows[row][columnRange]) }
    }

    /// One-based positions, negative counting from the end, as `CHOOSEROWS` takes them.
    public static func positions(_ call: FunctionCall, from start: Int, count: Int) throws(CellError) -> [Int] {
        var result: [Int] = []
        for number in try call.numbers(start..<call.count) {
            let index = Int(number.rounded(.towardZero))
            guard index != 0, abs(index) <= count else { throw .valueError }
            result.append(index > 0 ? index - 1 : count + index)
        }
        return result
    }

    /// `TOCOL` and `TOROW`'s values in order, skipping blanks (1), errors (2) or both (3).
    public static func flattened(_ call: FunctionCall) throws(CellError) -> [CellValue] {
        let rows = try call.matrix(0)
        let ignore = try call.integer(1, default: 0)
        let byColumn = try call.boolean(2, default: false)
        guard (0...3).contains(ignore) else { throw .valueError }
        let ordered = (byColumn ? transposed(rows) : rows).flatMap { $0 }
        let kept = ordered.filter { value in
            if ignore & 1 != 0, value.isEmpty { return false }
            if ignore & 2 != 0, value.isError { return false }
            return true
        }
        guard !kept.isEmpty else { throw .calc }
        return kept
    }

    /// `WRAPROWS`: a single row or column folded into rows of a given length.
    public static func wrapped(_ call: FunctionCall) throws(CellError) -> [[CellValue]] {
        let rows = try call.matrix(0)
        guard rows.count == 1 || rows.first?.count == 1 else { throw .valueError }
        let values = rows.flatMap { $0 }
        let length = try call.integer(1)
        guard length >= 1 else { throw .numberError }
        let pad = call.isMissing(2) ? CellValue.error(.notAvailable) : call.scalar(2)
        return stride(from: 0, to: values.count, by: length).map { start in
            let line = Array(values[start..<min(values.count, start + length)])
            return line + [CellValue](repeating: pad, count: length - line.count)
        }
    }
}

/// References written as text, for `INDIRECT` and `ADDRESS`.
public enum FormulaReferenceText {
    /// A sheet name as a reference writes it, quoted when it needs to be.
    public static func quotedSheet(_ name: String) -> String {
        let plain = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
            && !(name.first?.isNumber ?? true) && CellAddress(a1: name) == nil
        return plain ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// An A1-style reference or a defined name.
    public static func a1(_ text: String, evaluator: FormulaEvaluator) -> FormulaReference? {
        guard let node = try? FormulaParser.parse(text) else { return nil }
        switch node {
        case .reference, .range, .definedName, .binary(":", _, _):
            return evaluator.reference(node)
        default:
            return nil
        }
    }

    /// An R1C1-style reference: `R2C3`, `R[-1]C`, `R1C1:R2C2`, optionally
    /// sheet-qualified. Bracketed offsets are relative to `origin`.
    public static func r1c1(_ raw: String, relativeTo origin: CellAddress?) -> FormulaReference? {
        var text = raw
        var sheet: String?
        if let bang = text.lastIndex(of: "!") {
            var name = String(text[..<bang])
            if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            sheet = name
            text = String(text[text.index(after: bang)...])
        }
        let parts = text.uppercased().split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        var corners: [CellAddress] = []
        for part in parts {
            guard let address = address(String(part), origin: origin) else { return nil }
            corners.append(address)
        }
        return FormulaReference(sheet: sheet, range: CellRange(start: corners[0], end: corners[corners.count - 1]))
    }

    private static func address(_ text: String, origin: CellAddress?) -> CellAddress? {
        let characters = Array(text)
        var index = 0
        func component(_ letter: Character, base: Int?) -> Int? {
            guard index < characters.count, characters[index] == letter else { return nil }
            index += 1
            if index < characters.count, characters[index] == "[" {
                guard let close = characters[index...].firstIndex(of: "]"), let base,
                      let offset = Int(String(characters[(index + 1)..<close])) else { return nil }
                index = close + 1
                return base + offset
            }
            var digits = ""
            while index < characters.count, characters[index].isNumber {
                digits.append(characters[index])
                index += 1
            }
            if digits.isEmpty { return base }
            guard let value = Int(digits), value >= 1 else { return nil }
            return value - 1
        }
        guard let row = component("R", base: origin?.row), let column = component("C", base: origin?.column),
              index == characters.count, row >= 0, column >= 0,
              row <= SheetLimits.maxRow, column <= SheetLimits.maxColumn else { return nil }
        return CellAddress(row: row, column: column)
    }
}
