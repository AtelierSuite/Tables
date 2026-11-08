import Foundation

extension FormulaFunctions {
    public static let subtotalFunctions: [String: FunctionSpec] = [
        "SUBTOTAL": FunctionSpec(2...255, lifts: .only([0])) { call throws(CellError) in
            let code = try call.integer(0)
            let ignoresHidden = code > 100
            guard let operation = FormulaSubtotal.Operation(code: ignoresHidden ? code - 100 : code),
                  operation.rawValue <= 11 else { throw .valueError }
            let cells = try FormulaSubtotal.cells(
                call, from: 1, skippingHidden: ignoresHidden, skippingNested: true, skippingErrors: false)
            return try FormulaSubtotal.apply(operation, to: cells)
        },
        "AGGREGATE": FunctionSpec(3...255, lifts: .only([0, 1])) { call throws(CellError) in
            let code = try call.integer(0)
            let options = try call.integer(1, default: 0)
            guard let operation = FormulaSubtotal.Operation(code: code), (0...7).contains(options) else {
                throw .valueError
            }
            let skippingNested = [0, 1, 2, 3].contains(options)
            let skippingHidden = [1, 3, 5, 7].contains(options)
            let skippingErrors = [2, 3, 6, 7].contains(options)
            if operation.takesParameter {
                guard call.count == 4 else { throw .valueError }
                let cells = try FormulaSubtotal.cells(
                    call, from: 2, through: 2, skippingHidden: skippingHidden,
                    skippingNested: skippingNested, skippingErrors: skippingErrors)
                return try FormulaSubtotal.apply(operation, to: cells, parameter: try call.number(3))
            }
            let cells = try FormulaSubtotal.cells(
                call, from: 2, skippingHidden: skippingHidden, skippingNested: skippingNested,
                skippingErrors: skippingErrors)
            return try FormulaSubtotal.apply(operation, to: cells)
        },
    ]
}

/// `SUBTOTAL` and `AGGREGATE`, which choose a calculation by number and can
/// pass over hidden rows, other subtotals, and errors.
public enum FormulaSubtotal {
    public enum Operation: Int, Sendable {
        case average = 1, count, countA, max, min, product, standardDeviation, populationDeviation, sum,
             variance, populationVariance, median, mode, large, small, percentileInclusive, quartileInclusive,
             percentileExclusive, quartileExclusive

        public init?(code: Int) { self.init(rawValue: code) }

        public var takesParameter: Bool { rawValue >= 14 }
    }

    /// The values of the arguments from `start`, leaving out what the options say to.
    public static func cells(
        _ call: FunctionCall, from start: Int, through end: Int? = nil,
        skippingHidden: Bool, skippingNested: Bool, skippingErrors: Bool
    ) throws(CellError) -> [CellValue] {
        var result: [CellValue] = []
        for index in start...(end ?? (call.count - 1)) where !call.isMissing(index) {
            guard let areas = call.areas(index) else {
                // An array from a calculation has no rows to hide or formulas
                // to recognise; only its errors can be passed over.
                let values = try call.matrix(index).flatMap { $0 }
                result += skippingErrors ? values.filter { !$0.isError } : values
                continue
            }
            for reference in areas {
                let values = call.evaluator.materialize(reference).rows
                let start = reference.range.start
                for (rowOffset, row) in values.enumerated() {
                    let rowIndex = start.row + rowOffset
                    if skippingHidden, call.context.isRowHidden(rowIndex, sheetName: reference.sheet) { continue }
                    for (columnOffset, value) in row.enumerated() {
                        if skippingErrors, value.isError { continue }
                        if skippingNested {
                            let address = CellAddress(row: rowIndex, column: start.column + columnOffset)
                            if let formula = call.context.cell(at: address, sheetName: reference.sheet)?.formula?.uppercased(),
                               formula.contains("SUBTOTAL(") || formula.contains("AGGREGATE(") { continue }
                        }
                        result.append(value)
                    }
                }
            }
        }
        return result
    }

    public static func apply(_ operation: Operation, to cells: [CellValue], parameter: Double = 0) throws(CellError) -> FormulaValue {
        if operation == .countA { return .number(Double(cells.filter { !$0.isEmpty }.count)) }
        if operation == .count { return .number(Double(cells.filter(\.isNumber).count)) }
        var numbers: [Double] = []
        for cell in cells {
            if case .error(let error) = cell { throw error }
            if case .number(let number) = cell { numbers.append(number) }
        }
        switch operation {
        case .average: return try FormulaStatistics.mean(numbers)
        case .max: return .number(numbers.max() ?? 0)
        case .min: return .number(numbers.min() ?? 0)
        case .product: return .number(numbers.isEmpty ? 0 : numbers.reduce(1, *))
        case .sum: return .number(FormulaMath.sum(numbers))
        case .standardDeviation: return .number(sqrt(try FormulaStatistics.variance(numbers, sample: true)))
        case .populationDeviation: return .number(sqrt(try FormulaStatistics.variance(numbers, sample: false)))
        case .variance: return .number(try FormulaStatistics.variance(numbers, sample: true))
        case .populationVariance: return .number(try FormulaStatistics.variance(numbers, sample: false))
        case .median: return .number(try FormulaStatistics.median(numbers))
        case .mode:
            guard let first = try FormulaStatistics.modes(numbers).first else { throw .notAvailable }
            return .number(first)
        case .large, .small:
            let k = Int(parameter.rounded(.up))
            guard k >= 1, k <= numbers.count else { throw .numberError }
            let sorted = operation == .large ? numbers.sorted(by: >) : numbers.sorted()
            return .number(sorted[k - 1])
        case .percentileInclusive:
            return .number(try FormulaStatistics.percentile(numbers, parameter, exclusive: false))
        case .percentileExclusive:
            return .number(try FormulaStatistics.percentile(numbers, parameter, exclusive: true))
        case .quartileInclusive:
            let quart = parameter.rounded(.towardZero)
            guard (0...4).contains(quart) else { throw .numberError }
            return .number(try FormulaStatistics.percentile(numbers, quart / 4, exclusive: false))
        case .quartileExclusive:
            let quart = parameter.rounded(.towardZero)
            guard (1...3).contains(quart) else { throw .numberError }
            return .number(try FormulaStatistics.percentile(numbers, quart / 4, exclusive: true))
        case .count, .countA:
            return .number(0)
        }
    }
}
