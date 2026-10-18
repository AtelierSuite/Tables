import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Legacy tolerance for rounded published examples. The executable answer
/// catalog uses explicit absolute and relative tolerances for each vector.
func close(_ value: CellValue, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
    guard case .number(let actual) = value, actual.isFinite, expected.isFinite,
          tolerance.isFinite, tolerance >= 0 else { return false }
    return abs(actual - expected) <= tolerance * max(1, abs(expected))
}

@Suite("Math and trigonometry")
struct MathFunctionTests {
    @Test("Hyperbolic and reciprocal trigonometry")
    func trigonometry() {
        #expect(close(evaluate("=SINH(1)"), 1.1752011936438014))
        #expect(close(evaluate("=ACOSH(2)"), 1.3169578969248166))
        #expect(evaluate("=ACOSH(0.5)") == .error(.numberError))
        #expect(close(evaluate("=ACOT(2)"), 0.4636476090008061))
        #expect(close(evaluate("=ACOTH(3)"), 0.34657359027997264))
        #expect(close(evaluate("=COT(1)"), 0.6420926159343306))
        #expect(evaluate("=COT(0)") == .error(.divideByZero))
        #expect(close(evaluate("=CSC(1)"), 1.1883951057781212))
        #expect(close(evaluate("=SEC(1)"), 1.8508157176809255))
        #expect(close(evaluate("=SECH(1)"), 0.6480542736638855))
        #expect(close(evaluate("=SQRTPI(2)"), 2.5066282746310002))
    }

    @Test("Rounding to multiples and parity")
    func multiples() {
        #expect(evaluate("=CEILING.MATH(-2.5,2)") == .number(-2))
        #expect(evaluate("=CEILING.MATH(-2.5,2,1)") == .number(-4))
        #expect(evaluate("=FLOOR.MATH(-2.5,2)") == .number(-4))
        #expect(evaluate("=FLOOR.MATH(-2.5,2,1)") == .number(-2))
        #expect(evaluate("=CEILING.PRECISE(4.3,-2)") == .number(6))
        #expect(evaluate("=FLOOR.PRECISE(-3.2,-1)") == .number(-4))
        #expect(evaluate("=MROUND(10,3)") == .number(9))
        #expect(evaluate("=MROUND(-10,-3)") == .number(-9))
        #expect(evaluate("=MROUND(5,-2)") == .error(.numberError))
        #expect(evaluate("=EVEN(1.5)") == .number(2))
        #expect(evaluate("=EVEN(-1)") == .number(-2))
        #expect(evaluate("=ODD(0)") == .number(1))
        #expect(evaluate("=ODD(-2)") == .number(-3))
        #expect(evaluate("=QUOTIENT(-10,3)") == .number(-3))
    }

    @Test("Counting and combinatorics")
    func combinatorics() {
        #expect(evaluate("=FACT(5)") == .number(120))
        #expect(evaluate("=FACT(-1)") == .error(.numberError))
        #expect(evaluate("=FACTDOUBLE(7)") == .number(105))
        #expect(evaluate("=COMBIN(8,2)") == .number(28))
        #expect(evaluate("=COMBINA(4,3)") == .number(20))
        #expect(evaluate("=MULTINOMIAL(2,3,4)") == .number(1260))
        #expect(evaluate("=GCD(24,36,60)") == .number(12))
        #expect(evaluate("=LCM(4,6,10)") == .number(60))
        #expect(evaluate("=GCD(-1,2)") == .error(.numberError))
    }

    @Test("Sums of squares and series")
    func sums() {
        #expect(evaluate("=SUMSQ(3,4)") == .number(25))
        #expect(evaluate("=SUMX2MY2({2,3},{1,1})") == .number(11))
        #expect(evaluate("=SUMX2PY2({2,3},{1,1})") == .number(15))
        #expect(evaluate("=SUMXMY2({2,3},{1,1})") == .number(5))
        #expect(evaluate("=SERIESSUM(2,0,1,{1,1,1})") == .number(7))
        #expect(evaluate("=PERCENTOF({1,3},{1,3,4,2})") == .number(0.4))
    }

    @Test("Roman numerals in every form, and number bases")
    func numerals() {
        #expect(evaluate("=ROMAN(499)") == .text("CDXCIX"))
        #expect(evaluate("=ROMAN(499,1)") == .text("LDVLIV"))
        #expect(evaluate("=ROMAN(499,2)") == .text("XDIX"))
        #expect(evaluate("=ROMAN(499,3)") == .text("VDIV"))
        #expect(evaluate("=ROMAN(499,4)") == .text("ID"))
        #expect(evaluate("=ROMAN(1994)") == .text("MCMXCIV"))
        #expect(evaluate("=ARABIC(\"mcmxciv\")") == .number(1994))
        #expect(evaluate("=ARABIC(\"ID\")") == .number(499))
        #expect(evaluate("=BASE(255,16,4)") == .text("00FF"))
        #expect(evaluate("=BASE(7,2)") == .text("111"))
        #expect(evaluate("=DECIMAL(\"FF\",16)") == .number(255))
        #expect(evaluate("=DECIMAL(\"zz\",36)") == .number(1295))
    }

    @Test("Matrices")
    func matrices() {
        #expect(evaluate("=SUM(MMULT({1,2;3,4},{5;6}))") == .number(56))
        #expect(evaluate("=MMULT({1,2},{1,2})") == .error(.valueError))
        #expect(close(evaluate("=MDETERM({1,3,8,5;1,3,6,1;1,1,1,0;7,3,10,2})"), 88))
        #expect(close(evaluate("=INDEX(MINVERSE({4,-1;2,1}),1,2)"), 1.0 / 6))
        #expect(evaluate("=MINVERSE({1,2;2,4})") == .error(.numberError))
        #expect(evaluate("=SUM(MUNIT(3))") == .number(3))
    }

    @Test("SEQUENCE and RANDARRAY generate arrays")
    func generators() {
        #expect(evaluate("=SUM(SEQUENCE(4))") == .number(10))
        #expect(evaluate("=INDEX(SEQUENCE(2,3,10,5),2,1)") == .number(25))
        #expect(evaluate("=COUNT(RANDARRAY(3,2,1,6,TRUE))") == .number(6))
    }
}

@Suite("Descriptive statistics")
struct DescriptiveStatisticsTests {
    @Test("Spread and shape match Excel's documented examples")
    func shape() {
        let data = "{3,4,5,2,3,4,5,6,4,7}"
        #expect(close(evaluate("=KURT(\(data))"), -0.151799637, tolerance: 1e-8))
        #expect(close(evaluate("=SKEW(\(data))"), 0.359543071, tolerance: 1e-8))
        #expect(close(evaluate("=SKEW.P(\(data))"), 0.303193339, tolerance: 1e-8))
        #expect(close(evaluate("=TRIMMEAN({4,5,6,7,2,3,4,5,1,2,3},0.2)"), 3.777777778, tolerance: 1e-8))
        #expect(close(evaluate("=AVEDEV({4,5,6,7,5,4,3})"), 1.020408163, tolerance: 1e-8))
        #expect(evaluate("=DEVSQ({4,5,8,7,11,4,3})") == .number(48))
        #expect(close(evaluate("=GEOMEAN({4,5,8,7,11,4,3})"), 5.476986969, tolerance: 1e-8))
        #expect(close(evaluate("=HARMEAN({4,5,8,7,11,4,3})"), 5.028375962, tolerance: 1e-8))
        let sample = "{1345,1301,1368,1322,1310,1370,1318,1350,1303,1299}"
        #expect(close(evaluate("=STDEV.P(\(sample))"), 26.05455814, tolerance: 1e-8))
        #expect(close(evaluate("=STDEV.S(\(sample))"), 27.46391572, tolerance: 1e-8))
        #expect(close(evaluate("=VARA({1,TRUE,\"x\"})"), 1.0 / 3))
    }

    @Test("Percentiles, quartiles and percent ranks")
    func percentiles() {
        #expect(close(evaluate("=PERCENTILE.INC({1,3,2,4},0.3)"), 1.9))
        #expect(close(evaluate("=PERCENTILE.EXC({1,2,3,6,6,6,7,8,9},0.25)"), 2.5))
        #expect(evaluate("=PERCENTILE.EXC({1,2,3},0.1)") == .error(.numberError))
        #expect(close(evaluate("=QUARTILE.INC({1,2,4,7,8,9,10,12},1)"), 3.5))
        #expect(close(evaluate("=QUARTILE.EXC({6,7,15,36,39,40,41,42,43,47,49},1)"), 15))
        let ranks = "{13,12,11,8,4,3,2,1,1,1}"
        #expect(evaluate("=PERCENTRANK.INC(\(ranks),2)") == .number(0.333))
        #expect(evaluate("=PERCENTRANK.INC(\(ranks),4)") == .number(0.555))
        #expect(evaluate("=PERCENTRANK.INC(\(ranks),5)") == .number(0.583))
        #expect(evaluate("=PERCENTRANK.EXC({1,2,3,6,6,6,7,8,9},7)") == .number(0.7))
        #expect(evaluate("=PERCENTRANK.EXC({1,2,3,6,6,6,7,8,9},5.43)") == .number(0.381))
        #expect(evaluate("=PERCENTRANK.EXC({1,2,3,6,6,6,7,8,9},5.43,1)") == .number(0.3))
    }

    @Test("Ranks, modes and frequencies")
    func ranks() {
        #expect(evaluate("=RANK.EQ(7,{7,3.5,3.5,1,2})") == .number(1))
        #expect(evaluate("=RANK.EQ(2,{7,3.5,3.5,1,2},1)") == .number(2))
        #expect(evaluate("=RANK.AVG(3.5,{7,3.5,3.5,1,2})") == .number(2.5))
        #expect(evaluate("=RANK(9,{7,3.5})") == .error(.notAvailable))
        #expect(evaluate("=MODE.SNGL({5.6,4,4,3,2,4})") == .number(4))
        #expect(evaluate("=MODE({1,2,3})") == .error(.notAvailable))
        #expect(evaluate("=TEXTJOIN(\",\",,MODE.MULT({1,2,3,4,3,2,1,2,3,5,6,1}))") == .text("1,2,3"))
        #expect(evaluate("=TEXTJOIN(\",\",,FREQUENCY({79,85,78,85,50,81,95,88,97},{70,79,89}))") == .text("1,2,4,2"))
        #expect(evaluate("=MAXIFS({89,93,96,85,91,88},{1,2,2,3,1,1},1)") == .number(91))
        #expect(evaluate("=MINIFS({89,93,96,85,91,88},{1,2,2,3,1,1},2)") == .number(93))
    }

    @Test("Correlation, covariance and simple regression")
    func pairs() {
        #expect(close(evaluate("=CORREL({3,2,4,5,6},{9,7,12,15,17})"), 0.997054486, tolerance: 1e-8))
        #expect(close(evaluate("=COVARIANCE.P({3,2,4,5,6},{9,7,12,15,17})"), 5.2))
        #expect(close(evaluate("=COVARIANCE.S({3,2,4,5,6},{9,7,12,15,17})"), 6.5))
        let ys = "{2,3,9,1,8,7,5}"
        let xs = "{6,5,11,7,5,4,4}"
        #expect(close(evaluate("=SLOPE(\(ys),\(xs))"), 0.305555556, tolerance: 1e-8))
        #expect(close(evaluate("=INTERCEPT({2,3,9,1,8},{6,5,11,7,5})"), 0.048387097, tolerance: 1e-7))
        #expect(close(evaluate("=RSQ(\(ys),\(xs))"), 0.057950192, tolerance: 1e-7))
        #expect(close(evaluate("=STEYX(\(ys),\(xs))"), 3.305718950, tolerance: 1e-8))
        #expect(close(evaluate("=FORECAST(30,{6,7,9,15,21},{20,28,31,38,40})"), 10.607253, tolerance: 1e-7))
        #expect(close(evaluate("=FORECAST.LINEAR(30,{6,7,9,15,21},{20,28,31,38,40})"), 10.607253, tolerance: 1e-7))
    }

    @Test("Multiple regression and growth curves")
    func regression() {
        #expect(close(evaluate("=INDEX(LINEST({1,9,5,7},{0,4,2,3}),1,1)"), 2))
        #expect(close(evaluate("=INDEX(LINEST({1,9,5,7},{0,4,2,3}),1,2)"), 1))
        #expect(close(evaluate("=TREND({1,2,3},{1,2,3},4)"), 4))
        let sales = "{33100,47300,69000,102000,150000,220000}"
        let months = "{11,12,13,14,15,16}"
        #expect(close(evaluate("=GROWTH(\(sales),\(months),17)"), 320196.7184, tolerance: 1e-8))
        #expect(close(evaluate("=INDEX(LOGEST(\(sales),\(months)),1,1)"), 1.463275628, tolerance: 1e-8))
        #expect(close(evaluate("=INDEX(LOGEST(\(sales),\(months)),1,2)"), 495.3047702, tolerance: 1e-7))
        // Two predictors, with statistics.
        let y = "{1;2;3;5;8}"
        let x = "{1,2;2,1;3,4;4,3;5,7}"
        #expect(close(evaluate("=INDEX(LINEST(\(y),\(x),TRUE,TRUE),3,1)"), 0.9574102368220015))
        #expect(close(evaluate("=INDEX(LINEST(\(y),\(x)),1,1)"), 0.29411764705882354))
        #expect(close(evaluate("=INDEX(LINEST(\(y),\(x)),1,2)"), 1.3470588235294119))
        #expect(close(evaluate("=INDEX(LINEST(\(y),\(x)),1,3)"), -1.2411764705882353))
        #expect(evaluate("=INDEX(LINEST(\(y),\(x),TRUE,TRUE),3,3)") == .error(.notAvailable))
    }

    @Test("Standardising, Fisher transforms, permutations and probability")
    func odds() {
        #expect(close(evaluate("=STANDARDIZE(42,40,1.5)"), 1.333333333, tolerance: 1e-8))
        #expect(close(evaluate("=FISHER(0.75)"), 0.972955075, tolerance: 1e-8))
        #expect(close(evaluate("=FISHERINV(0.972955075)"), 0.75, tolerance: 1e-8))
        #expect(evaluate("=PERMUT(100,3)") == .number(970200))
        #expect(evaluate("=PERMUTATIONA(3,2)") == .number(9))
        #expect(close(evaluate("=PROB({0,1,2,3},{0.2,0.3,0.1,0.4},2)"), 0.1))
        #expect(close(evaluate("=PROB({0,1,2,3},{0.2,0.3,0.1,0.4},1,3)"), 0.8))
    }
}

@Suite("Probability distributions")
struct DistributionTests {
    private func check(_ formula: String, _ expected: Double, _ tolerance: Double = 1e-6) {
        let value = evaluate(formula)
        #expect(close(value, expected, tolerance: tolerance), "\(formula) gave \(value)")
    }

    @Test("Normal and log-normal")
    func normal() {
        check("=NORM.DIST(42,40,1.5,TRUE)", 0.9087888)
        check("=NORM.DIST(42,40,1.5,FALSE)", 0.10934005)
        check("=NORM.INV(0.908789,40,1.5)", 42.000002)
        check("=NORM.S.DIST(1.333333,TRUE)", 0.908788726)
        check("=NORM.S.DIST(1.333333,FALSE)", 0.164010148)
        check("=NORM.S.INV(0.908789)", 1.333334673)
        check("=NORMSINV(0.001)", -3.090232306)
        check("=LOGNORM.DIST(4,3.5,1.2,TRUE)", 0.0390836)
        check("=LOGNORM.DIST(4,3.5,1.2,FALSE)", 0.0176176)
        check("=LOGNORM.INV(0.039084,3.5,1.2)", 4.0000252)
        check("=GAUSS(2)", 0.47724987)
        check("=PHI(0.75)", 0.301137432)
        #expect(evaluate("=NORM.INV(0,1,1)") == .error(.numberError))
    }

    @Test("Student's t, chi-square and F")
    func sampling() {
        check("=T.DIST(60,1,TRUE)", 0.99469533)
        check("=T.DIST(8,3,FALSE)", 0.00073691)
        check("=T.DIST.2T(1.959999998,60)", 0.054644930)
        check("=T.DIST.RT(1.959999998,60)", 0.027322465)
        check("=TDIST(1.959999998,60,2)", 0.054644930)
        check("=T.INV(0.75,2)", 0.8164966)
        check("=T.INV.2T(0.546449,60)", 0.606533)
        check("=CHISQ.DIST(0.5,1,TRUE)", 0.52049988)
        check("=CHISQ.DIST(2,3,FALSE)", 0.20755375)
        check("=CHISQ.DIST.RT(18.307,10)", 0.0500006)
        check("=CHISQ.INV(0.93,1)", 3.283020287)
        check("=CHISQ.INV(0.6,2)", 1.832581464)
        check("=CHISQ.INV.RT(0.050001,10)", 18.30697)
        check("=F.DIST(15.2069,6,4,TRUE)", 0.99)
        check("=F.DIST(15.2069,6,4,FALSE)", 0.0012238)
        check("=F.DIST.RT(15.2069,6,4)", 0.01)
        check("=F.INV(0.01,6,4)", 0.10930991)
        check("=F.INV.RT(0.01,6,4)", 15.20686)
    }

    @Test("Beta and gamma")
    func continuous() {
        check("=BETA.DIST(2,8,10,TRUE,1,3)", 0.6854706)
        check("=BETA.DIST(2,8,10,FALSE,1,3)", 1.4837646)
        check("=BETA.INV(0.685470581,8,10,1,3)", 1.9999999999631428)
        check("=GAMMA.DIST(10.00001131,9,2,FALSE)", 0.032639)
        check("=GAMMA.DIST(10.00001131,9,2,TRUE)", 0.068094)
        check("=GAMMA.INV(0.068094,9,2)", 10.0000112, 1e-5)
        check("=GAMMA(2.5)", 1.329340388)
        check("=GAMMALN(4)", 1.791759469)
        #expect(evaluate("=GAMMA(-1)") == .error(.numberError))
        check("=EXPON.DIST(0.2,10,TRUE)", 0.86466472)
        check("=EXPON.DIST(0.2,10,FALSE)", 1.35335283)
        check("=WEIBULL.DIST(105,20,100,TRUE)", 0.929581)
        check("=WEIBULL.DIST(105,20,100,FALSE)", 0.035589)
    }

    @Test("Discrete distributions")
    func discrete() {
        check("=BINOM.DIST(6,10,0.5,FALSE)", 0.2050781)
        check("=BINOM.DIST(6,10,0.5,TRUE)", 0.828125)
        check("=BINOM.DIST.RANGE(60,0.75,48)", 0.083974967)
        check("=BINOM.DIST.RANGE(60,0.75,45,50)", 0.523629793)
        #expect(evaluate("=BINOM.INV(6,0.5,0.75)") == .number(4))
        check("=POISSON.DIST(2,5,TRUE)", 0.124652)
        check("=POISSON.DIST(2,5,FALSE)", 0.084224)
        check("=HYPGEOM.DIST(1,4,8,20,TRUE)", 0.4654, 1e-4)
        check("=HYPGEOM.DIST(1,4,8,20,FALSE)", 0.3633, 1e-4)
        check("=NEGBINOM.DIST(10,5,0.25,TRUE)", 0.3135141)
        check("=NEGBINOM.DIST(10,5,0.25,FALSE)", 0.0550487)
    }

    @Test("Confidence intervals and hypothesis tests")
    func tests() {
        check("=CONFIDENCE.NORM(0.05,2.5,50)", 0.692952)
        check("=CONFIDENCE.T(0.05,1,50)", 0.284196855)
        check("=Z.TEST({3,6,7,8,6,5,4,2,1,9},4)", 0.090574)
        check("=T.TEST({3,4,5,8,9,1,2,4,5},{6,19,3,2,14,4,5,17,1},2,1)", 0.196016)
        check("=CHISQ.TEST({58,35;11,25;10,23},{45.35,47.65;17.56,18.44;16.09,16.91})", 0.0003082)
        check("=F.TEST({6,7,9,15,21},{20,28,31,38,40})", 0.64831785)
        check("=ERF(0.745)", 0.70792892)
        check("=ERFC(1)", 0.15729921)
    }
}

@Suite("SUBTOTAL and AGGREGATE")
struct SubtotalTests {
    private func sheet(hiding rows: Set<Int> = []) -> (String) -> CellValue {
        var sheet = Worksheet(name: "Sheet 1")
        let entries = ["A1": "10", "A2": "20", "A3": "=SUBTOTAL(9,A1:A2)", "A4": "=1/0", "A5": "5"]
        for (reference, input) in entries {
            sheet[CellAddress(a1: reference)!] = CellInputParser.cell(from: input, inheriting: .default)
        }
        let formulas = [
            "B1": "=SUBTOTAL(9,A1:A3)", "B2": "=SUBTOTAL(109,A1:A2,A5)", "B3": "=SUBTOTAL(9,A1:A2,A5)",
            "B4": "=AGGREGATE(9,6,A1:A5)", "B5": "=AGGREGATE(9,3,A1:A5)", "B6": "=AGGREGATE(14,6,A1:A5,2)",
            "B7": "=AGGREGATE(9,4,A1:A5)", "B8": "=SUBTOTAL(2,A1:A5)", "B9": "=AGGREGATE(15,6,{3,1,#N/A,2},2)",
        ]
        for (reference, input) in formulas {
            sheet[CellAddress(a1: reference)!] = CellInputParser.cell(from: input, inheriting: .default)
        }
        sheet.hiddenRows = rows
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        return { workbook.sheets[0][CellAddress(a1: $0)!].value }
    }

    @Test("Nested subtotals are left out, and hidden rows when asked")
    func subtotal() {
        let visible = sheet()
        #expect(visible("B1") == .number(30))
        #expect(visible("B2") == .number(35))
        #expect(visible("B8") == .number(3))
        let hidden = sheet(hiding: [1])
        #expect(hidden("B2") == .number(15))
        #expect(hidden("B3") == .number(35))
    }

    @Test("AGGREGATE can pass over errors, hidden rows and nested results")
    func aggregate() {
        let visible = sheet()
        #expect(visible("B4") == .number(65))  // option 6 keeps nested subtotals
        #expect(visible("B6") == .number(20))
        #expect(visible("B7") == .error(.divideByZero))
        #expect(visible("B9") == .number(2))
        let hidden = sheet(hiding: [0])
        #expect(hidden("B5") == .number(25))
    }
}

@Suite("Text")
struct TextFunctionTests {
    @Test("Splitting text around delimiters")
    func splitting() {
        #expect(evaluate("=TEXTBEFORE(\"Red riding hood's, red hood\",\"hood\")") == .text("Red riding "))
        #expect(evaluate("=TEXTBEFORE(\"Red riding hood's, red hood\",\"hood\",-1)") == .text("Red riding hood's, red "))
        #expect(evaluate("=TEXTBEFORE(\"Red riding hood's, red hood\",\"HOOD\",1,1)") == .text("Red riding "))
        #expect(evaluate("=TEXTAFTER(\"Red riding hood's, red hood\",\"hood\")") == .text("'s, red hood"))
        #expect(evaluate("=TEXTAFTER(\"a-b_c\",{\"-\",\"_\"},2)") == .text("c"))
        #expect(evaluate("=TEXTAFTER(\"abc\",\"x\")") == .error(.notAvailable))
        #expect(evaluate("=TEXTAFTER(\"abc\",\"x\",,,,\"none\")") == .text("none"))
        #expect(evaluate("=TEXTBEFORE(\"abc\",\"x\",1,0,1)") == .text("abc"))
        #expect(evaluate("=INDEX(TEXTSPLIT(\"a,b;c\",\",\",\";\"),2,1)") == .text("c"))
        #expect(evaluate("=INDEX(TEXTSPLIT(\"a,b;c\",\",\",\";\"),2,2)") == .error(.notAvailable))
        #expect(evaluate("=TEXTJOIN(\"|\",,TEXTSPLIT(\"a,,b\",\",\",,TRUE))") == .text("a|b"))
        #expect(evaluate("=TEXTJOIN(\"|\",,TEXTSPLIT(\"a,b;c\",\",\",\";\",,,\"-\"))") == .text("a|b|c|-"))
    }

    @Test("Regular expressions")
    func regex() {
        #expect(evaluate("=REGEXTEST(\"abc123\",\"[0-9]+\")") == .boolean(true))
        #expect(evaluate("=REGEXTEST(\"ABC\",\"abc\",1)") == .boolean(true))
        #expect(evaluate("=REGEXEXTRACT(\"tel 555-1234\",\"[0-9]{3}-[0-9]{4}\")") == .text("555-1234"))
        #expect(evaluate("=TEXTJOIN(\",\",,REGEXEXTRACT(\"a1b22c333\",\"[0-9]+\",1))") == .text("1,22,333"))
        #expect(evaluate("=TEXTJOIN(\",\",,REGEXEXTRACT(\"John Smith\",\"(\\w+) (\\w+)\",2))") == .text("John,Smith"))
        #expect(evaluate("=REGEXREPLACE(\"John Smith\",\"(\\w+) (\\w+)\",\"$2, $1\")") == .text("Smith, John"))
        #expect(evaluate("=REGEXREPLACE(\"a1b2c3\",\"[0-9]\",\"#\",2)") == .text("a1b#c3"))
        #expect(evaluate("=REGEXEXTRACT(\"abc\",\"[0-9]\")") == .error(.notAvailable))
        #expect(evaluate("=REGEXTEST(\"a\",\"(\")") == .error(.valueError))
    }

    @Test("Formatting numbers as text")
    func numbers() {
        #expect(evaluate("=FIXED(1234.567,1)") == .text("1,234.6"))
        #expect(evaluate("=FIXED(1234.567,-1)") == .text("1,230"))
        #expect(evaluate("=FIXED(-1234.567,-1,TRUE)") == .text("-1230"))
        #expect(evaluate("=FIXED(44.332)") == .text("44.33"))
        #expect(evaluate("=DOLLAR(1234.567,2)") == .text("$1,234.57"))
        #expect(evaluate("=DOLLAR(-1234.567,-2)") == .text("($1,200)"))
        #expect(evaluate("=NUMBERVALUE(\"2.500,27\",\",\",\".\")") == .number(2500.27))
        #expect(evaluate("=NUMBERVALUE(\"3.5%\")") == .number(0.035))
        #expect(evaluate("=VALUETOTEXT(\"a\",1)") == .text("\"a\""))
        #expect(evaluate("=ARRAYTOTEXT({1,\"a\";TRUE,2})") == .text("1, a, TRUE, 2"))
        #expect(evaluate("=ARRAYTOTEXT({1,\"a\";TRUE,2},1)") == .text("{1,\"a\";TRUE,2}"))
    }

    @Test("Characters, cleaning and width")
    func characters() {
        #expect(evaluate("=UNICHAR(66)") == .text("B"))
        #expect(evaluate("=UNICODE(\"€\")") == .number(8364))
        #expect(evaluate("=CLEAN(CHAR(9)&\"Monthly\"&CHAR(10))") == .text("Monthly"))
        #expect(evaluate("=T(\"x\")&T(1)") == .text("x"))
        #expect(evaluate("=ASC(\"ＥＸＣＥＬ\")") == .text("EXCEL"))
        #expect(evaluate("=DBCS(\"EXCEL\")") == .text("ＥＸＣＥＬ"))
        #expect(evaluate("=LENB(\"abc\")") == .number(3))
        #expect(evaluate("=BAHTTEXT(1234)") == .text("หนึ่งพันสองร้อยสามสิบสี่บาทถ้วน"))
        #expect(evaluate("=BAHTTEXT(21.25)") == .text("ยี่สิบเอ็ดบาทยี่สิบห้าสตางค์"))
    }
}

@Suite("Dates and times")
struct DateFunctionTests {
    @Test("Reading dates and times from text")
    func parsing() {
        #expect(evaluate("=DATEVALUE(\"8/22/2011\")") == .number(40777))
        #expect(evaluate("=DATEVALUE(\"22-MAY-2011\")") == .number(40685))
        #expect(close(evaluate("=TIMEVALUE(\"2:24 AM\")"), 0.1))
        #expect(close(evaluate("=TIMEVALUE(\"22-Aug-2011 6:35 AM\")"), 0.274305556, tolerance: 1e-8))
        #expect(evaluate("=DATEVALUE(40777)") == .error(.valueError))
        #expect(evaluate("=DAYS(\"3/15/11\",\"2/1/11\")") == .number(42))
    }

    @Test("Differences and 360-day years")
    func differences() {
        #expect(evaluate("=DATEDIF(DATE(2001,1,1),DATE(2003,1,1),\"Y\")") == .number(2))
        #expect(evaluate("=DATEDIF(DATE(2001,6,1),DATE(2002,8,15),\"D\")") == .number(440))
        #expect(evaluate("=DATEDIF(DATE(2001,6,1),DATE(2002,8,15),\"YD\")") == .number(75))
        #expect(evaluate("=DATEDIF(DATE(2001,6,1),DATE(2002,8,15),\"MD\")") == .number(14))
        #expect(evaluate("=DATEDIF(DATE(2001,6,1),DATE(2002,8,15),\"YM\")") == .number(2))
        #expect(evaluate("=DATEDIF(DATE(2001,6,1),DATE(2002,8,15),\"M\")") == .number(14))
        #expect(evaluate("=DATEDIF(DATE(2003,1,1),DATE(2001,1,1),\"Y\")") == .error(.numberError))
        #expect(evaluate("=DAYS360(DATE(2011,1,30),DATE(2011,12,31))") == .number(330))
        #expect(evaluate("=DAYS360(DATE(2011,2,28),DATE(2011,3,31))") == .number(30))
        #expect(evaluate("=DAYS360(DATE(2011,1,15),DATE(2011,3,31),TRUE)") == .number(75))
    }

    @Test("Moving by months and counting weeks")
    func months() {
        #expect(evaluate("=EDATE(DATE(2011,1,31),1)") == .number(40602))
        #expect(evaluate("=EOMONTH(DATE(2011,1,1),1)") == .number(40602))
        #expect(evaluate("=EOMONTH(DATE(2011,1,1),-3)") == .number(40482))
        #expect(evaluate("=WEEKNUM(DATE(2012,3,9))") == .number(10))
        #expect(evaluate("=WEEKNUM(DATE(2012,3,9),2)") == .number(11))
        #expect(evaluate("=ISOWEEKNUM(DATE(2012,3,9))") == .number(10))
        #expect(evaluate("=ISOWEEKNUM(DATE(2021,1,1))") == .number(53))
    }

    @Test("Working days, with weekends and holidays")
    func workdays() {
        #expect(evaluate("=NETWORKDAYS(DATE(2012,10,1),DATE(2013,3,1))") == .number(110))
        #expect(evaluate("=NETWORKDAYS(DATE(2012,10,1),DATE(2013,3,1),DATE(2012,11,22))") == .number(109))
        #expect(evaluate("=NETWORKDAYS(DATE(2012,10,1),DATE(2013,3,1),{41235,41247,41295})") == .number(107))
        #expect(evaluate("=NETWORKDAYS.INTL(DATE(2006,1,1),DATE(2006,1,31))") == .number(22))
        #expect(evaluate("=NETWORKDAYS.INTL(DATE(2006,1,1),DATE(2006,2,1),7,{\"2006/1/2\",\"2006/1/16\"})")
                == .number(22))
        #expect(evaluate("=NETWORKDAYS.INTL(DATE(2006,1,1),DATE(2006,2,1),\"0010001\",{\"2006/1/2\",\"2006/1/16\"})")
                == .number(20))
        #expect(evaluate("=WORKDAY(DATE(2008,10,1),151)") == .number(39933))
        #expect(evaluate("=WORKDAY(DATE(2008,10,1),151,{39778,39786,39834})") == .number(39938))
        #expect(evaluate("=WORKDAY.INTL(DATE(2012,1,1),30,0)") == .error(.numberError))
        #expect(evaluate("=WORKDAY.INTL(DATE(2012,1,1),90,11)") == .number(41013))
        #expect(evaluate("=WORKDAY.INTL(DATE(2012,1,1),30,17)") == .number(40944))
    }

    @Test("Year fractions under each basis")
    func yearFractions() {
        #expect(close(evaluate("=YEARFRAC(DATE(2012,1,1),DATE(2012,7,30))"), 0.580555556, tolerance: 1e-8))
        #expect(close(evaluate("=YEARFRAC(DATE(2012,1,1),DATE(2012,7,30),1)"), 0.576502732, tolerance: 1e-8))
        #expect(close(evaluate("=YEARFRAC(DATE(2012,1,1),DATE(2012,7,30),3)"), 0.578082192, tolerance: 1e-8))
        #expect(close(evaluate("=YEARFRAC(DATE(2012,7,30),DATE(2012,1,1),2)"), 211.0 / 360))
    }
}

@Suite("Lookup, reference and array functions")
struct ArrayFunctionTests {
    private let grid = ["A1": "1", "A2": "2", "A3": "3", "B1": "x", "B2": "y", "B3": "z", "C1": "=SUM(A1:A3)"]

    @Test("OFFSET, INDIRECT and ADDRESS")
    func references() {
        #expect(evaluate("=SUM(OFFSET(A1,1,0,2,1))", with: grid) == .number(5))
        #expect(evaluate("=OFFSET(A1,2,1)", with: grid) == .text("z"))
        #expect(evaluate("=ROWS(OFFSET(A1,0,0,3,2))", with: grid) == .number(3))
        #expect(evaluate("=OFFSET(A1,-1,0)", with: grid) == .error(.referenceError))
        #expect(evaluate("=INDIRECT(\"B2\")", with: grid) == .text("y"))
        #expect(evaluate("=SUM(INDIRECT(\"A1:A\"&3))", with: grid) == .number(6))
        #expect(evaluate("=INDIRECT(\"R2C1\",FALSE)", with: grid) == .number(2))
        #expect(evaluate("=INDIRECT(\"nonsense!!\")", with: grid) == .error(.referenceError))
        #expect(evaluate("=ADDRESS(2,3)") == .text("$C$2"))
        #expect(evaluate("=ADDRESS(2,3,2)") == .text("C$2"))
        #expect(evaluate("=ADDRESS(2,3,2,FALSE)") == .text("R2C[3]"))
        #expect(evaluate("=ADDRESS(2,3,1,FALSE,\"[Book1]Sheet1\")") == .text("'[Book1]Sheet1'!R2C3"))
        #expect(evaluate("=ADDRESS(2,3,1,TRUE,\"EXCEL SHEET\")") == .text("'EXCEL SHEET'!$C$2"))
        #expect(evaluate("=FORMULATEXT(C1)", with: grid) == .text("=SUM(A1:A3)"))
        #expect(evaluate("=FORMULATEXT(A1)", with: grid) == .error(.notAvailable))
        #expect(evaluate("=COLUMNS(A1:C9)") == .number(3))
        #expect(evaluate("=ROWS({1;2;3})") == .number(3))
    }

    @Test("LOOKUP and XMATCH")
    func lookups() {
        #expect(evaluate("=LOOKUP(2.5,A1:A3,B1:B3)", with: grid) == .text("y"))
        #expect(evaluate("=LOOKUP(3,{1,2,3;\"a\",\"b\",\"c\"})") == .text("c"))
        #expect(evaluate("=XMATCH(\"y\",B1:B3)", with: grid) == .number(2))
        #expect(evaluate("=XMATCH(2.5,A1:A3,1)", with: grid) == .number(3))
        #expect(evaluate("=XMATCH(2.5,A1:A3,-1)", with: grid) == .number(2))
        #expect(evaluate("=XMATCH(\"^[yz]$\",B1:B3,3)", with: grid) == .number(2))
    }

    @Test("Filtering, sorting and de-duplicating")
    func reshaping() {
        #expect(evaluate("=TEXTJOIN(\",\",,FILTER(B1:B3,A1:A3>1))", with: grid) == .text("y,z"))
        #expect(evaluate("=FILTER(B1:B3,A1:A3>5)", with: grid) == .error(.calc))
        #expect(evaluate("=FILTER(B1:B3,A1:A3>5,\"none\")", with: grid) == .text("none"))
        #expect(evaluate("=TEXTJOIN(\",\",,SORT({3;1;2}))") == .text("1,2,3"))
        #expect(evaluate("=TEXTJOIN(\",\",,SORT({3;1;2},1,-1))") == .text("3,2,1"))
        #expect(evaluate("=TEXTJOIN(\",\",,SORT({\"b\",2;\"a\",2;\"c\",1},{2,1},{1,1}))") == .text("c,1,a,2,b,2"))
        #expect(evaluate("=TEXTJOIN(\",\",,SORTBY({\"x\";\"y\";\"z\"},{3;1;2}))") == .text("y,z,x"))
        #expect(evaluate("=TEXTJOIN(\",\",,UNIQUE({\"a\";\"A\";\"b\";\"a\"}))") == .text("a,b"))
        #expect(evaluate("=TEXTJOIN(\",\",,UNIQUE({\"a\";\"b\";\"a\"},,TRUE))") == .text("b"))
    }

    @Test("Taking, dropping, choosing and stacking")
    func slicing() {
        let block = "{1,2,3;4,5,6;7,8,9}"
        #expect(evaluate("=SUM(TAKE(\(block),2))") == .number(21))
        #expect(evaluate("=SUM(TAKE(\(block),-1,-2))") == .number(17))
        #expect(evaluate("=SUM(DROP(\(block),1,1))") == .number(28))
        #expect(evaluate("=DROP(\(block),3)") == .error(.calc))
        #expect(evaluate("=SUM(CHOOSEROWS(\(block),1,-1))") == .number(30))
        #expect(evaluate("=SUM(CHOOSECOLS(\(block),2))") == .number(15))
        #expect(evaluate("=CHOOSECOLS(\(block),4)") == .error(.valueError))
        #expect(evaluate("=INDEX(EXPAND({1,2},2,3,0),2,3)") == .number(0))
        #expect(evaluate("=INDEX(VSTACK({1,2},{3}),2,2)") == .error(.notAvailable))
        #expect(evaluate("=SUM(HSTACK({1;2},{3;4}))") == .number(10))
        #expect(evaluate("=TEXTJOIN(\",\",,TOCOL(\(block),,TRUE))") == .text("1,4,7,2,5,8,3,6,9"))
        #expect(evaluate("=TEXTJOIN(\",\",,TOROW({1,#N/A;3,4},2))") == .text("1,3,4"))
        #expect(evaluate("=INDEX(WRAPROWS({1,2,3,4,5},2,0),3,2)") == .number(0))
        #expect(evaluate("=INDEX(WRAPCOLS({1,2,3,4,5},2),2,3)") == .error(.notAvailable))
        #expect(evaluate("=INDEX(TRANSPOSE({1,2,3}),3,1)") == .number(3))
    }

    @Test("TRIMRANGE trims blank edges off a reference")
    func trimming() {
        #expect(evaluate("=ROWS(TRIMRANGE(A1:B10))", with: grid) == .number(3))
        #expect(evaluate("=ROWS(TRIMRANGE(A1:B10,1))", with: grid) == .number(10))
    }
}

@Suite("Information")
struct InformationFunctionTests {
    @Test("Kinds of value and of error")
    func kinds() {
        #expect(evaluate("=ISNA(NA())") == .boolean(true))
        #expect(evaluate("=ISERR(NA())") == .boolean(false))
        #expect(evaluate("=ISERR(1/0)") == .boolean(true))
        #expect(evaluate("=ISNONTEXT(A1)") == .boolean(true))
        #expect(evaluate("=ISREF(A1)") == .boolean(true))
        #expect(evaluate("=ISREF(1)") == .boolean(false))
        #expect(evaluate("=ISFORMULA(A1)", with: ["A1": "=1+1"]) == .boolean(true))
        #expect(evaluate("=ERROR.TYPE(1/0)") == .number(2))
        #expect(evaluate("=ERROR.TYPE(1)") == .error(.notAvailable))
        #expect(evaluate("=N(TRUE)+N(\"7\")+N(5)") == .number(6))
        #expect(evaluate("=TYPE(\"a\")+TYPE({1,2})") == .number(66))
        #expect(evaluate("=TYPE(LAMBDA(x,x))") == .number(128))
    }

    @Test("Sheets and cells")
    func cells() {
        #expect(evaluate("=SHEET()") == .number(1))
        #expect(evaluate("=SHEETS()") == .number(1))
        #expect(evaluate("=CELL(\"address\",B3)") == .text("$B$3"))
        #expect(evaluate("=CELL(\"row\",B3)+CELL(\"col\",B3)") == .number(5))
        #expect(evaluate("=CELL(\"contents\",A1)", with: ["A1": "hi"]) == .text("hi"))
        #expect(evaluate("=CELL(\"type\",A1)", with: ["A1": "hi"]) == .text("l"))
        #expect(evaluate("=CELL(\"type\",A2)", with: ["A1": "hi"]) == .text("b"))
        #expect(evaluate("=CELL(\"format\",A1)", with: ["A1": "5"]) == .text("G"))
        #expect(evaluate("=CELL(\"prefix\",A1)", with: ["A1": "hi"]) == .text("'"))
        #expect(FormulaInformation.formatCode("0.00") == "F2")
        #expect(FormulaInformation.formatCode("#,##0") == ",0")
        #expect(FormulaInformation.formatCode("$#,##0.00_);($#,##0.00)") == "C2")
        #expect(FormulaInformation.formatCode("0%") == "P0")
        #expect(FormulaInformation.formatCode("0.00E+00") == "S2")
        #expect(FormulaInformation.formatCode("d-mmm-yy") == "D1")
        #expect(FormulaInformation.formatCode("h:mm AM/PM") == "D7")
        #expect(evaluate("=INFO(\"recalc\")") == .text("Automatic"))
    }
}

@Suite("Financial")
struct FinancialFunctionTests {
    private func check(_ formula: String, _ expected: Double, _ tolerance: Double = 1e-6) {
        let value = evaluate(formula)
        #expect(close(value, expected, tolerance: tolerance), "\(formula) gave \(value)")
    }

    @Test("Loans and annuities")
    func annuities() {
        check("=PMT(0.08/12,10,10000)", -1037.032089)
        check("=FV(0.06/12,10,-200,-500,1)", 2581.403374)
        check("=PV(0.08/12,12*20,500,,0)", -59777.14585)
        check("=NPER(0.12/12,-100,-1000,10000,1)", 59.6738657)
        check("=RATE(4*12,-200,8000)", 0.007701472)
        check("=IPMT(0.1/12,1,3*12,8000)", -66.66666667)
        check("=IPMT(0.1,3,3,8000)", -292.4471299)
        check("=PPMT(0.1/12,1,2*12,2000)", -75.62318601)
        check("=CUMIPMT(0.09/12,30*12,125000,13,24,0)", -11135.23213)
        check("=CUMPRINC(0.09/12,30*12,125000,13,24,0)", -934.1071234)
        check("=ISPMT(0.1/12,1,3*12,8000000)", -64814.81481)
        check("=EFFECT(0.0525,4)", 0.053542667)
        check("=NOMINAL(0.053543,4)", 0.05250032, 1e-7)
        check("=PDURATION(0.025,2000,2200)", 3.859866163)
        check("=RRI(96,10000,11000)", 0.0009933073762913949)
        check("=FVSCHEDULE(1,{0.09,0.11,0.1})", 1.33089)
        check("=DOLLARDE(1.02,16)", 1.125)
        check("=DOLLARFR(1.125,16)", 1.02)
    }

    @Test("Cash flow returns")
    func cashFlows() {
        check("=NPV(0.1,-10000,3000,4200,6800)", 1188.443412)
        check("=XNPV(0.09,{-10000,2750,4250,3250,2750},{39448,39508,39751,39859,39904})", 2086.647602)
        check("=IRR({-70000,12000,15000,18000,21000,26000})", 0.086630948)
        check("=IRR({-70000,12000,15000})", -0.443506941)
        check("=XIRR({-10000,2750,4250,3250,2750},{39448,39508,39751,39859,39904})", 0.37336253351883153)
        check("=MIRR({-120000,39000,30000,21000,37000,46000},0.1,0.12)", 0.12609413036590514)
        #expect(evaluate("=IRR({1,2,3})") == .error(.numberError))
    }

    @Test("Depreciation")
    func depreciation() {
        check("=SLN(30000,7500,10)", 2250)
        check("=SYD(30000,7500,10,1)", 4090.909091)
        check("=DB(1000000,100000,6,1,7)", 186083.3333)
        check("=DB(1000000,100000,6,2,7)", 259639.4167)
        check("=DB(1000000,100000,6,7,7)", 15845.098473848073)
        check("=DDB(2400,300,10*365,1)", 1.315068493)
        check("=DDB(2400,300,10,1,2)", 480)
        check("=DDB(2400,300,10,10)", 22.1225472)
        check("=VDB(2400,300,10*365,0,1)", 1.315068493)
        check("=VDB(2400,300,10*12,0,1)", 40)
        check("=VDB(2400,300,10,0,1)", 480)
        check("=VDB(2400,300,10*12,6,18)", 396.3060533)
        check("=VDB(2400,300,10*12,6,18,1.5)", 311.8089366582341)
        check("=VDB(2400,300,10,0,0.875,1.5)", 315)
        check("=AMORLINC(2400,DATE(2008,8,19),DATE(2008,12,31),300,1,0.15,1)", 360)
        check("=AMORDEGRC(2400,DATE(2008,8,19),DATE(2008,12,31),300,1,0.15,1)", 776)
    }

    @Test("Coupon schedules")
    func coupons() {
        let bond = "DATE(2011,1,25),DATE(2011,11,15),2,1"
        check("=COUPDAYBS(\(bond))", 71)
        check("=COUPDAYS(\(bond))", 181)
        check("=COUPDAYSNC(\(bond))", 110)
        check("=COUPNCD(\(bond))", 40678)
        check("=COUPPCD(\(bond))", 40497)
        check("=COUPNUM(\(bond))", 2)
    }

    @Test("Bond prices, yields and durations")
    func bonds() {
        check("=PRICE(DATE(2008,2,15),DATE(2017,11,15),0.0575,0.065,100,2,0)", 94.63436162)
        check("=YIELD(DATE(2008,2,15),DATE(2016,11,15),0.0575,95.04287,100,2,0)", 0.065, 1e-6)
        check("=DURATION(DATE(2008,1,1),DATE(2016,1,1),0.08,0.09,2,1)", 5.993774955545184)
        check("=MDURATION(DATE(2008,1,1),DATE(2016,1,1),0.08,0.09,2,1)", 5.73566981)
        check("=ACCRINT(DATE(2008,3,1),DATE(2008,8,31),DATE(2008,5,1),0.1,1000,2,0)", 16.66666667)
        check("=ACCRINTM(DATE(2008,4,1),DATE(2008,6,15),0.1,1000,3)", 20.54794521)
        check("=DISC(DATE(2018,7,1),DATE(2048,1,1),97.975,100,1)", 0.0006863841691213449, 1e-5)
        check("=INTRATE(DATE(2008,2,15),DATE(2008,5,15),1000000,1014420,2)", 0.05768)
        check("=RECEIVED(DATE(2008,2,15),DATE(2008,5,15),1000000,0.0575,2)", 1014584.654)
        check("=PRICEDISC(DATE(2008,2,16),DATE(2008,3,1),0.0525,100,2)", 99.79583333)
        check("=PRICEMAT(DATE(2008,2,15),DATE(2008,4,13),DATE(2007,11,11),0.061,0.061,0)", 99.98449888)
        check("=YIELDDISC(DATE(2008,2,16),DATE(2008,3,1),99.795,100,2)", 0.052822572)
        check("=YIELDMAT(DATE(2008,3,15),DATE(2008,11,3),DATE(2007,11,8),0.0625,100.0123,0)", 0.060954334)
        check("=TBILLEQ(DATE(2008,3,31),DATE(2008,6,1),0.0914)", 0.094151494)
        check("=TBILLPRICE(DATE(2008,3,31),DATE(2008,6,1),0.09)", 98.45)
        check("=TBILLYIELD(DATE(2008,3,31),DATE(2008,6,1),98.45)", 0.091417)
    }

    @Test("Odd first and last periods")
    func oddPeriods() {
        check("=ODDLPRICE(DATE(2008,2,7),DATE(2008,6,15),DATE(2007,10,15),0.0375,0.0405,100,2,0)", 99.87828601)
        check("=ODDLYIELD(DATE(2008,4,20),DATE(2008,6,15),DATE(2007,12,24),0.0375,99.875,100,2,0)", 0.045192, 1e-5)
        check("=ODDFPRICE(DATE(2008,11,11),DATE(2021,3,1),DATE(2008,10,15),DATE(2009,3,1),0.0785,0.0625,100,2,1)",
              113.5977, 1e-5)
        check("=ODDFYIELD(DATE(2008,11,11),DATE(2021,3,1),DATE(2008,10,15),DATE(2009,3,1),0.0575,84.5,100,2,0)",
              0.0772, 0.00005)
    }
}

@Suite("Engineering")
struct EngineeringFunctionTests {
    private func check(_ formula: String, _ expected: Double, _ tolerance: Double = 1e-7) {
        let value = evaluate(formula)
        #expect(close(value, expected, tolerance: tolerance), "\(formula) gave \(value)")
    }

    @Test("Number bases, two's complement included")
    func bases() {
        #expect(evaluate("=BIN2DEC(1100100)") == .number(100))
        #expect(evaluate("=BIN2DEC(\"1111111111\")") == .number(-1))
        #expect(evaluate("=BIN2HEX(11111011,4)") == .text("00FB"))
        #expect(evaluate("=BIN2HEX(\"1110000000\")") == .text("FFFFFFFF80"))
        #expect(evaluate("=DEC2BIN(9,4)") == .text("1001"))
        #expect(evaluate("=DEC2BIN(-100)") == .text("1110011100"))
        #expect(evaluate("=DEC2BIN(512)") == .error(.numberError))
        #expect(evaluate("=DEC2HEX(100,4)") == .text("0064"))
        #expect(evaluate("=DEC2HEX(-54)") == .text("FFFFFFFFCA"))
        #expect(evaluate("=DEC2OCT(58,3)") == .text("072"))
        #expect(evaluate("=HEX2DEC(\"A5\")") == .number(165))
        #expect(evaluate("=HEX2DEC(\"FFFFFFFF5B\")") == .number(-165))
        #expect(evaluate("=HEX2BIN(\"F\",8)") == .text("00001111"))
        #expect(evaluate("=OCT2DEC(54)") == .number(44))
        #expect(evaluate("=OCT2HEX(\"7777777533\")") == .text("FFFFFFFF5B"))
        #expect(evaluate("=DEC2BIN(9,2)") == .error(.numberError))
    }

    @Test("Bitwise operations, DELTA and GESTEP")
    func bitwise() {
        #expect(evaluate("=BITAND(13,25)") == .number(9))
        #expect(evaluate("=BITOR(23,10)") == .number(31))
        #expect(evaluate("=BITXOR(5,3)") == .number(6))
        #expect(evaluate("=BITLSHIFT(4,2)") == .number(16))
        #expect(evaluate("=BITRSHIFT(13,2)") == .number(3))
        #expect(evaluate("=BITLSHIFT(4,-2)") == .number(1))
        #expect(evaluate("=BITAND(-1,1)") == .error(.numberError))
        #expect(evaluate("=DELTA(5,4)") == .number(0))
        #expect(evaluate("=GESTEP(5,4)") == .number(1))
    }

    @Test("Complex numbers")
    func complex() {
        #expect(evaluate("=COMPLEX(3,4)") == .text("3+4i"))
        #expect(evaluate("=COMPLEX(3,4,\"j\")") == .text("3+4j"))
        #expect(evaluate("=COMPLEX(0,1)") == .text("i"))
        #expect(evaluate("=COMPLEX(0,-1)") == .text("-i"))
        #expect(evaluate("=IMABS(\"5+12i\")") == .number(13))
        #expect(evaluate("=IMREAL(\"6-9i\")") == .number(6))
        #expect(evaluate("=IMAGINARY(\"3+4i\")") == .number(4))
        #expect(evaluate("=IMAGINARY(\"-j\")") == .number(-1))
        check("=IMARGUMENT(\"3+4i\")", 0.92729522)
        #expect(evaluate("=IMCONJUGATE(\"3+4i\")") == .text("3-4i"))
        #expect(evaluate("=IMSUM(\"3+4i\",\"5-3i\")") == .text("8+i"))
        #expect(evaluate("=IMSUB(\"13+4i\",\"5+3i\")") == .text("8+i"))
        #expect(evaluate("=IMPRODUCT(\"3+4i\",\"5-3i\")") == .text("27+11i"))
        #expect(evaluate("=IMDIV(\"-238+240i\",\"10+24i\")") == .text("5+12i"))
        // Excel's own answer carries the same binary dust.
        #expect(evaluate("=IMPOWER(\"2+3i\",3)") == .text("-46+9.00000000000001i"))
        #expect(evaluate("=IMSQRT(\"1+i\")") == .text("1.09868411346781+0.455089860562227i"))
        #expect(evaluate("=IMSUM(\"1+i\",\"1+j\")") == .error(.valueError))
        #expect(evaluate("=IMEXP(\"1+i\")") == .text("1.46869393991589+2.28735528717884i"))
        #expect(evaluate("=IMLN(\"3+4i\")") == .text("1.6094379124341+0.927295218001612i"))
        #expect(evaluate("=IMSIN(\"4+3i\")") == .text("-7.61923172032141-6.548120040911i"))
    }

    @Test("Unit conversion")
    func units() {
        check("=CONVERT(1,\"lbm\",\"kg\")", 0.45359237)
        check("=CONVERT(68,\"F\",\"C\")", 20)
        #expect(evaluate("=CONVERT(2.5,\"ft\",\"sec\")") == .error(.notAvailable))
        check("=CONVERT(CONVERT(100,\"ft\",\"m\"),\"ft\",\"m\")", 9.290304)
        check("=CONVERT(6,\"tsp\",\"tbs\")", 2)
        check("=CONVERT(1,\"gal\",\"l\")", 3.785411784)
        check("=CONVERT(100,\"mi\",\"km\")", 160.9344)
        check("=CONVERT(1,\"km2\",\"m2\")", 1e6)
        check("=CONVERT(1,\"Mibyte\",\"byte\")", 1_048_576)
        check("=CONVERT(1,\"hr\",\"mn\")", 60)
        check("=CONVERT(0,\"C\",\"K\")", 273.15)
        #expect(evaluate("=CONVERT(1,\"xyz\",\"m\")") == .error(.notAvailable))
    }

    @Test("Bessel functions")
    func bessel() {
        check("=BESSELI(1.5,1)", 0.9816664285779075, 1e-8)
        check("=BESSELJ(1.9,2)", 0.32992572769238726, 1e-6)
        check("=BESSELK(1.5,1)", 0.277387804, 1e-6)
        check("=BESSELY(2.5,1)", 0.145918138, 1e-8)
    }
}

@Suite("Database functions")
struct DatabaseFunctionTests {
    /// Excel's documented orchard example.
    private let orchard: [String: String] = [
        "A1": "Tree", "B1": "Height", "C1": "Age", "D1": "Yield", "E1": "Profit", "F1": "Height",
        "A2": "=\"=Apple\"", "B2": ">10", "F2": "<16",
        "A3": "=\"=Pear\"",
        "A6": "Tree", "B6": "Height", "C6": "Age", "D6": "Yield", "E6": "Profit",
        "A7": "Apple", "B7": "18", "C7": "20", "D7": "14", "E7": "105",
        "A8": "Pear", "B8": "12", "C8": "12", "D8": "10", "E8": "96",
        "A9": "Cherry", "B9": "13", "C9": "14", "D9": "9", "E9": "105",
        "A10": "Apple", "B10": "14", "C10": "15", "D10": "10", "E10": "75",
        "A11": "Pear", "B11": "9", "C11": "8", "D11": "8", "E11": "76.8",
        "A12": "Apple", "B12": "8", "C12": "9", "D12": "6", "E12": "45",
    ]

    @Test("The documented orchard examples")
    func orchardExamples() {
        #expect(evaluate("=DCOUNT(A6:E12,\"Age\",A1:F2)", with: orchard) == .number(1))
        #expect(evaluate("=DCOUNTA(A6:E12,\"Profit\",A1:F2)", with: orchard) == .number(1))
        #expect(evaluate("=DMAX(A6:E12,\"Profit\",A1:A3)", with: orchard) == .number(105))
        #expect(evaluate("=DMIN(A6:E12,\"Profit\",A1:B2)", with: orchard) == .number(75))
        #expect(close(evaluate("=DSUM(A6:E12,\"Profit\",A1:A2)", with: orchard), 225))
        #expect(close(evaluate("=DSUM(A6:E12,\"Profit\",A1:F2)", with: orchard), 75))
        #expect(evaluate("=DPRODUCT(A6:E12,\"Yield\",A1:F2)", with: orchard) == .number(10))
        #expect(close(evaluate("=DAVERAGE(A6:E12,\"Yield\",A1:B2)", with: orchard), 12))
        #expect(close(evaluate("=DAVERAGE(A6:E12,3,A6:E12)", with: orchard), 13))
        #expect(close(evaluate("=DSTDEV(A6:E12,\"Yield\",A1:A3)", with: orchard), 2.96647939, tolerance: 1e-8))
        #expect(close(evaluate("=DSTDEVP(A6:E12,\"Yield\",A1:A3)", with: orchard), 2.65329983, tolerance: 1e-8))
        #expect(close(evaluate("=DVAR(A6:E12,\"Yield\",A1:A3)", with: orchard), 8.8))
        #expect(close(evaluate("=DVARP(A6:E12,\"Yield\",A1:A3)", with: orchard), 7.04))
        #expect(evaluate("=DGET(A6:E12,\"Yield\",A1:A3)", with: orchard) == .error(.numberError))
    }

    @Test("A bare word matches the start of a value")
    func prefixMatching() {
        let data: [String: String] = ["A1": "Name", "A2": "Apples", "A3": "Applesauce", "A4": "Pear",
                                      "B1": "Name", "B2": "Apple"]
        #expect(evaluate("=DCOUNTA(A1:A4,1,B1:B2)", with: data) == .number(2))
        #expect(evaluate("=DGET(A1:A4,\"Name\",B1:B2)", with: data) == .error(.numberError))
    }
}

@Suite("GROUPBY and PIVOTBY")
struct GroupingTests {
    private let sales: [String: String] = [
        "A1": "Region", "B1": "Product", "C1": "Sales",
        "A2": "East", "B2": "Pen", "C2": "10",
        "A3": "West", "B3": "Pen", "C3": "20",
        "A4": "East", "B4": "Ink", "C4": "5",
        "A5": "East", "B5": "Pen", "C5": "7",
        "A6": "West", "B6": "Ink", "C6": "3",
    ]

    @Test("GROUPBY totals values by key, with headers and a grand total")
    func groupBy() {
        let sheet = evaluateSheet(sales.merging(["E1": "=GROUPBY(A1:A6,C1:C6,SUM)"]) { $1 })
        #expect(sheet("E1") == .text("Region"))
        #expect(sheet("F1") == .text("Sales"))
        #expect(sheet("E2") == .text("East"))
        #expect(sheet("F2") == .number(22))
        #expect(sheet("E3") == .text("West"))
        #expect(sheet("F3") == .number(23))
        #expect(sheet("E4") == .text("Total"))
        #expect(sheet("F4") == .number(45))
    }

    @Test("GROUPBY takes LAMBDAs, sort orders, filters and no totals")
    func options() {
        let sheet = evaluateSheet(sales.merging([
            "E1": "=GROUPBY(A2:A6,C2:C6,LAMBDA(v,MAX(v)),0,0,-2)",
            "H1": "=GROUPBY(B2:B6,C2:C6,COUNT,0,0,,A2:A6=\"East\")",
        ]) { $1 })
        #expect(sheet("E1") == .text("West"))
        #expect(sheet("F1") == .number(20))
        #expect(sheet("E2") == .text("East"))
        #expect(sheet("E3") == .empty)
        #expect(sheet("H1") == .text("Ink"))
        #expect(sheet("I1") == .number(1))
        #expect(sheet("I2") == .number(2))
    }

    @Test("PIVOTBY crosses row keys with column keys")
    func pivotBy() {
        let sheet = evaluateSheet(sales.merging(["E1": "=PIVOTBY(A2:A6,B2:B6,C2:C6,SUM)"]) { $1 })
        #expect(sheet("F1") == .text("Ink"))
        #expect(sheet("G1") == .text("Pen"))
        #expect(sheet("H1") == .text("Total"))
        #expect(sheet("E2") == .text("East"))
        #expect(sheet("F2") == .number(5))
        #expect(sheet("G2") == .number(17))
        #expect(sheet("H2") == .number(22))
        #expect(sheet("F3") == .number(3))
        #expect(sheet("E4") == .text("Total"))
        #expect(sheet("H4") == .number(45))
    }

    @Test("A function named without a call is stored with _xleta.")
    func etaInFiles() {
        #expect(FormulaDialect.toFile("GROUPBY(A1:A3,B1:B3,SUM)") == "_xlfn.GROUPBY(A1:A3,B1:B3,_xleta.SUM)")
        #expect(FormulaDialect.fromFile("_xlfn.GROUPBY(A1:A3,B1:B3,_xleta.SUM)") == "GROUPBY(A1:A3,B1:B3,SUM)")
        #expect(evaluate("=SUM(MAP({-1,2},ABS))") == .number(3))
        #expect(evaluate("=ENCODEURL(\"a b&c\")") == .text("a%20b%26c"))
    }
}

@Suite("Exponential smoothing forecasts")
struct ForecastTests {
    /// Twelve quarters of a rising series with a repeating four-quarter pattern.
    private var seasonal: [String: String] {
        var cells: [String: String] = [:]
        let pattern = [5.0, -2, 3, -6]
        for index in 0..<12 {
            cells["A\(index + 1)"] = String(index + 1)
            cells["B\(index + 1)"] = String(100 + 2 * Double(index) + pattern[index % 4])
        }
        return cells
    }

    @Test("A clean seasonal series is found and continued")
    func seasonalSeries() {
        #expect(evaluate("=FORECAST.ETS.SEASONALITY(B1:B12,A1:A12)", with: seasonal) == .number(4))
        // Quarter 13 continues the trend (100 + 24) with the first quarter's lift (+5).
        #expect(close(evaluate("=FORECAST.ETS(13,B1:B12,A1:A12)", with: seasonal), 129, tolerance: 0.02))
        #expect(close(evaluate("=FORECAST.ETS(14,B1:B12,A1:A12)", with: seasonal), 124, tolerance: 0.02))
        #expect(evaluate("=FORECAST.ETS.STAT(B1:B12,A1:A12,8)", with: seasonal) == .number(1))
        // A noisy series must have a finite, positive interval; detailed
        // confidence and scale contracts live in FormulaContractTests.
        if case .number(let width) = evaluate("=FORECAST.ETS.CONFINT(13,B1:B12,A1:A12)", with: seasonal) {
            #expect(width.isFinite && width > 0)
        } else {
            Issue.record("No confidence interval")
        }
    }

    @Test("Bad timelines and targets are refused")
    func errors() {
        #expect(evaluate("=FORECAST.ETS(5,{1,2,3},{1,2,2.7})") == .error(.numberError))
        #expect(evaluate("=FORECAST.ETS(0,B1:B12,A1:A12)", with: seasonal) == .error(.numberError))
    }
}

@Suite("Structured references")
struct StructuredReferenceTests {
    private func salesWorkbook(_ extra: [String: String] = [:]) -> Workbook {
        var sheet = Worksheet(name: "Sheet1")
        let entries: [String: String] = [
            "A1": "Item", "B1": "Price", "C1": "Qty", "D1": "Total",
            "A2": "Pen", "B2": "2", "C2": "10", "D2": "=[@Price]*[@Qty]",
            "A3": "Ink", "B3": "5", "C3": "3", "D3": "=[@Price]*[@Qty]",
            "A4": "Pad", "B4": "4", "C4": "1", "D4": "=Sales[[#This Row],[Price]]*Sales[[#This Row],[Qty]]",
        ].merging(extra) { $1 }
        for (reference, input) in entries {
            let address = CellAddress(a1: reference)!
            sheet.rowCount = max(sheet.rowCount, address.row + 1)
            sheet.columnCount = max(sheet.columnCount, address.column + 1)
            sheet[address] = CellInputParser.cell(from: input, inheriting: .default)
        }
        var workbook = Workbook(sheets: [sheet])
        workbook.tables = [TableDefinition(
            name: "Sales", sheetID: sheet.id,
            range: CellRange(start: CellAddress(a1: "A1")!, end: CellAddress(a1: "D4")!),
            headerRowCount: 1, totalsRowCount: 0, columns: ["Item", "Price", "Qty", "Total"])]
        workbook.recalculate()
        return workbook
    }

    private func value(_ workbook: Workbook, _ reference: String) -> CellValue {
        workbook.sheets[0][CellAddress(a1: reference)!].value
    }

    @Test("Columns, this row, headers and spans resolve to the table's cells")
    func resolution() {
        let workbook = salesWorkbook([
            "F1": "=SUM(Sales[Total])", "F2": "=ROWS(Sales)", "F3": "=Sales[[#Headers],[Qty]]",
            "F4": "=SUM(Sales[[Price]:[Qty]])", "F5": "=COUNTA(Sales[#All])", "F6": "=Sales[Missing]",
            "F7": "=SUMIFS(Sales[Total],Sales[Item],\"P*\")",
        ])
        #expect(value(workbook, "D2") == .number(20))
        #expect(value(workbook, "D3") == .number(15))
        #expect(value(workbook, "D4") == .number(4))
        #expect(value(workbook, "F1") == .number(39))
        #expect(value(workbook, "F2") == .number(3))
        #expect(value(workbook, "F3") == .text("Qty"))
        #expect(value(workbook, "F4") == .number(25))
        #expect(value(workbook, "F5") == .number(16))
        #expect(value(workbook, "F6") == .error(.referenceError))
        #expect(value(workbook, "F7") == .number(24))
    }

    @Test("Column names in brackets are not shifted as cell references")
    func shifting() {
        #expect(FormulaReferenceShifter.rewrite("SUM(T[Q1])+A1", operation: .insert(index: 0, count: 1), axis: .row)
                == "SUM(T[Q1])+A2")
        #expect(FormulaReferenceShifter.rewrite("T[[#This Row],[Q1]]", operation: .insert(index: 0, count: 1), axis: .row)
                == "T[[#This Row],[Q1]]")
    }

    @Test("@ references are written out in full for the file")
    func fileForm() {
        #expect(FormulaDialect.toFile("[@Price]*[@Qty]", tableName: "Sales")
                == "Sales[[#This Row],[Price]]*Sales[[#This Row],[Qty]]")
        #expect(FormulaDialect.toFile("Sales[@[Unit Price]]") == "Sales[[#This Row],[Unit Price]]")
        #expect(FormulaDialect.toFile("SUM(Sales[Total])") == "SUM(Sales[Total])")
        #expect(FormulaDialect.toFile("SUM([Total])", tableName: "Sales") == "SUM(Sales[Total])")
        #expect(FormulaDialect.legacyToDynamic("Sales[Price]*2") == "@Sales[Price]*2")
    }

    @Test("A formula Tables cannot read keeps the result it was saved with")
    func unreadable() {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .number(5), formula: "[1]Prices!B2")
        sheet[CellAddress(a1: "A2")!] = Cell(formula: "A1*2")
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        #expect(workbook.sheets[0][CellAddress(a1: "A1")!].value == .number(5))
        #expect(workbook.sheets[0][CellAddress(a1: "A2")!].value == .number(10))
    }
}

@Suite("Excel's own forecasts")
struct KeptForecastTests {
    private func workbook(savedValue: Double) -> Workbook {
        var sheet = Worksheet(name: "Sheet1")
        let pattern = [5.0, -2, 3, -6]
        for index in 0..<12 {
            sheet[CellAddress(row: index, column: 0)] = Cell(value: .number(Double(index + 1)))
            sheet[CellAddress(row: index, column: 1)] = Cell(value: .number(100 + 2 * Double(index) + pattern[index % 4]))
        }
        sheet[CellAddress(a1: "D1")!] = Cell(value: .number(savedValue), formula: "FORECAST.ETS(13,B1:B12,A1:A12)")
        return Workbook(sheets: [sheet])
    }

    @Test("A file's forecast stands until the data under it changes")
    func keepsUntilInputsChange() throws {
        let data = try XLSXWriter.data(from: workbook(savedValue: 128.75))
        var opened = try XLSXReader.workbook(from: data)
        let d1 = CellAddress(a1: "D1")!
        #expect(opened.sheets[0][d1].value == .number(128.75))
        #expect(opened.sheets[0][d1].savedResultInputs != nil)

        // Unrelated edits leave it alone.
        opened.sheets[0][CellAddress(a1: "F1")!] = Cell(value: .number(1))
        opened.recalculate()
        #expect(opened.sheets[0][d1].value == .number(128.75))

        // Changing a value it reads hands it to Tables' own calculation.
        opened.sheets[0][CellAddress(a1: "B12")!] = Cell(value: .number(500))
        opened.recalculate()
        #expect(opened.sheets[0][d1].value != .number(128.75))
        #expect(opened.sheets[0][d1].savedResultInputs == nil)
    }

    @Test("A forecast typed in Tables is always calculated")
    func typedIsCalculated() {
        var book = workbook(savedValue: 0)
        book.sheets[0][CellAddress(a1: "D1")!] = CellInputParser.cell(
            from: "=FORECAST.ETS(13,B1:B12,A1:A12)", inheriting: .default)
        book.recalculate()
        #expect(close(book.sheets[0][CellAddress(a1: "D1")!].value, 129, tolerance: 0.02))
    }
}
