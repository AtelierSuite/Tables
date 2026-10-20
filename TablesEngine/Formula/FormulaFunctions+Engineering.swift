import Foundation

extension FormulaFunctions {
    public static let engineeringFunctions: [String: FunctionSpec] = makeEngineeringFunctions()

    private static func makeEngineeringFunctions() -> [String: FunctionSpec] {
        var table: [String: FunctionSpec] = [
            "DELTA": FunctionSpec(1...2) { call throws(CellError) in
                .number(try call.number(0) == call.number(1, default: 0) ? 1 : 0)
            },
            "GESTEP": FunctionSpec(1...2) { call throws(CellError) in
                .number(try call.number(0) >= call.number(1, default: 0) ? 1 : 0)
            },
            "BITAND": FunctionSpec(2...2) { call throws(CellError) in
                .number(Double(try FormulaEngineering.bits(call, 0) & FormulaEngineering.bits(call, 1)))
            },
            "BITOR": FunctionSpec(2...2) { call throws(CellError) in
                .number(Double(try FormulaEngineering.bits(call, 0) | FormulaEngineering.bits(call, 1)))
            },
            "BITXOR": FunctionSpec(2...2) { call throws(CellError) in
                .number(Double(try FormulaEngineering.bits(call, 0) ^ FormulaEngineering.bits(call, 1)))
            },
            "BITLSHIFT": FunctionSpec(2...2) { call throws(CellError) in
                try FormulaEngineering.shift(call, left: true)
            },
            "BITRSHIFT": FunctionSpec(2...2) { call throws(CellError) in
                try FormulaEngineering.shift(call, left: false)
            },
            "BESSELJ": FunctionSpec(2...2) { call throws(CellError) in
                let x = try call.number(0)
                let n = try call.number(1).rounded(.towardZero)
                guard n >= 0, n < 1000 else { throw .numberError }
                return .number(jn(Int32(n), x))
            },
            "BESSELY": FunctionSpec(2...2) { call throws(CellError) in
                let x = try call.number(0)
                let n = try call.number(1).rounded(.towardZero)
                guard x > 0, n >= 0, n < 1000 else { throw .numberError }
                return .number(yn(Int32(n), x))
            },
            "BESSELI": FunctionSpec(2...2) { call throws(CellError) in
                let x = try call.number(0)
                let n = try call.number(1).rounded(.towardZero)
                guard n >= 0, n < 1000 else { throw .numberError }
                return .number(FormulaEngineering.besselI(x, Int(n)))
            },
            "BESSELK": FunctionSpec(2...2) { call throws(CellError) in
                let x = try call.number(0)
                let n = try call.number(1).rounded(.towardZero)
                guard x > 0, n >= 0, n < 1000 else { throw .numberError }
                return .number(FormulaEngineering.besselK(x, Int(n)))
            },
            "CONVERT": FunctionSpec(3...3) { call throws(CellError) in
                .number(try FormulaUnits.convert(try call.number(0), from: try call.text(1), to: try call.text(2)))
            },
            "COMPLEX": FunctionSpec(2...3) { call throws(CellError) in
                let suffix = try call.text(2, default: "i")
                guard suffix == "i" || suffix == "j" || suffix.isEmpty else { throw .valueError }
                let value = FormulaComplex(real: try call.number(0), imaginary: try call.number(1))
                return .text(value.text(suffix: suffix.isEmpty ? "i" : suffix))
            },
        ]

        // Conversions between binary, octal, decimal and hexadecimal.
        let bases: [(name: String, radix: Int)] = [("BIN", 2), ("OCT", 8), ("DEC", 10), ("HEX", 16)]
        for source in bases {
            for target in bases where target.radix != source.radix {
                let name = "\(source.name)2\(target.name)"
                let from = source.radix
                let to = target.radix
                table[name] = FunctionSpec(1...(to == 10 ? 1 : 2)) { call throws(CellError) in
                    let value = try FormulaEngineering.parse(call, 0, radix: from)
                    if to == 10 { return .number(Double(value)) }
                    let places = call.isMissing(1) ? nil : try call.integer(1)
                    return .text(try FormulaEngineering.format(value, radix: to, places: places))
                }
            }
        }

        // Complex arithmetic.
        let unaryComplex: [(String, @Sendable (FormulaComplex) throws(CellError) -> FormulaComplex)] = [
            ("IMCONJUGATE", { FormulaComplex(real: $0.real, imaginary: -$0.imaginary) }),
            ("IMEXP", { $0.exp }),
            ("IMLN", { value throws(CellError) in try value.log }),
            ("IMLOG10", { value throws(CellError) in try value.log.scaled(1 / Foundation.log(10)) }),
            ("IMLOG2", { value throws(CellError) in try value.log.scaled(1 / Foundation.log(2)) }),
            ("IMSQRT", { $0.power(0.5) }),
            ("IMSIN", { $0.sin }),
            ("IMCOS", { $0.cos }),
            ("IMTAN", { value throws(CellError) in try value.sin.divided(by: value.cos) }),
            ("IMSINH", { $0.sinh }),
            ("IMCOSH", { $0.cosh }),
            ("IMSEC", { value throws(CellError) in try FormulaComplex.one.divided(by: value.cos) }),
            ("IMCSC", { value throws(CellError) in try FormulaComplex.one.divided(by: value.sin) }),
            ("IMCOT", { value throws(CellError) in try value.cos.divided(by: value.sin) }),
            ("IMSECH", { value throws(CellError) in try FormulaComplex.one.divided(by: value.cosh) }),
            ("IMCSCH", { value throws(CellError) in try FormulaComplex.one.divided(by: value.sinh) }),
        ]
        for (name, operation) in unaryComplex {
            table[name] = FunctionSpec(1...1) { call throws(CellError) in
                let (value, suffix) = try FormulaComplex.argument(call, 0)
                return .text(try operation(value).text(suffix: suffix))
            }
        }
        table["IMABS"] = FunctionSpec(1...1) { call throws(CellError) in
            .number(try FormulaComplex.argument(call, 0).0.magnitude)
        }
        table["IMREAL"] = FunctionSpec(1...1) { call throws(CellError) in
            .number(try FormulaComplex.argument(call, 0).0.real)
        }
        table["IMAGINARY"] = FunctionSpec(1...1) { call throws(CellError) in
            .number(try FormulaComplex.argument(call, 0).0.imaginary)
        }
        table["IMARGUMENT"] = FunctionSpec(1...1) { call throws(CellError) in
            let value = try FormulaComplex.argument(call, 0).0
            guard value.real != 0 || value.imaginary != 0 else { throw .divideByZero }
            return .number(atan2(value.imaginary, value.real))
        }
        table["IMPOWER"] = FunctionSpec(2...2) { call throws(CellError) in
            let (value, suffix) = try FormulaComplex.argument(call, 0)
            let exponent = try call.number(1)
            if value.real == 0, value.imaginary == 0, exponent <= 0 { throw .numberError }
            return .text(value.power(exponent).text(suffix: suffix))
        }
        table["IMDIV"] = FunctionSpec(2...2) { call throws(CellError) in
            let (numerator, suffix) = try FormulaComplex.argument(call, 0)
            let (denominator, other) = try FormulaComplex.argument(call, 1)
            let combined = try FormulaComplex.combinedSuffix([suffix, other])
            return .text(try numerator.divided(by: denominator).text(suffix: combined))
        }
        table["IMSUB"] = FunctionSpec(2...2) { call throws(CellError) in
            let (a, suffix) = try FormulaComplex.argument(call, 0)
            let (b, other) = try FormulaComplex.argument(call, 1)
            let combined = try FormulaComplex.combinedSuffix([suffix, other])
            return .text(FormulaComplex(real: a.real - b.real, imaginary: a.imaginary - b.imaginary).text(suffix: combined))
        }
        table["IMSUM"] = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            let (values, suffix) = try FormulaComplex.arguments(call)
            let total = values.reduce(FormulaComplex(real: 0, imaginary: 0)) {
                FormulaComplex(real: $0.real + $1.real, imaginary: $0.imaginary + $1.imaginary)
            }
            return .text(total.text(suffix: suffix))
        }
        table["IMPRODUCT"] = FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            let (values, suffix) = try FormulaComplex.arguments(call)
            return .text(values.reduce(FormulaComplex.one) { $0.times($1) }.text(suffix: suffix))
        }
        return table
    }
}

/// Base conversion, bitwise operations and Bessel functions.
public enum FormulaEngineering {
    /// Digits each base allows; negative numbers are their ten-digit two's complement.
    private static func bitCount(_ radix: Int) -> Int {
        switch radix {
        case 2: return 10
        case 8: return 30
        default: return 40
        }
    }

    /// A number written in `radix`, from text or a number typed as its digits.
    public static func parse(_ call: FunctionCall, _ index: Int, radix: Int) throws(CellError) -> Int {
        let raw: String
        switch call.scalar(index) {
        case .number(let number):
            if radix == 10 {
                guard abs(number) < 549_755_813_888 else { throw .numberError }
                return Int(number.rounded(.towardZero))
            }
            guard number >= 0, number == number.rounded() else { throw .numberError }
            raw = String(format: "%.0f", number)
        case .text(let text): raw = text.trimmingCharacters(in: .whitespaces)
        case .empty: raw = "0"
        case .boolean: throw .valueError
        case .error(let error): throw error
        }
        if radix == 10 {
            guard let value = Double(raw) else { throw .valueError }
            let whole = value.rounded(.towardZero)
            guard abs(whole) < 549_755_813_888 else { throw .numberError }
            return Int(whole)
        }
        guard raw.count <= 10 else { throw .numberError }
        if raw.isEmpty { return 0 }
        guard let unsigned = Int(raw, radix: radix) else { throw .numberError }
        let bits = bitCount(radix)
        // Ten digits with the top bit set read as a negative number.
        if raw.count == 10, unsigned >= 1 << (bits - 1) { return unsigned - (1 << bits) }
        return unsigned
    }

    /// A number written in `radix`, zero-padded to `places` when given.
    public static func format(_ value: Int, radix: Int, places: Int?) throws(CellError) -> String {
        let bits = bitCount(radix)
        let limit = 1 << (bits - 1)
        guard value >= -limit, value < limit else { throw .numberError }
        if value < 0 {
            // Negative numbers ignore `places` and come out as ten digits.
            return String(value + (1 << bits), radix: radix).uppercased()
        }
        let digits = String(value, radix: radix).uppercased()
        guard let places else { return digits }
        guard places >= digits.count, places <= 10 else { throw .numberError }
        return String(repeating: "0", count: places - digits.count) + digits
    }

    /// A bitwise operand: a whole number from 0 to 2⁴⁸ − 1.
    public static func bits(_ call: FunctionCall, _ index: Int) throws(CellError) -> Int {
        let value = try call.number(index)
        guard value >= 0, value < 281_474_976_710_656, value == value.rounded() else { throw .numberError }
        return Int(value)
    }

    public static func shift(_ call: FunctionCall, left: Bool) throws(CellError) -> FormulaValue {
        let value = try bits(call, 0)
        let amount = try call.number(1).rounded(.towardZero)
        guard abs(amount) <= 53 else { throw .numberError }
        let leftward = left ? Int(amount) : -Int(amount)
        let result = leftward >= 0 ? Double(value) * pow(2, Double(leftward)) : Double(value >> -leftward)
        guard result < 281_474_976_710_656 else { throw .numberError }
        return .number(result)
    }

    /// The modified Bessel function Iₙ by its power series.
    public static func besselI(_ x: Double, _ n: Int) -> Double {
        let half = x / 2
        var term = pow(half, Double(n)) / exp(lgamma(Double(n) + 1))
        var sum = term
        var k = 1.0
        while k < 1000 {
            term *= half * half / (k * (k + Double(n)))
            sum += term
            if abs(term) < abs(sum) * 1e-16 { break }
            k += 1
        }
        return sum
    }

    private static func besselI0(_ x: Double) -> Double { besselI(x, 0) }
    private static func besselI1(_ x: Double) -> Double { besselI(x, 1) }

    /// The modified Bessel function Kₙ, from polynomial approximations of K₀
    /// and K₁ and the upward recurrence.
    public static func besselK(_ x: Double, _ n: Int) -> Double {
        let k0: Double
        let k1: Double
        if x <= 2 {
            let y = x * x / 4
            k0 = -Foundation.log(x / 2) * besselI0(x) + (-0.57721566 + y * (0.42278420 + y * (0.23069756
                + y * (0.3488590e-1 + y * (0.262698e-2 + y * (0.10750e-3 + y * 0.74e-5))))))
            k1 = Foundation.log(x / 2) * besselI1(x) + (1 / x) * (1 + y * (0.15443144 + y * (-0.67278579
                + y * (-0.18156897 + y * (-0.1919402e-1 + y * (-0.110404e-2 + y * -0.4686e-4))))))
        } else {
            let y = 2 / x
            let scale = exp(-x) / x.squareRoot()
            k0 = scale * (1.25331414 + y * (-0.7832358e-1 + y * (0.2189568e-1 + y * (-0.1062446e-1
                + y * (0.587872e-2 + y * (-0.251540e-2 + y * 0.53208e-3))))))
            k1 = scale * (1.25331414 + y * (0.23498619 + y * (-0.3655620e-1 + y * (0.1504268e-1
                + y * (-0.780353e-2 + y * (0.325614e-2 + y * -0.68245e-3))))))
        }
        if n == 0 { return k0 }
        var previous = k0
        var current = k1
        for order in 1..<max(1, n) {
            let next = previous + 2 * Double(order) / x * current
            previous = current
            current = next
        }
        return current
    }
}

/// A complex number as the `IM…` functions read and write it: text such as
/// `3+4i`.
public struct FormulaComplex: Sendable {
    public var real: Double
    public var imaginary: Double

    public static let one = FormulaComplex(real: 1, imaginary: 0)

    public var magnitude: Double { hypot(real, imaginary) }

    public func times(_ other: FormulaComplex) -> FormulaComplex {
        FormulaComplex(real: real * other.real - imaginary * other.imaginary,
                       imaginary: real * other.imaginary + imaginary * other.real)
    }

    public func divided(by other: FormulaComplex) throws(CellError) -> FormulaComplex {
        let denominator = other.real * other.real + other.imaginary * other.imaginary
        guard denominator != 0 else { throw .numberError }
        return FormulaComplex(real: (real * other.real + imaginary * other.imaginary) / denominator,
                              imaginary: (imaginary * other.real - real * other.imaginary) / denominator)
    }

    public func scaled(_ factor: Double) -> FormulaComplex {
        FormulaComplex(real: real * factor, imaginary: imaginary * factor)
    }

    public var exp: FormulaComplex {
        let scale = Foundation.exp(real)
        return FormulaComplex(real: scale * Foundation.cos(imaginary), imaginary: scale * Foundation.sin(imaginary))
    }

    public var log: FormulaComplex {
        get throws(CellError) {
            guard real != 0 || imaginary != 0 else { throw .numberError }
            return FormulaComplex(real: Foundation.log(magnitude), imaginary: atan2(imaginary, real))
        }
    }

    public func power(_ exponent: Double) -> FormulaComplex {
        if real == 0, imaginary == 0 { return FormulaComplex(real: 0, imaginary: 0) }
        let radius = pow(magnitude, exponent)
        let angle = atan2(imaginary, real) * exponent
        return FormulaComplex(real: radius * Foundation.cos(angle), imaginary: radius * Foundation.sin(angle))
    }

    public var sin: FormulaComplex {
        FormulaComplex(real: Foundation.sin(real) * Foundation.cosh(imaginary),
                       imaginary: Foundation.cos(real) * Foundation.sinh(imaginary))
    }

    public var cos: FormulaComplex {
        FormulaComplex(real: Foundation.cos(real) * Foundation.cosh(imaginary),
                       imaginary: -Foundation.sin(real) * Foundation.sinh(imaginary))
    }

    public var sinh: FormulaComplex {
        FormulaComplex(real: Foundation.sinh(real) * Foundation.cos(imaginary),
                       imaginary: Foundation.cosh(real) * Foundation.sin(imaginary))
    }

    public var cosh: FormulaComplex {
        FormulaComplex(real: Foundation.cosh(real) * Foundation.cos(imaginary),
                       imaginary: Foundation.sinh(real) * Foundation.sin(imaginary))
    }

    /// Parses `a+bi`, `bi`, `a`, `i`, `-j` and the like, with the suffix used.
    public static func parse(_ raw: String) -> (FormulaComplex, String?)? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return (FormulaComplex(real: 0, imaginary: 0), nil) }
        guard let last = text.last else { return nil }
        if last != "i", last != "j" {
            guard let real = Double(text) else { return nil }
            return (FormulaComplex(real: real, imaginary: 0), nil)
        }
        let suffix = String(last)
        let body = String(text.dropLast())
        // Find where the imaginary part starts: the last sign not in an exponent.
        let characters = Array(body)
        var split = 0
        for index in stride(from: characters.count - 1, through: 0, by: -1)
        where characters[index] == "+" || characters[index] == "-" {
            if index > 0, characters[index - 1] == "e" || characters[index - 1] == "E" { continue }
            split = index
            break
        }
        let realText = String(characters[0..<split])
        var imaginaryText = String(characters[split...])
        if imaginaryText.isEmpty || imaginaryText == "+" { imaginaryText = "1" }
        if imaginaryText == "-" { imaginaryText = "-1" }
        guard let imaginary = Double(imaginaryText) else { return nil }
        let real = realText.isEmpty ? 0 : Double(realText)
        guard let real else { return nil }
        return (FormulaComplex(real: real, imaginary: imaginary), suffix)
    }

    public static func argument(_ call: FunctionCall, _ index: Int) throws(CellError) -> (FormulaComplex, String) {
        let value = call.scalar(index)
        if case .error(let error) = value { throw error }
        if case .boolean = value { throw .valueError }
        if case .number(let number) = value { return (FormulaComplex(real: number, imaginary: 0), "i") }
        guard let (parsed, suffix) = parse(try value.coercedText()) else { throw .numberError }
        return (parsed, suffix ?? "i")
    }

    /// Every complex value in the arguments, ranges expanded, and the suffix
    /// they share; mixing `i` and `j` is an error.
    public static func arguments(_ call: FunctionCall) throws(CellError) -> ([FormulaComplex], String) {
        var values: [FormulaComplex] = []
        var suffixes: [String] = []
        for cell in try call.cells() {
            switch cell {
            case .empty: continue
            case .number(let number): values.append(FormulaComplex(real: number, imaginary: 0))
            case .error(let error): throw error
            case .boolean: throw .valueError
            case .text(let text):
                guard let (parsed, suffix) = parse(text) else { throw .numberError }
                values.append(parsed)
                if let suffix { suffixes.append(suffix) }
            }
        }
        return (values, try combinedSuffix(suffixes))
    }

    public static func combinedSuffix(_ suffixes: [String]) throws(CellError) -> String {
        let distinct = Set(suffixes)
        guard distinct.count <= 1 else { throw .valueError }
        return distinct.first ?? "i"
    }

    public func text(suffix: String) -> String {
        func number(_ value: Double) -> String { FormulaNumberText.general(FormulaMath.significant(value)) }
        let realPart = abs(real) < 1e-300 ? 0 : real
        let imaginaryPart = abs(imaginary) < 1e-300 ? 0 : imaginary
        if imaginaryPart == 0 { return number(realPart) }
        let coefficient: String
        switch imaginaryPart {
        case 1: coefficient = ""
        case -1: coefficient = "-"
        default: coefficient = number(imaginaryPart)
        }
        if realPart == 0 { return coefficient + suffix }
        let sign = imaginaryPart > 0 ? "+" : ""
        return number(realPart) + sign + coefficient + suffix
    }
}

/// `CONVERT`'s units, each measured in its category's base unit.
public enum FormulaUnits {
    private struct Unit {
        var category: String
        var factor: Double
        /// Whether metric prefixes may be put in front of it.
        var prefixable = false
        /// Whether binary prefixes (`ki`, `Mi`, …) may be.
        var binary = false
        /// The power a prefix is raised to: 2 for areas, 3 for volumes.
        var power: Double = 1
    }

    private static let units: [String: Unit] = {
        var table: [String: Unit] = [:]
        func add(_ names: [String], _ category: String, _ factor: Double, prefixable: Bool = false,
                 binary: Bool = false, power: Double = 1) {
            for name in names {
                table[name] = Unit(category: category, factor: factor, prefixable: prefixable, binary: binary, power: power)
            }
        }
        // Mass, in grams.
        add(["g"], "mass", 1, prefixable: true)
        add(["sg"], "mass", 14593.902937206)
        add(["lbm"], "mass", 453.59237)
        add(["u"], "mass", 1.66053886e-24, prefixable: true)
        add(["ozm"], "mass", 28.349523125)
        add(["grain"], "mass", 0.06479891)
        add(["cwt", "shweight"], "mass", 45359.237)
        add(["uk_cwt", "lcwt", "hweight"], "mass", 50802.34544)
        add(["stone"], "mass", 6350.29318)
        add(["ton"], "mass", 907184.74)
        add(["uk_ton", "LTON", "brton"], "mass", 1016046.9088)
        // Distance, in metres.
        add(["m"], "distance", 1, prefixable: true)
        add(["mi"], "distance", 1609.344)
        add(["Nmi"], "distance", 1852)
        add(["in"], "distance", 0.0254)
        add(["ft"], "distance", 0.3048)
        add(["yd"], "distance", 0.9144)
        add(["ang"], "distance", 1e-10, prefixable: true)
        add(["ell"], "distance", 1.143)
        add(["ly"], "distance", 9.46073047258e15, prefixable: true)
        add(["parsec", "pc"], "distance", 3.08567758128155e16, prefixable: true)
        add(["Pica", "Picapt"], "distance", 0.0254 / 72)
        add(["pica"], "distance", 0.0254 / 6)
        add(["survey_mi"], "distance", 1609.34721869444)
        // Time, in seconds.
        add(["yr"], "time", 31_557_600)
        add(["day", "d"], "time", 86_400)
        add(["hr"], "time", 3600)
        add(["mn", "min"], "time", 60)
        add(["sec", "s"], "time", 1, prefixable: true)
        // Pressure, in pascals.
        add(["Pa", "p"], "pressure", 1, prefixable: true)
        add(["atm", "at"], "pressure", 101_325, prefixable: true)
        add(["mmHg"], "pressure", 133.322, prefixable: true)
        add(["psi"], "pressure", 6894.75729316836)
        add(["Torr"], "pressure", 101_325.0 / 760)
        // Force, in newtons.
        add(["N"], "force", 1, prefixable: true)
        add(["dyn", "dy"], "force", 1e-5, prefixable: true)
        add(["lbf"], "force", 4.4482216152605)
        add(["pond"], "force", 0.00980665, prefixable: true)
        // Energy, in joules.
        add(["J"], "energy", 1, prefixable: true)
        add(["e"], "energy", 1e-7, prefixable: true)
        add(["c"], "energy", 4.184, prefixable: true)
        add(["cal"], "energy", 4.1868, prefixable: true)
        add(["eV", "ev"], "energy", 1.60217653e-19, prefixable: true)
        add(["HPh", "hh"], "energy", 2_684_519.53769617)
        add(["Wh", "wh"], "energy", 3600, prefixable: true)
        add(["flb"], "energy", 1.3558179483314)
        add(["BTU", "btu"], "energy", 1055.05585262)
        // Power, in watts.
        add(["HP", "h"], "power", 745.69987158227)
        add(["PS"], "power", 735.49875)
        add(["W", "w"], "power", 1, prefixable: true)
        // Magnetism, in teslas.
        add(["T"], "magnetism", 1, prefixable: true)
        add(["ga"], "magnetism", 1e-4, prefixable: true)
        // Volume, in cubic metres.
        add(["tsp"], "volume", 4.92892159375e-6)
        add(["tspm"], "volume", 5e-6)
        add(["tbs"], "volume", 1.478676478125e-5)
        add(["oz"], "volume", 2.95735295625e-5)
        add(["cup"], "volume", 2.365882365e-4)
        add(["pt", "us_pt"], "volume", 4.73176473e-4)
        add(["uk_pt"], "volume", 5.6826125e-4)
        add(["qt"], "volume", 9.46352946e-4)
        add(["uk_qt"], "volume", 1.1365225e-3)
        add(["gal"], "volume", 3.785411784e-3)
        add(["uk_gal"], "volume", 4.54609e-3)
        add(["l", "L", "lt"], "volume", 1e-3, prefixable: true)
        add(["ang3", "ang^3"], "volume", 1e-30, prefixable: true, power: 3)
        add(["barrel"], "volume", 0.158987294928)
        add(["bushel"], "volume", 0.03523907016688)
        add(["ft3", "ft^3"], "volume", 0.028316846592)
        add(["in3", "in^3"], "volume", 1.6387064e-5)
        add(["ly3", "ly^3"], "volume", 8.46786664623715e47, prefixable: true, power: 3)
        add(["m3", "m^3"], "volume", 1, prefixable: true, power: 3)
        add(["mi3", "mi^3"], "volume", 4_168_181_825.44058)
        add(["yd3", "yd^3"], "volume", 0.764554857984)
        add(["Nmi3", "Nmi^3"], "volume", 6_352_182_208)
        add(["Picapt3", "Picapt^3", "Pica3", "Pica^3"], "volume", pow(0.0254 / 72, 3))
        add(["GRT", "regton"], "volume", 2.8316846592)
        add(["MTON"], "volume", 1.13267386368)
        // Area, in square metres.
        add(["uk_acre"], "area", 4046.8564224)
        add(["us_acre"], "area", 4046.87260987425)
        add(["ang2", "ang^2"], "area", 1e-20, prefixable: true, power: 2)
        add(["ar"], "area", 100, prefixable: true)
        add(["ft2", "ft^2"], "area", 0.09290304)
        add(["ha"], "area", 10_000)
        add(["in2", "in^2"], "area", 6.4516e-4)
        add(["ly2", "ly^2"], "area", 8.95054210748189e31, prefixable: true, power: 2)
        add(["m2", "m^2"], "area", 1, prefixable: true, power: 2)
        add(["Morgen"], "area", 2500)
        add(["mi2", "mi^2"], "area", 2_589_988.110336)
        add(["Nmi2", "Nmi^2"], "area", 3_429_904)
        add(["Picapt2", "Picapt^2", "Pica2", "Pica^2"], "area", pow(0.0254 / 72, 2))
        add(["yd2", "yd^2"], "area", 0.83612736)
        // Information, in bits.
        add(["bit"], "information", 1, prefixable: true, binary: true)
        add(["byte"], "information", 8, prefixable: true, binary: true)
        // Speed, in metres per second.
        add(["admkn"], "speed", 0.514773333333333)
        add(["kn"], "speed", 0.514444444444444)
        add(["m/h", "m/hr"], "speed", 1.0 / 3600, prefixable: true)
        add(["m/s", "m/sec"], "speed", 1, prefixable: true)
        add(["mph"], "speed", 0.44704)
        return table
    }()

    private static let prefixes: [(String, Double)] = [
        ("da", 1e1), ("Y", 1e24), ("Z", 1e21), ("E", 1e18), ("P", 1e15), ("T", 1e12), ("G", 1e9), ("M", 1e6),
        ("k", 1e3), ("h", 1e2), ("e", 1e1), ("d", 1e-1), ("c", 1e-2), ("m", 1e-3), ("u", 1e-6), ("n", 1e-9),
        ("p", 1e-12), ("f", 1e-15), ("a", 1e-18), ("z", 1e-21), ("y", 1e-24),
    ]

    private static let binaryPrefixes: [(String, Double)] = [
        ("ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824), ("Ti", 1_099_511_627_776),
        ("Pi", 1_125_899_906_842_624), ("Ei", 1_152_921_504_606_846_976),
        ("Zi", 1_180_591_620_717_411_303_424), ("Yi", 1_208_925_819_614_629_174_706_176),
    ]

    /// A unit name resolved to its category and its size in the base unit.
    private static func resolve(_ name: String) -> (category: String, factor: Double)? {
        if let unit = units[name] { return (unit.category, unit.factor) }
        for (prefix, scale) in binaryPrefixes where name.hasPrefix(prefix) {
            if let unit = units[String(name.dropFirst(prefix.count))], unit.binary {
                return (unit.category, unit.factor * scale)
            }
        }
        for (prefix, scale) in prefixes where name.hasPrefix(prefix) {
            if let unit = units[String(name.dropFirst(prefix.count))], unit.prefixable {
                return (unit.category, unit.factor * pow(scale, unit.power))
            }
        }
        return nil
    }

    /// A temperature in kelvin, and back, with its prefix scale for kelvin.
    private static func kelvin(_ value: Double, from unit: String) -> Double? {
        switch unit {
        case "C", "cel": return value + 273.15
        case "F", "fah": return (value - 32) * 5 / 9 + 273.15
        case "K", "kel": return value
        case "Rank": return value * 5 / 9
        case "Reau": return value * 5 / 4 + 273.15
        default:
            for (prefix, scale) in prefixes where unit.hasPrefix(prefix) {
                let rest = String(unit.dropFirst(prefix.count))
                if rest == "K" || rest == "kel" { return value * scale }
            }
            return nil
        }
    }

    private static func fromKelvin(_ value: Double, to unit: String) -> Double? {
        switch unit {
        case "C", "cel": return value - 273.15
        case "F", "fah": return (value - 273.15) * 9 / 5 + 32
        case "K", "kel": return value
        case "Rank": return value * 9 / 5
        case "Reau": return (value - 273.15) * 4 / 5
        default:
            for (prefix, scale) in prefixes where unit.hasPrefix(prefix) {
                let rest = String(unit.dropFirst(prefix.count))
                if rest == "K" || rest == "kel" { return value / scale }
            }
            return nil
        }
    }

    public static func convert(_ value: Double, from: String, to: String) throws(CellError) -> Double {
        if let kelvin = kelvin(value, from: from) {
            guard let result = fromKelvin(kelvin, to: to) else { throw .notAvailable }
            return result
        }
        guard let source = resolve(from), let target = resolve(to), source.category == target.category else {
            throw .notAvailable
        }
        return value * source.factor / target.factor
    }
}
