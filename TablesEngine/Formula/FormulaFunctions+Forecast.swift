import Foundation

extension FormulaFunctions {
    public static let forecastFunctions: [String: FunctionSpec] = [
        "FORECAST.ETS": FunctionSpec(3...6, lifts: .only([0])) { call throws(CellError) in
            let target = try call.number(0)
            let model = try FormulaSmoothing.model(call, valuesIndex: 1, timelineIndex: 2, seasonalityIndex: 3,
                                                   completionIndex: 4, aggregationIndex: 5)
            return .number(try model.forecast(at: target))
        },
        "FORECAST.ETS.CONFINT": FunctionSpec(3...7, lifts: .only([0, 3])) { call throws(CellError) in
            let target = try call.number(0)
            let confidence = try call.number(3, default: 0.95)
            guard confidence > 0, confidence < 1 else { throw .numberError }
            let model = try FormulaSmoothing.model(call, valuesIndex: 1, timelineIndex: 2, seasonalityIndex: 4,
                                                   completionIndex: 5, aggregationIndex: 6)
            return .number(try model.interval(at: target, confidence: confidence))
        },
        "FORECAST.ETS.SEASONALITY": FunctionSpec(2...4, lifts: .none) { call throws(CellError) in
            let model = try FormulaSmoothing.model(call, valuesIndex: 0, timelineIndex: 1, seasonalityIndex: nil,
                                                   completionIndex: 2, aggregationIndex: 3)
            return .number(Double(model.season))
        },
        "FORECAST.ETS.STAT": FunctionSpec(3...6, lifts: .only([2])) { call throws(CellError) in
            let statistic = try call.integer(2)
            guard (1...8).contains(statistic) else { throw .numberError }
            let model = try FormulaSmoothing.model(call, valuesIndex: 0, timelineIndex: 1, seasonalityIndex: 3,
                                                   completionIndex: 4, aggregationIndex: 5)
            return .number(model.statistic(statistic))
        },
    ]
}

/// Additive Holt–Winters exponential smoothing (error, trend and season all
/// additive), as Excel's `FORECAST.ETS` family describes its model. The
/// smoothing constants are fitted by minimising the one-step squared error,
/// so results follow Excel's closely but are not guaranteed to match it to
/// the last digit: Excel does not document its fitting procedure.
public struct FormulaSmoothing: Sendable {
    public let values: [Double]
    public let start: Double
    public let step: Double
    public let season: Int
    public let alpha: Double
    public let beta: Double
    public let gamma: Double
    public let level: Double
    public let trend: Double
    public let seasonal: [Double]
    public let errors: [Double]

    public var end: Double { start + step * Double(values.count - 1) }

    public static func model(
        _ call: FunctionCall, valuesIndex: Int, timelineIndex: Int, seasonalityIndex: Int?,
        completionIndex: Int, aggregationIndex: Int
    ) throws(CellError) -> FormulaSmoothing {
        let rawValues = try call.matrix(valuesIndex).flatMap { $0 }
        let rawTimeline = try call.matrix(timelineIndex).flatMap { $0 }
        guard rawValues.count == rawTimeline.count, rawValues.count >= 3 else { throw .numberError }
        let completion = try call.integer(completionIndex, default: 1)
        let aggregation = try call.integer(aggregationIndex, default: 1)
        guard completion == 0 || completion == 1, (1...7).contains(aggregation) else { throw .numberError }

        // Gather points by time, aggregating duplicates.
        var buckets: [Double: [CellValue]] = [:]
        for (value, time) in zip(rawValues, rawTimeline) {
            guard case .number(let moment) = time else { throw .valueError }
            buckets[moment, default: []].append(value)
        }
        let times = buckets.keys.sorted()
        guard times.count >= 3 else { throw .numberError }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        guard let step = gaps.min(), step > 0,
              gaps.allSatisfy({ abs(($0 / step).rounded() - $0 / step) < 1e-9 }) else { throw .numberError }

        func aggregate(_ cells: [CellValue]) throws(CellError) -> Double? {
            let numbers = cells.compactMap { cell -> Double? in if case .number(let n) = cell { return n }; return nil }
            switch aggregation {
            case 2: return Double(numbers.count)
            case 3: return Double(cells.filter { !$0.isEmpty }.count)
            case 4: return numbers.max()
            case 5: return numbers.isEmpty ? nil : try FormulaStatistics.median(numbers)
            case 6: return numbers.min()
            case 7: return numbers.isEmpty ? nil : FormulaMath.sum(numbers)
            default: return numbers.isEmpty ? nil : FormulaMath.sum(numbers) / Double(numbers.count)
            }
        }

        // Lay the series on a regular grid, filling gaps.
        let count = Int(((times.last! - times.first!) / step).rounded()) + 1
        guard count <= 100_000 else { throw .numberError }
        var series = [Double?](repeating: nil, count: count)
        for time in times {
            series[Int(((time - times.first!) / step).rounded())] = try aggregate(buckets[time] ?? [])
        }
        var filled: [Double] = []
        for index in series.indices {
            if let value = series[index] {
                filled.append(value)
            } else if completion == 0 {
                filled.append(0)
            } else {
                // Linear interpolation between the neighbours either side.
                let previous = filled.last
                let nextIndex = series[(index + 1)...].firstIndex { $0 != nil }
                let nextValue = nextIndex.flatMap { series[$0] }
                if let previous, let nextIndex, let nextValue {
                    filled.append(previous + (nextValue - previous) / Double(nextIndex - index + 1))
                } else {
                    filled.append(previous ?? nextValue ?? 0)
                }
            }
        }

        var season = 1
        if let seasonalityIndex, !call.isMissing(seasonalityIndex) {
            season = try call.integer(seasonalityIndex)
            guard season >= 0, season <= 8760 else { throw .numberError }
            if season == 1 { season = detectSeason(filled) }
        } else {
            season = detectSeason(filled)
        }
        if season > 0, filled.count < 2 * season { season = 0 }
        return fit(filled, start: times.first!, step: step, season: max(0, season))
    }

    /// The season length with the strongest autocorrelation in the detrended
    /// series, or 0 when nothing repeats convincingly.
    public static func detectSeason(_ values: [Double]) -> Int {
        let n = values.count
        guard n >= 6 else { return 0 }
        let xs = (0..<n).map(Double.init)
        let meanX = FormulaMath.sum(xs) / Double(n)
        let meanY = FormulaMath.sum(values) / Double(n)
        let sxx = FormulaMath.sum(xs.map { ($0 - meanX) * ($0 - meanX) })
        let slope = FormulaMath.sum(zip(xs, values).map { ($0 - meanX) * ($1 - meanY) }) / sxx
        let residuals = zip(xs, values).map { $1 - (meanY + slope * ($0 - meanX)) }
        let variance = FormulaMath.sum(residuals.map { $0 * $0 })
        guard variance > 0 else { return 0 }
        var best = 0
        var bestCorrelation = 0.0
        for lag in 2...max(2, n / 2) {
            let correlation = FormulaMath.sum((lag..<n).map { residuals[$0] * residuals[$0 - lag] }) / variance
            if correlation > bestCorrelation + 1e-9 {
                bestCorrelation = correlation
                best = lag
            }
        }
        return bestCorrelation > 0.25 ? best : 0
    }

    /// Runs the smoothing recursions for one set of constants.
    private static func run(_ values: [Double], season: Int, alpha: Double, beta: Double, gamma: Double)
        -> (level: Double, trend: Double, seasonal: [Double], errors: [Double]) {
        let m = max(1, season)
        var level: Double
        var trend: Double
        var seasonal = [Double](repeating: 0, count: m)
        if season > 0 {
            let first = FormulaMath.sum(Array(values[0..<m])) / Double(m)
            let second = FormulaMath.sum(Array(values[m..<(2 * m)])) / Double(m)
            level = first
            trend = (second - first) / Double(m)
            for index in 0..<m { seasonal[index] = values[index] - first }
        } else {
            level = values[0]
            trend = values[1] - values[0]
        }
        // The nonseasonal initial level already represents the first observation.
        // Updating it again predicts the second point against the first and biases
        // an otherwise exact linear trend. Keep its initialization residual zero.
        var errors: [Double] = season == 0 ? [0] : []
        for (index, value) in values.enumerated() {
            if season == 0 && index == 0 { continue }
            let s = season > 0 ? seasonal[index % m] : 0
            let prediction = level + trend + s
            errors.append(value - prediction)
            let previousLevel = level
            level = alpha * (value - s) + (1 - alpha) * (level + trend)
            trend = beta * (level - previousLevel) + (1 - beta) * trend
            if season > 0 { seasonal[index % m] = gamma * (value - level) + (1 - gamma) * s }
        }
        return (level, trend, seasonal, errors)
    }

    /// Fits the constants by a coarse grid search refined around the best point.
    private static func fit(_ values: [Double], start: Double, step: Double, season: Int) -> FormulaSmoothing {
        func cost(_ a: Double, _ b: Double, _ g: Double) -> Double {
            let errors = run(values, season: season, alpha: a, beta: b, gamma: g).errors
            return FormulaMath.sum(errors.dropFirst().map { $0 * $0 })
        }
        var best = (alpha: 0.5, beta: 0.1, gamma: 0.1)
        var bestCost = Double.infinity
        let grid = stride(from: 0.05, through: 0.95, by: 0.15).map { $0 }
        for a in grid {
            for b in grid {
                for g in season > 0 ? grid : [0] {
                    let value = cost(a, b, g)
                    if value < bestCost { bestCost = value; best = (a, b, g) }
                }
            }
        }
        var radius = 0.075
        while radius > 0.001 {
            var improved = false
            for da in [-radius, 0, radius] {
                for db in [-radius, 0, radius] {
                    for dg in season > 0 ? [-radius, 0, radius] : [0] {
                        let a = min(1, max(0.001, best.alpha + da))
                        let b = min(1, max(0.001, best.beta + db))
                        let g = season > 0 ? min(1, max(0.001, best.gamma + dg)) : 0
                        let value = cost(a, b, g)
                        if value < bestCost - 1e-12 { bestCost = value; best = (a, b, g); improved = true }
                    }
                }
            }
            if !improved { radius /= 2 }
        }
        let final = run(values, season: season, alpha: best.alpha, beta: best.beta, gamma: best.gamma)
        return FormulaSmoothing(values: values, start: start, step: step, season: season,
                                alpha: best.alpha, beta: best.beta, gamma: best.gamma,
                                level: final.level, trend: final.trend, seasonal: final.seasonal, errors: final.errors)
    }

    private func horizon(_ target: Double) throws(CellError) -> Double {
        let steps = (target - end) / step
        guard steps >= 0 else { throw .numberError }
        return steps
    }

    public func forecast(at target: Double) throws(CellError) -> Double {
        let h = try horizon(target)
        var value = level + h * trend
        if season > 0 {
            let position = values.count + Int(h.rounded(.up)) - 1
            value += seasonal[((position % season) + season) % season]
        }
        return value
    }

    public func interval(at target: Double, confidence: Double) throws(CellError) -> Double {
        let h = max(1, try horizon(target).rounded(.up))
        let mse = FormulaMath.sum(errors.dropFirst().map { $0 * $0 }) / Double(max(1, errors.count - 1))
        // The variance of an h-step forecast grows with the level and trend
        // updates that pile up over the horizon.
        var spread = 1.0
        var j = 1.0
        while j < h {
            spread += pow(alpha + alpha * beta * j, 2)
            j += 1
        }
        return FormulaDistributions.normalQuantile((1 + confidence) / 2) * (mse * spread).squareRoot()
    }

    public func statistic(_ kind: Int) -> Double {
        let residuals = Array(errors.dropFirst())
        let n = Double(max(1, residuals.count))
        switch kind {
        case 1: return alpha
        case 2: return beta
        case 3: return gamma
        case 4:
            let naive = zip(values.dropFirst(), values).map { abs($0 - $1) }
            let scale = FormulaMath.sum(naive) / Double(max(1, naive.count))
            return scale == 0 ? 0 : FormulaMath.sum(residuals.map(abs)) / n / scale
        case 5:
            let terms = zip(values.dropFirst(), residuals).map { actual, error -> Double in
                let forecast = actual - error
                let denominator = (abs(actual) + abs(forecast)) / 2
                return denominator == 0 ? 0 : abs(error) / denominator
            }
            return FormulaMath.sum(terms) / n
        case 6: return FormulaMath.sum(residuals.map(abs)) / n
        case 7: return (FormulaMath.sum(residuals.map { $0 * $0 }) / n).squareRoot()
        default: return step
        }
    }
}
