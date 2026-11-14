import Foundation

/// The arithmetic a chart needs beyond reading its cells: fitting trendlines,
/// sizing error bars, and choosing round numbers for an axis. It lives in the
/// engine so that every app draws the same line through the same points.

// MARK: - Trendlines

/// A trendline fitted to a series' points.
public struct ChartTrendlineFit: Hashable, Sendable {
    public var kind: ChartTrendline.Kind
    /// Linear and polynomial: the coefficients from the constant up.
    /// Exponential `a·e^(bx)`, power `a·x^b` and logarithmic `a·ln(x) + b`:
    /// `[a, b]`.
    public var coefficients: [Double]
    /// How much of the variation the line accounts for, measured as Excel
    /// measures it: on the logarithms for exponential and power fits.
    public var rSquared: Double

    public func value(at x: Double) -> Double? {
        let result: Double
        switch kind {
        case .linear, .polynomial:
            result = coefficients.reversed().reduce(0) { $0 * x + $1 }
        case .exponential:
            result = coefficients[0] * exp(coefficients[1] * x)
        case .power:
            guard x > 0 else { return nil }
            result = coefficients[0] * pow(x, coefficients[1])
        case .logarithmic:
            guard x > 0 else { return nil }
            result = coefficients[0] * log(x) + coefficients[1]
        case .movingAverage:
            return nil
        }
        return result.isFinite ? result : nil
    }

    /// The equation as Excel's label gives it: `y = 2.5x + 1`.
    public var equation: String {
        func number(_ value: Double) -> String { ChartTrendlineFit.text(value) }
        /// A coefficient before its variable: `x` rather than `1x`.
        func term(_ value: Double, _ suffix: String) -> String {
            let text = number(value)
            guard !suffix.isEmpty, text == "1" else { return text + suffix }
            return suffix
        }
        /// `+ 3` or `- 3`, for every term after the first.
        func signed(_ value: Double, _ suffix: String = "") -> String {
            (value < 0 ? " - " : " + ") + term(abs(value), suffix)
        }
        switch kind {
        case .linear, .polynomial:
            let powers = ["", "x", "x²", "x³", "x⁴", "x⁵", "x⁶"]
            var text = ""
            for (power, coefficient) in coefficients.enumerated().reversed() {
                // Terms that round away are left out, as Excel leaves them.
                guard number(coefficient) != "0" else { continue }
                let suffix = powers.indices.contains(power) ? powers[power] : "x^\(power)"
                if text.isEmpty {
                    text = coefficient < 0 ? "-" + term(-coefficient, suffix) : term(coefficient, suffix)
                } else {
                    text += signed(coefficient, suffix)
                }
            }
            return "y = " + (text.isEmpty ? "0" : text)
        case .exponential:
            return "y = \(number(coefficients[0]))e^(\(number(coefficients[1]))x)"
        case .power:
            return "y = \(number(coefficients[0]))x^\(number(coefficients[1]))"
        case .logarithmic:
            let constant = number(coefficients[1]) == "0" ? "" : signed(coefficients[1])
            return "y = \(term(coefficients[0], "ln(x)"))" + constant
        case .movingAverage:
            return ""
        }
    }

    public var rSquaredText: String { "R² = " + ChartTrendlineFit.text(rSquared) }

    /// About five significant figures and never more than four decimals,
    /// which is what Excel's General format makes of a coefficient.
    static func text(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        // What is left of a zero after the arithmetic.
        if abs(value) < 1e-9 { return "0" }
        let magnitude = Int(floor(log10(abs(value))))
        if magnitude >= 7 || magnitude < -4 { return String(format: "%.4E", value) }
        var text = String(format: "%.\(max(0, min(4, 4 - magnitude)))f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}

extension ChartTrendline {
    /// Fits the line to the points given, by least squares. `nil` when there
    /// are too few points, or the fit needs logarithms of numbers that have
    /// none. A moving average is not a fit; see `movingAverage(x:y:)`.
    public func fit(x: [Double], y: [Double]) -> ChartTrendlineFit? {
        let count = min(x.count, y.count)
        guard count >= 2 else { return nil }
        let xs = Array(x.prefix(count))
        let ys = Array(y.prefix(count))
        switch kind {
        case .linear:
            return Self.polynomial(xs, ys, degree: 1, intercept: intercept).map {
                ChartTrendlineFit(kind: .linear, coefficients: $0.coefficients, rSquared: $0.rSquared)
            }
        case .polynomial:
            let degree = min(max(order, 2), 6)
            guard count > degree else { return nil }
            return Self.polynomial(xs, ys, degree: degree, intercept: intercept).map {
                ChartTrendlineFit(kind: .polynomial, coefficients: $0.coefficients, rSquared: $0.rSquared)
            }
        case .exponential:
            guard ys.allSatisfy({ $0 > 0 }) else { return nil }
            let forced = intercept.flatMap { $0 > 0 ? log($0) : nil }
            return Self.polynomial(xs, ys.map { log($0) }, degree: 1, intercept: forced).map {
                ChartTrendlineFit(
                    kind: .exponential, coefficients: [exp($0.coefficients[0]), $0.coefficients[1]],
                    rSquared: $0.rSquared
                )
            }
        case .power:
            guard ys.allSatisfy({ $0 > 0 }), xs.allSatisfy({ $0 > 0 }) else { return nil }
            return Self.polynomial(xs.map { log($0) }, ys.map { log($0) }, degree: 1, intercept: nil).map {
                ChartTrendlineFit(
                    kind: .power, coefficients: [exp($0.coefficients[0]), $0.coefficients[1]], rSquared: $0.rSquared
                )
            }
        case .logarithmic:
            guard xs.allSatisfy({ $0 > 0 }) else { return nil }
            return Self.polynomial(xs.map { log($0) }, ys, degree: 1, intercept: nil).map {
                ChartTrendlineFit(
                    kind: .logarithmic, coefficients: [$0.coefficients[1], $0.coefficients[0]], rSquared: $0.rSquared
                )
            }
        case .movingAverage:
            return nil
        }
    }

    /// The moving average's points: each the mean of the `period` values up
    /// to and including its own.
    public func movingAverage(x: [Double], y: [Double]) -> [ChartPoint] {
        let count = min(x.count, y.count)
        let span = max(period, 2)
        guard count >= span else { return [] }
        return (span - 1..<count).map { index in
            ChartPoint(x: x[index], y: y[(index - span + 1)...index].reduce(0, +) / Double(span))
        }
    }

    /// The points to draw the line through. `positions` are the X values the
    /// line may be drawn at when the axis has only those — the categories of
    /// a column or line chart; `nil` lets it run smoothly from end to end,
    /// carried forward and backward as the trendline asks.
    public func points(x: [Double], y: [Double], fit: ChartTrendlineFit?, positions: [Double]?) -> [ChartPoint] {
        if kind == .movingAverage { return movingAverage(x: x, y: y) }
        guard let fit, let low = x.min(), let high = x.max() else { return [] }
        let samples: [Double]
        if let positions {
            samples = positions.filter { $0 >= low && $0 <= high }
        } else {
            let start = low - max(0, backward)
            let end = high + max(0, forward)
            let steps = kind == .linear ? 1 : 48
            samples = (0...steps).map { start + (end - start) * Double($0) / Double(steps) }
        }
        return samples.compactMap { x in fit.value(at: x).map { ChartPoint(x: x, y: $0) } }
    }

    /// Least squares for a polynomial of the degree given, by the normal
    /// equations. With an intercept the constant is fixed and the rest fitted.
    private static func polynomial(
        _ x: [Double], _ y: [Double], degree: Int, intercept: Double?
    ) -> (coefficients: [Double], rSquared: Double)? {
        let first = intercept == nil ? 0 : 1
        let size = degree + 1 - first
        guard size > 0, x.count >= size else { return nil }
        let target = intercept.map { fixed in y.map { $0 - fixed } } ?? y
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: size + 1), count: size)
        for (xValue, yValue) in zip(x, target) {
            let powers = (0...(2 * degree)).map { pow(xValue, Double($0)) }
            for row in 0..<size {
                for column in 0..<size { matrix[row][column] += powers[row + column + 2 * first] }
                matrix[row][size] += powers[row + first] * yValue
            }
        }
        guard let solved = solve(matrix) else { return nil }
        let coefficients = (intercept.map { [$0] } ?? []) + solved

        let mean = y.reduce(0, +) / Double(y.count)
        var residual = 0.0
        var total = 0.0
        for (xValue, yValue) in zip(x, y) {
            let fitted = coefficients.reversed().reduce(0) { $0 * xValue + $1 }
            residual += (yValue - fitted) * (yValue - fitted)
            total += (yValue - mean) * (yValue - mean)
        }
        return (coefficients, total == 0 ? 1 : 1 - residual / total)
    }

    /// Gaussian elimination with partial pivoting on an augmented matrix.
    private static func solve(_ augmented: [[Double]]) -> [Double]? {
        var matrix = augmented
        let size = matrix.count
        for column in 0..<size {
            guard let pivot = (column..<size).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) }),
                  abs(matrix[pivot][column]) > 1e-12 else { return nil }
            matrix.swapAt(column, pivot)
            for row in 0..<size where row != column {
                let factor = matrix[row][column] / matrix[column][column]
                guard factor != 0 else { continue }
                for index in column...size { matrix[row][index] -= factor * matrix[column][index] }
            }
        }
        let solution = (0..<size).map { matrix[$0][size] / matrix[$0][$0] }
        return solution.allSatisfy(\.isFinite) ? solution : nil
    }
}

/// A point in a plot's own units.
public struct ChartPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - Error bars

extension ChartErrorBars {
    /// One bar: the span it covers at the point of this index.
    public struct Bar: Hashable, Sendable {
        public var index: Int
        public var low: Double
        public var high: Double
    }

    /// The bars for a series' values — its X values, for bars that run
    /// sideways. `plus` and `minus` are the amounts of custom bars.
    public func bars(for values: [Double?], plus: [Double?] = [], minus: [Double?] = []) -> [Bar] {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return [] }
        let mean = present.reduce(0, +) / Double(present.count)
        // The sample deviation, as Excel's own error bars use.
        let deviation = present.count > 1
            ? (present.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(present.count - 1)).squareRoot()
            : 0

        func custom(_ amounts: [Double?], _ index: Int) -> Double {
            // One amount stands for every point.
            let amount = amounts.count == 1 ? amounts[0] : (amounts.indices.contains(index) ? amounts[index] : nil)
            return abs(amount ?? 0)
        }

        return values.enumerated().compactMap { index, value in
            guard let value else { return nil }
            var center = value
            var up: Double
            var down: Double
            switch amount {
            case .fixed:
                up = abs(self.value)
                down = up
            case .percentage:
                up = abs(value) * abs(self.value) / 100
                down = up
            case .standardDeviation:
                // Deviation bars straddle the mean, not the point.
                center = mean
                up = deviation * abs(self.value)
                down = up
            case .standardError:
                up = deviation / Double(present.count).squareRoot()
                down = up
            case .custom:
                up = custom(plus, index)
                down = custom(minus, index)
            }
            if side == .plus { down = 0 }
            if side == .minus { up = 0 }
            return Bar(index: index, low: center - down, high: center + up)
        }
    }
}

// MARK: - Axis scales

/// Round numbers for a value axis: where it starts and ends and how far
/// apart its labels sit.
public struct ChartAxisScale: Hashable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public var majorUnit: Double

    public var ticks: [Double] {
        guard majorUnit > 0, maximum > minimum else { return [minimum] }
        let count = Int(((maximum - minimum) / majorUnit + 1e-9).rounded(.down))
        return (0...min(count, 200)).map { minimum + Double($0) * majorUnit }
    }

    /// Where a value falls between the ends of the scale, from 0 to 1.
    public func fraction(_ value: Double) -> Double {
        maximum > minimum ? (value - minimum) / (maximum - minimum) : 0
    }

    /// A scale covering `values` that honours whatever the axis pins. With
    /// `intervals`, the scale is given exactly that many steps, so that two
    /// axes on one plot can share their gridlines.
    public static func nice(
        _ values: [Double], axis: ChartAxis = ChartAxis(), includesZero: Bool = true, intervals: Int? = nil
    ) -> ChartAxisScale {
        var low = values.min() ?? 0
        var high = values.max() ?? 1
        if includesZero {
            low = min(low, 0)
            high = max(high, 0)
        }
        if let pinned = axis.minimum { low = pinned }
        if let pinned = axis.maximum { high = pinned }
        if high <= low { high = low + 1 }

        func step(for raw: Double) -> Double {
            let magnitude = pow(10, floor(log10(raw)))
            let fraction = raw / magnitude
            return (fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10) * magnitude
        }
        func next(after step: Double) -> Double {
            let magnitude = pow(10, floor(log10(step) + 1e-9))
            let fraction = (step / magnitude).rounded()
            return (fraction < 2 ? 2 : fraction < 5 ? 5 : 10) * magnitude
        }

        if let intervals, intervals > 0 {
            var unit = step(for: (high - low) / Double(intervals))
            for _ in 0..<8 {
                let start = axis.minimum ?? (unit * (low / unit).rounded(.down))
                if start + unit * Double(intervals) >= high - unit * 1e-9 {
                    return ChartAxisScale(minimum: start, maximum: start + unit * Double(intervals), majorUnit: unit)
                }
                unit = next(after: unit)
            }
            return ChartAxisScale(minimum: low, maximum: high, majorUnit: (high - low) / Double(intervals))
        }

        let unit = axis.majorUnit.flatMap { $0 > 0 ? $0 : nil } ?? step(for: (high - low) / 5)
        return ChartAxisScale(
            minimum: axis.minimum ?? unit * (low / unit + 1e-9).rounded(.down),
            maximum: axis.maximum ?? unit * (high / unit - 1e-9).rounded(.up),
            majorUnit: unit
        )
    }
}
