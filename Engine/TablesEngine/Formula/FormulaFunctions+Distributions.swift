import Foundation

private typealias D = FormulaDistributions

extension FormulaFunctions {
    public static let distributionFunctions: [String: FunctionSpec] = makeDistributionFunctions()

    private static func makeDistributionFunctions() -> [String: FunctionSpec] {
        var table: [String: FunctionSpec] = [:]

        // MARK: Normal and log-normal

        let normalDistribution = FunctionSpec(4...4) { call throws(CellError) in
            let x = try call.number(0)
            let mean = try call.number(1)
            let deviation = try call.number(2)
            guard deviation > 0 else { throw .numberError }
            let z = (x - mean) / deviation
            return .number(try call.boolean(3) ? D.normalCDF(z) : D.normalPDF(z) / deviation)
        }
        table["NORM.DIST"] = normalDistribution
        table["NORMDIST"] = normalDistribution
        let normalInverse = FunctionSpec(3...3) { call throws(CellError) in
            let p = try call.number(0)
            let deviation = try call.number(2)
            guard p > 0, p < 1, deviation > 0 else { throw .numberError }
            return .number(try call.number(1) + deviation * D.normalQuantile(p))
        }
        table["NORM.INV"] = normalInverse
        table["NORMINV"] = normalInverse
        table["NORM.S.DIST"] = FunctionSpec(2...2) { call throws(CellError) in
            let z = try call.number(0)
            return .number(try call.boolean(1) ? D.normalCDF(z) : D.normalPDF(z))
        }
        table["NORMSDIST"] = .unary { D.normalCDF($0) }
        let standardInverse = FunctionSpec.unary { p throws(CellError) in
            guard p > 0, p < 1 else { throw .numberError }
            return D.normalQuantile(p)
        }
        table["NORM.S.INV"] = standardInverse
        table["NORMSINV"] = standardInverse
        table["PHI"] = .unary { D.normalPDF($0) }
        table["GAUSS"] = .unary { D.normalCDF($0) - 0.5 }
        table["LOGNORM.DIST"] = FunctionSpec(4...4) { call throws(CellError) in
            let x = try call.number(0)
            let mean = try call.number(1)
            let deviation = try call.number(2)
            guard x > 0, deviation > 0 else { throw .numberError }
            let z = (log(x) - mean) / deviation
            return .number(try call.boolean(3) ? D.normalCDF(z) : D.normalPDF(z) / (x * deviation))
        }
        table["LOGNORMDIST"] = FunctionSpec(3...3) { call throws(CellError) in
            let x = try call.number(0)
            let deviation = try call.number(2)
            guard x > 0, deviation > 0 else { throw .numberError }
            return .number(D.normalCDF((log(x) - (try call.number(1))) / deviation))
        }
        let logInverse = FunctionSpec(3...3) { call throws(CellError) in
            let p = try call.number(0)
            let deviation = try call.number(2)
            guard p > 0, p < 1, deviation > 0 else { throw .numberError }
            return .number(exp(try call.number(1) + deviation * D.normalQuantile(p)))
        }
        table["LOGNORM.INV"] = logInverse
        table["LOGINV"] = logInverse

        // MARK: Student's t

        table["T.DIST"] = FunctionSpec(3...3) { call throws(CellError) in
            let t = try call.number(0)
            let df = try call.number(1).rounded(.towardZero)
            guard df >= 1 else { throw .numberError }
            return .number(try call.boolean(2) ? D.studentCDF(t, df) : D.studentPDF(t, df))
        }
        table["T.DIST.2T"] = FunctionSpec(2...2) { call throws(CellError) in
            let t = try call.number(0)
            let df = try call.number(1).rounded(.towardZero)
            guard t >= 0, df >= 1 else { throw .numberError }
            return .number(2 * (1 - D.studentCDF(t, df)))
        }
        table["T.DIST.RT"] = FunctionSpec(2...2) { call throws(CellError) in
            let df = try call.number(1).rounded(.towardZero)
            guard df >= 1 else { throw .numberError }
            return .number(1 - D.studentCDF(try call.number(0), df))
        }
        table["TDIST"] = FunctionSpec(3...3) { call throws(CellError) in
            let t = try call.number(0)
            let df = try call.number(1).rounded(.towardZero)
            let tails = try call.integer(2)
            guard t >= 0, df >= 1, tails == 1 || tails == 2 else { throw .numberError }
            return .number(Double(tails) * (1 - D.studentCDF(t, df)))
        }
        table["T.INV"] = FunctionSpec(2...2) { call throws(CellError) in
            let p = try call.number(0)
            let df = try call.number(1).rounded(.towardZero)
            guard p > 0, p < 1, df >= 1, let t = D.studentQuantile(p, df) else { throw .numberError }
            return .number(t)
        }
        let twoTailedInverse = FunctionSpec(2...2) { call throws(CellError) in
            let p = try call.number(0)
            let df = try call.number(1).rounded(.towardZero)
            guard p > 0, p <= 1, df >= 1, let t = D.studentQuantile(1 - p / 2, df) else { throw .numberError }
            return .number(abs(t))
        }
        table["T.INV.2T"] = twoTailedInverse
        table["TINV"] = twoTailedInverse

        // MARK: Chi-square

        table["CHISQ.DIST"] = FunctionSpec(3...3) { call throws(CellError) in
            let x = try call.number(0)
            let df = try call.number(1).rounded(.towardZero)
            guard x >= 0, df >= 1, df <= 1e10 else { throw .numberError }
            return .number(try call.boolean(2) ? D.chiSquareCDF(x, df) : D.chiSquarePDF(x, df))
        }
        let chiRightTail = FunctionSpec(2...2) { call throws(CellError) in
            let x = try call.number(0)
            let df = try call.number(1).rounded(.towardZero)
            guard x >= 0, df >= 1, df <= 1e10 else { throw .numberError }
            return .number(x == 0 ? 1 : D.upperGamma(df / 2, x / 2))
        }
        table["CHISQ.DIST.RT"] = chiRightTail
        table["CHIDIST"] = chiRightTail
        table["CHISQ.INV"] = FunctionSpec(2...2) { call throws(CellError) in
            let p = try call.number(0)
            let df = try call.number(1).rounded(.towardZero)
            guard p >= 0, p < 1, df >= 1, df <= 1e10 else { throw .numberError }
            if p == 0 { return .number(0) }
            guard let x = D.inverse(p, lower: 0, upper: max(1, df), { D.chiSquareCDF($0, df) }) else { throw .numberError }
            return .number(x)
        }
        let chiRightInverse = FunctionSpec(2...2) { call throws(CellError) in
            let p = try call.number(0)
            let df = try call.number(1).rounded(.towardZero)
            guard p > 0, p <= 1, df >= 1, df <= 1e10 else { throw .numberError }
            if p == 1 { return .number(0) }
            guard let x = D.inverse(1 - p, lower: 0, upper: max(1, df), { D.chiSquareCDF($0, df) }) else {
                throw .numberError
            }
            return .number(x)
        }
        table["CHISQ.INV.RT"] = chiRightInverse
        table["CHIINV"] = chiRightInverse
        let chiTest = FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            let actual = try FormulaMath.numericMatrix(call.matrix(0))
            let expected = try FormulaMath.numericMatrix(call.matrix(1))
            guard actual.count == expected.count, actual.first?.count == expected.first?.count else {
                throw .notAvailable
            }
            var statistic = 0.0
            for (row, line) in actual.enumerated() {
                for (column, observed) in line.enumerated() {
                    let expectation = expected[row][column]
                    guard expectation != 0 else { throw .divideByZero }
                    statistic += (observed - expectation) * (observed - expectation) / expectation
                }
            }
            let rows = Double(actual.count)
            let columns = Double(actual.first?.count ?? 0)
            let df = rows > 1 && columns > 1 ? (rows - 1) * (columns - 1) : rows * columns - 1
            guard df >= 1 else { throw .notAvailable }
            return .number(D.upperGamma(df / 2, statistic / 2))
        }
        table["CHISQ.TEST"] = chiTest
        table["CHITEST"] = chiTest

        // MARK: F

        table["F.DIST"] = FunctionSpec(4...4) { call throws(CellError) in
            let x = try call.number(0)
            let d1 = try call.number(1).rounded(.towardZero)
            let d2 = try call.number(2).rounded(.towardZero)
            guard x >= 0, d1 >= 1, d2 >= 1 else { throw .numberError }
            return .number(try call.boolean(3) ? D.fCDF(x, d1, d2) : D.fPDF(x, d1, d2))
        }
        let fRightTail = FunctionSpec(3...3) { call throws(CellError) in
            let x = try call.number(0)
            let d1 = try call.number(1).rounded(.towardZero)
            let d2 = try call.number(2).rounded(.towardZero)
            guard x >= 0, d1 >= 1, d2 >= 1 else { throw .numberError }
            return .number(x == 0 ? 1 : D.incompleteBeta(d2 / (d2 + d1 * x), d2 / 2, d1 / 2))
        }
        table["F.DIST.RT"] = fRightTail
        table["FDIST"] = fRightTail
        table["F.INV"] = FunctionSpec(3...3) { call throws(CellError) in
            let p = try call.number(0)
            let d1 = try call.number(1).rounded(.towardZero)
            let d2 = try call.number(2).rounded(.towardZero)
            guard p >= 0, p < 1, d1 >= 1, d2 >= 1 else { throw .numberError }
            if p == 0 { return .number(0) }
            guard let x = D.inverse(p, lower: 0, upper: 1, { D.fCDF($0, d1, d2) }) else { throw .numberError }
            return .number(x)
        }
        let fRightInverse = FunctionSpec(3...3) { call throws(CellError) in
            let p = try call.number(0)
            let d1 = try call.number(1).rounded(.towardZero)
            let d2 = try call.number(2).rounded(.towardZero)
            guard p > 0, p <= 1, d1 >= 1, d2 >= 1 else { throw .numberError }
            if p == 1 { return .number(0) }
            guard let x = D.inverse(1 - p, lower: 0, upper: 1, { D.fCDF($0, d1, d2) }) else { throw .numberError }
            return .number(x)
        }
        table["F.INV.RT"] = fRightInverse
        table["FINV"] = fRightInverse
        let fTest = FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            let first = try call.numbers([0])
            let second = try call.numbers([1])
            guard first.count >= 2, second.count >= 2 else { throw .divideByZero }
            let v1 = try FormulaStatistics.variance(first, sample: true)
            let v2 = try FormulaStatistics.variance(second, sample: true)
            guard v1 > 0, v2 > 0 else { throw .divideByZero }
            let p = D.fCDF(v1 / v2, Double(first.count - 1), Double(second.count - 1))
            return .number(2 * min(p, 1 - p))
        }
        table["F.TEST"] = fTest
        table["FTEST"] = fTest

        // MARK: Beta and gamma

        table["BETA.DIST"] = FunctionSpec(4...6) { call throws(CellError) in
            let x = try call.number(0)
            let a = try call.number(1)
            let b = try call.number(2)
            let cumulative = try call.boolean(3)
            let low = try call.number(4, default: 0)
            let high = try call.number(5, default: 1)
            guard a > 0, b > 0, low < high, x >= low, x <= high else { throw .numberError }
            let scaled = (x - low) / (high - low)
            return .number(cumulative ? D.incompleteBeta(scaled, a, b) : D.betaPDF(scaled, a, b) / (high - low))
        }
        table["BETADIST"] = FunctionSpec(3...5) { call throws(CellError) in
            let x = try call.number(0)
            let a = try call.number(1)
            let b = try call.number(2)
            let low = try call.number(3, default: 0)
            let high = try call.number(4, default: 1)
            guard a > 0, b > 0, low < high, x >= low, x <= high else { throw .numberError }
            return .number(D.incompleteBeta((x - low) / (high - low), a, b))
        }
        let betaInverse = FunctionSpec(3...5) { call throws(CellError) in
            let p = try call.number(0)
            let a = try call.number(1)
            let b = try call.number(2)
            let low = try call.number(3, default: 0)
            let high = try call.number(4, default: 1)
            guard p > 0, p <= 1, a > 0, b > 0, low < high,
                  let x = D.inverse(p, lower: 0, upper: 1, unbounded: false, { D.incompleteBeta($0, a, b) }) else {
                throw .numberError
            }
            return .number(low + x * (high - low))
        }
        table["BETA.INV"] = betaInverse
        table["BETAINV"] = betaInverse
        let gammaDistribution = FunctionSpec(4...4) { call throws(CellError) in
            let x = try call.number(0)
            let alpha = try call.number(1)
            let beta = try call.number(2)
            guard x >= 0, alpha > 0, beta > 0 else { throw .numberError }
            return .number(try call.boolean(3) ? D.gammaCDF(x, alpha, beta) : D.gammaPDF(x, alpha, beta))
        }
        table["GAMMA.DIST"] = gammaDistribution
        table["GAMMADIST"] = gammaDistribution
        let gammaInverse = FunctionSpec(3...3) { call throws(CellError) in
            let p = try call.number(0)
            let alpha = try call.number(1)
            let beta = try call.number(2)
            guard p >= 0, p < 1, alpha > 0, beta > 0 else { throw .numberError }
            if p == 0 { return .number(0) }
            guard let x = D.inverse(p, lower: 0, upper: alpha * beta, { D.gammaCDF($0, alpha, beta) }) else {
                throw .numberError
            }
            return .number(x)
        }
        table["GAMMA.INV"] = gammaInverse
        table["GAMMAINV"] = gammaInverse
        table["GAMMA"] = .unary { x throws(CellError) in
            guard !(x <= 0 && x == x.rounded()) else { throw .numberError }
            let result = tgamma(x)
            guard result.isFinite else { throw .numberError }
            return result
        }
        let logGamma = FunctionSpec.unary { x throws(CellError) in
            guard x > 0 else { throw .numberError }
            return lgamma(x)
        }
        table["GAMMALN"] = logGamma
        table["GAMMALN.PRECISE"] = logGamma

        // MARK: Discrete

        let binomial = FunctionSpec(4...4) { call throws(CellError) in
            let k = try call.number(0).rounded(.towardZero)
            let n = try call.number(1).rounded(.towardZero)
            let p = try call.number(2)
            guard k >= 0, n >= k, p >= 0, p <= 1 else { throw .numberError }
            return .number(try call.boolean(3) ? D.binomialCDF(k, n, p) : D.binomialPMF(k, n, p))
        }
        table["BINOM.DIST"] = binomial
        table["BINOMDIST"] = binomial
        table["BINOM.DIST.RANGE"] = FunctionSpec(3...4) { call throws(CellError) in
            let n = try call.number(0).rounded(.towardZero)
            let p = try call.number(1)
            let first = try call.number(2).rounded(.towardZero)
            let last = try call.number(3, default: first).rounded(.towardZero)
            guard n >= 0, p >= 0, p <= 1, first >= 0, first <= n, last >= first, last <= n else { throw .numberError }
            return .number(D.binomialCDF(last, n, p) - (first > 0 ? D.binomialCDF(first - 1, n, p) : 0))
        }
        let binomialInverse = FunctionSpec(3...3) { call throws(CellError) in
            let n = try call.number(0).rounded(.towardZero)
            let p = try call.number(1)
            let alpha = try call.number(2)
            guard n >= 0, p >= 0, p <= 1, alpha >= 0, alpha <= 1 else { throw .numberError }
            var k = 0.0
            while k < n, D.binomialCDF(k, n, p) < alpha { k += 1 }
            return .number(k)
        }
        table["BINOM.INV"] = binomialInverse
        table["CRITBINOM"] = binomialInverse
        let poisson = FunctionSpec(3...3) { call throws(CellError) in
            let k = try call.number(0).rounded(.towardZero)
            let mean = try call.number(1)
            guard k >= 0, mean >= 0 else { throw .numberError }
            return .number(try call.boolean(2) ? D.poissonCDF(k, mean) : D.poissonPMF(k, mean))
        }
        table["POISSON.DIST"] = poisson
        table["POISSON"] = poisson
        let exponential = FunctionSpec(3...3) { call throws(CellError) in
            let x = try call.number(0)
            let rate = try call.number(1)
            guard x >= 0, rate > 0 else { throw .numberError }
            return .number(try call.boolean(2) ? -expm1(-rate * x) : rate * exp(-rate * x))
        }
        table["EXPON.DIST"] = exponential
        table["EXPONDIST"] = exponential
        let weibull = FunctionSpec(4...4) { call throws(CellError) in
            let x = try call.number(0)
            let alpha = try call.number(1)
            let beta = try call.number(2)
            guard x >= 0, alpha > 0, beta > 0 else { throw .numberError }
            let scaled = pow(x / beta, alpha)
            return .number(try call.boolean(3)
                           ? -expm1(-scaled)
                           : alpha / pow(beta, alpha) * pow(x, alpha - 1) * exp(-scaled))
        }
        table["WEIBULL.DIST"] = weibull
        table["WEIBULL"] = weibull
        table["HYPGEOM.DIST"] = FunctionSpec(5...5) { call throws(CellError) in
            let (k, sample, successes, population) = try FormulaDistributions.hypergeometricArguments(call)
            guard try call.boolean(4) else {
                return .number(D.hypergeometricPMF(k, sample: sample, successes: successes, population: population))
            }
            var total = 0.0
            var i = max(0, sample - (population - successes))
            while i <= k {
                total += D.hypergeometricPMF(i, sample: sample, successes: successes, population: population)
                i += 1
            }
            return .number(min(1, total))
        }
        table["HYPGEOMDIST"] = FunctionSpec(4...4) { call throws(CellError) in
            let (k, sample, successes, population) = try FormulaDistributions.hypergeometricArguments(call)
            return .number(D.hypergeometricPMF(k, sample: sample, successes: successes, population: population))
        }
        table["NEGBINOM.DIST"] = FunctionSpec(4...4) { call throws(CellError) in
            let failures = try call.number(0).rounded(.towardZero)
            let successes = try call.number(1).rounded(.towardZero)
            let p = try call.number(2)
            guard failures >= 0, successes >= 1, p >= 0, p <= 1 else { throw .numberError }
            if try call.boolean(3) {
                return .number(D.incompleteBeta(p, successes, failures + 1))
            }
            return .number(D.negativeBinomialPMF(failures, successes, p))
        }
        table["NEGBINOMDIST"] = FunctionSpec(3...3) { call throws(CellError) in
            let failures = try call.number(0).rounded(.towardZero)
            let successes = try call.number(1).rounded(.towardZero)
            let p = try call.number(2)
            guard failures >= 0, successes >= 1, p >= 0, p <= 1 else { throw .numberError }
            return .number(D.negativeBinomialPMF(failures, successes, p))
        }

        // MARK: Confidence and tests

        let normalConfidence = FunctionSpec(3...3) { call throws(CellError) in
            let alpha = try call.number(0)
            let deviation = try call.number(1)
            let size = try call.number(2).rounded(.towardZero)
            guard alpha > 0, alpha < 1, deviation > 0, size >= 1 else { throw .numberError }
            return .number(D.normalQuantile(1 - alpha / 2) * deviation / size.squareRoot())
        }
        table["CONFIDENCE.NORM"] = normalConfidence
        table["CONFIDENCE"] = normalConfidence
        table["CONFIDENCE.T"] = FunctionSpec(3...3) { call throws(CellError) in
            let alpha = try call.number(0)
            let deviation = try call.number(1)
            let size = try call.number(2).rounded(.towardZero)
            guard alpha > 0, alpha < 1, deviation > 0, size >= 1 else { throw .numberError }
            guard size > 1 else { throw .divideByZero }
            guard let t = D.studentQuantile(1 - alpha / 2, size - 1) else { throw .numberError }
            return .number(t * deviation / size.squareRoot())
        }
        let zTest = FunctionSpec(2...3, lifts: .only([1, 2])) { call throws(CellError) in
            let numbers = try call.numbers([0])
            guard !numbers.isEmpty else { throw .notAvailable }
            let x = try call.number(1)
            let n = Double(numbers.count)
            let mean = FormulaMath.sum(numbers) / n
            let deviation = call.isMissing(2)
                ? sqrt(try FormulaStatistics.variance(numbers, sample: true))
                : try call.number(2)
            guard deviation > 0 else { throw .divideByZero }
            return .number(1 - D.normalCDF((mean - x) / (deviation / n.squareRoot())))
        }
        table["Z.TEST"] = zTest
        table["ZTEST"] = zTest
        let tTest = FunctionSpec(4...4, lifts: .only([2, 3])) { call throws(CellError) in
            try FormulaDistributions.tTest(call)
        }
        table["T.TEST"] = tTest
        table["TTEST"] = tTest

        // MARK: Error function

        table["ERF"] = FunctionSpec(1...2) { call throws(CellError) in
            let lower = try call.number(0)
            guard !call.isMissing(1) else { return .number(erf(lower)) }
            return .number(erf(try call.number(1)) - erf(lower))
        }
        table["ERF.PRECISE"] = .unary { erf($0) }
        table["ERFC"] = .unary { erfc($0) }
        table["ERFC.PRECISE"] = .unary { erfc($0) }

        return table
    }
}

extension FormulaDistributions {
    public static func hypergeometricArguments(_ call: FunctionCall) throws(CellError) -> (Double, Double, Double, Double) {
        let k = try call.number(0).rounded(.towardZero)
        let sample = try call.number(1).rounded(.towardZero)
        let successes = try call.number(2).rounded(.towardZero)
        let population = try call.number(3).rounded(.towardZero)
        guard k >= 0, k <= sample, k <= successes, sample <= population, successes <= population,
              sample - k <= population - successes, sample > 0, successes > 0 else { throw .numberError }
        return (k, sample, successes, population)
    }

    /// Student's t-test: paired (1), equal variances (2) or unequal (3).
    public static func tTest(_ call: FunctionCall) throws(CellError) -> FormulaValue {
        let tails = try call.integer(2)
        let type = try call.integer(3)
        guard tails == 1 || tails == 2, (1...3).contains(type) else { throw .numberError }
        let statistic: Double
        let df: Double
        if type == 1 {
            let first = try call.matrix(0).flatMap { $0 }
            let second = try call.matrix(1).flatMap { $0 }
            guard first.count == second.count else { throw .notAvailable }
            var differences: [Double] = []
            for (a, b) in zip(first, second) {
                if case .number(let x) = a, case .number(let y) = b { differences.append(x - y) }
            }
            guard differences.count >= 2 else { throw .divideByZero }
            let n = Double(differences.count)
            let mean = FormulaMath.sum(differences) / n
            let variance = try FormulaStatistics.variance(differences, sample: true)
            guard variance > 0 else { throw .divideByZero }
            statistic = mean / (variance / n).squareRoot()
            df = n - 1
        } else {
            let first = try call.numbers([0])
            let second = try call.numbers([1])
            guard first.count >= 2, second.count >= 2 else { throw .divideByZero }
            let n1 = Double(first.count)
            let n2 = Double(second.count)
            let mean1 = FormulaMath.sum(first) / n1
            let mean2 = FormulaMath.sum(second) / n2
            let v1 = try FormulaStatistics.variance(first, sample: true)
            let v2 = try FormulaStatistics.variance(second, sample: true)
            if type == 2 {
                let pooled = ((n1 - 1) * v1 + (n2 - 1) * v2) / (n1 + n2 - 2)
                guard pooled > 0 else { throw .divideByZero }
                statistic = (mean1 - mean2) / (pooled * (1 / n1 + 1 / n2)).squareRoot()
                df = n1 + n2 - 2
            } else {
                let s1 = v1 / n1
                let s2 = v2 / n2
                guard s1 + s2 > 0 else { throw .divideByZero }
                statistic = (mean1 - mean2) / (s1 + s2).squareRoot()
                df = (s1 + s2) * (s1 + s2) / (s1 * s1 / (n1 - 1) + s2 * s2 / (n2 - 1))
            }
        }
        let tail = 1 - studentCDF(abs(statistic), df)
        return .number(Double(tails) * tail)
    }
}
