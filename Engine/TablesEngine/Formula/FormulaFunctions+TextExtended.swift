import Foundation

extension FormulaFunctions {
    public static let textExtendedFunctions: [String: FunctionSpec] = {
        var table: [String: FunctionSpec] = [
            "CLEAN": FunctionSpec(1...1) { call throws(CellError) in
                .text(String(String.UnicodeScalarView(try call.text(0).unicodeScalars.filter { $0.value >= 32 })))
            },
            "T": FunctionSpec(1...1) { call throws(CellError) in
                switch call.scalar(0) {
                case .text(let text): return .text(text)
                case .error(let error): throw error
                default: return .text("")
                }
            },
            "UNICHAR": FunctionSpec(1...1) { call throws(CellError) in
                let code = try call.integer(0)
                guard code >= 1, let scalar = UnicodeScalar(UInt32(clamping: code)) else { throw .valueError }
                return .text(String(Character(scalar)))
            },
            "UNICODE": FunctionSpec(1...1) { call throws(CellError) in
                guard let scalar = try call.text(0).unicodeScalars.first else { throw .valueError }
                return .number(Double(scalar.value))
            },
            "FIXED": FunctionSpec(1...3) { call throws(CellError) in
                let value = try call.number(0)
                let decimals = try call.integer(1, default: 2)
                let ungrouped = try call.boolean(2, default: false)
                guard decimals <= 127 else { throw .valueError }
                return .text(FormulaText.fixed(value, decimals: decimals, grouped: !ungrouped))
            },
            "NUMBERVALUE": FunctionSpec(1...3) { call throws(CellError) in
                let text = try call.text(0)
                let decimal = try call.text(1, default: ".")
                let group = try call.text(2, default: ",")
                let groupMark = group.first ?? ","
                guard let decimalMark = decimal.first, decimalMark != groupMark else { throw .valueError }
                return .number(try FormulaText.numberValue(text, decimal: decimalMark, group: groupMark))
            },
            "TEXTBEFORE": FunctionSpec(2...6, lifts: .only([0, 2, 3, 4])) { call throws(CellError) in
                try FormulaText.split(call, keepingBefore: true)
            },
            "TEXTAFTER": FunctionSpec(2...6, lifts: .only([0, 2, 3, 4])) { call throws(CellError) in
                try FormulaText.split(call, keepingBefore: false)
            },
            "TEXTSPLIT": FunctionSpec(2...6, lifts: .none) { call throws(CellError) in
                try FormulaText.textSplit(call)
            },
            "VALUETOTEXT": FunctionSpec(1...2) { call throws(CellError) in
                let strict = try call.integer(1, default: 0)
                guard strict == 0 || strict == 1 else { throw .valueError }
                return .text(FormulaText.valueText(call.scalar(0), strict: strict == 1))
            },
            "ARRAYTOTEXT": FunctionSpec(1...2, lifts: .none) { call throws(CellError) in
                let strict = try call.integer(1, default: 0)
                guard strict == 0 || strict == 1 else { throw .valueError }
                let rows = try call.matrix(0)
                if strict == 1 {
                    let body = rows.map { $0.map { FormulaText.valueText($0, strict: true) }.joined(separator: ",") }
                        .joined(separator: ";")
                    return .text("{" + body + "}")
                }
                return .text(rows.flatMap { $0 }.map { FormulaText.valueText($0, strict: false) }
                    .joined(separator: ", "))
            },
            "REGEXTEST": FunctionSpec(2...3) { call throws(CellError) in
                let text = try call.text(0)
                let expression = try FormulaText.regex(try call.text(1), insensitive: try call.integer(2, default: 0) == 1)
                return .boolean(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
            },
            "REGEXEXTRACT": FunctionSpec(2...4, lifts: .only([0, 1, 3])) { call throws(CellError) in
                try FormulaText.regexExtract(call)
            },
            "REGEXREPLACE": FunctionSpec(3...5) { call throws(CellError) in
                try FormulaText.regexReplace(call)
            },
            "ASC": FunctionSpec(1...1) { call throws(CellError) in
                let text = try call.text(0)
                return .text(text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
            },
            // PHONETIC needs reading guides, which Tables does not retain. Leave
            // it unregistered so imported workbooks keep Excel's saved answer.
            "BAHTTEXT": FunctionSpec(1...1) { call throws(CellError) in
                .text(FormulaText.bahtText(try call.number(0)))
            },
        ]
        let toFullWidth = FunctionSpec(1...1) { call throws(CellError) in
            let text = try call.text(0)
            return .text(text.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? text)
        }
        table["DBCS"] = toFullWidth
        table["JIS"] = toFullWidth
        let dollar = FunctionSpec(1...2) { call throws(CellError) in
            let value = try call.number(0)
            let decimals = try call.integer(1, default: 2)
            guard decimals <= 127 else { throw .valueError }
            let body = "$" + FormulaText.fixed(abs(value), decimals: decimals, grouped: true)
            return .text(value < 0 && FormulaMath.round(value, digits: decimals, rule: .toNearestOrAwayFromZero) != 0
                         ? "(" + body + ")" : body)
        }
        table["DOLLAR"] = dollar
        table["USDOLLAR"] = dollar
        // The byte-counting variants count as the plain ones do outside
        // double-byte locales, which is how Excel behaves in English.
        for (byteName, name) in [("LENB", "LEN"), ("LEFTB", "LEFT"), ("RIGHTB", "RIGHT"), ("MIDB", "MID"),
                                 ("FINDB", "FIND"), ("SEARCHB", "SEARCH"), ("REPLACEB", "REPLACE")] {
            table[byteName] = textFunctions[name]
        }
        return table
    }()
}

extension FormulaText {
    /// A number rounded and written with a fixed count of decimals, grouping
    /// thousands unless told not to. A negative count rounds left of the point.
    public static func fixed(_ value: Double, decimals: Int, grouped: Bool) -> String {
        let rounded = FormulaMath.round(value, digits: decimals, rule: .toNearestOrAwayFromZero)
        let places = max(0, decimals)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouped
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: rounded)) ?? CellValue.plainNumberString(rounded)
    }

    /// `NUMBERVALUE`: a number written with any decimal and group marks.
    public static func numberValue(_ raw: String, decimal: Character, group: Character) throws(CellError) -> Double {
        var text = raw.filter { !$0.isWhitespace }
        if text.isEmpty { return 0 }
        var scale = 1.0
        while text.hasSuffix("%") {
            scale /= 100
            text.removeLast()
        }
        let decimalIndex = text.firstIndex(of: decimal) ?? text.endIndex
        let integer = text[..<decimalIndex]
        let fraction = decimalIndex < text.endIndex ? text[text.index(after: decimalIndex)...] : ""
        // Group marks may only stand in the integer part.
        guard !fraction.contains(group), !fraction.contains(decimal) else { throw .valueError }
        let cleaned = integer.filter { $0 != group } + (fraction.isEmpty ? "" : "." + fraction)
        guard let value = Double(cleaned) else { throw .valueError }
        return value * scale
    }

    /// `TEXTBEFORE` and `TEXTAFTER`.
    public static func split(_ call: FunctionCall, keepingBefore: Bool) throws(CellError) -> FormulaValue {
        let text = try call.text(0)
        let delimiters = try call.matrix(1).flatMap { $0 }.map { cell throws(CellError) in try cell.coercedText() }
        let instance = try call.integer(2, default: 1)
        let insensitive = try call.integer(3, default: 0) == 1
        let matchesEnd = try call.integer(4, default: 0) == 1
        let units = Array(text.utf16)
        guard instance != 0, abs(instance) <= max(1, units.count) else { throw .valueError }

        // Every delimiter occurrence, as UTF-16 ranges, in order.
        var occurrences: [Range<Int>] = []
        if delimiters.contains("") {
            occurrences = instance > 0 ? [0..<0] : [units.count..<units.count]
        } else {
            let haystack = insensitive ? text.lowercased() : text
            let haystackUnits = Array(haystack.utf16)
            var position = 0
            while position < haystackUnits.count {
                var matched: Range<Int>?
                for delimiter in delimiters {
                    let needle = Array((insensitive ? delimiter.lowercased() : delimiter).utf16)
                    guard position + needle.count <= haystackUnits.count,
                          Array(haystackUnits[position..<(position + needle.count)]) == needle else { continue }
                    matched = position..<(position + needle.count)
                    break
                }
                if let matched {
                    occurrences.append(matched)
                    position = matched.upperBound
                } else {
                    position += 1
                }
            }
            if matchesEnd {
                if instance > 0 { occurrences.append(units.count..<units.count) } else { occurrences.insert(0..<0, at: 0) }
            }
        }
        let chosen: Range<Int>?
        if instance > 0 {
            chosen = instance <= occurrences.count ? occurrences[instance - 1] : nil
        } else {
            chosen = -instance <= occurrences.count ? occurrences[occurrences.count + instance] : nil
        }
        guard let chosen else {
            if !call.isMissing(5) { return call.value(5) }
            throw .notAvailable
        }
        let piece = keepingBefore ? units[0..<chosen.lowerBound] : units[chosen.upperBound...]
        return .text(String(decoding: piece, as: UTF16.self))
    }

    /// `TEXTSPLIT`: text cut into a block by column and row delimiters.
    public static func textSplit(_ call: FunctionCall) throws(CellError) -> FormulaValue {
        let text = try call.text(0)
        func delimiters(_ index: Int) throws(CellError) -> [String] {
            guard !call.isMissing(index) else { return [] }
            return try call.matrix(index).flatMap { $0 }.map { cell throws(CellError) in try cell.coercedText() }
                .filter { !$0.isEmpty }
        }
        let columnDelimiters = try delimiters(1)
        let rowDelimiters = try delimiters(2)
        guard !columnDelimiters.isEmpty || !rowDelimiters.isEmpty else { throw .valueError }
        let skipsEmpty = try call.boolean(3, default: false)
        let insensitive = try call.integer(4, default: 0) == 1
        let pad = call.isMissing(5) ? CellValue.error(.notAvailable) : call.scalar(5)

        func pieces(_ text: String, by marks: [String]) -> [String] {
            guard !marks.isEmpty else { return [text] }
            var result: [String] = []
            var current = ""
            var index = text.startIndex
            outer: while index < text.endIndex {
                for mark in marks {
                    let options: String.CompareOptions = insensitive ? [.caseInsensitive, .anchored] : [.anchored]
                    if let found = text.range(of: mark, options: options, range: index..<text.endIndex) {
                        result.append(current)
                        current = ""
                        index = found.upperBound
                        continue outer
                    }
                }
                current.append(text[index])
                index = text.index(after: index)
            }
            result.append(current)
            return skipsEmpty ? result.filter { !$0.isEmpty } : result
        }
        let rows = pieces(text, by: rowDelimiters).map { pieces($0, by: columnDelimiters) }.filter { !$0.isEmpty }
        guard !rows.isEmpty else { throw .calc }
        let width = rows.map(\.count).max() ?? 1
        return .block(rows.map { row in
            row.map(CellValue.text) + [CellValue](repeating: pad, count: width - row.count)
        })
    }

    /// A value as `VALUETOTEXT` and `ARRAYTOTEXT` write it; the strict form
    /// quotes text so it could be pasted back into a formula.
    public static func valueText(_ value: CellValue, strict: Bool) -> String {
        switch value {
        case .text(let text): return strict ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        case .number(let number): return FormulaNumberText.general(number)
        case .boolean(let flag): return flag ? "TRUE" : "FALSE"
        case .error(let error): return error.rawValue
        case .empty: return ""
        }
    }

    public static func regex(_ pattern: String, insensitive: Bool) throws(CellError) -> NSRegularExpression {
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: insensitive ? [.caseInsensitive] : []
        ) else { throw .valueError }
        return expression
    }

    public static func regexExtract(_ call: FunctionCall) throws(CellError) -> FormulaValue {
        let text = try call.text(0)
        let mode = try call.integer(2, default: 0)
        let expression = try regex(try call.text(1), insensitive: try call.integer(3, default: 0) == 1)
        guard (0...2).contains(mode) else { throw .valueError }
        let range = NSRange(text.startIndex..., in: text)
        func substring(_ range: NSRange) -> String {
            Range(range, in: text).map { String(text[$0]) } ?? ""
        }
        switch mode {
        case 0:
            guard let match = expression.firstMatch(in: text, range: range) else { throw .notAvailable }
            return .text(substring(match.range))
        case 1:
            let matches = expression.matches(in: text, range: range)
            guard !matches.isEmpty else { throw .notAvailable }
            return .block(matches.map { [.text(substring($0.range))] })
        default:
            guard let match = expression.firstMatch(in: text, range: range) else { throw .notAvailable }
            guard match.numberOfRanges > 1 else { return .text(substring(match.range)) }
            return .block([(1..<match.numberOfRanges).map { group in
                let groupRange = match.range(at: group)
                return groupRange.location == NSNotFound ? .text("") : .text(substring(groupRange))
            }])
        }
    }

    public static func regexReplace(_ call: FunctionCall) throws(CellError) -> FormulaValue {
        let text = try call.text(0)
        let expression = try regex(try call.text(1), insensitive: try call.integer(4, default: 0) == 1)
        let replacement = try call.text(2)
        let occurrence = try call.integer(3, default: 0)
        let range = NSRange(text.startIndex..., in: text)
        guard occurrence != 0 else {
            return .text(expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement))
        }
        let matches = expression.matches(in: text, range: range)
        let index = occurrence > 0 ? occurrence - 1 : matches.count + occurrence
        guard matches.indices.contains(index) else { return .text(text) }
        let match = matches[index]
        let substitute = expression.replacementString(for: match, in: text, offset: 0, template: replacement)
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: match.range, with: substitute)
        return .text(mutable as String)
    }

    /// A number in Thai words with the baht currency suffix.
    public static func bahtText(_ value: Double) -> String {
        let digits = ["ศูนย์", "หนึ่ง", "สอง", "สาม", "สี่", "ห้า", "หก", "เจ็ด", "แปด", "เก้า"]
        let places = ["", "สิบ", "ร้อย", "พัน", "หมื่น", "แสน"]
        func words(_ number: Int) -> String {
            guard number > 0 else { return "" }
            if number >= 1_000_000 {
                return words(number / 1_000_000) + "ล้าน" + words(number % 1_000_000)
            }
            var result = ""
            let text = String(number)
            let count = text.count
            for (index, character) in text.enumerated() {
                let digit = Int(String(character)) ?? 0
                let place = count - index - 1
                guard digit > 0 else { continue }
                if place == 0, digit == 1, count > 1 {
                    result += "เอ็ด"
                } else if place == 1, digit == 2 {
                    result += "ยี่" + places[1]
                } else if place == 1, digit == 1 {
                    result += places[1]
                } else {
                    result += digits[digit] + places[place]
                }
            }
            return result
        }
        let rounded = FormulaMath.round(abs(value), digits: 2, rule: .toNearestOrAwayFromZero)
        let baht = Int(rounded.rounded(.down))
        let satang = Int(((rounded - Double(baht)) * 100).rounded())
        var result = value < 0 && rounded != 0 ? "ลบ" : ""
        if baht == 0, satang == 0 { return "ศูนย์บาทถ้วน" }
        if baht > 0 { result += words(baht) + "บาท" }
        result += satang == 0 ? "ถ้วน" : words(satang) + "สตางค์"
        return result
    }
}
