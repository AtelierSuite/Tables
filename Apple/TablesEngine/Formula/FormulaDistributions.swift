import Foundation

/// The special functions and probability distributions behind the
/// statistical functions.
public enum FormulaDistributions {
    private static let epsilon = 1e-15
    private static let tiny = 1e-300

    // MARK: - Special functions

    /// The regularized lower incomplete gamma function P(a, x).
    public static func lowerGamma(_ a: Double, _ x: Double) -> Double {
        guard a > 0, x > 0 else { return 0 }
        if x < a + 1 {
            var term = 1 / a
            var sum = term
            var ap = a
            for _ in 0..<10_000 {
                ap += 1
                term *= x / ap
                sum += term
                if abs(term) < abs(sum) * epsilon { break }
            }
            return min(1, sum * exp(-x + a * log(x) - lgamma(a)))
        }
        return max(0, 1 - upperGammaFraction(a, x))
    }

    /// The regularized upper incomplete gamma function Q(a, x) = 1 − P(a, x).
    public static func upperGamma(_ a: Double, _ x: Double) -> Double {
        guard a > 0 else { return 0 }
        guard x > 0 else { return 1 }
        return x < a + 1 ? 1 - lowerGamma(a, x) : upperGammaFraction(a, x)
    }

    /// Q(a, x) by Lentz's continued fraction, accurate where x ≥ a + 1.
    private static func upperGammaFraction(_ a: Double, _ x: Double) -> Double {
        var b = x + 1 - a
        var c = 1 / tiny
        var d = 1 / b
        var h = d
        for i in 1..<10_000 {
            let an = -Double(i) * (Double(i) - a)
            b += 2
            d = an * d + b
            if abs(d) < tiny { d = tiny }
            c = b + an / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < epsilon { break }
        }
        return exp(-x + a * log(x) - lgamma(a)) * h
    }

    /// The regularized incomplete beta function I_x(a, b).
    public static func incompleteBeta(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let front = exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log1p(-x))
        if x < (a + 1) / (a + b + 2) {
            return front * betaFraction(x, a, b) / a
        }
        return 1 - front * betaFraction(1 - x, b, a) / b
    }

    private static func betaFraction(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let qab = a + b
        let qap = a + 1
        let qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1..<10_000 {
            let m = Double(m)
            let m2 = 2 * m
            var aa = m * (b - m) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < epsilon { break }
        }
        return h
    }

    /// The value where an increasing `cdf` reaches `p`, by bisection inside a
    /// bracket that is widened until it holds the answer.
    public static func inverse(
        _ p: Double, lower: Double, upper: Double, unbounded: Bool = true, _ cdf: (Double) -> Double
    ) -> Double? {
        var low = lower
        var high = upper
        if unbounded {
            var guardCount = 0
            while cdf(high) < p, guardCount < 2000 { high = high * 2 + 1; guardCount += 1 }
            while low < 0, cdf(low) > p, guardCount < 4000 { low = low * 2 - 1; guardCount += 1 }
        }
        for _ in 0..<2000 {
            let middle = (low + high) / 2
            if middle == low || middle == high { break }
            if cdf(middle) < p { low = middle } else { high = middle }
            if high - low <= 1e-15 * max(1, abs(middle)) { break }
        }
        let result = (low + high) / 2
        return result.isFinite ? result : nil
    }

    // MARK: - Normal

    public static func normalCDF(_ z: Double) -> Double { 0.5 * erfc(-z / 2.0.squareRoot()) }

    public static func normalPDF(_ z: Double) -> Double { exp(-z * z / 2) / (2 * Double.pi).squareRoot() }

    /// The standard normal quantile: Acklam's approximation, refined by one
    /// Halley step to full double precision.
    public static func normalQuantile(_ p: Double) -> Double {
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let low = 0.02425
        var x: Double
        if p < low {
            let q = (-2 * log(p)).squareRoot()
            x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        } else if p <= 1 - low {
            let q = p - 0.5
            let r = q * q
            x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
                / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        } else {
            let q = (-2 * log1p(-p)).squareRoot()
            x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        for _ in 0..<2 {
            let e = normalCDF(x) - p
            let u = e * (2 * Double.pi).squareRoot() * exp(x * x / 2)
            x -= u / (1 + x * u / 2)
        }
        return x
    }

    // MARK: - Student's t, chi-square, F

    public static func studentCDF(_ t: Double, _ df: Double) -> Double {
        let tail = 0.5 * incompleteBeta(df / (df + t * t), df / 2, 0.5)
        return t >= 0 ? 1 - tail : tail
    }

    public static func studentPDF(_ t: Double, _ df: Double) -> Double {
        exp(lgamma((df + 1) / 2) - lgamma(df / 2)) / (df * Double.pi).squareRoot() * pow(1 + t * t / df, -(df + 1) / 2)
    }

    public static func studentQuantile(_ p: Double, _ df: Double) -> Double? {
        if p == 0.5 { return 0 }
        return inverse(p, lower: -1, upper: 1) { studentCDF($0, df) }
    }

    public static func chiSquareCDF(_ x: Double, _ df: Double) -> Double { x <= 0 ? 0 : lowerGamma(df / 2, x / 2) }

    public static func chiSquarePDF(_ x: Double, _ df: Double) -> Double {
        guard x > 0 else { return df == 2 && x == 0 ? 0.5 : 0 }
        return exp((df / 2 - 1) * log(x) - x / 2 - (df / 2) * log(2) - lgamma(df / 2))
    }

    public static func fCDF(_ x: Double, _ d1: Double, _ d2: Double) -> Double {
        x <= 0 ? 0 : incompleteBeta(d1 * x / (d1 * x + d2), d1 / 2, d2 / 2)
    }

    public static func fPDF(_ x: Double, _ d1: Double, _ d2: Double) -> Double {
        guard x > 0 else { return 0 }
        let logValue = (d1 / 2) * log(d1 / d2) + (d1 / 2 - 1) * log(x) - ((d1 + d2) / 2) * log1p(d1 * x / d2)
            - (lgamma(d1 / 2) + lgamma(d2 / 2) - lgamma((d1 + d2) / 2))
        return exp(logValue)
    }

    // MARK: - Gamma and beta

    public static func gammaCDF(_ x: Double, _ alpha: Double, _ beta: Double) -> Double {
        x <= 0 ? 0 : lowerGamma(alpha, x / beta)
    }

    public static func gammaPDF(_ x: Double, _ alpha: Double, _ beta: Double) -> Double {
        guard x > 0 else { return x == 0 && alpha == 1 ? 1 / beta : 0 }
        return exp((alpha - 1) * log(x) - x / beta - lgamma(alpha) - alpha * log(beta))
    }

    public static func betaPDF(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard x > 0, x < 1 else { return 0 }
        return exp((a - 1) * log(x) + (b - 1) * log1p(-x) + lgamma(a + b) - lgamma(a) - lgamma(b))
    }

    // MARK: - Discrete

    /// log(n choose k), for probabilities too large or small to compute directly.
    public static func logChoose(_ n: Double, _ k: Double) -> Double {
        lgamma(n + 1) - lgamma(k + 1) - lgamma(n - k + 1)
    }

    public static func binomialPMF(_ k: Double, _ n: Double, _ p: Double) -> Double {
        if p == 0 { return k == 0 ? 1 : 0 }
        if p == 1 { return k == n ? 1 : 0 }
        return exp(logChoose(n, k) + k * log(p) + (n - k) * log1p(-p))
    }

    public static func binomialCDF(_ k: Double, _ n: Double, _ p: Double) -> Double {
        if k >= n { return 1 }
        if k < 0 { return 0 }
        return incompleteBeta(1 - p, n - k, k + 1)
    }

    public static func poissonPMF(_ k: Double, _ mean: Double) -> Double {
        if mean == 0 { return k == 0 ? 1 : 0 }
        return exp(k * log(mean) - mean - lgamma(k + 1))
    }

    public static func poissonCDF(_ k: Double, _ mean: Double) -> Double {
        mean == 0 ? 1 : upperGamma(k + 1, mean)
    }

    public static func hypergeometricPMF(_ k: Double, sample: Double, successes: Double, population: Double) -> Double {
        exp(logChoose(successes, k) + logChoose(population - successes, sample - k) - logChoose(population, sample))
    }

    public static func negativeBinomialPMF(_ failures: Double, _ successes: Double, _ p: Double) -> Double {
        exp(logChoose(failures + successes - 1, successes - 1) + successes * log(p) + failures * log1p(-p))
    }
}
