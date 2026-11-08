import Foundation

// MARK: - Coercion

/// How Excel turns one kind of value into another when a function or operator
/// needs a particular kind. Errors are thrown so they carry through unchanged.
extension CellValue {
    /// A number, from a number, a boolean, a blank, or text that reads as a
    /// number, a percentage, a currency amount, a date or a time.
    public func coercedNumber() throws(CellError) -> Double {
        switch self {
        case .empty: return 0
        case .number(let value): return value
        case .boolean(let flag): return flag ? 1 : 0
        case .text(let text):
            guard let number = FormulaValueParser.number(from: text) else { throw .valueError }
            return number
        case .error(let error): throw error
        }
    }

    /// Text, with numbers written the way Excel writes them into text: up to
    /// fifteen significant digits, and no grouping.
    public func coercedText() throws(CellError) -> String {
        switch self {
        case .empty: return ""
        case .number(let value): return FormulaNumberText.general(value)
        case .text(let text): return text
        case .boolean(let flag): return flag ? "TRUE" : "FALSE"
        case .error(let error): throw error
        }
    }

    /// A truth value. Text counts only when it spells TRUE or FALSE.
    public func coercedBoolean() throws(CellError) -> Bool {
        switch self {
        case .empty: return false
        case .number(let value): return value != 0
        case .boolean(let flag): return flag
        case .text(let text):
            if text.caseInsensitiveCompare("TRUE") == .orderedSame { return true }
            if text.caseInsensitiveCompare("FALSE") == .orderedSame { return false }
            throw .valueError
        case .error(let error): throw error
        }
    }

    public var isNumber: Bool {
        if case .number = self { return true }
        return false
    }

    public var isText: Bool {
        if case .text = self { return true }
        return false
    }

    public var isBoolean: Bool {
        if case .boolean = self { return true }
        return false
    }

    public var isError: Bool { errorValue != nil }
}

// MARK: - Numbers as text

public enum FormulaNumberText {
    /// A number as Excel renders it when converting to text.
    public static func general(_ value: Double) -> String {
        if value == 0 { return "0" }
        if !value.isFinite { return CellError.numberError.rawValue }
        let magnitude = abs(value)
        let exponent = Int(floor(log10(magnitude)))
        if exponent >= 15 || exponent < -9 {
            return scientific(value)
        }
        // Fifteen significant digits, then trailing zeros dropped.
        let decimals = max(0, 14 - exponent)
        var text = String(format: "%.\(min(decimals, 30))f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { return "0" }
        return text
    }

    /// `1.23456789012346E+15`: a mantissa of up to fifteen significant digits
    /// and an exponent of at least two.
    public static func scientific(_ value: Double) -> String {
        let formatted = String(format: "%.14E", value)
        guard let marker = formatted.firstIndex(of: "E") else { return formatted }
        var mantissa = String(formatted[..<marker])
        var exponent = String(formatted[formatted.index(after: marker)...])
        if mantissa.contains(".") {
            while mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
        }
        let sign = exponent.hasPrefix("-") ? "-" : "+"
        exponent = exponent.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        while exponent.count > 2, exponent.hasPrefix("0") { exponent.removeFirst() }
        if exponent.count < 2 { exponent = "0" + exponent }
        return mantissa + "E" + sign + exponent
    }
}

// MARK: - Comparison

public enum FormulaComparison {
    /// Orders two values the way Excel's comparison operators do: numbers
    /// before text before booleans, text without regard to case, and a blank
    /// standing for zero, empty text or FALSE as the other side requires.
    public static func compare(_ lhs: CellValue, _ rhs: CellValue) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.empty, .empty): return .orderedSame
        case (.empty, .number(let b)): return compareNumbers(0, b)
        case (.number(let a), .empty): return compareNumbers(a, 0)
        case (.empty, .text(let b)): return compareText("", b)
        case (.text(let a), .empty): return compareText(a, "")
        case (.empty, .boolean(let b)): return compareNumbers(0, b ? 1 : 0)
        case (.boolean(let a), .empty): return compareNumbers(a ? 1 : 0, 0)
        case (.number(let a), .number(let b)): return compareNumbers(a, b)
        case (.text(let a), .text(let b)): return compareText(a, b)
        case (.boolean(let a), .boolean(let b)): return compareNumbers(a ? 1 : 0, b ? 1 : 0)
        default: return rank(lhs) < rank(rhs) ? .orderedAscending : .orderedDescending
        }
    }

    private static func rank(_ value: CellValue) -> Int {
        switch value {
        case .empty, .number: return 0
        case .text: return 1
        case .boolean: return 2
        case .error: return 3
        }
    }

    /// Numbers equal to fifteen significant digits count as equal, which is
    /// what makes `0.1+0.2=0.3` true.
    public static func compareNumbers(_ a: Double, _ b: Double) -> ComparisonResult {
        if a == b || abs(a - b) <= 1e-15 * max(abs(a), abs(b)) { return .orderedSame }
        return a < b ? .orderedAscending : .orderedDescending
    }

    public static func compareText(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive], range: nil, locale: Locale(identifier: "en_US"))
    }

    /// Whether two values are the same for lookup and matching: same kind,
    /// text ignoring case.
    public static func equal(_ lhs: CellValue, _ rhs: CellValue) -> Bool {
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)): return compareNumbers(a, b) == .orderedSame
        case (.text(let a), .text(let b)): return a.caseInsensitiveCompare(b) == .orderedSame
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.empty, .empty): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }

    /// The result of an addition or subtraction, with the dust of binary
    /// floating point swept to zero when the operands cancel exactly in decimal.
    public static func snapped(_ result: Double, _ a: Double, _ b: Double) -> Double {
        let scale = max(abs(a), abs(b))
        return scale > 0 && abs(result) < scale * 1e-15 ? 0 : result
    }
}

// MARK: - Reading numbers out of text

/// Parses text the way Excel does when text meets arithmetic: plain numbers,
/// grouped thousands, currency, percentages, accounting negatives, fractions,
/// dates and times.
public enum FormulaValueParser {
    public static func number(from raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let plain = Double(text), !text.lowercased().hasPrefix("0x"), !text.lowercased().contains("n") {
            return plain
        }
        if let amount = amount(from: text) { return amount }
        if let fraction = fraction(from: text) { return fraction }
        return dateTime(from: text)
    }

    /// `1,234.5`, `$1,234`, `(12)`, `-$5`, `50%`.
    private static func amount(from text: String) -> Double? {
        var working = text
        var negative = false
        if working.hasPrefix("("), working.hasSuffix(")") {
            negative = true
            working = String(working.dropFirst().dropLast())
        }
        if working.hasPrefix("-") {
            negative.toggle()
            working.removeFirst()
        } else if working.hasPrefix("+") {
            working.removeFirst()
        }
        working = working.trimmingCharacters(in: .whitespaces)
        if let first = working.first, "$€£¥".contains(first) {
            working.removeFirst()
            working = working.trimmingCharacters(in: .whitespaces)
            if working.hasPrefix("-") {
                negative.toggle()
                working.removeFirst()
            }
        }
        var percent = false
        if working.hasSuffix("%") {
            percent = true
            working.removeLast()
            working = working.trimmingCharacters(in: .whitespaces)
        }
        guard !working.isEmpty, working.first?.isNumber == true || working.first == "." else { return nil }
        // Grouping commas must fall every three digits of the integer part.
        if working.contains(",") {
            let integer = working.split(separator: ".", maxSplits: 1).first.map(String.init) ?? working
            let groups = integer.split(separator: ",", omittingEmptySubsequences: false)
            guard groups.count > 1, (1...3).contains(groups[0].count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            working = working.replacingOccurrences(of: ",", with: "")
        }
        guard working.allSatisfy({ $0.isNumber || $0 == "." || $0 == "E" || $0 == "e" || $0 == "+" || $0 == "-" }),
              var value = Double(working) else { return nil }
        if percent { value /= 100 }
        return negative ? -value : value
    }

    /// `1 1/2` and `3/4`. A bare `3/4` reads as a date in Excel, so only the
    /// mixed form is a fraction here.
    private static func fraction(from text: String) -> Double? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, let whole = Double(parts[0]) else { return nil }
        let pieces = parts[1].split(separator: "/")
        guard pieces.count == 2, let numerator = Double(pieces[0]), let denominator = Double(pieces[1]),
              denominator != 0, numerator >= 0 else { return nil }
        let magnitude = abs(whole) + numerator / denominator
        return whole < 0 || parts[0].hasPrefix("-") ? -magnitude : magnitude
    }

    // MARK: Dates and times

    private static let monthNames: [String: Int] = {
        var names: [String: Int] = [:]
        let long = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                    "october", "november", "december"]
        for (index, name) in long.enumerated() {
            names[name] = index + 1
            names[String(name.prefix(3))] = index + 1
        }
        names["sept"] = 9
        return names
    }()

    /// A date, a time, or both, as a serial number.
    public static func dateTime(from raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        // Split off a trailing time, which may follow a date after a space or a `T`.
        var datePart = text
        var timeValue: Double?
        if let time = time(from: text) {
            return time
        }
        for separator in [" ", "t"] {
            guard let split = datePart.range(of: separator, options: .backwards) else { continue }
            let tail = String(datePart[split.upperBound...])
            var head = String(datePart[..<split.lowerBound]).trimmingCharacters(in: .whitespaces)
            // "1:30 pm" splits at the space before the meridiem; reach past it.
            if tail == "am" || tail == "pm" || tail == "a" || tail == "p",
               let inner = head.range(of: " ", options: .backwards) {
                let candidate = String(head[inner.upperBound...]) + " " + tail
                if let time = time(from: candidate) {
                    head = String(head[..<inner.lowerBound]).trimmingCharacters(in: .whitespaces)
                    timeValue = time
                    datePart = head
                    break
                }
            }
            if let time = time(from: tail) {
                timeValue = time
                datePart = head
                break
            }
        }
        guard let day = date(from: datePart) else { return nil }
        return day + (timeValue ?? 0)
    }

    /// `13:45`, `1:45:30 PM`, `9 am`. Returns the fraction of a day.
    public static func time(from raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where text.hasSuffix(suffix) {
            let head = text.dropLast(suffix.count)
            guard head.last?.isNumber == true || head.last == " " else { continue }
            meridiem = suffix.hasPrefix("a") ? "am" : "pm"
            text = String(head).trimmingCharacters(in: .whitespaces)
            break
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (meridiem != nil && parts.count == 1) || (2...3).contains(parts.count) else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0 == "." } }) else { return nil }
        guard var hours = Double(parts[0]) else { return nil }
        let minutes = parts.count > 1 ? Double(parts[1]) ?? -1 : 0
        let seconds = parts.count > 2 ? Double(parts[2]) ?? -1 : 0
        guard minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { return nil }
        if let meridiem {
            guard hours >= 0, hours <= 12 else { return nil }
            if meridiem == "am", hours == 12 { hours = 0 }
            if meridiem == "pm", hours < 12 { hours += 12 }
        }
        guard hours >= 0, hours < 10_000 else { return nil }
        return (hours * 3600 + minutes * 60 + seconds) / 86_400
    }

    /// `2024-01-15`, `1/15/2024`, `15-Jan-2024`, `Jan 15, 2024`, `15 January 2024`, `1/15`.
    public static func date(from raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: ",", with: " ")
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" || $0 == "." })
            .map(String.init)
        guard (2...3).contains(tokens.count) else { return nil }
        let currentYear = FormulaDates.components(fromSerial: FormulaDates.today()).year

        var year: Int?
        var month: Int?
        var day: Int?
        let numbers = tokens.map { Int($0) }
        if let monthIndex = tokens.firstIndex(where: { monthNames[$0] != nil }) {
            month = monthNames[tokens[monthIndex]]
            let others = tokens.indices.filter { $0 != monthIndex }.compactMap { numbers[$0] }
            guard others.count == tokens.count - 1 else { return nil }
            if others.count == 2 {
                // `Jan 15 2024`, `15 Jan 2024`, or `Jan 2024` read as its first day.
                if others[0] > 31 { year = others[0]; day = others[1] } else { day = others[0]; year = others[1] }
            } else if let only = others.first {
                if only > 31 { year = only; day = 1 } else { day = only; year = currentYear }
            }
        } else {
            guard numbers.allSatisfy({ $0 != nil }) else { return nil }
            let values = numbers.compactMap { $0 }
            if values.count == 3 {
                if tokens[0].count == 4 {
                    (year, month, day) = (values[0], values[1], values[2])
                } else {
                    (month, day, year) = (values[0], values[1], values[2])
                }
            } else if tokens[0].count == 4 {
                (year, month, day) = (values[0], values[1], 1)
            } else if values[1] > 31 || tokens[1].count == 4 {
                (month, year, day) = (values[0], values[1], 1)
            } else {
                (month, day, year) = (values[0], values[1], currentYear)
            }
        }
        guard var resolvedYear = year, let month, let day,
              (1...12).contains(month), day >= 1 else { return nil }
        // Two-digit years: 00–29 are this century, 30–99 the last.
        if resolvedYear < 100 { resolvedYear += resolvedYear < 30 ? 2000 : 1900 }
        guard (1900...9999).contains(resolvedYear), day <= FormulaDates.daysInMonth(resolvedYear, month) else {
            return nil
        }
        return FormulaDates.serial(year: resolvedYear, month: month, day: day)
    }
}

// MARK: - Serial dates

/// Excel's 1900 date system, done in integer arithmetic so no time zone or
/// calendar setting can shift a day. Serial 1 is 1900-01-01, and serial 60 is
/// the 29 February 1900 that never was — kept because Lotus 1-2-3 had it and
/// every workbook since depends on it.
public enum FormulaDates {
    public struct Components: Hashable, Sendable {
        public var year: Int
        public var month: Int
        public var day: Int
    }

    /// The serial for a date. Months and days outside their ranges roll over
    /// into neighbouring ones, as `DATE(2024,14,1)` does.
    public static func serial(year: Int, month: Int, day: Int) -> Double {
        var y = year
        var m = month - 1
        y += m >= 0 ? m / 12 : (m - 11) / 12
        m = ((m % 12) + 12) % 12
        let first = daysFromCivil(y, m + 1, 1)
        var serial = first - daysFromCivil(1899, 12, 31) + day - 1
        // Everything from 1 March 1900 on sits one past where a real calendar
        // would put it, to leave room for the phantom leap day.
        if serial >= 60 { serial += 1 }
        return Double(serial)
    }

    public static func components(fromSerial serial: Double) -> Components {
        let whole = Int(serial.rounded(.down))
        if whole == 60 { return Components(year: 1900, month: 2, day: 29) }
        if whole <= 0 { return Components(year: 1900, month: 1, day: 0) }
        let adjusted = whole > 60 ? whole - 1 : whole
        let civil = civilFromDays(daysFromCivil(1899, 12, 31) + adjusted)
        return Components(year: civil.0, month: civil.1, day: civil.2)
    }

    /// 1 for Sunday through 7 for Saturday.
    public static func weekday(ofSerial serial: Double) -> Int {
        // Serial 0 is a Saturday by Excel's count. The phantom leap day makes
        // that count wrong before March 1900 and right ever after.
        let whole = Int(serial.rounded(.down))
        return ((whole + 6) % 7 + 7) % 7 + 1
    }

    public static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    public static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// Today's serial in the device's time zone.
    public static func today() -> Double {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        return serial(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Now as a serial with the time of day, in the device's time zone.
    public static func now() -> Double {
        let parts = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: Date())
        let day = serial(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1)
        let seconds = Double((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0))
            + Double(parts.nanosecond ?? 0) / 1e9
        return day + seconds / 86_400
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}
