import Foundation

extension FormulaFunctions {
    public static let trigonometryFunctions: [String: FunctionSpec] = [
        "SINH": .unary { sinh($0) },
        "COSH": .unary { cosh($0) },
        "TANH": .unary { tanh($0) },
        "ASINH": .unary { asinh($0) },
        "ACOSH": .unary { value throws(CellError) in
            guard value >= 1 else { throw .numberError }
            return acosh(value)
        },
        "ATANH": .unary { value throws(CellError) in
            guard abs(value) < 1 else { throw .numberError }
            return atanh(value)
        },
        "ACOT": .unary { .pi / 2 - atan($0) },
        "ACOTH": .unary { value throws(CellError) in
            guard abs(value) > 1 else { throw .numberError }
            return 0.5 * log((value + 1) / (value - 1))
        },
        "COT": .unary { value throws(CellError) in
            guard abs(value) < 134_217_728 else { throw .numberError }
            guard value != 0 else { throw .divideByZero }
            return 1 / tan(value)
        },
        "COTH": .unary { value throws(CellError) in
            guard value != 0 else { throw .divideByZero }
            return 1 / tanh(value)
        },
        "CSC": .unary { value throws(CellError) in
            guard abs(value) < 134_217_728 else { throw .numberError }
            guard value != 0 else { throw .divideByZero }
            return 1 / sin(value)
        },
        "CSCH": .unary { value throws(CellError) in
            guard value != 0 else { throw .divideByZero }
            return 1 / sinh(value)
        },
        "SEC": .unary { value throws(CellError) in
            guard abs(value) < 134_217_728 else { throw .numberError }
            return 1 / cos(value)
        },
        "SECH": .unary { 1 / cosh($0) },
        "SQRTPI": .unary { value throws(CellError) in
            guard value >= 0 else { throw .numberError }
            return sqrt(value * .pi)
        },
    ]

    public static let arithmeticFunctions: [String: FunctionSpec] = [
        "CEILING.MATH": FunctionSpec(1...3) { call throws(CellError) in
            let value = try call.number(0)
            let step = abs(try call.number(1, default: 1))
            let awayFromZero = try call.number(2, default: 0) != 0
            guard step != 0 else { return .number(0) }
            let rule: FormulaMath.MultipleRule = value < 0 && awayFromZero ? .awayFromZero : .up
            return .number(FormulaMath.multiple(value, of: step, rule: rule))
        },
        "FLOOR.MATH": FunctionSpec(1...3) { call throws(CellError) in
            let value = try call.number(0)
            let step = abs(try call.number(1, default: 1))
            let towardZero = try call.number(2, default: 0) != 0
            guard step != 0 else { return .number(0) }
            let rule: FormulaMath.MultipleRule = value < 0 && towardZero ? .towardZero : .down
            return .number(FormulaMath.multiple(value, of: step, rule: rule))
        },
        "CEILING.PRECISE": FunctionSpec(1...2) { call throws(CellError) in
            let step = abs(try call.number(1, default: 1))
            return .number(step == 0 ? 0 : FormulaMath.multiple(try call.number(0), of: step, rule: .up))
        },
        "ISO.CEILING": FunctionSpec(1...2) { call throws(CellError) in
            let step = abs(try call.number(1, default: 1))
            return .number(step == 0 ? 0 : FormulaMath.multiple(try call.number(0), of: step, rule: .up))
        },
        "FLOOR.PRECISE": FunctionSpec(1...2) { call throws(CellError) in
            let step = abs(try call.number(1, default: 1))
            return .number(step == 0 ? 0 : FormulaMath.multiple(try call.number(0), of: step, rule: .down))
        },
        "MROUND": .binary { value, multiple throws(CellError) in
            if multiple == 0 { return 0 }
            guard value == 0 || (value > 0) == (multiple > 0) else { throw .numberError }
            return FormulaMath.multiple(value, of: multiple, rule: .nearest)
        },
        "EVEN": .unary { value in
            let magnitude = (FormulaMath.significant(abs(value)) / 2).rounded(.up) * 2
            return value < 0 ? -magnitude : magnitude
        },
        "ODD": .unary { value in
            var magnitude = FormulaMath.significant(abs(value)).rounded(.up)
            if magnitude.truncatingRemainder(dividingBy: 2) == 0 { magnitude += 1 }
            return value < 0 ? -magnitude : magnitude
        },
        "QUOTIENT": .binary { numerator, denominator throws(CellError) in
            guard denominator != 0 else { throw .divideByZero }
            return FormulaMath.significant(numerator / denominator).rounded(.towardZero)
        },
        "FACT": .unary { value throws(CellError) in
            let n = value.rounded(.towardZero)
            guard n >= 0, n <= 170 else { throw .numberError }
            return FormulaMath.factorial(Int(n))
        },
        "FACTDOUBLE": .unary { value throws(CellError) in
            let n = Int(value.rounded(.towardZero))
            guard n >= -1, n <= 300 else { throw .numberError }
            var result = 1.0
            var k = n
            while k > 1 {
                result *= Double(k)
                k -= 2
            }
            guard result.isFinite else { throw .numberError }
            return result
        },
        "COMBIN": .binary { n, k throws(CellError) in
            try FormulaMath.combinations(n.rounded(.towardZero), k.rounded(.towardZero))
        },
        "COMBINA": .binary { n, k throws(CellError) in
            let items = n.rounded(.towardZero)
            let chosen = k.rounded(.towardZero)
            guard items >= 0, chosen >= 0, items >= chosen || items > 0 else { throw .numberError }
            if items == 0, chosen == 0 { return 1 }
            return try FormulaMath.combinations(items + chosen - 1, chosen)
        },
        "MULTINOMIAL": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            let numbers = try call.allNumbers().map { $0.rounded(.towardZero) }
            guard numbers.allSatisfy({ $0 >= 0 }) else { throw .numberError }
            var result = 1.0
            var running = 0.0
            for number in numbers {
                running += number
                result *= try FormulaMath.combinations(running, number)
            }
            guard result.isFinite else { throw .numberError }
            return .number(result)
        },
        "GCD": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            let numbers = try FormulaMath.wholeNumbers(call.allNumbers())
            return .number(Double(numbers.reduce(0, FormulaMath.gcd)))
        },
        "LCM": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            let numbers = try FormulaMath.wholeNumbers(call.allNumbers())
            if numbers.contains(0) { return .number(0) }
            var result = 1.0
            for number in numbers {
                result = result / Double(FormulaMath.gcd(Int(result), number)) * Double(number)
                guard result < 9.007_199_254_740_992e15 else { throw .numberError }
            }
            return .number(result)
        },
        "SUMSQ": FunctionSpec(1...255, lifts: .none) { call throws(CellError) in
            .number(FormulaMath.sum(try call.allNumbers().map { $0 * $0 }))
        },
        "SUMX2MY2": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            .number(FormulaMath.sum(try FormulaMath.pairs(call).map { $0 * $0 - $1 * $1 }))
        },
        "SUMX2PY2": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            .number(FormulaMath.sum(try FormulaMath.pairs(call).map { $0 * $0 + $1 * $1 }))
        },
        "SUMXMY2": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            .number(FormulaMath.sum(try FormulaMath.pairs(call).map { ($0 - $1) * ($0 - $1) }))
        },
        "SERIESSUM": FunctionSpec(4...4, lifts: .only([0, 1, 2])) { call throws(CellError) in
            let x = try call.number(0)
            let n = try call.number(1)
            let m = try call.number(2)
            var total = 0.0
            for (index, cell) in try call.matrix(3).flatMap({ $0 }).enumerated() {
                guard case .number(let coefficient) = cell else { throw .valueError }
                total += coefficient * pow(x, n + Double(index) * m)
            }
            return .number(total)
        },
        "PERCENTOF": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            let part = FormulaMath.sum(try call.numbers([0]))
            let whole = FormulaMath.sum(try call.numbers([1]))
            guard whole != 0 else { throw .divideByZero }
            return .number(part / whole)
        },
        "ROMAN": FunctionSpec(1...2) { call throws(CellError) in
            let value = try call.number(0).rounded(.towardZero)
            let formValue = call.scalar(1)
            let form: Int
            if case .boolean(let flag) = formValue {
                form = flag ? 0 : 4
            } else {
                form = try call.integer(1, default: 0)
            }
            guard value >= 0, value < 4000, (0...4).contains(form) else { throw .valueError }
            return .text(FormulaMath.roman(Int(value), form: form))
        },
        "ARABIC": FunctionSpec(1...1) { call throws(CellError) in
            .number(Double(try FormulaMath.arabic(try call.text(0))))
        },
        "BASE": FunctionSpec(2...3) { call throws(CellError) in
            let value = try call.number(0).rounded(.towardZero)
            let radix = try call.integer(1)
            let length = try call.integer(2, default: 0)
            guard value >= 0, value < 9_007_199_254_740_992, (2...36).contains(radix), (0...255).contains(length) else {
                throw .numberError
            }
            let digits = String(Int(value), radix: radix).uppercased()
            return .text(String(repeating: "0", count: max(0, length - digits.count)) + digits)
        },
        "DECIMAL": FunctionSpec(2...2) { call throws(CellError) in
            var text = try call.text(0).trimmingCharacters(in: .whitespaces)
            let radix = try call.integer(1)
            guard (2...36).contains(radix), text.count <= 255 else { throw .numberError }
            if radix == 16, text.lowercased().hasPrefix("0x") { text.removeFirst(2) }
            var total = 0.0
            for character in text {
                guard let digit = character.hexDigitValue ?? Self.baseDigit(character), digit < radix else {
                    throw .numberError
                }
                total = total * Double(radix) + Double(digit)
            }
            return .number(total)
        },
        "RANDARRAY": FunctionSpec(0...5, lifts: .none) { call throws(CellError) in
            let rows = try call.integer(0, default: 1)
            let columns = try call.integer(1, default: 1)
            let low = try call.number(2, default: 0)
            let high = try call.number(3, default: 1)
            let whole = try call.boolean(4, default: false)
            guard rows >= 1, columns >= 1, low <= high else { throw .valueError }
            guard rows * columns <= FormulaLogic.maximumArrayCells else { throw .numberError }
            let lower = whole ? low.rounded(.up) : low
            let upper = whole ? high.rounded(.down) : high
            guard lower <= upper else { throw .valueError }
            func draw() -> CellValue {
                if whole { return .number(Double(Int.random(in: Int(lower)...Int(upper)))) }
                return .number(lower == upper ? lower : Double.random(in: lower..<upper))
            }
            return .block(FormulaArrays.grid(rows: rows, columns: columns) { _, _ in draw() })
        },
        "SEQUENCE": FunctionSpec(1...4, lifts: .none) { call throws(CellError) in
            let rows = try call.integer(0, default: 1)
            let columns = try call.integer(1, default: 1)
            let start = try call.number(2, default: 1)
            let step = try call.number(3, default: 1)
            guard rows >= 1, columns >= 1 else { throw .calc }
            guard rows * columns <= FormulaLogic.maximumArrayCells else { throw .numberError }
            return .block(FormulaArrays.grid(rows: rows, columns: columns) { row, column in
                .number(start + Double(row * columns + column) * step)
            })
        },
        "MUNIT": FunctionSpec(1...1) { call throws(CellError) in
            let size = try call.integer(0)
            guard size >= 1, size * size <= FormulaLogic.maximumArrayCells else { throw .valueError }
            return .block(FormulaArrays.grid(rows: size, columns: size) { row, column in .number(row == column ? 1 : 0) })
        },
        "MMULT": FunctionSpec(2...2, lifts: .none) { call throws(CellError) in
            let a = try FormulaMath.numericMatrix(call.matrix(0))
            let b = try FormulaMath.numericMatrix(call.matrix(1))
            guard let inner = a.first?.count, inner == b.count, let width = b.first?.count else { throw .valueError }
            func product(_ row: Int, _ column: Int) -> Double {
                var terms: [Double] = []
                for index in 0..<inner { terms.append(a[row][index] * b[index][column]) }
                return FormulaMath.sum(terms)
            }
            return .block(FormulaArrays.grid(rows: a.count, columns: width) { row, column in
                .number(product(row, column))
            })
        },
        "MDETERM": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            let matrix = try FormulaMath.numericMatrix(call.matrix(0))
            guard matrix.count == matrix.first?.count else { throw .valueError }
            return .number(FormulaMath.determinant(matrix))
        },
        "MINVERSE": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            let matrix = try FormulaMath.numericMatrix(call.matrix(0))
            guard matrix.count == matrix.first?.count else { throw .valueError }
            guard let inverse = FormulaMath.inverse(matrix) else { throw .numberError }
            return .block(inverse.map { $0.map(CellValue.number) })
        },
    ]

    /// Digit values for bases above 16, where letters run on past F.
    private static func baseDigit(_ character: Character) -> Int? {
        guard let scalar = character.uppercased().unicodeScalars.first, scalar.properties.isASCIIHexDigit == false,
              (65...90).contains(scalar.value) else { return nil }
        return Int(scalar.value) - 55
    }
}

extension FormulaMath {
    public static func factorial(_ n: Int) -> Double {
        guard n > 1 else { return 1 }
        return (2...n).reduce(1.0) { $0 * Double($1) }
    }

    /// n choose k, exact while it fits in a double's integers.
    public static func combinations(_ n: Double, _ k: Double) throws(CellError) -> Double {
        guard n >= 0, k >= 0, n >= k else { throw .numberError }
        let smaller = min(k, n - k)
        var result = 1.0
        var i = 0.0
        while i < smaller {
            result = result * (n - i) / (i + 1)
            i += 1
        }
        guard result.isFinite else { throw .numberError }
        return result.rounded()
    }

    public static func gcd(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Numbers truncated to integers for `GCD` and `LCM`, which refuse negatives
    /// and anything past 2⁵³.
    public static func wholeNumbers(_ numbers: [Double]) throws(CellError) -> [Int] {
        var result: [Int] = []
        for number in numbers {
            guard number >= 0, number < 9_007_199_254_740_992 else { throw .numberError }
            result.append(Int(number.rounded(.towardZero)))
        }
        return result
    }

    /// The `SUMX2MY2` family's pairs: two same-shaped arrays, taking only
    /// positions where both hold numbers.
    public static func pairs(_ call: FunctionCall) throws(CellError) -> [(Double, Double)] {
        let first = try call.matrix(0).flatMap { $0 }
        let second = try call.matrix(1).flatMap { $0 }
        guard first.count == second.count else { throw .notAvailable }
        var result: [(Double, Double)] = []
        for (a, b) in zip(first, second) {
            if let error = a.errorValue ?? b.errorValue { throw error }
            if case .number(let x) = a, case .number(let y) = b { result.append((x, y)) }
        }
        return result
    }

    /// A block of numbers, refusing anything else, as the matrix functions do.
    public static func numericMatrix(_ rows: [[CellValue]]) throws(CellError) -> [[Double]] {
        var result: [[Double]] = []
        for row in rows {
            var line: [Double] = []
            for cell in row {
                switch cell {
                case .number(let number): line.append(number)
                case .error(let error): throw error
                default: throw .valueError
                }
            }
            result.append(line)
        }
        guard !result.isEmpty, result.allSatisfy({ $0.count == result[0].count }) else { throw .valueError }
        return result
    }

    /// The determinant by LU decomposition with partial pivoting.
    public static func determinant(_ matrix: [[Double]]) -> Double {
        var a = matrix
        let n = a.count
        var determinant = 1.0
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  a[pivot][column] != 0 else { return 0 }
            if pivot != column {
                a.swapAt(pivot, column)
                determinant = -determinant
            }
            determinant *= a[column][column]
            for row in (column + 1)..<max(column + 1, n) {
                let factor = a[row][column] / a[column][column]
                for k in column..<n { a[row][k] -= factor * a[column][k] }
            }
        }
        return determinant
    }

    /// The inverse by Gauss–Jordan elimination, or nil for a singular matrix.
    public static func inverse(_ matrix: [[Double]]) -> [[Double]]? {
        let n = matrix.count
        var a = matrix
        var inverse = (0..<n).map { row in (0..<n).map { $0 == row ? 1.0 : 0.0 } }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  abs(a[pivot][column]) > 1e-300 else { return nil }
            a.swapAt(pivot, column)
            inverse.swapAt(pivot, column)
            let scale = a[column][column]
            for k in 0..<n {
                a[column][k] /= scale
                inverse[column][k] /= scale
            }
            for row in 0..<n where row != column {
                let factor = a[row][column]
                guard factor != 0 else { continue }
                for k in 0..<n {
                    a[row][k] -= factor * a[column][k]
                    inverse[row][k] -= factor * inverse[column][k]
                }
            }
        }
        return inverse
    }

    /// Roman numerals in Excel's five styles, from classic (0) to the most
    /// condensed (4), which allow ever wider subtractive pairs.
    public static func roman(_ number: Int, form: Int) -> String {
        let characters: [Character] = ["M", "D", "C", "L", "X", "V", "I"]
        let values = [1000, 500, 100, 50, 10, 5, 1]
        let maxIndex = values.count - 1
        var result = ""
        var value = number
        for step in 0...(maxIndex / 2) {
            var index = 2 * step
            let digit = value / values[index]
            if digit % 5 == 4 {
                let index2 = digit == 4 ? index - 1 : index - 2
                var steps = 0
                while steps < form, index < maxIndex {
                    steps += 1
                    if values[index2] - values[index + 1] <= value {
                        index += 1
                    } else {
                        steps = form
                    }
                }
                result.append(characters[index])
                result.append(characters[index2])
                value = value + values[index] - values[index2]
            } else {
                if digit > 4 { result.append(characters[index - 1]) }
                result += String(repeating: characters[index], count: digit % 5)
                value %= values[index]
            }
        }
        return result
    }

    /// Reads a Roman numeral, accepting the condensed forms `ROMAN` writes.
    public static func arabic(_ raw: String) throws(CellError) -> Int {
        var text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        var sign = 1
        if text.hasPrefix("-") {
            sign = -1
            text.removeFirst()
        }
        guard text.count <= 255 else { throw .valueError }
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        var total = 0
        var previous = 0
        for character in text.reversed() {
            guard let value = values[character] else { throw .valueError }
            if value < previous { total -= value } else { total += value; previous = value }
        }
        return sign * total
    }
}
