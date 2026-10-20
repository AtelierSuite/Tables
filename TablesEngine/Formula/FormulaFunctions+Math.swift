import Foundation

extension FormulaFunctions {
    public static let mathFunctions: [String: FunctionSpec] = [
        "ABS": .unary { abs($0) },
        "SIGN": .unary { value in
            if value > 0 { return 1 }
            return value < 0 ? -1 : 0
        },
        "INT": .unary { FormulaMath.significant($0).rounded(.down) },
        "TRUNC": FunctionSpec(1...2) { call throws(CellError) in
            .number(FormulaMath.round(try call.number(0), digits: try call.integer(1, default: 0), rule: .towardZero))
        },
        "ROUND": FunctionSpec(2...2) { call throws(CellError) in
            .number(FormulaMath.round(try call.number(0), digits: try call.integer(1),
                                      rule: .toNearestOrAwayFromZero))
        },
        "ROUNDUP": FunctionSpec(2...2) { call throws(CellError) in
            .number(FormulaMath.round(try call.number(0), digits: try call.integer(1), rule: .awayFromZero))
        },
        "ROUNDDOWN": FunctionSpec(2...2) { call throws(CellError) in
            .number(FormulaMath.round(try call.number(0), digits: try call.integer(1), rule: .towardZero))
        },
        "MOD": .binary { number, divisor throws(CellError) in
            guard divisor != 0 else { throw .divideByZero }
            return FormulaMath.modulo(number, divisor)
        },
        "POWER": .binary { base, exponent throws(CellError) in try FormulaMath.power(base, exponent) },
        "SQRT": .unary { value throws(CellError) in
            guard value >= 0 else { throw .numberError }
            return sqrt(value)
        },
        "EXP": .unary { exp($0) },
        "LN": .unary { value throws(CellError) in
            guard value > 0 else { throw .numberError }
            return log(value)
        },
        "LOG10": .unary { value throws(CellError) in
            guard value > 0 else { throw .numberError }
            return log10(value)
        },
        "LOG": FunctionSpec(1...2) { call throws(CellError) in
            let value = try call.number(0)
            let base = try call.number(1, default: 10)
            guard value > 0, base > 0 else { throw .numberError }
            guard base != 1 else { throw .divideByZero }
            return .number(log(value) / log(base))
        },
        "PI": .constant { .number(.pi) },
        "RADIANS": .unary { $0 * .pi / 180 },
        "DEGREES": .unary { $0 * 180 / .pi },
        "SIN": .unary { sin($0) },
        "COS": .unary { cos($0) },
        "TAN": .unary { tan($0) },
        "ASIN": .unary { value throws(CellError) in
            guard abs(value) <= 1 else { throw .numberError }
            return asin(value)
        },
        "ACOS": .unary { value throws(CellError) in
            guard abs(value) <= 1 else { throw .numberError }
            return acos(value)
        },
        "ATAN": .unary { atan($0) },
        "ATAN2": .binary { x, y throws(CellError) in
            guard x != 0 || y != 0 else { throw .divideByZero }
            return atan2(y, x)
        },
        "CEILING": FunctionSpec(1...2) { call throws(CellError) in
            let value = try call.number(0)
            let step = try call.number(1, default: value < 0 ? -1 : 1)
            if step == 0 { return .number(0) }
            guard !(value > 0 && step < 0) else { throw .numberError }
            // A negative number with a positive step rounds toward zero.
            return .number(FormulaMath.multiple(value, of: step, rule: value < 0 && step > 0 ? .up : .awayFromZero))
        },
        "FLOOR": FunctionSpec(1...2) { call throws(CellError) in
            let value = try call.number(0)
            let step = try call.number(1, default: value < 0 ? -1 : 1)
            guard !(value > 0 && step < 0) else { throw .numberError }
            guard step != 0 else { throw value == 0 ? .numberError : .divideByZero }
            return .number(FormulaMath.multiple(value, of: step, rule: value < 0 && step > 0 ? .down : .towardZero))
        },
        "RAND": .constant { .number(Double.random(in: 0..<1)) },
        "RANDBETWEEN": FunctionSpec(2...2) { call throws(CellError) in
            let low = try call.number(0).rounded(.up)
            let high = try call.number(1).rounded(.down)
            guard low <= high, abs(low) < 1e15, abs(high) < 1e15 else { throw .numberError }
            return .number(Double(Int.random(in: Int(low)...Int(high))))
        },

        "SUM": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(FormulaMath.sum(try call.allNumbers()))
        },
        "PRODUCT": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            let numbers = try call.allNumbers()
            return .number(numbers.isEmpty ? 0 : numbers.reduce(1, *))
        },
        "SUMPRODUCT": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            let arrays = try (0..<call.count).map { index throws(CellError) in try call.matrix(index) }
            guard let first = arrays.first else { throw .valueError }
            let height = first.count
            let width = first.first?.count ?? 0
            guard arrays.allSatisfy({ $0.count == height && ($0.first?.count ?? 0) == width }) else {
                throw .valueError
            }
            var total = 0.0
            for row in 0..<height {
                for column in 0..<width {
                    var product = 1.0
                    for array in arrays {
                        switch array[row][column] {
                        case .number(let number): product *= number
                        case .error(let error): throw error
                        default: product = 0
                        }
                    }
                    total += product
                }
            }
            return .number(total)
        },
        "SUMIF": FunctionSpec(2...3, lifts: .only([1])) { call throws(CellError) in
            let tested = try call.matrix(0)
            let criterion = FormulaCriterion(call.scalar(1))
            let summed = try criteriaTarget(call, index: 2, shapedLike: 0, fallback: tested)
            var total = 0.0
            for (row, line) in tested.enumerated() {
                for (column, candidate) in line.enumerated() where criterion.matches(candidate) {
                    guard row < summed.count, column < summed[row].count else { continue }
                    if case .number(let number) = summed[row][column] { total += number }
                    if case .error(let error) = summed[row][column] { throw error }
                }
            }
            return .number(total)
        },
        "SUMIFS": FunctionSpec(3...255, lifts: .matching({ $0 >= 2 && $0 % 2 == 0 })) { call throws(CellError) in
            let matched = try criteriaMatches(call, firstPair: 1)
            return .number(FormulaMath.sum(try numbersAt(matched, in: call.matrix(0))))
        },
    ]

    /// The range a `SUMIF` or `AVERAGEIF` totals: the optional argument at
    /// `index`, which Excel resizes to the tested range's shape from its own
    /// top-left cell, or the tested range itself when it is left out.
    public static func criteriaTarget(
        _ call: FunctionCall, index: Int, shapedLike tested: Int, fallback: [[CellValue]]
    ) throws(CellError) -> [[CellValue]] {
        guard !call.isMissing(index) else { return fallback }
        if let target = call.reference(index), let source = call.reference(tested) {
            let start = target.range.start
            let end = CellAddress(row: start.row + source.rowCount - 1, column: start.column + source.columnCount - 1)
            return call.evaluator.materialize(FormulaReference(sheet: target.sheet, range: CellRange(start: start, end: end))).rows
        }
        return try call.matrix(index)
    }

    /// For the `…IFS` functions: which cells pass every criteria pair, starting
    /// with the pair at `firstPair`. All the ranges must share one shape.
    public static func criteriaMatches(_ call: FunctionCall, firstPair: Int) throws(CellError) -> [[Bool]] {
        guard (call.count - firstPair) % 2 == 0, call.count > firstPair else { throw .valueError }
        var result: [[Bool]]?
        var index = firstPair
        while index + 1 < call.count {
            let range = try call.matrix(index)
            let criterion = FormulaCriterion(call.scalar(index + 1))
            let passes = range.map { $0.map(criterion.matches) }
            if let existing = result {
                guard existing.count == range.count, existing.first?.count == range.first?.count else {
                    throw .valueError
                }
                result = zip(existing, passes).map { zip($0, $1).map { $0 && $1 } }
            } else {
                result = passes
            }
            index += 2
        }
        return result ?? []
    }

    /// The numbers of `values` where `mask` is set, which must be the same shape.
    public static func numbersAt(_ mask: [[Bool]], in values: [[CellValue]]) throws(CellError) -> [Double] {
        guard values.count == mask.count, values.first?.count == mask.first?.count else { throw .valueError }
        var numbers: [Double] = []
        for (row, line) in mask.enumerated() {
            for (column, passes) in line.enumerated() where passes {
                switch values[row][column] {
                case .number(let number): numbers.append(number)
                case .error(let error): throw error
                default: break
                }
            }
        }
        return numbers
    }
}

/// Number handling shared across the library.
public enum FormulaMath {
    /// A value rounded to fifteen significant digits, the precision Excel
    /// displays and rounds at. This is what makes `ROUND(2.675, 2)` 2.68 when
    /// the double nearest 2.675 sits just below it.
    public static func significant(_ value: Double) -> Double {
        guard value.isFinite, value != 0 else { return value }
        return Double(String(format: "%.15g", value)) ?? value
    }

    public static func round(_ value: Double, digits: Int, rule: FloatingPointRoundingRule) -> Double {
        let clamped = max(-308, min(308, digits))
        let factor = pow(10.0, Double(abs(clamped)))
        if clamped >= 0 {
            let scaled = significant(value * factor)
            guard scaled.isFinite, abs(scaled) < 1e300 else { return value }
            return scaled.rounded(rule) / factor
        }
        return significant(value / factor).rounded(rule) * factor
    }

    public enum MultipleRule: Sendable { case up, down, towardZero, awayFromZero, nearest }

    /// `value` rounded to a multiple of `step`.
    public static func multiple(_ value: Double, of step: Double, rule: MultipleRule) -> Double {
        guard step != 0 else { return 0 }
        let quotient = significant(value / step)
        let rounded: Double
        switch rule {
        case .up: rounded = (quotient * (step > 0 ? 1 : -1)).rounded(.up) * (step > 0 ? 1 : -1)
        case .down: rounded = (quotient * (step > 0 ? 1 : -1)).rounded(.down) * (step > 0 ? 1 : -1)
        case .towardZero: rounded = quotient.rounded(.towardZero)
        case .awayFromZero: rounded = quotient.rounded(.awayFromZero)
        case .nearest: rounded = quotient.rounded(.toNearestOrAwayFromZero)
        }
        return significant(rounded * step)
    }

    /// Excel's `MOD`: the remainder takes the divisor's sign.
    public static func modulo(_ number: Double, _ divisor: Double) -> Double {
        let quotient = significant(number / divisor).rounded(.down)
        return significant(number - divisor * quotient)
    }

    public static func power(_ base: Double, _ exponent: Double) throws(CellError) -> Double {
        if base == 0, exponent == 0 { throw .numberError }
        if base == 0, exponent < 0 { throw .divideByZero }
        let result = pow(base, exponent)
        guard result.isFinite else { throw .numberError }
        return result
    }

    /// A sum with compensation, so long columns of decimals do not drift.
    public static func sum(_ numbers: [Double]) -> Double {
        var total = 0.0
        var compensation = 0.0
        for number in numbers {
            let y = number - compensation
            let t = total + y
            compensation = (t - total) - y
            total = t
        }
        return total
    }
}
