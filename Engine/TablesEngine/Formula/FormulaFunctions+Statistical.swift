import Foundation

extension FormulaFunctions {
    public static let statisticalFunctions: [String: FunctionSpec] = [
        "AVERAGE": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            try FormulaStatistics.mean(call.allNumbers())
        },
        "AVERAGEA": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            try FormulaStatistics.mean(call.allNumbers(mode: .valuesAsNumbers))
        },
        "MAX": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(try call.allNumbers().max() ?? 0)
        },
        "MIN": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(try call.allNumbers().min() ?? 0)
        },
        "MEDIAN": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(try FormulaStatistics.median(call.allNumbers()))
        },
        "COUNT": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            var total = 0
            for index in 0..<call.count {
                let value = call.value(index)
                if call.isReference(index) || value.isMatrix {
                    total += value.flattened.filter(\.isNumber).count
                } else if !call.isMissing(index), (try? value.single.coercedNumber()) != nil, !value.single.isError {
                    total += 1
                }
            }
            return .number(Double(total))
        },
        "COUNTA": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            var total = 0
            for index in 0..<call.count where !call.isMissing(index) {
                let value = call.value(index)
                if call.isReference(index) || value.isMatrix {
                    total += value.flattened.filter { !$0.isEmpty }.count
                } else {
                    total += 1
                }
            }
            return .number(Double(total))
        },
        "COUNTBLANK": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            let cells = try call.matrix(0).flatMap { $0 }
            return .number(Double(cells.filter { cell in
                if case .text(let text) = cell { return text.isEmpty }
                return cell.isEmpty
            }.count))
        },
        "COUNTIF": FunctionSpec(2...2, lifts: .only([1])) { call throws(CellError) in
            let criterion = FormulaCriterion(call.scalar(1))
            return .number(Double(try call.matrix(0).flatMap { $0 }.filter(criterion.matches).count))
        },
        "COUNTIFS": FunctionSpec(2...254, lifts: .matching({ $0 % 2 == 1 })) { call throws(CellError) in
            let matched = try criteriaMatches(call, firstPair: 0)
            return .number(Double(matched.flatMap { $0 }.filter { $0 }.count))
        },
        "AVERAGEIF": FunctionSpec(2...3, lifts: .only([1])) { call throws(CellError) in
            let tested = try call.matrix(0)
            let criterion = FormulaCriterion(call.scalar(1))
            let averaged = try criteriaTarget(call, index: 2, shapedLike: 0, fallback: tested)
            let mask = tested.map { $0.map(criterion.matches) }
            var numbers: [Double] = []
            for (row, line) in mask.enumerated() {
                for (column, passes) in line.enumerated() where passes {
                    guard row < averaged.count, column < averaged[row].count else { continue }
                    switch averaged[row][column] {
                    case .number(let number): numbers.append(number)
                    case .error(let error): throw error
                    default: break
                    }
                }
            }
            return try FormulaStatistics.mean(numbers)
        },
        "AVERAGEIFS": FunctionSpec(3...255, lifts: .matching({ $0 >= 2 && $0 % 2 == 0 })) { call throws(CellError) in
            let matched = try criteriaMatches(call, firstPair: 1)
            return try FormulaStatistics.mean(numbersAt(matched, in: call.matrix(0)))
        },
        "LARGE": FunctionSpec(2...2, lifts: .only([1])) { call throws(CellError) in
            try FormulaStatistics.ranked(call, descending: true)
        },
        "SMALL": FunctionSpec(2...2, lifts: .only([1])) { call throws(CellError) in
            try FormulaStatistics.ranked(call, descending: false)
        },
        "STDEV": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(sqrt(try FormulaStatistics.variance(call.allNumbers(), sample: true)))
        },
        "VAR": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(try FormulaStatistics.variance(call.allNumbers(), sample: true))
        },
    ]
}

/// Descriptive statistics shared by the aggregate functions.
public enum FormulaStatistics {
    public static func mean(_ numbers: [Double]) throws(CellError) -> FormulaValue {
        guard !numbers.isEmpty else { throw .divideByZero }
        return .number(FormulaMath.sum(numbers) / Double(numbers.count))
    }

    public static func median(_ numbers: [Double]) throws(CellError) -> Double {
        guard !numbers.isEmpty else { throw .numberError }
        let sorted = numbers.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Sample variance divides by n − 1, population variance by n.
    public static func variance(_ numbers: [Double], sample: Bool) throws(CellError) -> Double {
        let minimum = sample ? 2 : 1
        guard numbers.count >= minimum else { throw .divideByZero }
        let mean = FormulaMath.sum(numbers) / Double(numbers.count)
        let squares = FormulaMath.sum(numbers.map { ($0 - mean) * ($0 - mean) })
        return squares / Double(numbers.count - (sample ? 1 : 0))
    }

    /// `LARGE` and `SMALL`: the k-th value of an array's numbers.
    public static func ranked(_ call: FunctionCall, descending: Bool) throws(CellError) -> FormulaValue {
        let numbers = try call.numbers([0])
        let k = Int(try call.number(1).rounded(.up))
        guard k >= 1, k <= numbers.count else { throw .numberError }
        let sorted = descending ? numbers.sorted(by: >) : numbers.sorted()
        return .number(sorted[k - 1])
    }
}
