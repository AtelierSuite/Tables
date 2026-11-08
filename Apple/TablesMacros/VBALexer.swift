import Foundation
import TablesEngine

/// A lexical unit of VBA source.
public enum VBAToken: Hashable, Sendable {
    /// A name or keyword, without any type-declaration suffix (`x$`, `n&`).
    /// Keywords are recognised by the parser, case-insensitively, since VBA
    /// lets many of them double as ordinary names.
    case identifier(String)
    case integer(Int)
    case double(Double)
    case string(String)
    /// A `#1/2/2024#` literal, as an OLE Automation date.
    case date(Double)
    case symbol(String)
    /// The end of a logical line, after continuations are joined.
    case newline
    case end
}

public struct VBASourceToken: Hashable, Sendable {
    public var token: VBAToken
    /// One-based line in the module source, for error messages.
    public var line: Int
    /// Whether whitespace came immediately before, which is how VBA tells
    /// `.Value` inside a `With` block apart from `x.Value`.
    public var followsSpace: Bool
}

public struct VBASyntaxError: LocalizedError, Hashable, Sendable {
    public var message: String
    public var line: Int
    /// The module the line is in, once known.
    public var module: String?

    /// A message from the string catalog, with its arguments filled in.
    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: String(localized: String.LocalizationValue(key), bundle: #bundle), arguments: arguments)
    }

    public var errorDescription: String? {
        guard let module else { return String(format: String(localized: "Macro.SyntaxError", bundle: #bundle), line, message) }
        return String(format: String(localized: "Macro.SyntaxError.InModule", bundle: #bundle), module, line, message)
    }
}

public enum VBALexer {
    public static func tokenize(_ source: String) throws -> [VBASourceToken] {
        var tokens: [VBASourceToken] = []
        let characters = Array(source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var index = 0
        var line = 1
        var followsSpace = true

        func peek(_ offset: Int = 0) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }
        func emit(_ token: VBAToken) {
            tokens.append(VBASourceToken(token: token, line: line, followsSpace: followsSpace))
            followsSpace = false
        }
        func emitNewline() {
            if let last = tokens.last?.token, last != .newline { emit(.newline) }
            followsSpace = true
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\n" {
                emitNewline()
                line += 1
                index += 1
                continue
            }
            if character == " " || character == "\t" {
                // ` _` before the end of a line joins it to the next.
                if peek(1) == "_" {
                    var lookahead = index + 2
                    while lookahead < characters.count, characters[lookahead] == " " || characters[lookahead] == "\t" {
                        lookahead += 1
                    }
                    if lookahead >= characters.count || characters[lookahead] == "\n" {
                        index = lookahead + 1
                        line += 1
                        followsSpace = true
                        continue
                    }
                }
                followsSpace = true
                index += 1
                continue
            }
            if character == "'" {
                index = skipComment(characters, from: index, line: &line)
                continue
            }
            if character == "\"" {
                var text = ""
                index += 1
                while true {
                    guard let next = peek(), next != "\n" else {
                        throw VBASyntaxError(message: VBASyntaxError.text("Macro.Syntax.UnterminatedString"), line: line)
                    }
                    index += 1
                    if next == "\"" {
                        if peek() == "\"" {
                            text.append("\"")
                            index += 1
                            continue
                        }
                        break
                    }
                    text.append(next)
                }
                emit(.string(text))
                continue
            }
            if character.isNumber || (character == "." && peek(1)?.isNumber == true && !isMemberDot(tokens, followsSpace)) {
                emit(try number(characters, from: &index, line: line))
                continue
            }
            if character == "&", let radix = peek(1).flatMap(radixPrefix) {
                index += 2
                var digits = ""
                while let next = peek(), next.isHexDigit {
                    digits.append(next)
                    index += 1
                }
                while let next = peek(), "&%^".contains(next) { index += 1 }
                guard let value = UInt64(digits, radix: radix) else {
                    throw VBASyntaxError(message: VBASyntaxError.text("Macro.Syntax.MalformedNumber"), line: line)
                }
                // `&HFFFF` is an Integer and so -1; wider literals are Longs.
                let signed: Int
                if digits.count <= 4 { signed = Int(Int16(truncatingIfNeeded: value)) }
                else if digits.count <= 8 { signed = Int(Int32(truncatingIfNeeded: value)) }
                else { signed = Int(Int64(bitPattern: value)) }
                emit(.integer(signed))
                continue
            }
            if character == "#", let (serial, length) = dateLiteral(characters, from: index) {
                emit(.date(serial))
                index += length
                continue
            }
            if character.isLetter || character == "_" {
                var name = ""
                while let next = peek(), next.isLetter || next.isNumber || next == "_" {
                    name.append(next)
                    index += 1
                }
                // A type-declaration suffix belongs to the name and says nothing
                // the interpreter needs beyond what the value carries.
                if let next = peek(), "%&@!#$^".contains(next) {
                    let after = peek(1)
                    if after == nil || !(after!.isLetter || after!.isNumber || after == "_") { index += 1 }
                }
                if name.lowercased() == "rem", tokens.last.map({ $0.token == .newline || $0.token == .symbol(":") }) ?? true {
                    index = skipComment(characters, from: index, line: &line)
                    continue
                }
                emit(.identifier(name))
                continue
            }
            if character == "[" {
                // `[A1]` is shorthand for `Evaluate("A1")`.
                var text = ""
                index += 1
                while let next = peek(), next != "]", next != "\n" {
                    text.append(next)
                    index += 1
                }
                guard peek() == "]" else { throw VBASyntaxError(message: VBASyntaxError.text("Macro.Syntax.UnterminatedBracket"), line: line) }
                index += 1
                emit(.identifier("Evaluate"))
                emit(.symbol("("))
                emit(.string(text))
                emit(.symbol(")"))
                continue
            }
            let two = peek(1).map { String([character, $0]) }
            if let two, ["<>", "<=", ">=", ":=", "=<", "=>"].contains(two) {
                emit(.symbol(["=<": "<=", "=>": ">="][two] ?? two))
                index += 2
                continue
            }
            // `#` also marks file numbers, as in `Close #1`: file I/O cannot
            // run here, but it should not stop the rest of the module parsing.
            if "+-*/\\^&=<>.,():;!#".contains(character) {
                emit(.symbol(String(character)))
                index += 1
                continue
            }
            throw VBASyntaxError(message: VBASyntaxError.text("Macro.Syntax.UnexpectedCharacter", String(character)), line: line)
        }
        emitNewline()
        tokens.append(VBASourceToken(token: .end, line: line, followsSpace: true))
        return tokens
    }

    /// A comment runs to the end of the line, and a continuation carries it
    /// onto the next one just as it would code.
    private static func skipComment(_ characters: [Character], from start: Int, line: inout Int) -> Int {
        var index = start
        while index < characters.count, characters[index] != "\n" {
            if characters[index] == "_", index > start, characters[index - 1] == " " {
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead] == " " { lookahead += 1 }
                if lookahead < characters.count, characters[lookahead] == "\n" {
                    index = lookahead + 1
                    line += 1
                    continue
                }
            }
            index += 1
        }
        return index
    }

    /// `.5` is a number unless it follows something it could be a member of.
    private static func isMemberDot(_ tokens: [VBASourceToken], _ followsSpace: Bool) -> Bool {
        guard !followsSpace, let last = tokens.last?.token else { return false }
        switch last {
        case .identifier, .symbol(")"): return true
        default: return false
        }
    }

    private static func radixPrefix(_ character: Character) -> Int? {
        switch character {
        case "H", "h": return 16
        case "O", "o": return 8
        default: return nil
        }
    }

    private static func number(_ characters: [Character], from index: inout Int, line: Int) throws -> VBAToken {
        var text = ""
        var isFloating = false
        while index < characters.count {
            let character = characters[index]
            if character.isNumber {
                text.append(character)
            } else if character == ".", !isFloating {
                isFloating = true
                text.append(character)
            } else if character == "E" || character == "e" || character == "D" || character == "d",
                      index + 1 < characters.count,
                      characters[index + 1].isNumber || "+-".contains(characters[index + 1]) {
                isFloating = true
                text.append("e")
                index += 1
                text.append(characters[index])
            } else {
                break
            }
            index += 1
        }
        var forcesFloating = false
        if index < characters.count, "%&@!#^".contains(characters[index]) {
            forcesFloating = "!#@".contains(characters[index])
            index += 1
        }
        if !isFloating, !forcesFloating, let value = Int(text) { return .integer(value) }
        guard let value = Double(text) else { throw VBASyntaxError(message: VBASyntaxError.text("Macro.Syntax.MalformedNumber"), line: line) }
        return .double(value)
    }

    /// `#2024-01-31#`, `#1/31/2024#`, `#1/31/2024 13:45#`, `#13:45:00#`. A `#`
    /// that does not open one of these is something else — a file number, say.
    private static func dateLiteral(_ characters: [Character], from start: Int) -> (Double, Int)? {
        var end = start + 1
        while end < characters.count, characters[end] != "#", characters[end] != "\n", end - start < 40 { end += 1 }
        guard end < characters.count, characters[end] == "#", end > start + 1 else { return nil }
        let text = String(characters[(start + 1)..<end]).trimmingCharacters(in: .whitespaces)
        guard let serial = VBADate.parse(text) else { return nil }
        return (serial, end - start + 1)
    }
}

/// Dates as VBA keeps them: OLE Automation serials, whole days since
/// 30 December 1899 plus the time as a fraction — which for any date after
/// February 1900 is the same number a spreadsheet cell holds.
public enum VBADate {
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let epoch = DateComponents(calendar: calendar, year: 1899, month: 12, day: 30).date!

    public static func serial(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Double? {
        // DateSerial rolls months and days over, so normalise through the calendar.
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let withMonth = calendar.date(byAdding: .month, value: month - 1, to: start),
              let date = calendar.date(byAdding: .day, value: day - 1, to: withMonth) else { return nil }
        let days = (date.timeIntervalSince(epoch) / 86_400).rounded()
        return days + Double(hour * 3600 + minute * 60 + second) / 86_400
    }

    public static func components(_ serial: Double) -> DateComponents {
        // Round to the second so 0.1 days does not come out as 2:23:59.
        let seconds = (serial * 86_400).rounded()
        let date = epoch.addingTimeInterval(seconds)
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    }

    public static func date(_ serial: Double) -> Date {
        epoch.addingTimeInterval((serial * 86_400).rounded())
    }

    public static func serial(_ date: Date) -> Double {
        date.timeIntervalSince(epoch) / 86_400
    }

    /// The forms VBA accepts in a literal and in `CDate`: ISO dates, US-style
    /// month/day/year, and an optional time with AM/PM.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var datePart = trimmed
        var timePart = ""
        if let space = trimmed.firstIndex(of: " "), trimmed.contains(":") || trimmed.uppercased().hasSuffix("M") {
            datePart = String(trimmed[..<space])
            timePart = String(trimmed[trimmed.index(after: space)...])
        }
        if timePart.isEmpty, datePart.contains(":") {
            timePart = datePart
            datePart = ""
        }
        var serial = 0.0
        if !datePart.isEmpty {
            let separators = CharacterSet(charactersIn: "/-.")
            let parts = datePart.components(separatedBy: separators).compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            let (year, month, day): (Int, Int, Int)
            if datePart.components(separatedBy: separators)[0].count == 4 {
                (year, month, day) = (parts[0], parts[1], parts[2])
            } else {
                (month, day, year) = (parts[0], parts[1], parts[2] < 100 ? (parts[2] < 30 ? 2000 : 1900) + parts[2] : parts[2])
            }
            guard (1...12).contains(month), (1...31).contains(day),
                  let value = self.serial(year: year, month: month, day: day) else { return nil }
            serial = value
        }
        if !timePart.isEmpty {
            var clock = timePart.uppercased()
            var offset = 0
            if clock.hasSuffix("PM") || clock.hasSuffix("AM") {
                let isPM = clock.hasSuffix("PM")
                clock = String(clock.dropLast(2)).trimmingCharacters(in: .whitespaces)
                offset = isPM ? 12 : 0
                if let hour = Int(clock.split(separator: ":").first ?? ""), hour == 12 { offset -= 12 }
            }
            let pieces = clock.split(separator: ":").compactMap { Int($0) }
            guard (1...3).contains(pieces.count) else { return nil }
            let hour = pieces[0] + offset
            let minute = pieces.count > 1 ? pieces[1] : 0
            let second = pieces.count > 2 ? pieces[2] : 0
            guard (0..<24).contains(hour), (0..<60).contains(minute), (0..<60).contains(second) else { return nil }
            serial += Double(hour * 3600 + minute * 60 + second) / 86_400
        }
        return serial
    }
}
