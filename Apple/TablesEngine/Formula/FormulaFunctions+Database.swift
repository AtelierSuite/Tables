import Foundation

extension FormulaFunctions {
    public static let databaseFunctions: [String: FunctionSpec] = makeDatabaseFunctions()

    private static func makeDatabaseFunctions() -> [String: FunctionSpec] {
        var table: [String: FunctionSpec] = [:]
        let numeric: [(String, @Sendable ([Double]) throws(CellError) -> Double)] = [
            ("DSUM", { FormulaMath.sum($0) }),
            ("DAVERAGE", { numbers throws(CellError) in
                guard !numbers.isEmpty else { throw .divideByZero }
                return FormulaMath.sum(numbers) / Double(numbers.count)
            }),
            ("DMAX", { $0.max() ?? 0 }),
            ("DMIN", { $0.min() ?? 0 }),
            ("DPRODUCT", { $0.isEmpty ? 0 : $0.reduce(1, *) }),
            ("DSTDEV", { numbers throws(CellError) in sqrt(try FormulaStatistics.variance(numbers, sample: true)) }),
            ("DSTDEVP", { numbers throws(CellError) in sqrt(try FormulaStatistics.variance(numbers, sample: false)) }),
            ("DVAR", { numbers throws(CellError) in try FormulaStatistics.variance(numbers, sample: true) }),
            ("DVARP", { numbers throws(CellError) in try FormulaStatistics.variance(numbers, sample: false) }),
        ]
        for (name, operation) in numeric {
            table[name] = FunctionSpec(3...3, lifts: .none) { call throws(CellError) in
                let values = try FormulaDatabase.fieldValues(call, requireField: true)
                return .number(try operation(values.compactMap { if case .number(let n) = $0 { return n }; return nil }))
            }
        }
        table["DCOUNT"] = FunctionSpec(2...3, lifts: .none) { call throws(CellError) in
            let values = try FormulaDatabase.fieldValues(call, requireField: false)
            if call.isMissing(1) || call.count == 2 { return .number(Double(values.count)) }
            return .number(Double(values.filter(\.isNumber).count))
        }
        table["DCOUNTA"] = FunctionSpec(2...3, lifts: .none) { call throws(CellError) in
            let values = try FormulaDatabase.fieldValues(call, requireField: false)
            if call.isMissing(1) || call.count == 2 { return .number(Double(values.count)) }
            return .number(Double(values.filter { !$0.isEmpty }.count))
        }
        table["DGET"] = FunctionSpec(3...3, lifts: .none) { call throws(CellError) in
            let values = try FormulaDatabase.fieldValues(call, requireField: true)
            guard !values.isEmpty else { throw .valueError }
            guard values.count == 1 else { throw .numberError }
            return .scalar(values[0])
        }
        return table
    }
}

/// The D-functions' shared reading of a database, a field and a criteria range.
public enum FormulaDatabase {
    /// The field's values in every record the criteria accept. With no field,
    /// one entry per accepted record.
    public static func fieldValues(_ call: FunctionCall, requireField: Bool) throws(CellError) -> [CellValue] {
        let database = try call.matrix(0)
        guard let headers = database.first, database.count >= 1 else { throw .valueError }
        let criteriaIndex = call.count == 2 ? 1 : 2
        let criteria = try call.matrix(criteriaIndex)
        var column: Int?
        if call.count == 3, !call.isMissing(1) {
            column = try fieldColumn(call.scalar(1), headers: headers)
        } else if requireField {
            throw .valueError
        }

        // Each criteria row is a set of conditions that must all hold; a
        // record passes when any row accepts it.
        guard let criteriaHeaders = criteria.first else { throw .valueError }
        var rows: [[(Int, FormulaCriterion, CellValue)]] = []
        for line in criteria.dropFirst() {
            var conditions: [(Int, FormulaCriterion, CellValue)] = []
            for (index, cell) in line.enumerated() where !cell.isEmpty {
                guard index < criteriaHeaders.count,
                      let target = headers.firstIndex(where: { FormulaComparison.equal($0, criteriaHeaders[index]) })
                else { continue }
                conditions.append((target, FormulaCriterion(cell), cell))
            }
            rows.append(conditions)
        }
        if rows.isEmpty { rows = [[]] }

        var result: [CellValue] = []
        for record in database.dropFirst() {
            let accepted = rows.contains { conditions in
                conditions.allSatisfy { target, criterion, raw in
                    let value = target < record.count ? record[target] : .empty
                    // A bare word in a criteria range matches anything starting with it.
                    if case .text(let text) = raw, !text.isEmpty, !"<>=".contains(text.first!),
                       FormulaValueParser.number(from: text) == nil, case .text(let candidate) = value {
                        return FormulaWildcard.matches(candidate, pattern: text + "*")
                    }
                    return criterion.matches(value)
                }
            }
            guard accepted else { continue }
            if let column {
                result.append(column < record.count ? record[column] : .empty)
            } else {
                result.append(.boolean(true))
            }
        }
        return result
    }

    /// A field named by its heading or by its one-based position.
    private static func fieldColumn(_ field: CellValue, headers: [CellValue]) throws(CellError) -> Int {
        switch field {
        case .number(let number):
            let index = Int(number.rounded(.towardZero))
            guard index >= 1, index <= headers.count else { throw .valueError }
            return index - 1
        case .text:
            guard let index = headers.firstIndex(where: { FormulaComparison.equal($0, field) }) else {
                throw .valueError
            }
            return index
        case .error(let error):
            throw error
        default:
            throw .valueError
        }
    }
}
