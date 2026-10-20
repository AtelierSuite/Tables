import Foundation

extension FormulaFunctions {
    public static let descriptiveFunctions: [String: FunctionSpec] = makeDescriptiveFunctions()

    private static func makeDescriptiveFunctions() -> [String: FunctionSpec] {
        var table: [String: FunctionSpec] = [
            "MAXA": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
                .number(try call.allNumbers(mode: .valuesAsNumbers).max() ?? 0)
            },
            "MINA": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
                .number(try call.allNumbers(mode: .valuesAsNumbers).min() ?? 0)
            },
            "MAXIFS": FunctionSpec(3...255, lifts: .matching({ $0 >= 2 && $0 % 2 == 0 })) { call throws(CellError) in
                let matched = try criteriaMatches(call, firstPair: 1)
                return .number(try numbersAt(matched, in: call.matrix(0)).max() ?? 0)
            },
            "MINIFS": FunctionSpec(3...255, lifts: .matching({ $0 >= 2 && $0 % 2 == 0 })) { call throws(CellError) in
                let matched = try criteriaMatches(call, firstPair: 1)
                return .number(try numbersAt(matched, in: call.matrix(0)).min() ?? 0)
            },
            "AVEDEV": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
                let numbers = try call.allNumbers()
                guard !numbers.isEmpty else { throw .numberError }
                let mean = FormulaMath.sum(numbers) / Double(numbers.count)
                return .number(FormulaMath.sum(numbers.map { abs($0 - mean) }) / Double(numbers.count))
            },
            "DEVSQ": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
                let numbers = try call.allNumbers()
                guard !numbers.isEmpty else { throw .numberError }
                return .number(FormulaStatistics.squaredDeviations(numbers))
            },
            "GEOMEAN": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
                let numbers = try call.allNumbers()
                guard !numbers.isEmpty, numbers.allSatisfy({ $0 > 0 }) else { throw .numberError }
                return .number(exp(FormulaMath.sum(numbers.map(log)) / Double(numbers.count)))
            },
            "HARMEAN": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
                let numbers = try call.allNumbers()
                guard !numbers.isEmpty, numbers.allSatisfy({ $0 > 0 }) else { throw .numberError }
                return .number(Double(numbers.count) / FormulaMath.sum(numbers.map { 1 / $0 }))
            },
            "TRIMMEAN": FunctionSpec(2...2, lifts: .only([1])) { call throws(CellError) in
                let numbers = try call.numbers([0]).sorted()
                let percent = try call.number(1)
                guard !numbers.isEmpty, percent >= 0, percent < 1 else { throw .numberError }
                // Excel trims a whole number of points from each end, rounding down.
                let trimmed = Int((Double(numbers.count) * percent / 2).rounded(.down))
                let kept = numbers[trimmed..<(numbers.count - trimmed)]
                return .number(FormulaMath.sum(Array(kept)) / Double(kept.count))
            },
            "KURT": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
                let numbers = try call.allNumbers()
                let n = Double(numbers.count)
                guard numbers.count >= 4 else { throw .divideByZero }
                let deviation = sqrt(try FormulaStatistics.variance(numbers, sample: true))
                guard deviation > 0 else { throw .divideByZero }
                let mean = FormulaMath.sum(numbers) / n
                let fourth = FormulaMath.sum(numbers.map { pow(($0 - mean) / deviation, 4) })
                return .number(n * (n + 1) / ((n - 1) * (n - 2) * (n - 3)) * fourth
                               - 3 * (n - 1) * (n - 1) / ((n - 2) * (n - 3)))
            },
            "SKEW": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
                let numbers = try call.allNumbers()
                let n = Double(numbers.count)
                guard numbers.count >= 3 else { throw .divideByZero }
                let deviation = sqrt(try FormulaStatistics.variance(numbers, sample: true))
                guard deviation > 0 else { throw .divideByZero }
                let mean = FormulaMath.sum(numbers) / n
                let third = FormulaMath.sum(numbers.map { pow(($0 - mean) / deviation, 3) })
                return .number(n / ((n - 1) * (n - 2)) * third)
            },
            "SKEW.P": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
                let numbers = try call.allNumbers()
                let n = Double(numbers.count)
                guard numbers.count >= 1 else { throw .divideByZero }
                let deviation = sqrt(try FormulaStatistics.variance(numbers, sample: false))
                guard deviation > 0 else { throw .divideByZero }
                let mean = FormulaMath.sum(numbers) / n
                return .number(FormulaMath.sum(numbers.map { pow(($0 - mean) / deviation, 3) }) / n)
            },
            "MODE.MULT": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
                let modes = try FormulaStatistics.modes(call.allNumbers())
                return .block(modes.map { [.number($0)] })
            },
            "PERCENTILE.EXC": FunctionSpec(2...2, lifts: .only([1])) { call throws(CellError) in
                .number(try FormulaStatistics.percentile(call.numbers([0]), try call.number(1), exclusive: true))
            },
            "QUARTILE.EXC": FunctionSpec(2...2, lifts: .only([1])) { call throws(CellError) in
                let quart = try call.integer(1)
                guard (1...3).contains(quart) else { throw .numberError }
                return .number(try FormulaStatistics.percentile(call.numbers([0]), Double(quart) / 4, exclusive: true))
            },
            "PERCENTRANK.EXC": FunctionSpec(2...3, lifts: .only([1, 2])) { call throws(CellError) in
                try FormulaStatistics.percentRank(call, exclusive: true)
            },
            "RANK.AVG": FunctionSpec(2...3, lifts: .only([0, 2])) { call throws(CellError) in
                try FormulaStatistics.rank(call, averagingTies: true)
            },
            "FREQUENCY": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
                let data = try call.numbers([0])
                let bins = try call.numbers([1])
                let order = bins.indices.sorted { bins[$0] < bins[$1] }
                var counts = [Double](repeating: 0, count: bins.count + 1)
                for value in data {
                    if let bin = order.first(where: { value <= bins[$0] }) {
                        counts[bin] += 1
                    } else {
                        counts[bins.count] += 1
                    }
                }
                return .block(counts.map { [.number($0)] })
            },
            "COVARIANCE.S": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
                .number(try FormulaStatistics.covariance(FormulaStatistics.pairedNumbers(call), sample: true))
            },
            "SLOPE": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
                .number(try FormulaStatistics.simpleRegression(call).slope)
            },
            "INTERCEPT": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
                .number(try FormulaStatistics.simpleRegression(call).intercept)
            },
            "RSQ": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
                let r = try FormulaStatistics.correlation(FormulaStatistics.pairedNumbers(call))
                return .number(r * r)
            },
            "STEYX": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
                let pairs = try FormulaStatistics.pairedNumbers(call)
                guard pairs.count >= 3 else { throw .divideByZero }
                let fit = try FormulaStatistics.simpleRegression(call)
                let residuals = pairs.map { $0.y - (fit.intercept + fit.slope * $0.x) }
                return .number(sqrt(FormulaMath.sum(residuals.map { $0 * $0 }) / Double(pairs.count - 2)))
            },
            "FORECAST.LINEAR": FunctionSpec(3...3, lifts: .only([0])) { call throws(CellError) in
                let x = try call.number(0)
                let fit = try FormulaStatistics.simpleRegression(call, yIndex: 1, xIndex: 2)
                return .number(fit.intercept + fit.slope * x)
            },
            "TREND": FunctionSpec(1...4, lifts: .none) { call throws(CellError) in
                try FormulaRegression.projection(call, logarithmic: false)
            },
            "GROWTH": FunctionSpec(1...4, lifts: .none) { call throws(CellError) in
                try FormulaRegression.projection(call, logarithmic: true)
            },
            "LINEST": FunctionSpec(1...4, lifts: .none) { call throws(CellError) in
                try FormulaRegression.estimate(call, logarithmic: false)
            },
            "LOGEST": FunctionSpec(1...4, lifts: .none) { call throws(CellError) in
                try FormulaRegression.estimate(call, logarithmic: true)
            },
            "STANDARDIZE": FunctionSpec(3...3) { call throws(CellError) in
                let deviation = try call.number(2)
                guard deviation > 0 else { throw .numberError }
                return .number((try call.number(0) - call.number(1)) / deviation)
            },
            "FISHER": .unary { value throws(CellError) in
                guard abs(value) < 1 else { throw .numberError }
                return 0.5 * log((1 + value) / (1 - value))
            },
            "FISHERINV": .unary { value in tanh(value) },
            "PERMUT": .binary { n, k throws(CellError) in
                let items = n.rounded(.towardZero)
                let chosen = k.rounded(.towardZero)
                guard items > 0 || (items == 0 && chosen == 0), chosen >= 0, items >= chosen else { throw .numberError }
                var result = 1.0
                var i = 0.0
                while i < chosen {
                    result *= items - i
                    i += 1
                }
                guard result.isFinite else { throw .numberError }
                return result
            },
            "PERMUTATIONA": .binary { n, k throws(CellError) in
                let items = n.rounded(.towardZero)
                let chosen = k.rounded(.towardZero)
                guard items >= 0, chosen >= 0 else { throw .numberError }
                return pow(items, chosen)
            },
            "PROB": FunctionSpec(3...4, lifts: .none) { call throws(CellError) in
                let values = try call.matrix(0).flatMap { $0 }
                let probabilities = try call.matrix(1).flatMap { $0 }
                guard values.count == probabilities.count else { throw .notAvailable }
                let lower = try call.number(2)
                let upper = try call.number(3, default: lower)
                var total = 0.0
                var result = 0.0
                for (value, probability) in zip(values, probabilities) {
                    guard case .number(let p) = probability, p >= 0, p <= 1 else { throw .numberError }
                    total += p
                    if case .number(let x) = value, x >= lower, x <= upper { result += p }
                }
                guard abs(total - 1) < 1e-7 else { throw .numberError }
                return .number(result)
            },
        ]

        // Old and new names for the same calculations.
        let sampleDeviation = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(sqrt(try FormulaStatistics.variance(call.allNumbers(), sample: true)))
        }
        let populationDeviation = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(sqrt(try FormulaStatistics.variance(call.allNumbers(), sample: false)))
        }
        let sampleVariance = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(try FormulaStatistics.variance(call.allNumbers(), sample: true))
        }
        let populationVariance = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(try FormulaStatistics.variance(call.allNumbers(), sample: false))
        }
        let mode = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            guard let first = try FormulaStatistics.modes(call.allNumbers()).first else { throw .notAvailable }
            return .number(first)
        }
        let percentile = FunctionSpec(2...2, lifts: .only([1])) { call throws(CellError) in
            .number(try FormulaStatistics.percentile(call.numbers([0]), try call.number(1), exclusive: false))
        }
        let quartile = FunctionSpec(2...2, lifts: .only([1])) { call throws(CellError) in
            let quart = try call.integer(1)
            guard (0...4).contains(quart) else { throw .numberError }
            return .number(try FormulaStatistics.percentile(call.numbers([0]), Double(quart) / 4, exclusive: false))
        }
        let percentRank = FunctionSpec(2...3, lifts: .only([1, 2])) { call throws(CellError) in
            try FormulaStatistics.percentRank(call, exclusive: false)
        }
        let rank = FunctionSpec(2...3, lifts: .only([0, 2])) { call throws(CellError) in
            try FormulaStatistics.rank(call, averagingTies: false)
        }
        let correlation = FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            .number(try FormulaStatistics.correlation(FormulaStatistics.pairedNumbers(call)))
        }
        let populationCovariance = FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            .number(try FormulaStatistics.covariance(FormulaStatistics.pairedNumbers(call), sample: false))
        }
        let forecast = FunctionSpec(3...3, lifts: .only([0])) { call throws(CellError) in
            let x = try call.number(0)
            let fit = try FormulaStatistics.simpleRegression(call, yIndex: 1, xIndex: 2)
            return .number(fit.intercept + fit.slope * x)
        }
        for name in ["STDEV.S"] { table[name] = sampleDeviation }
        for name in ["STDEV.P", "STDEVP"] { table[name] = populationDeviation }
        for name in ["VAR.S"] { table[name] = sampleVariance }
        for name in ["VAR.P", "VARP"] { table[name] = populationVariance }
        table["STDEVA"] = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(sqrt(try FormulaStatistics.variance(call.allNumbers(mode: .valuesAsNumbers), sample: true)))
        }
        table["STDEVPA"] = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(sqrt(try FormulaStatistics.variance(call.allNumbers(mode: .valuesAsNumbers), sample: false)))
        }
        table["VARA"] = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(try FormulaStatistics.variance(call.allNumbers(mode: .valuesAsNumbers), sample: true))
        }
        table["VARPA"] = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(try FormulaStatistics.variance(call.allNumbers(mode: .valuesAsNumbers), sample: false))
        }
        for name in ["MODE", "MODE.SNGL"] { table[name] = mode }
        for name in ["PERCENTILE", "PERCENTILE.INC"] { table[name] = percentile }
        for name in ["QUARTILE", "QUARTILE.INC"] { table[name] = quartile }
        for name in ["PERCENTRANK", "PERCENTRANK.INC"] { table[name] = percentRank }
        for name in ["RANK", "RANK.EQ"] { table[name] = rank }
        for name in ["CORREL", "PEARSON"] { table[name] = correlation }
        for name in ["COVAR", "COVARIANCE.P"] { table[name] = populationCovariance }
        table["FORECAST"] = forecast
        return table
    }
}

extension FormulaStatistics {
    public static func squaredDeviations(_ numbers: [Double]) -> Double {
        let mean = FormulaMath.sum(numbers) / Double(numbers.count)
        return FormulaMath.sum(numbers.map { ($0 - mean) * ($0 - mean) })
    }

    /// The most frequent values, in the order each first appears. A list with
    /// no repeated value has no mode.
    public static func modes(_ numbers: [Double]) throws(CellError) -> [Double] {
        var counts: [Double: Int] = [:]
        var order: [Double] = []
        for number in numbers {
            if counts[number] == nil { order.append(number) }
            counts[number, default: 0] += 1
        }
        let highest = counts.values.max() ?? 0
        guard highest > 1 else { throw .notAvailable }
        return order.filter { counts[$0] == highest }
    }

    /// The k-th percentile by linear interpolation between ranks. The inclusive
    /// form ranks from 0 to n − 1; the exclusive one from 1 to n, and refuses
    /// what falls outside its data.
    public static func percentile(_ numbers: [Double], _ k: Double, exclusive: Bool) throws(CellError) -> Double {
        let sorted = numbers.sorted()
        let n = Double(sorted.count)
        guard !sorted.isEmpty else { throw .numberError }
        let position: Double
        if exclusive {
            guard k > 0, k < 1 else { throw .numberError }
            position = k * (n + 1) - 1
            guard position >= 0, position <= n - 1 else { throw .numberError }
        } else {
            guard k >= 0, k <= 1 else { throw .numberError }
            position = k * (n - 1)
        }
        let lower = Int(position.rounded(.down))
        let fraction = position - Double(lower)
        guard lower + 1 < sorted.count else { return sorted[lower] }
        return sorted[lower] + fraction * (sorted[lower + 1] - sorted[lower])
    }

    /// `PERCENTRANK` and its variants: where a value sits among the data, as a
    /// fraction interpolated between neighbours and cut, not rounded, to the
    /// requested digits.
    public static func percentRank(_ call: FunctionCall, exclusive: Bool) throws(CellError) -> FormulaValue {
        let sorted = try call.numbers([0]).sorted()
        let x = try call.number(1)
        let digits = try call.integer(2, default: 3)
        guard !sorted.isEmpty, digits >= 1 else { throw .numberError }
        guard let first = sorted.first, let last = sorted.last, x >= first, x <= last else { throw .notAvailable }
        let n = Double(sorted.count)
        func rank(at index: Int) -> Double {
            if exclusive { return Double(index + 1) / (n + 1) }
            return sorted.count == 1 ? 1 : Double(index) / (n - 1)
        }
        let result: Double
        if let index = sorted.firstIndex(of: x) {
            result = rank(at: index)
        } else {
            let upper = sorted.firstIndex { $0 > x } ?? (sorted.count - 1)
            let lower = upper - 1
            let fraction = (x - sorted[lower]) / (sorted[upper] - sorted[lower])
            result = rank(at: lower) + fraction * (rank(at: upper) - rank(at: lower))
        }
        let scale = pow(10, Double(digits))
        return .number((FormulaMath.significant(result * scale)).rounded(.down) / scale)
    }

    /// `RANK` and its variants: position counted from the largest by default,
    /// from the smallest when `order` is non-zero.
    public static func rank(_ call: FunctionCall, averagingTies: Bool) throws(CellError) -> FormulaValue {
        let x = try call.number(0)
        let numbers = try call.numbers([1])
        let ascending = try call.number(2, default: 0) != 0
        guard numbers.contains(x) else { throw .notAvailable }
        let before = numbers.filter { ascending ? $0 < x : $0 > x }.count
        let ties = numbers.filter { $0 == x }.count
        return .number(averagingTies ? Double(before) + Double(ties + 1) / 2 : Double(before + 1))
    }

    /// Positions where both arrays hold numbers, for the two-variable statistics.
    /// The arrays must have the same number of cells.
    public static func pairedNumbers(_ call: FunctionCall, yIndex: Int = 0, xIndex: Int = 1) throws(CellError) -> [(y: Double, x: Double)] {
        let ys = try call.matrix(yIndex).flatMap { $0 }
        let xs = try call.matrix(xIndex).flatMap { $0 }
        guard ys.count == xs.count else { throw .notAvailable }
        var pairs: [(y: Double, x: Double)] = []
        for (y, x) in zip(ys, xs) {
            if let error = y.errorValue ?? x.errorValue { throw error }
            if case .number(let a) = y, case .number(let b) = x { pairs.append((a, b)) }
        }
        return pairs
    }

    public static func covariance(_ pairs: [(y: Double, x: Double)], sample: Bool) throws(CellError) -> Double {
        guard pairs.count >= (sample ? 2 : 1) else { throw .divideByZero }
        let n = Double(pairs.count)
        let meanY = FormulaMath.sum(pairs.map(\.y)) / n
        let meanX = FormulaMath.sum(pairs.map(\.x)) / n
        return FormulaMath.sum(pairs.map { ($0.y - meanY) * ($0.x - meanX) }) / (sample ? n - 1 : n)
    }

    public static func correlation(_ pairs: [(y: Double, x: Double)]) throws(CellError) -> Double {
        guard pairs.count >= 2 else { throw .divideByZero }
        let n = Double(pairs.count)
        let meanY = FormulaMath.sum(pairs.map(\.y)) / n
        let meanX = FormulaMath.sum(pairs.map(\.x)) / n
        let sxy = FormulaMath.sum(pairs.map { ($0.y - meanY) * ($0.x - meanX) })
        let sxx = FormulaMath.sum(pairs.map { ($0.x - meanX) * ($0.x - meanX) })
        let syy = FormulaMath.sum(pairs.map { ($0.y - meanY) * ($0.y - meanY) })
        guard sxx > 0, syy > 0 else { throw .divideByZero }
        return sxy / sqrt(sxx * syy)
    }

    /// The least-squares line through paired data.
    public static func simpleRegression(
        _ call: FunctionCall, yIndex: Int = 0, xIndex: Int = 1
    ) throws(CellError) -> (slope: Double, intercept: Double) {
        let pairs = try pairedNumbers(call, yIndex: yIndex, xIndex: xIndex)
        guard pairs.count >= 2 else { throw .divideByZero }
        let n = Double(pairs.count)
        let meanY = FormulaMath.sum(pairs.map(\.y)) / n
        let meanX = FormulaMath.sum(pairs.map(\.x)) / n
        let sxx = FormulaMath.sum(pairs.map { ($0.x - meanX) * ($0.x - meanX) })
        guard sxx > 0 else { throw .divideByZero }
        let slope = FormulaMath.sum(pairs.map { ($0.y - meanY) * ($0.x - meanX) }) / sxx
        return (slope, meanY - slope * meanX)
    }
}

/// Multiple linear regression for `LINEST`, `LOGEST`, `TREND` and `GROWTH`.
public enum FormulaRegression {
    public struct Fit: Sendable {
        /// One per predictor, then the intercept.
        public var coefficients: [Double]
        public var standardErrors: [Double]
        public var rSquared: Double
        public var standardErrorY: Double
        public var fStatistic: Double
        public var degreesOfFreedom: Double
        public var regressionSumOfSquares: Double
        public var residualSumOfSquares: Double
    }

    /// The observations and predictors: `y` as a list and each row of `x` the
    /// predictors for one observation. Predictors run down columns when `y`
    /// is a column and across rows when it is a row.
    public static func data(_ call: FunctionCall) throws(CellError) -> (y: [Double], x: [[Double]], byColumns: Bool) {
        let yMatrix = try FormulaMath.numericMatrix(call.matrix(0))
        let byColumns = yMatrix.first?.count == 1
        let y = yMatrix.flatMap { $0 }
        let n = y.count
        guard n > 0 else { throw .valueError }
        if call.isMissing(1) {
            return (y, (1...n).map { [Double($0)] }, byColumns)
        }
        let xMatrix = try FormulaMath.numericMatrix(call.matrix(1))
        let x: [[Double]]
        if xMatrix.count == yMatrix.count, xMatrix.first?.count == yMatrix.first?.count {
            x = xMatrix.flatMap { $0 }.map { [$0] }
        } else if byColumns, xMatrix.count == n {
            x = xMatrix
        } else if !byColumns, xMatrix.first?.count == n {
            x = (0..<n).map { column in xMatrix.map { $0[column] } }
        } else {
            throw .referenceError
        }
        return (y, x, byColumns)
    }

    /// Least squares through the normal equations, after dropping predictors
    /// that are linear combinations of earlier ones — Excel reports those with
    /// a coefficient of 0 rather than failing.
    public static func fit(y: [Double], x: [[Double]], constant: Bool) throws(CellError) -> Fit {
        let n = y.count
        let k = x.first?.count ?? 0
        let columns = k + (constant ? 1 : 0)
        let design = x.map { row in row + (constant ? [1] : []) }
        let meanY = FormulaMath.sum(y) / Double(n)

        // Keep only independent columns.
        var kept: [Int] = []
        for column in 0..<columns {
            let candidate = kept + [column]
            let sub = design.map { row in candidate.map { row[$0] } }
            if rank(sub) == candidate.count { kept = candidate }
        }
        let p = kept.count
        guard p > 0, n > 0 else { throw .numberError }
        let reduced = design.map { row in kept.map { row[$0] } }
        // Normal equations on the independent columns.
        var xtx = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var xty = [Double](repeating: 0, count: p)
        for i in 0..<n {
            for a in 0..<p {
                xty[a] += reduced[i][a] * y[i]
                for b in 0..<p { xtx[a][b] += reduced[i][a] * reduced[i][b] }
            }
        }
        guard let inverse = FormulaMath.inverse(xtx) else { throw .numberError }
        let beta = (0..<p).map { a in FormulaMath.sum((0..<p).map { inverse[a][$0] * xty[$0] }) }

        var fitted = [Double](repeating: 0, count: n)
        for i in 0..<n { fitted[i] = FormulaMath.sum((0..<p).map { reduced[i][$0] * beta[$0] }) }
        let residual = FormulaMath.sum((0..<n).map { (y[$0] - fitted[$0]) * (y[$0] - fitted[$0]) })
        let total = constant
            ? FormulaMath.sum(y.map { ($0 - meanY) * ($0 - meanY) })
            : FormulaMath.sum(y.map { $0 * $0 })
        let regression = total - residual
        let degrees = Double(n - p)
        let variance = degrees > 0 ? residual / degrees : 0
        let predictors = Double(p - (constant && kept.contains(k) ? 1 : 0))

        var coefficients = [Double](repeating: 0, count: k + 1)
        var errors = [Double](repeating: 0, count: k + 1)
        for (position, column) in kept.enumerated() {
            coefficients[column] = beta[position]
            errors[column] = sqrt(max(0, variance * inverse[position][position]))
        }
        return Fit(
            coefficients: coefficients, standardErrors: errors,
            rSquared: total > 0 ? regression / total : 1,
            standardErrorY: sqrt(variance),
            fStatistic: degrees > 0 && predictors > 0 && residual > 0 ? (regression / predictors) / (residual / degrees) : 0,
            degreesOfFreedom: degrees, regressionSumOfSquares: regression, residualSumOfSquares: residual
        )
    }

    /// The rank of a matrix, by elimination with a relative tolerance.
    private static func rank(_ matrix: [[Double]]) -> Int {
        var a = matrix
        let rows = a.count
        let columns = a.first?.count ?? 0
        let scale = a.flatMap { $0 }.map(abs).max() ?? 0
        let tolerance = max(1e-10, scale * 1e-12)
        var rank = 0
        for column in 0..<columns where rank < rows {
            guard let pivot = (rank..<rows).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  abs(a[pivot][column]) > tolerance else { continue }
            a.swapAt(pivot, rank)
            for row in (rank + 1)..<max(rank + 1, rows) {
                let factor = a[row][column] / a[rank][column]
                for k in column..<columns { a[row][k] -= factor * a[rank][k] }
            }
            rank += 1
        }
        return rank
    }

    /// `LINEST` and `LOGEST`: the coefficients, last predictor first, then the
    /// intercept; with statistics, the 5-row block Excel lays out.
    public static func estimate(_ call: FunctionCall, logarithmic: Bool) throws(CellError) -> FormulaValue {
        var (y, x, _) = try data(call)
        if logarithmic {
            guard y.allSatisfy({ $0 > 0 }) else { throw .numberError }
            y = y.map(log)
        }
        let constant = try call.boolean(2, default: true)
        let statistics = try call.boolean(3, default: false)
        let fit = try fit(y: y, x: x, constant: constant)
        let k = x.first?.count ?? 0
        func transform(_ value: Double) -> Double { logarithmic ? exp(value) : value }
        let fixedConstant: Double = logarithmic ? 1 : 0
        let coefficients = (0..<k).reversed().map { transform(fit.coefficients[$0]) }
            + [constant ? transform(fit.coefficients[k]) : fixedConstant]
        guard statistics else { return .block([coefficients.map(CellValue.number)]) }
        let errors = (0..<k).reversed().map { fit.standardErrors[$0] } + [constant ? fit.standardErrors[k] : .nan]
        let width = k + 1
        func row(_ values: [CellValue]) -> [CellValue] {
            values + [CellValue](repeating: .error(.notAvailable), count: max(0, width - values.count))
        }
        return .block([
            coefficients.map(CellValue.number),
            errors.map { $0.isNaN ? .error(.notAvailable) : .number($0) },
            row([.number(fit.rSquared), .number(fit.standardErrorY)]),
            row([.number(fit.fStatistic), .number(fit.degreesOfFreedom)]),
            row([.number(fit.regressionSumOfSquares), .number(fit.residualSumOfSquares)]),
        ])
    }

    /// `TREND` and `GROWTH`: the fitted line's values at new points, or at the
    /// known ones when none are given, laid out like the points.
    public static func projection(_ call: FunctionCall, logarithmic: Bool) throws(CellError) -> FormulaValue {
        var (y, x, byColumns) = try data(call)
        if logarithmic {
            guard y.allSatisfy({ $0 > 0 }) else { throw .numberError }
            y = y.map(log)
        }
        let constant = try call.boolean(3, default: true)
        let fit = try fit(y: y, x: x, constant: constant)
        let k = x.first?.count ?? 0

        var points: [[Double]]
        var shape: (rows: Int, columns: Int)
        if call.isMissing(2) {
            points = x
            let yShape = try call.matrix(0)
            shape = (yShape.count, yShape.first?.count ?? 1)
        } else {
            let matrix = try FormulaMath.numericMatrix(call.matrix(2))
            if k == 1 {
                points = matrix.flatMap { $0 }.map { [$0] }
                shape = (matrix.count, matrix.first?.count ?? 1)
            } else if byColumns {
                guard matrix.first?.count == k else { throw .referenceError }
                points = matrix
                shape = (matrix.count, 1)
            } else {
                guard matrix.count == k else { throw .referenceError }
                points = (0..<(matrix.first?.count ?? 0)).map { column in matrix.map { $0[column] } }
                shape = (1, points.count)
            }
        }
        let values = points.map { point -> Double in
            var value = constant ? fit.coefficients[k] : 0
            for index in 0..<k { value += fit.coefficients[index] * point[index] }
            return logarithmic ? exp(value) : value
        }
        guard values.count == shape.rows * shape.columns else { throw .referenceError }
        return .block((0..<shape.rows).map { row in
            (0..<shape.columns).map { .number(values[row * shape.columns + $0]) }
        })
    }
}
