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
        unmarked(marked(value, format: formatCode))
    }

    /// What `cell` lays out in its grid: its display text, but with the
    /// character each `_x` in its format reserves kept, behind `reserveMark`.
    /// The renderer measures that character but leaves it undrawn, so an
    /// accounting format's `_)` pads a positive amount by the width of the
    /// `)` a negative one ends in, and their decimals line up.
    public static func layoutText(for cell: Cell) -> String {
        let text = marked(cell.value, format: cell.style.numberFormat)
        return text.contains(fillMark) ? text.replacingOccurrences(of: String(fillMark), with: "") : text
    }

    /// `text` from `layoutText` or `filledText(reservingWidth:)`, cut into
    /// the runs that are drawn and the reserved characters that only take up
    /// their width.
    public static func reservedRuns(in text: String) -> [(text: String, isReserved: Bool)] {
        guard text.contains(reserveMark) else { return [(text, false)] }
        var runs: [(text: String, isReserved: Bool)] = []
        var drawn = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == reserveMark else { drawn.append(character); continue }
            // Elided text can end on a mark whose character was cut off.
            guard let reserved = iterator.next() else { break }
            if !drawn.isEmpty { runs.append((drawn, false)); drawn = "" }
            if let last = runs.last, last.isReserved {
                runs[runs.count - 1].text.append(reserved)
            } else {
                runs.append((String(reserved), true))
            }
        }
        if !drawn.isEmpty { runs.append((drawn, false)) }
        return runs
    }

    /// What `cell` shows split where its format's `*` fill falls, or nil
    /// when its format has none. The fill takes up whatever room the cell
    /// has, so the first part sits at the cell's leading edge and the second
    /// at its trailing one — an accounting format's currency symbol at the
    /// left and the amount at the right. `reservingWidth` keeps the
    /// characters `_x` reserves in the parts, as `layoutText` does.
    public static func filledText(
        for cell: Cell, reservingWidth: Bool = false
    ) -> (leading: String, trailing: String)? {
        let text = marked(cell.value, format: cell.style.numberFormat)
        guard let mark = text.firstIndex(of: fillMark) else { return nil }
        let strip = { (part: Substring) in
            reservingWidth ? part.replacingOccurrences(of: String(fillMark), with: "") : unmarked(String(part))
        }
        return (strip(text[..<mark]), strip(text[text.index(after: mark)...]))
    }

    /// What a General number shows when its full text is too wide for the
    /// cell, or nil when the cell is not a General number or nothing fits.
    ///
    /// Excel never shows `#`s for a General number while a shorter rendering
    /// of it fits: it drops decimals first (`0.333333`), then switches to
    /// scientific notation with fewer digits (`1.2E+11`), and only gives way
    /// to `#`s when even that is too wide. Rounding that would leave no
    /// significant digit — `0.00001` to `0` — is skipped in favour of
    /// scientific notation, so a non-zero value never reads as zero.
    /// `fits` measures a candidate against the room the cell has.
    public static func fittedGeneralText(for cell: Cell, fits: (String) -> Bool) -> String? {
        guard case .number(let number) = cell.value, number.isFinite,
              isGeneral(cell.style.numberFormat) else { return nil }
        return fittedGeneralText(for: number, fits: fits)
    }

    static func fittedGeneralText(for number: Double, fits: (String) -> Bool) -> String? {
        let full = CellValue.plainNumberString(number)
        if fits(full) { return full }

        // Fewer decimals, for a number General writes out in full.
        var decimal: String?
        if !full.contains("E"), let point = full.firstIndex(of: ".") {
            let decimals = full.distance(from: point, to: full.endIndex) - 1
            for places in stride(from: decimals - 1, through: 0, by: -1) {
                let candidate = trimmedDecimal(String(format: "%.\(places)f", number))
                guard let rounded = Double(candidate), rounded != 0 else { break }
                if fits(candidate) { decimal = candidate; break }
            }
        }

        // Scientific notation, with as many mantissa digits as fit.
        var exponent: String?
        for places in stride(from: 5, through: 0, by: -1) {
            let candidate = scientific(number, places: places)
            if candidate != full, fits(candidate) { exponent = candidate; break }
        }

        // Whichever keeps more of the number: `0.333333` over `3.33E-01`, but
        // `1.2E-05` over `0.00001`.
        guard let decimal else { return exponent }
        guard let exponent else { return decimal }
        return significantDigits(exponent) > significantDigits(decimal) ? exponent : decimal
    }

    private static func significantDigits(_ text: String) -> Int {
        let mantissa = text.prefix { $0 != "E" }.filter(\.isNumber)
        return mantissa.drop { $0 == "0" }.count
    }

    private static func isGeneral(_ code: String) -> Bool {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.caseInsensitiveCompare("General") == .orderedSame
    }

    /// `1.20E+11` as Excel's General writes it: `1.2E+11`.
    private static func scientific(_ number: Double, places: Int) -> String {
        let text = String(format: "%.\(places)E", number)
        guard let e = text.firstIndex(of: "E") else { return text }
        return trimmedDecimal(String(text[..<e])) + text[e...]
    }

    private static func trimmedDecimal(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var text = text
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Stands where a format's `*` fill goes in the text it renders.
    private static let fillMark: Character = "\u{1F}"

    /// Stands before the character a format's `_` reserves the width of.
    public static let reserveMark: Character = "\u{1E}"

    /// `text` without its fill marks or reserved characters: what the cell
    /// reads as, for copying, finding and exporting.
    private static func unmarked(_ text: String) -> String {
        guard text.contains(fillMark) || text.contains(reserveMark) else { return text }
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            switch character {
            case fillMark: continue
            case reserveMark: _ = iterator.next()
            default: result.append(character)
            }
        }
        return result
    }

    private static func marked(_ value: CellValue, format formatCode: String) -> String {
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
        let section = sections[sectionIndex(for: number, count: sections.count)]

        // A negative number falling back to the positive section keeps its sign.
        let usesDedicatedNegativeSection = number < 0 && sections.count >= 2
        let magnitude = usesDedicatedNegativeSection ? abs(number) : number

        if containsDateTokens(section) {
            return formatDateTime(serial: number, pattern: section)
        }
        return formatNumeric(magnitude, pattern: section)
    }

    /// Which of a format's `count` sections renders `number`: the negative
    /// and zero sections when the format has them, the first otherwise.
    private static func sectionIndex(for number: Double, count: Int) -> Int {
        if number < 0, count >= 2 { return 1 }
        if number == 0, count >= 3 { return 2 }
        return 0
    }

    // MARK: - Section colours

    /// The colour the format section that renders `cell` names, such as the
    /// red of `#,##0;[Red](#,##0)` for a negative number, as an RGB hex
    /// string; nil when that section names none. It takes the place of the
    /// cell's font colour, as in Excel.
    public static func sectionColorHex(for cell: Cell) -> String? {
        sectionColorHex(for: cell.value, format: cell.style.numberFormat)
    }

    public static func sectionColorHex(for value: CellValue, format formatCode: String) -> String? {
        let trimmed = formatCode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "@",
              trimmed.caseInsensitiveCompare("General") != .orderedSame else { return nil }
        let sections = split(trimmed)
        switch value {
        case .number(let number):
            return colorHex(inSection: sections[sectionIndex(for: number, count: sections.count)])
        case .text:
            return sections.count >= 4 ? colorHex(inSection: sections[3]) : nil
        case .empty, .error, .boolean:
            return nil
        }
    }

    /// The eight colours a format may name, as Excel draws them.
    private static let namedColors: [String: String] = [
        "black": "000000", "blue": "0000FF", "cyan": "00FFFF", "green": "00FF00",
        "magenta": "FF00FF", "red": "FF0000", "white": "FFFFFF", "yellow": "FFFF00",
    ]

    /// The first bracketed colour in a section: a name like `[Red]` or a
    /// palette slot like `[Color10]` (1–56, the indexed palette from 8 on).
    /// Conditions, locales and elapsed-time tokens are passed over.
    private static func colorHex(inSection section: String) -> String? {
        let characters = Array(section)
        var inQuotes = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes {
                switch character {
                case "\\", "_", "*":
                    index += 1  // The next character is literal, reserved or a fill.
                case "[":
                    guard let close = characters[index...].firstIndex(of: "]") else { return nil }
                    let name = String(characters[(index + 1)..<close]).lowercased()
                    if let hex = namedColors[name] { return hex }
                    if name.hasPrefix("color"), let slot = Int(name.dropFirst(5)), (1...56).contains(slot) {
                        return ThemeColorPalette.indexedColors[slot + 7]
                    }
                    index = close
                default:
                    break
                }
            }
            index += 1
        }
        return nil
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
                case "_":
                    index += 1
                    if index < characters.count { result += [reserveMark, characters[index]] }
                case "*":
                    index += 1
                    result.append(fillMark)
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
        var bracket: String?
        for character in pattern {
            if character == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            // Bracketed sections are colours (`[Red]`, `[Color10]`), conditions
            // (`[>100]`) or locales (`[$-409]`), none of which make a date. Only
            // the elapsed-time tokens `[h]`, `[mm]`, `[ss]` and the like do.
            if var section = bracket {
                if character == "]" {
                    bracket = nil
                    if isElapsedTimeToken(section) { return true }
                } else {
                    section.append(character)
                    bracket = section
                }
                continue
            }
            if character == "[" { bracket = ""; continue }
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

    /// Whether a bracketed section is an elapsed-time token: one or more of the
    /// same `h`, `m` or `s`, as in `[h]`, `[mm]` or `[ss]`.
    private static func isElapsedTimeToken(_ section: String) -> Bool {
        let lowered = section.lowercased()
        guard let first = lowered.first, "hms".contains(first) else { return false }
        return lowered.allSatisfy { $0 == first }
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
                index += 1  // Reserve-width token: marked, for the renderer to leave undrawn.
                if index < characters.count {
                    let reserved = [reserveMark, characters[index]]
                    if seenDigit { result.suffix += reserved } else { result.prefix += reserved }
                }
            case "*":
                index += 1  // Fill token: marked, for the renderer to spread.
                if seenDigit { result.suffix.append(fillMark) } else { result.prefix.append(fillMark) }
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
