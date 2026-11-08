import Foundation

extension FormulaFunctions {
    public static let textFunctions: [String: FunctionSpec] = [
        "LEN": FunctionSpec(1...1) { call throws(CellError) in .number(Double(try call.text(0).utf16.count)) },
        "LOWER": FunctionSpec(1...1) { call throws(CellError) in .text(try call.text(0).lowercased()) },
        "UPPER": FunctionSpec(1...1) { call throws(CellError) in .text(try call.text(0).uppercased()) },
        "PROPER": FunctionSpec(1...1) { call throws(CellError) in .text(FormulaText.proper(try call.text(0))) },
        "TRIM": FunctionSpec(1...1) { call throws(CellError) in
            .text(try call.text(0).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
        },
        "EXACT": FunctionSpec(2...2) { call throws(CellError) in .boolean(try call.text(0) == call.text(1)) },
        "LEFT": FunctionSpec(1...2) { call throws(CellError) in
            let text = try call.text(0)
            let count = try call.integer(1, default: 1)
            guard count >= 0 else { throw .valueError }
            return .text(FormulaText.slice(text, from: 0, length: count))
        },
        "RIGHT": FunctionSpec(1...2) { call throws(CellError) in
            let text = try call.text(0)
            let count = try call.integer(1, default: 1)
            guard count >= 0 else { throw .valueError }
            let length = text.utf16.count
            return .text(FormulaText.slice(text, from: max(0, length - count), length: count))
        },
        "MID": FunctionSpec(3...3) { call throws(CellError) in
            let text = try call.text(0)
            let start = try call.integer(1)
            let count = try call.integer(2)
            guard start >= 1, count >= 0 else { throw .valueError }
            return .text(FormulaText.slice(text, from: start - 1, length: count))
        },
        "REPT": FunctionSpec(2...2) { call throws(CellError) in
            let text = try call.text(0)
            let times = try call.integer(1)
            guard times >= 0, text.utf16.count * times <= FormulaText.maximumLength else { throw .valueError }
            return .text(String(repeating: text, count: times))
        },
        "FIND": FunctionSpec(2...3) { call throws(CellError) in
            try FormulaText.find(call, caseSensitive: true)
        },
        "SEARCH": FunctionSpec(2...3) { call throws(CellError) in
            try FormulaText.find(call, caseSensitive: false)
        },
        "SUBSTITUTE": FunctionSpec(3...4) { call throws(CellError) in
            let text = try call.text(0)
            let old = try call.text(1)
            let new = try call.text(2)
            guard !old.isEmpty else { return .text(text) }
            guard !call.isMissing(3) else { return .text(text.replacingOccurrences(of: old, with: new)) }
            let occurrence = try call.integer(3)
            guard occurrence >= 1 else { throw .valueError }
            return .text(FormulaText.replace(text, old, new, occurrence: occurrence))
        },
        "REPLACE": FunctionSpec(4...4) { call throws(CellError) in
            let text = try call.text(0)
            let start = try call.integer(1)
            let count = try call.integer(2)
            let insert = try call.text(3)
            guard start >= 1, count >= 0 else { throw .valueError }
            let length = text.utf16.count
            let head = FormulaText.slice(text, from: 0, length: start - 1)
            let tail = FormulaText.slice(text, from: start - 1 + count, length: max(0, length))
            return .text(head + insert + tail)
        },
        "CONCAT": FunctionSpec(1...253, lifts: .none) { call throws(CellError) in
            try FormulaText.limited(call.cells().map { cell throws(CellError) in try cell.coercedText() }.joined())
        },
        "CONCATENATE": FunctionSpec(1...255) { call throws(CellError) in
            try FormulaText.limited((0..<call.count).map { index throws(CellError) in try call.text(index) }.joined())
        },
        "TEXTJOIN": FunctionSpec(2...252, lifts: .none) { call throws(CellError) in
            let delimiters = try call.matrix(0).flatMap { $0 }.map { cell throws(CellError) in try cell.coercedText() }
            let skipsBlanks = try call.boolean(1)
            var pieces: [String] = []
            for cell in try call.cells(from: 2) {
                let text = try cell.coercedText()
                if skipsBlanks, text.isEmpty { continue }
                pieces.append(text)
            }
            var joined = ""
            for (position, piece) in pieces.enumerated() {
                if position > 0, !delimiters.isEmpty { joined += delimiters[(position - 1) % delimiters.count] }
                joined += piece
            }
            return try FormulaText.limited(joined)
        },
        "TEXT": FunctionSpec(2...2) { call throws(CellError) in
            let value = call.scalar(0)
            if let error = value.errorValue { throw error }
            let format = try call.text(1)
            // Text that reads as a number is formatted as that number.
            if case .text(let text) = value, let number = FormulaValueParser.number(from: text) {
                return .text(CellFormatter.displayText(for: .number(number), format: format))
            }
            return .text(CellFormatter.displayText(for: value, format: format))
        },
        "VALUE": FunctionSpec(1...1) { call throws(CellError) in
            switch call.scalar(0) {
            case .number(let number): return .number(number)
            case .empty: return .number(0)
            case .text(let text):
                guard let number = FormulaValueParser.number(from: text) else { throw .valueError }
                return .number(number)
            case .error(let error): throw error
            case .boolean: throw .valueError
            }
        },
        "CHAR": FunctionSpec(1...1) { call throws(CellError) in
            let code = try call.integer(0)
            guard (1...255).contains(code) else { throw .valueError }
            return .text(String(FormulaText.windows1252Character(code)))
        },
        "CODE": FunctionSpec(1...1) { call throws(CellError) in
            guard let first = try call.text(0).first else { throw .valueError }
            return .number(Double(FormulaText.windows1252Code(first)))
        },
    ]
}

/// Text handling shared by the text functions.
public enum FormulaText {
    /// The longest text a cell can hold.
    public static let maximumLength = 32_767

    public static func limited(_ text: String) throws(CellError) -> FormulaValue {
        guard text.utf16.count <= maximumLength else { throw .valueError }
        return .text(text)
    }

    /// A substring by UTF-16 position, which is how Excel counts characters.
    public static func slice(_ text: String, from start: Int, length: Int) -> String {
        let units = Array(text.utf16)
        guard start < units.count, length > 0 else { return "" }
        let lower = max(0, start)
        let upper = min(units.count, lower + length)
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    /// Capitalises each letter that follows something other than a letter,
    /// so `o'neil` becomes `O'Neil`, as Excel's `PROPER` does.
    public static func proper(_ text: String) -> String {
        var result = ""
        var previousIsLetter = false
        for character in text {
            let piece = String(character)
            result += previousIsLetter ? piece.lowercased() : piece.uppercased()
            previousIsLetter = character.isLetter
        }
        return result
    }

    /// `FIND` and `SEARCH`. `SEARCH` ignores case and honours wildcards.
    public static func find(_ call: FunctionCall, caseSensitive: Bool) throws(CellError) -> FormulaValue {
        let needle = try call.text(0)
        let haystack = try call.text(1)
        let start = try call.integer(2, default: 1)
        let units = Array(haystack.utf16)
        guard start >= 1, start <= units.count + 1 else { throw .valueError }
        if needle.isEmpty { return .number(Double(start)) }
        let pattern = caseSensitive || !FormulaWildcard.hasWildcards(needle) ? nil : needle + "*"
        for offset in (start - 1)..<units.count {
            let rest = String(decoding: units[offset...], as: UTF16.self)
            let found: Bool
            if let pattern {
                found = FormulaWildcard.matches(rest, pattern: pattern)
            } else if caseSensitive {
                found = rest.hasPrefix(needle)
            } else {
                found = rest.range(of: needle, options: [.caseInsensitive, .anchored]) != nil
            }
            if found { return .number(Double(offset + 1)) }
        }
        throw .valueError
    }

    public static func replace(_ text: String, _ old: String, _ new: String, occurrence: Int) -> String {
        var result = text
        var searchStart = result.startIndex
        var seen = 0
        while let found = result.range(of: old, range: searchStart..<result.endIndex) {
            seen += 1
            if seen == occurrence {
                result.replaceSubrange(found, with: new)
                return result
            }
            searchStart = found.upperBound
        }
        return result
    }

    /// Windows-1252's characters for 128–159, where it differs from Latin-1.
    private static let windows1252High: [UInt32] = [
        0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152,
        0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122,
        0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
    ]

    public static func windows1252Character(_ code: Int) -> Character {
        let scalar = (128...159).contains(code) ? windows1252High[code - 128] : UInt32(code)
        return Character(UnicodeScalar(scalar) ?? "?")
    }

    public static func windows1252Code(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first?.value else { return 63 }
        if let index = windows1252High.firstIndex(of: scalar), scalar > 0xFF { return 128 + index }
        if scalar <= 0xFF { return Int(scalar) }
        return 63  // `?`, as Excel answers for a character outside the code page.
    }
}
