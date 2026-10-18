import Foundation

/// Renders `CellValue`s using a useful subset of OOXML number format codes.
///
/// Supported: `General`, `@`, digit placeholders (`0`, `#`, `?`), decimal points,
/// thousands separators, percent scaling, scientific notation, literal text in
/// quotes, and date/time tokens. Sections are split on `;` in the usual
/// positive/negative/zero/text order.
public enum CellFormatter {
    public static func displayText(for cell: Cell) -> String {
        displayText(for: cell.value, format: cell.style.numberFormat)
    }

    public static func displayText(for value: CellValue, format formatCode: String) -> String {
        switch value {
        case .empty:
            return ""
        case .error(let error):
            return error.rawValue
        case .boolean(let flag):
            return flag ? "TRUE" : "FALSE"
        case .text(let text):
            let sections = split(formatCode)
            if sections.count >= 4 { return apply(textSection: sections[3], to: text) }
            return text
        case .number(let number):
            return format(number: number, code: formatCode)
        }
    }

    /// Whether a value renders right-aligned when the style says `.automatic`.
    public static func naturalAlignment(for value: CellValue) -> HorizontalTextAlignment {
        switch value {
        case .number, .boolean: return .trailing
        case .error: return .center
        case .text, .empty: return .leading
        }
    }

    // MARK: - Number formatting

    private static func format(number: Double, code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("General") == .orderedSame {
            return CellValue.plainNumberString(number)
        }
        if trimmed == "@" { return CellValue.plainNumberString(number) }

        let sections = split(trimmed)
        let section: String
        if number < 0, sections.count >= 2 {
            section = sections[1]
        } else if number == 0, sections.count >= 3 {
            section = sections[2]
        } else {
            section = sections[0]
        }

        // A negative number falling back to the positive section keeps its sign.
        let usesDedicatedNegativeSection = number < 0 && sections.count >= 2
        let magnitude = usesDedicatedNegativeSection ? abs(number) : number

        if containsDateTokens(section) {
            return formatDateTime(serial: number, pattern: section)
        }
        return formatNumeric(magnitude, pattern: section)
    }

    private static func split(_ code: String) -> [String] {
        var sections: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = code.makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == ";" && !inQuotes {
                sections.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        sections.append(current)
        return sections
    }

    /// A format's text section, with the same tokens the numeric sections
    /// honour: `_x` reserves the width of `x` and `*x` repeats it to fill the
    /// cell — neither drawn — `\x` is a literal, and `[…]` a colour or
    /// condition. Accounting formats end in `_(@_)`, which is just the text.
    private static func apply(textSection: String, to text: String) -> String {
        var result = ""
        var inQuotes = false
        let characters = Array(textSection)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if inQuotes {
                result.append(character)
            } else {
                switch character {
                case "@": result += text
                case "_", "*": index += 1
                case "\\":
                    index += 1
                    if index < characters.count { result.append(characters[index]) }
                case "[":
                    while index < characters.count, characters[index] != "]" { index += 1 }
                default: result.append(character)
                }
            }
            index += 1
        }
        return result.isEmpty ? text : result
    }

    /// Whether a format code renders its number as a date or time. OOXML stores
    /// dates as bare serials, so the format is the only thing that marks them.
    public static func isDateFormat(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "@",
              trimmed.caseInsensitiveCompare("General") != .orderedSame else { return false }
        return containsDateTokens(split(trimmed).first ?? trimmed)
    }

    private static func containsDateTokens(_ pattern: String) -> Bool {
        var inQuotes = false
        var previous: Character?
        for character in pattern {
            if character == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            switch character {
            case "y", "Y", "d", "D", "h", "H", "s", "S":
                return true
            case "m", "M":
                // `m` is minutes or months; either way it means date/time.
                return true
            case "e":
                if previous == "0" || previous == "#" { return false }
            default:
                break
            }
            previous = character
        }
        return false
    }

    // MARK: - Numeric patterns

    private struct NumericPattern {
        var prefix = ""
        var suffix = ""
        var integerPlaceholders = 0
        var integerOptional = 0
        var fractionPlaceholders = 0
        var fractionOptional = 0
        var usesThousandsSeparator = false
        var percentScale = 0
        var isScientific = false
        var exponentDigits = 0
    }

    private static func parse(pattern: String) -> NumericPattern {
        var result = NumericPattern()
        var stage = 0  // 0 = integer, 1 = fraction, 2 = exponent
        var seenDigit = false
        var inQuotes = false
        let characters = Array(pattern)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                inQuotes.toggle()
                index += 1
                continue
            }
            if inQuotes {
                if seenDigit { result.suffix.append(character) } else { result.prefix.append(character) }
                index += 1
                continue
            }
            switch character {
            case "0", "#", "?":
                seenDigit = true
                let isRequired = character == "0"
                switch stage {
                case 0:
                    if isRequired { result.integerPlaceholders += 1 } else { result.integerOptional += 1 }
                case 1:
                    if isRequired { result.fractionPlaceholders += 1 } else { result.fractionOptional += 1 }
                default:
                    result.exponentDigits += 1
                }
            case ".":
                if stage == 0 { stage = 1 } else if seenDigit { result.suffix.append(character) }
            case ",":
                if seenDigit && stage == 0 { result.usesThousandsSeparator = true }
            case "%":
                result.percentScale += 1
                if seenDigit { result.suffix.append(character) } else { result.prefix.append(character) }
            case "E", "e":
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                if seenDigit, next == "+" || next == "-" {
                    result.isScientific = true
                    stage = 2
                    index += 1
                } else if seenDigit {
                    result.suffix.append(character)
                } else {
                    result.prefix.append(character)
                }
            case "\\":
                index += 1
                if index < characters.count {
                    if seenDigit { result.suffix.append(characters[index]) } else { result.prefix.append(characters[index]) }
                }
            case "_":
                index += 1  // Reserve-width token: skip the following character.
            case "*":
                index += 1  // Fill token: not reproduced.
            case "[":
                while index < characters.count, characters[index] != "]" { index += 1 }
            default:
                if seenDigit { result.suffix.append(character) } else { result.prefix.append(character) }
            }
            index += 1
        }
        return result
    }

    private static func formatNumeric(_ value: Double, pattern patternText: String) -> String {
        let pattern = parse(pattern: patternText)
        var working = value
        for _ in 0..<pattern.percentScale { working *= 100 }

        if pattern.integerPlaceholders == 0 && pattern.integerOptional == 0
            && pattern.fractionPlaceholders == 0 && pattern.fractionOptional == 0 {
            return pattern.prefix + pattern.suffix
        }

        if pattern.isScientific {
            let digits = max(0, pattern.fractionPlaceholders + pattern.fractionOptional)
            let exponentWidth = max(1, pattern.exponentDigits)
            var text = String(format: "%.\(digits)E", working)
            // Normalize the platform's exponent width to the pattern's.
            if let separator = text.firstIndex(where: { $0 == "E" }) {
                let mantissa = String(text[text.startIndex..<separator])
                var exponent = String(text[text.index(after: separator)...])
                let sign = exponent.hasPrefix("-") ? "-" : "+"
                exponent = exponent.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
                while exponent.count > exponentWidth, exponent.hasPrefix("0") { exponent.removeFirst() }
                while exponent.count < exponentWidth { exponent = "0" + exponent }
                text = mantissa + "E" + sign + exponent
            }
            return pattern.prefix + text + pattern.suffix
        }

        let fractionDigits = pattern.fractionPlaceholders + pattern.fractionOptional
        let isNegative = working < 0 || (working == 0 && working.sign == .minus)
        // Spreadsheets round halves away from zero; `%f` rounds to even.
        let scale = pow(10.0, Double(fractionDigits))
        let magnitude = ((abs(working) * scale).rounded(.toNearestOrAwayFromZero) / scale)
        var rendered = String(format: "%.\(fractionDigits)f", magnitude)

        var integerPart = rendered
        var fractionPart = ""
        if let dot = rendered.firstIndex(of: ".") {
            integerPart = String(rendered[rendered.startIndex..<dot])
            fractionPart = String(rendered[rendered.index(after: dot)...])
        }

        // Pad or trim the integer side to the pattern's required width.
        while integerPart.count < pattern.integerPlaceholders { integerPart = "0" + integerPart }
        if integerPart == "0", pattern.integerPlaceholders == 0 { integerPart = "" }

        if pattern.usesThousandsSeparator { integerPart = groupThousands(integerPart) }

        // Drop optional trailing decimals ("#" placeholders) that ended up as zeros.
        if pattern.fractionOptional > 0 {
            var keep = fractionPart.count
            while keep > pattern.fractionPlaceholders,
                  fractionPart[fractionPart.index(fractionPart.startIndex, offsetBy: keep - 1)] == "0" {
                keep -= 1
            }
            fractionPart = String(fractionPart.prefix(keep))
        }

        rendered = integerPart
        if !fractionPart.isEmpty { rendered += "." + fractionPart }
        if rendered.isEmpty { rendered = "0" }
        if isNegative, Double(rendered.replacingOccurrences(of: ",", with: "")) != 0 { rendered = "-" + rendered }
        return pattern.prefix + rendered + pattern.suffix
    }

    private static func groupThousands(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var grouped = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { grouped.append(",") }
            grouped.append(character)
        }
        return String(grouped.reversed())
    }

    // MARK: - Date and time

    /// 1899-12-31 UTC — serial 1 is 1900-01-01 in the 1900 date system.
    public static let excelEpoch = Date(timeIntervalSince1970: -2_209_075_200)

    public static func date(fromSerial serial: Double) -> Date {
        // Serials above 59 are shifted by Excel's non-existent 1900-02-29.
        let adjusted = serial > 59 ? serial - 1 : serial
        return excelEpoch.addingTimeInterval(adjusted * 86_400)
    }

    public static func serial(fromDate date: Date) -> Double {
        let days = date.timeIntervalSince(excelEpoch) / 86_400
        return days >= 59 ? days + 1 : days
    }

    private static func formatDateTime(serial: Double, pattern: String) -> String {
        let date = date(fromSerial: serial)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday], from: date
        )
        let usesTwelveHourClock = pattern.lowercased().contains("am/pm") || pattern.lowercased().contains("a/p")

        var result = ""
        var inQuotes = false
        let characters = Array(pattern)
        var index = 0
        var previousWasHour = false

        while index < characters.count {
            let character = characters[index]
            if character == "\"" { inQuotes.toggle(); index += 1; continue }
            if inQuotes { result.append(character); index += 1; continue }

            let lower = Character(character.lowercased())
            if lower == "a", matches(characters, at: index, "am/pm") {
                let hour = parts.hour ?? 0
                result += hour < 12 ? "AM" : "PM"
                index += 5
                continue
            }
            guard "ymdhs".contains(lower) else {
                if character != "\\" { result.append(character) }
                index += 1
                previousWasHour = false
                continue
            }

            var run = 0
            while index + run < characters.count,
                  Character(characters[index + run].lowercased()) == lower { run += 1 }

            switch lower {
            case "y":
                let year = parts.year ?? 1900
                result += run <= 2 ? pad(year % 100, 2) : pad(year, 4)
            case "d":
                let day = parts.day ?? 1
                switch run {
                case 1, 2: result += pad(day, run)
                case 3: result += shortWeekdaySymbol(parts.weekday ?? 1)
                default: result += longWeekdaySymbol(parts.weekday ?? 1)
                }
            case "h":
                var hour = parts.hour ?? 0
                if usesTwelveHourClock {
                    hour = hour % 12
                    if hour == 0 { hour = 12 }
                }
                result += pad(hour, run)
                previousWasHour = true
                index += run
                continue
            case "s":
                result += pad(parts.second ?? 0, run)
            case "m":
                // `m` right after an hour token (or before seconds) means minutes.
                let followedBySeconds = nextMeaningfulToken(characters, after: index + run) == "s"
                if previousWasHour || followedBySeconds {
                    result += pad(parts.minute ?? 0, run)
                } else {
                    let month = parts.month ?? 1
                    switch run {
                    case 1, 2: result += pad(month, run)
                    case 3: result += shortMonthSymbol(month)
                    default: result += longMonthSymbol(month)
                    }
                }
            default:
                break
            }
            previousWasHour = false
            index += run
        }
        return result
    }

    private static func matches(_ characters: [Character], at index: Int, _ token: String) -> Bool {
        let token = Array(token)
        guard index + token.count <= characters.count else { return false }
        for offset in 0..<token.count
        where Character(characters[index + offset].lowercased()) != token[offset] { return false }
        return true
    }

    private static func nextMeaningfulToken(_ characters: [Character], after index: Int) -> Character? {
        var cursor = index
        while cursor < characters.count {
            let lower = Character(characters[cursor].lowercased())
            if "ymdhs".contains(lower) { return lower }
            if lower.isLetter { return nil }
            cursor += 1
        }
        return nil
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(abs(value))
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    private static let shortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let longMonths = ["January", "February", "March", "April", "May", "June",
                                     "July", "August", "September", "October", "November", "December"]
    private static let shortWeekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let longWeekdays = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                       "Thursday", "Friday", "Saturday"]

    private static func shortMonthSymbol(_ month: Int) -> String { shortMonths[(month - 1 + 12) % 12] }
    private static func longMonthSymbol(_ month: Int) -> String { longMonths[(month - 1 + 12) % 12] }
    private static func shortWeekdaySymbol(_ weekday: Int) -> String { shortWeekdays[(weekday - 1 + 7) % 7] }
    private static func longWeekdaySymbol(_ weekday: Int) -> String { longWeekdays[(weekday - 1 + 7) % 7] }
}
