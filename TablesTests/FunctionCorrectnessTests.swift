import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

// Expected values come from Microsoft's documented examples, or are worked out
// from each function's closed form outside Tables.

@Suite("Elementary math")
struct ElementaryMathTests {
    @Test("Trigonometry and its inverses")
    func trigonometry() {
        #expect(close(evaluate("=SIN(PI()/6)"), 0.5))
        #expect(close(evaluate("=COS(1.047)"), 0.5001710745970701))
        #expect(close(evaluate("=TAN(0.785)"), 0.9992039901050427))
        #expect(close(evaluate("=ASIN(-0.5)"), -0.5235987755982988))
        #expect(close(evaluate("=ACOS(-0.5)"), 2.0943951023931957))
        #expect(evaluate("=ACOS(2)") == .error(.numberError))
        #expect(close(evaluate("=ATAN(1)"), 0.7853981633974483))
        #expect(close(evaluate("=ATAN2(-1,-1)"), -2.356194490192345))
        #expect(evaluate("=ATAN2(0,0)") == .error(.divideByZero))
        #expect(close(evaluate("=DEGREES(PI())"), 180))
        #expect(close(evaluate("=RADIANS(270)"), 4.71238898038469))
        #expect(close(evaluate("=PI()"), 3.141592653589793))
    }

    @Test("Hyperbolic functions")
    func hyperbolic() {
        #expect(close(evaluate("=COSH(4)"), 27.308232836016487))
        #expect(close(evaluate("=TANH(-2)"), -0.9640275800758169))
        #expect(close(evaluate("=ASINH(-2.5)"), -1.6472311463710958))
        #expect(close(evaluate("=ATANH(0.76159416)"), 1.0000000096297197))
        #expect(evaluate("=ATANH(1)") == .error(.numberError))
        #expect(close(evaluate("=COTH(2)"), 1.0373147207275482))
        #expect(evaluate("=COTH(0)") == .error(.divideByZero))
        #expect(close(evaluate("=CSCH(1.5)"), 0.46964244059522464))
        #expect(evaluate("=CSCH(0)") == .error(.divideByZero))
    }

    @Test("Powers, roots and logarithms")
    func powers() {
        #expect(evaluate("=POWER(5,2)") == .number(25))
        #expect(close(evaluate("=POWER(98.6,3.2)"), 2401077.2220695773))
        #expect(close(evaluate("=POWER(4,5/4)"), 5.656854249492381))
        #expect(evaluate("=SQRT(16)") == .number(4))
        #expect(evaluate("=SQRT(-16)") == .error(.numberError))
        #expect(close(evaluate("=EXP(2)"), 7.38905609893065))
        #expect(close(evaluate("=LN(86)"), 4.454347296253507))
        #expect(evaluate("=LN(0)") == .error(.numberError))
        #expect(close(evaluate("=LOG(10)"), 1))
        #expect(close(evaluate("=LOG(8,2)"), 3))
        #expect(close(evaluate("=LOG(86,2.7182818)"), 4.454347342888286))
        #expect(evaluate("=LOG(-1)") == .error(.numberError))
    }

    @Test("Signs, integer parts and rounding down")
    func rounding() {
        #expect(evaluate("=ABS(-4)") == .number(4))
        #expect(evaluate("=ABS(2)") == .number(2))
        #expect(evaluate("=SIGN(10)") == .number(1))
        #expect(evaluate("=SIGN(0)") == .number(0))
        #expect(evaluate("=SIGN(-0.00001)") == .number(-1))
        #expect(evaluate("=INT(8.9)") == .number(8))
        #expect(evaluate("=INT(-8.9)") == .number(-9))
        #expect(evaluate("=TRUNC(8.9)") == .number(8))
        #expect(evaluate("=TRUNC(-8.9)") == .number(-8))
        #expect(close(evaluate("=TRUNC(PI(),2)"), 3.14))
        #expect(close(evaluate("=ROUNDDOWN(3.14159,3)"), 3.141))
        #expect(close(evaluate("=ROUNDDOWN(-3.14159,1)"), -3.1))
        #expect(evaluate("=ROUNDDOWN(31415.92654,-2)") == .number(31400))
        #expect(evaluate("=ISO.CEILING(4.3)") == .number(5))
        #expect(evaluate("=ISO.CEILING(-4.3)") == .number(-4))
        #expect(evaluate("=ISO.CEILING(4.3,2)") == .number(6))
        #expect(evaluate("=ISO.CEILING(4.3,-2)") == .number(6))
        #expect(evaluate("=ISO.CEILING(-4.3,2)") == .number(-4))
    }

    @Test("Products")
    func products() {
        #expect(evaluate("=PRODUCT(5,15,30)") == .number(2250))
        #expect(evaluate("=PRODUCT(A1:A3,2)", with: ["A1": "5", "A2": "x", "A3": "30"]) == .number(300))
    }

    @Test("Random numbers stay within their bounds")
    func random() {
        for _ in 0..<100 {
            guard case .number(let fraction) = evaluate("=RAND()") else {
                Issue.record("RAND did not return a number")
                return
            }
            #expect(fraction >= 0 && fraction < 1)
            guard case .number(let roll) = evaluate("=RANDBETWEEN(1,6)") else {
                Issue.record("RANDBETWEEN did not return a number")
                return
            }
            #expect(roll >= 1 && roll <= 6 && roll == roll.rounded())
        }
        #expect(evaluate("=RANDBETWEEN(-3,-3)") == .number(-3))
    }
}

@Suite("Basic statistics")
struct BasicStatisticsTests {
    private let sample = ["A1": "2", "A2": "4", "A3": "4", "A4": "4", "A5": "5", "A6": "5", "A7": "7", "A8": "9"]

    @Test("Variance and standard deviation of numbers")
    func spread() {
        #expect(close(evaluate("=STDEV(A1:A8)", with: sample), 2.138089935299395))
        #expect(close(evaluate("=STDEVP(A1:A8)", with: sample), 2))
        #expect(close(evaluate("=VAR(A1:A8)", with: sample), 4.571428571428571))
        #expect(close(evaluate("=VAR.S(A1:A8)", with: sample), 4.571428571428571))
        #expect(close(evaluate("=VARP(A1:A8)", with: sample), 4))
        #expect(close(evaluate("=VAR.P(A1:A8)", with: sample), 4))
        #expect(evaluate("=STDEV(1)") == .error(.divideByZero))
        #expect(evaluate("=VAR.S(1)") == .error(.divideByZero))
    }

    @Test("The A variants count text as zero and TRUE as one")
    func textAndLogicals() {
        let mixed = ["A1": "2", "A2": "TRUE", "A3": "x", "A4": "4"]
        #expect(close(evaluate("=STDEVA(A1:A4)", with: mixed), 1.707825127659933))
        #expect(close(evaluate("=STDEVPA(A1:A4)", with: mixed), 1.479019945774904))
        #expect(close(evaluate("=VARPA(A1:A4)", with: mixed), 2.1875))
        #expect(evaluate("=MAXA(A1:A3)", with: ["A1": "-3", "A2": "TRUE", "A3": "x"]) == .number(1))
        #expect(evaluate("=MINA(A1:A3)", with: ["A1": "3", "A2": "FALSE", "A3": "x"]) == .number(0))
        #expect(evaluate("=MAX(A1:A3)", with: ["A1": "-3", "A2": "TRUE", "A3": "x"]) == .number(-3))
    }

    @Test("Middle values, ranks and percentiles")
    func order() {
        #expect(evaluate("=MEDIAN(A1:A8)", with: sample) == .number(4.5))
        #expect(evaluate("=MEDIAN(1,2,3,4,5)") == .number(3))
        #expect(evaluate("=LARGE({3,5,3,5,4},3)") == .number(4))
        #expect(evaluate("=LARGE({3,5,3,5,4},6)") == .error(.numberError))
        #expect(evaluate("=SMALL({3,4,5,2,3,4,6,4,7},4)") == .number(4))
        #expect(evaluate("=SMALL({1,2},0)") == .error(.numberError))
        #expect(close(evaluate("=PERCENTILE({1,2,3,4},0.3)"), 1.9))
        #expect(evaluate("=PERCENTILE({1,2,3,4},1.1)") == .error(.numberError))
        #expect(evaluate("=QUARTILE({1,2,4,7,8,9,10,12},1)") == .number(3.5))
        let ranked = "{13,12,11,8,4,3,2,1,1,1}"
        #expect(close(evaluate("=PERCENTRANK(\(ranked),4)"), 0.555))
        #expect(close(evaluate("=PERCENTRANK(\(ranked),8)"), 0.666))
        #expect(close(evaluate("=PERCENTRANK(\(ranked),5)"), 0.583))
    }

    @Test("Conditional averages and blank counts")
    func conditional() {
        let values = ["A1": "100000", "A2": "200000", "A3": "300000", "A4": "400000",
                      "B1": "7000", "B2": "14000", "B3": "21000", "B4": "28000"]
        #expect(evaluate("=AVERAGEIF(A1:A4,\"<250000\")", with: values) == .number(150000))
        #expect(evaluate("=AVERAGEIF(A1:A4,\">250000\",B1:B4)", with: values) == .number(24500))
        #expect(evaluate("=AVERAGEIF(A1:A4,\"<95000\")", with: values) == .error(.divideByZero))
        #expect(evaluate("=COUNTBLANK(A1:A4)", with: ["A1": "6", "A3": "=\"\"", "A4": "4"]) == .number(2))
    }

    @Test("Correlation and covariance")
    func correlation() {
        let pairs = ["A1": "9", "A2": "7", "A3": "5", "A4": "3", "A5": "1",
                     "B1": "10", "B2": "6", "B3": "1", "B4": "5", "B5": "3"]
        #expect(close(evaluate("=PEARSON(A1:A5,B1:B5)", with: pairs), 0.6993786061802354))
        #expect(close(evaluate("=COVAR({3,2,4,5,6},{9,7,12,15,17})"), 5.2))
        #expect(evaluate("=COVAR({1,2},{1,2,3})") == .error(.notAvailable))
    }
}

@Suite("Compatibility distributions")
struct CompatibilityDistributionTests {
    private func check(_ formula: String, _ expected: Double, _ tolerance: Double = 1e-7) {
        #expect(close(evaluate(formula), expected, tolerance: tolerance), "\(formula) gave \(evaluate(formula))")
    }

    @Test("Normal and lognormal")
    func normal() {
        check("=NORMDIST(42,40,1.5,TRUE)", 0.9087887802741321)
        check("=NORMDIST(42,40,1.5,FALSE)", 0.10934004978399575)
        check("=NORMINV(0.908789,40,1.5)", 42.00000200956616)
        check("=NORMSDIST(1.333333)", 0.9087887256040951)
        check("=LOGNORMDIST(4,3.5,1.2)", 0.0390835557068005)
        check("=LOGINV(0.039084,3.5,1.2)", 4.000025218680636)
        check("=CONFIDENCE(0.05,2.5,50)", 0.6929519121748386)
        check("=ERF.PRECISE(0.745)", 0.7079289200957377)
        check("=ERFC.PRECISE(1)", 0.15729920705028516)
        check("=GAMMALN.PRECISE(4)", 1.791759469228055)
    }

    @Test("Discrete distributions")
    func discrete() {
        check("=BINOMDIST(6,10,0.5,FALSE)", 0.205078125)
        check("=BINOMDIST(6,10,0.5,TRUE)", 0.828125)
        #expect(evaluate("=CRITBINOM(6,0.5,0.75)") == .number(4))
        check("=HYPGEOMDIST(1,4,8,20)", 0.3632610939112487)
        check("=NEGBINOMDIST(10,5,0.25)", 0.05504866037517786)
        check("=POISSON(2,5,TRUE)", 0.12465201948308113)
        check("=POISSON(2,5,FALSE)", 0.08422433748856833)
    }

    @Test("Continuous distributions")
    func continuous() {
        check("=BETADIST(2,8,10,1,3)", 0.6854705810546875)
        check("=BETAINV(0.685470581,8,10,1,3)", 2, 1e-6)
        check("=CHIDIST(18.307,10)", 0.05000058909139812)
        check("=CHIINV(0.050001,10)", 18.306973456961053, 1e-6)
        check("=EXPONDIST(0.2,10,TRUE)", 0.8646647167633873)
        check("=EXPONDIST(0.2,10,FALSE)", 1.353352832366127)
        check("=FDIST(15.2068649,6,4)", 0.0099999999524647)
        check("=FINV(0.01,6,4)", 15.206864861157516, 1e-6)
        check("=GAMMADIST(10.00001131,9,2,FALSE)", 0.032639130418294)
        check("=GAMMADIST(10.00001131,9,2,TRUE)", 0.06809400386978748)
        check("=GAMMAINV(0.068094,9,2)", 10.000011191437181, 1e-6)
        check("=TINV(0.05464,60)", 1.9600411871274246, 1e-6)
        check("=WEIBULL(105,20,100,TRUE)", 0.9295813900692769)
        check("=WEIBULL(105,20,100,FALSE)", 0.03558886402450434)
    }

    @Test("Hypothesis tests")
    func tests() {
        let observed = ["A1": "58", "B1": "11", "C1": "10", "A2": "35", "B2": "25", "C2": "23",
                        "A4": "45.35", "B4": "17.56", "C4": "16.09", "A5": "47.65", "B5": "18.44", "C5": "16.91"]
        #expect(close(evaluate("=CHITEST(A1:C2,A4:C5)", with: observed), 0.00030819201700830936, tolerance: 1e-7))
        #expect(close(evaluate("=FTEST({6,7,9,15,21},{20,28,31,38,40})"), 0.6483178467861745, tolerance: 1e-7))
        let a = "{3,4,5,8,9,1,2,4,5}", b = "{6,19,3,2,14,4,5,17,1}"
        #expect(close(evaluate("=TTEST(\(a),\(b),2,1)"), 0.1960157849252654, tolerance: 1e-7))
        #expect(close(evaluate("=TTEST(\(a),\(b),2,2)"), 0.1919958867604109, tolerance: 1e-7))
        #expect(close(evaluate("=TTEST(\(a),\(b),1,1)"), 0.0980078924626327, tolerance: 1e-7))
        let z = "{3,6,7,8,6,5,4,2,1,9}"
        #expect(close(evaluate("=ZTEST(\(z),4)"), 0.09057419685136381, tolerance: 1e-7))
        #expect(close(evaluate("=ZTEST(\(z),4,2)"), 0.040995160500191474, tolerance: 1e-7))
    }
}

@Suite("Engineering conversions and complex functions")
struct EngineeringCorrectnessTests {
    @Test("Octal conversions")
    func octal() {
        #expect(evaluate("=BIN2OCT(1001,3)") == .text("011"))
        #expect(evaluate("=BIN2OCT(1100100)") == .text("144"))
        #expect(evaluate("=BIN2OCT(1111111111)") == .text("7777777777"))
        #expect(evaluate("=HEX2OCT(\"F\",3)") == .text("017"))
        #expect(evaluate("=HEX2OCT(\"3B4E\")") == .text("35516"))
        #expect(evaluate("=HEX2OCT(\"FFFFFFFF00\")") == .text("7777777400"))
        #expect(evaluate("=OCT2BIN(3,3)") == .text("011"))
        #expect(evaluate("=OCT2BIN(7777777000)") == .text("1000000000"))
        #expect(evaluate("=OCT2BIN(1000)") == .error(.numberError))
    }

    @Test("Complex trigonometry, hyperbolics and logarithms")
    func complex() {
        let expected: [(String, Double, Double)] = [
            ("IMCOS(\"1+i\")", 0.8337300251311491, -0.9888977057628651),
            ("IMCOSH(\"4+3i\")", -27.034945603074224, 3.8511533348117775),
            ("IMSINH(\"4+3i\")", -27.016813258003936, 3.853738037919377),
            ("IMTAN(\"4+3i\")", 0.00490825806749606, 1.000709536067233),
            ("IMCOT(\"4+3i\")", 0.004901182394304474, -0.9992669278059017),
            ("IMCSC(\"4+3i\")", -0.0754898329158637, 0.06487747137063549),
            ("IMCSCH(\"4+3i\")", -0.03627588962862601, -0.005174473184019397),
            ("IMSEC(\"4+3i\")", -0.06529402785794704, -0.07522496030277323),
            ("IMSECH(\"4+3i\")", -0.03625349691586887, -0.00516434460775318),
            ("IMLOG10(\"3+4i\")", 0.6989700043360187, 0.4027191962733731),
            ("IMLOG2(\"3+4i\")", 2.321928094887362, 1.3378042124509761),
        ]
        for (call, real, imaginary) in expected {
            #expect(close(evaluate("=IMREAL(\(call))"), real, tolerance: 1e-12), "\(call)")
            #expect(close(evaluate("=IMAGINARY(\(call))"), imaginary, tolerance: 1e-12), "\(call)")
        }
        #expect(evaluate("=IMLOG10(\"0\")") == .error(.numberError))
    }
}

@Suite("Logical and information basics")
struct LogicalInformationTests {
    @Test("TRUE, FALSE, NOT and OR")
    func logic() {
        #expect(evaluate("=TRUE()") == .boolean(true))
        #expect(evaluate("=FALSE()") == .boolean(false))
        #expect(evaluate("=NOT(FALSE)") == .boolean(true))
        #expect(evaluate("=NOT(1+1=2)") == .boolean(false))
        #expect(evaluate("=OR(TRUE,FALSE)") == .boolean(true))
        #expect(evaluate("=OR(1+1=1,2+2=5)") == .boolean(false))
        #expect(evaluate("=OR(A1:A2)", with: ["A1": "0", "A2": "3"]) == .boolean(true))
        #expect(evaluate("=OR(\"x\")") == .error(.valueError))
    }

    @Test("IFS takes the first true condition")
    func ifs() {
        let grades = "=IFS(A1>89,\"A\",A1>79,\"B\",A1>69,\"C\",TRUE,\"F\")"
        #expect(evaluate(grades, with: ["A1": "85"]) == .text("B"))
        #expect(evaluate(grades, with: ["A1": "93"]) == .text("A"))
        #expect(evaluate(grades, with: ["A1": "12"]) == .text("F"))
        #expect(evaluate("=IFS(FALSE,1)") == .error(.notAvailable))
    }

    @Test("IS functions")
    func isFunctions() {
        #expect(evaluate("=ISBLANK(A1)") == .boolean(true))
        #expect(evaluate("=ISBLANK(A1)", with: ["A1": "=\"\""]) == .boolean(false))
        #expect(evaluate("=ISEVEN(-1)") == .boolean(false))
        #expect(evaluate("=ISEVEN(2.5)") == .boolean(true))
        #expect(evaluate("=ISEVEN(\"x\")") == .error(.valueError))
        #expect(evaluate("=ISODD(5)") == .boolean(true))
        #expect(evaluate("=ISODD(-2)") == .boolean(false))
        #expect(evaluate("=ISLOGICAL(TRUE)") == .boolean(true))
        #expect(evaluate("=ISLOGICAL(\"TRUE\")") == .boolean(false))
        #expect(evaluate("=ISNUMBER(4)") == .boolean(true))
        #expect(evaluate("=ISNUMBER(\"4\")") == .boolean(false))
        #expect(evaluate("=ISTEXT(\"x\")") == .boolean(true))
        #expect(evaluate("=ISTEXT(1)") == .boolean(false))
    }
}

@Suite("Text basics")
struct TextBasicsTests {
    @Test("Taking parts of text")
    func parts() {
        #expect(evaluate("=MID(\"Fluid Flow\",1,5)") == .text("Fluid"))
        #expect(evaluate("=MID(\"Fluid Flow\",7,20)") == .text("Flow"))
        #expect(evaluate("=MID(\"Fluid Flow\",20,5)") == .text(""))
        #expect(evaluate("=MID(\"Fluid Flow\",0,5)") == .error(.valueError))
        #expect(evaluate("=RIGHT(\"Sale Price\",5)") == .text("Price"))
        #expect(evaluate("=RIGHT(\"Stock Number\")") == .text("r"))
        #expect(evaluate("=LOWER(\"E. E. Cummings\")") == .text("e. e. cummings"))
        #expect(evaluate("=TRIM(\" First Quarter   Earnings \")") == .text("First Quarter Earnings"))
        #expect(evaluate("=REPT(\"*-\",3)") == .text("*-*-*-"))
        #expect(evaluate("=REPT(\"x\",0)") == .text(""))
    }

    @Test("Replacing and comparing text")
    func replacing() {
        #expect(evaluate("=REPLACE(\"abcdefghijk\",6,5,\"*\")") == .text("abcde*k"))
        #expect(evaluate("=REPLACE(\"2009\",3,2,\"10\")") == .text("2010"))
        #expect(evaluate("=SUBSTITUTE(\"Sales Data\",\"Sales\",\"Cost\")") == .text("Cost Data"))
        #expect(evaluate("=SUBSTITUTE(\"Quarter 1, 2008\",\"1\",\"2\",1)") == .text("Quarter 2, 2008"))
        #expect(evaluate("=SUBSTITUTE(\"Quarter 1, 2011\",\"1\",\"2\",3)") == .text("Quarter 1, 2012"))
        #expect(evaluate("=EXACT(\"word\",\"Word\")") == .boolean(false))
        #expect(evaluate("=EXACT(\"word\",\"word\")") == .boolean(true))
        #expect(evaluate("=CONCATENATE(\"Stream \",\"population\",1,TRUE)") == .text("Stream population1TRUE"))
        #expect(evaluate("=CODE(\"A\")") == .number(65))
        #expect(evaluate("=CODE(\"\")") == .error(.valueError))
    }

    @Test("Byte-counting variants match the plain ones outside double-byte locales")
    func byteVariants() {
        #expect(evaluate("=LEFTB(\"Sale Price\",4)") == .text("Sale"))
        #expect(evaluate("=RIGHTB(\"Sale Price\",5)") == .text("Price"))
        #expect(evaluate("=MIDB(\"Fluid Flow\",7,20)") == .text("Flow"))
        #expect(evaluate("=FINDB(\"m\",\"Miriam Mcgovern\",3)") == .number(6))
        #expect(evaluate("=SEARCHB(\"e\",\"Statements\",6)") == .number(7))
        #expect(evaluate("=REPLACEB(\"abcdefghijk\",6,5,\"*\")") == .text("abcde*k"))
    }

    @Test("Full-width letters, readings and dollar text")
    func conversions() {
        #expect(evaluate("=JIS(\"ABC 123\")") == .text("ＡＢＣ　１２３"))
        #expect(evaluate("=JIS(\"ｱｲｳ\")") == .text("アイウ"))
        #expect(evaluate("=PHONETIC(A1:A2)", with: ["A1": "東京", "A2": "都"]) == .error(.nameError))
        #expect(evaluate("=USDOLLAR(1234.567,2)") == .text("$1,234.57"))
        #expect(evaluate("=USDOLLAR(-0.123,4)") == .text("($0.1230)"))
        #expect(evaluate("=VALUE(\"$1,000\")") == .number(1000))
        #expect(close(evaluate("=VALUE(\"16:48:00\")-VALUE(\"12:00:00\")"), 0.2))
        #expect(evaluate("=VALUE(\"x\")") == .error(.valueError))
    }

    @Test("HYPERLINK shows its friendly name, or the address")
    func hyperlink() {
        #expect(evaluate("=HYPERLINK(\"https://example.com\",\"Example\")") == .text("Example"))
        #expect(evaluate("=HYPERLINK(\"https://example.com\")") == .text("https://example.com"))
        #expect(evaluate("=HYPERLINK(\"https://example.com\",A1)", with: ["A1": "42"]) == .number(42))
    }
}

@Suite("Times and the current date")
struct TimeCorrectnessTests {
    @Test("Building and reading times")
    func times() {
        #expect(evaluate("=TIME(12,0,0)") == .number(0.5))
        #expect(close(evaluate("=TIME(16,48,10)"), 0.7001157407407407))
        #expect(evaluate("=MINUTE(0.78125)") == .number(45))
        #expect(evaluate("=MINUTE(TIME(12,45,0))") == .number(45))
        #expect(evaluate("=SECOND(TIME(16,48,18))") == .number(18))
        #expect(evaluate("=MONTH(40648)") == .number(4))
        #expect(evaluate("=MONTH(DATE(2024,2,29))") == .number(2))
        #expect(evaluate("=MONTH(-1)") == .error(.numberError))
    }

    // TODAY/NOW are checked against independent before/after clock samples in
    // FormulaContractTests, so a midnight crossing does not make the test flaky.
}
