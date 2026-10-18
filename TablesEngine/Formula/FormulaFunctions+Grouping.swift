import Foundation

extension FormulaFunctions {
    public static let groupingFunctions: [String: FunctionSpec] = [
        "GROUPBY": FunctionSpec(3...8, lifts: .none) { call throws(CellError) in
            try FormulaGrouping.groupBy(call)
        },
        "PIVOTBY": FunctionSpec(4...11, lifts: .none) { call throws(CellError) in
            try FormulaGrouping.pivotBy(call)
        },
        "ENCODEURL": FunctionSpec(1...1) { call throws(CellError) in
            var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
            allowed.insert(charactersIn: "-_.~")
            return .text(try call.text(0).addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        },
    ]
}

/// `GROUPBY` and `PIVOTBY`: summaries of values by the distinct keys beside them.
public enum FormulaGrouping {
    /// A group's key, compared the way Excel compares for grouping.
    private struct Key: Hashable {
        var parts: [String]

        init(_ values: [CellValue]) {
            parts = values.map { value in
                switch value {
                case .text(let text): return "t" + text.lowercased()
                case .number(let number): return "n" + FormulaNumberText.general(number)
                case .boolean(let flag): return flag ? "bT" : "bF"
                case .error(let error): return "e" + error.rawValue
                case .empty: return "_"
                }
            }
        }
    }

    private struct Group {
        var values: [CellValue]
        var rows: [Int]
    }

    /// The fields and values with any header row split off, and the data
    /// rows the filter keeps. Headers are assumed when the call leaves it
    /// open and the first values are text above numbers.
    private static func prepare(
        _ call: FunctionCall, fieldIndices: [Int], valuesIndex: Int, headersIndex: Int, filterIndex: Int
    ) throws(CellError) -> (fields: [[[CellValue]]], values: [[CellValue]], fieldHeaders: [[CellValue]?],
                             valueHeaders: [CellValue]?, showsHeaders: Bool, rows: [Int]) {
        let values = try call.matrix(valuesIndex)
        let fields = try fieldIndices.map { index throws(CellError) in try call.matrix(index) }
        guard fields.allSatisfy({ $0.count == values.count }) else { throw .valueError }
        var mode = try call.integer(headersIndex, default: -1)
        if mode == -1 {
            // Headers are assumed when the first values are text above numbers.
            let firstIsText = values.first?.allSatisfy(\.isText) ?? false
            let secondHasNumber = values.count > 1 && values[1].contains(where: \.isNumber)
            mode = firstIsText && secondHasNumber ? 3 : 0
        }
        guard (0...3).contains(mode) else { throw .valueError }
        let hasHeaders = mode == 1 || mode == 3
        let start = hasHeaders ? 1 : 0
        var rows = Array(start..<values.count)
        if !call.isMissing(filterIndex) {
            let filter = try call.matrix(filterIndex).flatMap { $0 }
            guard filter.count == values.count - start || filter.count == values.count else { throw .valueError }
            let offset = filter.count == values.count ? 0 : start
            var kept: [Int] = []
            for row in rows {
                if try filter[row - offset].coercedBoolean() { kept.append(row) }
            }
            rows = kept
        }
        return (fields, values, fields.map { hasHeaders ? $0.first : nil },
                hasHeaders ? values.first : nil, mode == 3 || mode == 2, rows)
    }

    /// Applies the summary function to one block of values.
    private static func summarize(
        _ lambda: FormulaLambda, _ evaluator: FormulaEvaluator, _ subset: [CellValue], whole: [CellValue]
    ) -> CellValue {
        guard !subset.isEmpty else { return .empty }
        let column = FormulaValue.block(subset.map { [$0] })
        let arguments = lambda.parameters.count >= 2 ? [column, .block(whole.map { [$0] })] : [column]
        return FormulaLogic.single(evaluator.invoke(lambda, values: arguments))
    }

    /// Distinct keys in order of appearance, each with its rows.
    private static func groups(_ rows: [Int], key: (Int) -> [CellValue]) -> [Group] {
        var order: [Key] = []
        var table: [Key: Group] = [:]
        for row in rows {
            let values = key(row)
            let identity = Key(values)
            if table[identity] == nil {
                order.append(identity)
                table[identity] = Group(values: values, rows: [])
            }
            table[identity]?.rows.append(row)
        }
        return order.compactMap { table[$0] }
    }

    /// Orders rows by output columns, one-based, negative for descending.
    private static func sorted(_ rows: [[CellValue]], by keys: [Int]) -> [[CellValue]] {
        let columns = keys.compactMap { key -> ([CellValue], Int)? in
            let index = abs(key) - 1
            guard index >= 0, let width = rows.first?.count, index < width else { return nil }
            return (rows.map { $0[index] }, key < 0 ? -1 : 1)
        }
        return FormulaArrays.stableSorted(rows, keys: columns)
    }

    public static func groupBy(_ call: FunctionCall) throws(CellError) -> FormulaValue {
        let lambda = try call.lambda(2)
        let prepared = try prepare(call, fieldIndices: [0], valuesIndex: 1, headersIndex: 3, filterIndex: 6)
        let fields = prepared.fields[0]
        let values = prepared.values
        let keyWidth = fields.first?.count ?? 1
        let valueWidth = values.first?.count ?? 1
        let depth = try call.integer(4, default: 1)
        guard (-2...2).contains(depth) else { throw .valueError }
        let evaluator = call.evaluator

        func summaries(_ rows: [Int]) -> [CellValue] {
            (0..<valueWidth).map { column in
                summarize(lambda, evaluator, rows.map { values[$0][column] },
                          whole: prepared.rows.map { values[$0][column] })
            }
        }

        var body = groups(prepared.rows) { fields[$0] }.map { $0.values + summaries($0.rows) }
        let sortKeys = call.isMissing(5) ? Array(1...keyWidth) : try call.numbers([5]).map { Int($0) }
        guard sortKeys.allSatisfy({ $0 != 0 && abs($0) <= keyWidth + valueWidth }) else { throw .valueError }
        body = sorted(body, by: abs(depth) == 2 && keyWidth > 1 ? [1] + sortKeys.filter { abs($0) != 1 } : sortKeys)

        // Subtotals after each run sharing the first key.
        if abs(depth) == 2, keyWidth > 1 {
            var withSubtotals: [[CellValue]] = []
            var index = 0
            while index < body.count {
                let first = body[index][0]
                var end = index
                while end < body.count, FormulaComparison.equal(body[end][0], first) { end += 1 }
                let rows = prepared.rows.filter { FormulaComparison.equal(fields[$0][0], first) }
                let subtotal = [first] + [CellValue](repeating: .empty, count: keyWidth - 1) + summaries(rows)
                if depth < 0 { withSubtotals.append(subtotal) }
                withSubtotals += body[index..<end]
                if depth > 0 { withSubtotals.append(subtotal) }
                index = end
            }
            body = withSubtotals
        }
        if depth != 0 {
            let total = [CellValue.text("Total")] + [CellValue](repeating: .empty, count: keyWidth - 1)
                + summaries(prepared.rows)
            if depth < 0 { body.insert(total, at: 0) } else { body.append(total) }
        }
        if prepared.showsHeaders {
            let headers = (prepared.fieldHeaders[0] ?? (1...keyWidth).map { .text("Row Field \($0)") })
                + (prepared.valueHeaders ?? (1...valueWidth).map { .text("Value \($0)") })
            body.insert(headers, at: 0)
        }
        guard !body.isEmpty else { throw .calc }
        return .block(body)
    }

    public static func pivotBy(_ call: FunctionCall) throws(CellError) -> FormulaValue {
        let lambda = try call.lambda(3)
        let prepared = try prepare(call, fieldIndices: [0, 1], valuesIndex: 2, headersIndex: 4, filterIndex: 9)
        let rowFields = prepared.fields[0]
        let columnFields = prepared.fields[1]
        let values = prepared.values
        let rowWidth = rowFields.first?.count ?? 1
        let columnDepth = columnFields.first?.count ?? 1
        let valueWidth = values.first?.count ?? 1
        let rowTotals = try call.integer(5, default: 1)
        let columnTotals = try call.integer(7, default: 1)
        let relativeTo = try call.integer(10, default: 0)
        let evaluator = call.evaluator

        var rowGroups = groups(prepared.rows) { rowFields[$0] }
        var columnGroups = groups(prepared.rows) { columnFields[$0] }
        let rowSort = call.isMissing(6) ? [1] : try call.numbers([6]).map { Int($0) }
        let columnSort = call.isMissing(8) ? [1] : try call.numbers([8]).map { Int($0) }
        rowGroups = sortedGroups(rowGroups, by: rowSort)
        columnGroups = sortedGroups(columnGroups, by: columnSort)

        func cell(_ rows: [Int], column: Int, rowGroup: [Int]?, columnGroup: [Int]?) -> CellValue {
            let reference: [Int]
            switch relativeTo {
            case 1: reference = rowGroup ?? prepared.rows
            case 2: reference = prepared.rows
            default: reference = columnGroup ?? prepared.rows
            }
            return summarize(lambda, evaluator, rows.map { values[$0][column] },
                             whole: reference.map { values[$0][column] })
        }

        var columnBlocks: [(header: [CellValue], rows: [Int]?)] = columnGroups.map { ($0.values, $0.rows) }
        if columnTotals != 0 {
            let total = (header: [CellValue.text("Total")] + [CellValue](repeating: .empty, count: columnDepth - 1),
                         rows: [Int]?.none)
            if columnTotals < 0 { columnBlocks.insert(total, at: 0) } else { columnBlocks.append(total) }
        }

        var output: [[CellValue]] = []
        for level in 0..<columnDepth {
            var line = [CellValue](repeating: .empty, count: rowWidth)
            for block in columnBlocks {
                line += [CellValue](repeating: block.header[level], count: valueWidth)
            }
            output.append(line)
        }
        if valueWidth > 1 || prepared.showsHeaders {
            var line = prepared.showsHeaders
                ? (prepared.fieldHeaders[0] ?? [CellValue](repeating: .empty, count: rowWidth))
                : [CellValue](repeating: .empty, count: rowWidth)
            let names = prepared.valueHeaders ?? (1...valueWidth).map { .text("Value \($0)") }
            for _ in columnBlocks { line += names }
            output.append(line)
        }

        var bodyRows: [(header: [CellValue], rows: [Int]?)] = rowGroups.map { ($0.values, $0.rows) }
        if rowTotals != 0 {
            let total = (header: [CellValue.text("Total")] + [CellValue](repeating: .empty, count: rowWidth - 1),
                         rows: [Int]?.none)
            if rowTotals < 0 { bodyRows.insert(total, at: 0) } else { bodyRows.append(total) }
        }
        for rowBlock in bodyRows {
            var line = rowBlock.header
            let inRow = Set(rowBlock.rows ?? prepared.rows)
            for columnBlock in columnBlocks {
                let selected = (columnBlock.rows ?? prepared.rows).filter { inRow.contains($0) }
                for column in 0..<valueWidth {
                    line.append(cell(selected, column: column, rowGroup: rowBlock.rows, columnGroup: columnBlock.rows))
                }
            }
            output.append(line)
        }
        return .block(output)
    }

    private static func sortedGroups(_ groups: [Group], by keys: [Int]) -> [Group] {
        let width = groups.first?.values.count ?? 0
        let columns = keys.compactMap { key -> ([CellValue], Int)? in
            let index = abs(key) - 1
            guard index >= 0, index < width else { return nil }
            return (groups.map { $0.values[index] }, key < 0 ? -1 : 1)
        }
        let order = FormulaArrays.stableSorted(groups.indices.map { [.number(Double($0))] }, keys: columns)
        return order.compactMap { row in
            guard case .number(let index) = row.first else { return nil }
            return groups[Int(index)]
        }
    }
}
