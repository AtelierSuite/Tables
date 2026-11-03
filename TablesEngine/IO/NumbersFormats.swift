import Foundation

/// Numbers' number formats, `TSK.FormatStructArchive`s, as the Excel format
/// codes Tables shows cells in and saves them with.
///
/// A cell keeps a key into its table's list of formats for each kind of
/// value it could hold — one for numbers, one for currency, one for dates
/// and so on — and the one for the kind it holds is the one shown.
enum NumbersFormats {
    /// Values of a format's `format_type`.
    enum FormatType {
        static let decimal: UInt64 = 256
        static let currency: UInt64 = 257
        static let percentage: UInt64 = 258
        static let scientific: UInt64 = 259
        static let text: UInt64 = 260
        static let date: UInt64 = 261
    }

    /// Fields of a `TSK.FormatStructArchive`.
    enum Field {
        static let type = 1
        static let decimalPlaces = 2
        static let currencyCode = 3
        static let negativeStyle = 4
        static let showsThousandsSeparator = 5
        static let usesAccountingStyle = 6
        static let dateTimeFormat = 14
    }

    /// Fields of a cell's storage holding a key into the table's formats,
    /// for the kind of value that format is for.
    enum StorageField {
        static let number: UInt32 = 0x2000
        static let currency: UInt32 = 0x4000
        static let date: UInt32 = 0x8000
    }

    /// The storage field whose format a cell of `type` is shown in, or nil
    /// for a kind of value Tables shows its own way.
    static func storageField(forCellType type: UInt8) -> UInt32? {
        switch type {
        case NumbersCellStorage.CellType.number: return StorageField.number
        case NumbersCellStorage.CellType.currency: return StorageField.currency
        case NumbersCellStorage.CellType.date: return StorageField.date
        default: return nil
        }
    }

    /// Decimal places at or above this mean "as many as the value needs".
    private static let automaticDecimalPlaces: UInt64 = 253

    /// The Excel format code for `format`, or nil for one Tables has no
    /// code for. `language` is the document's, which names its months.
    static func code(for format: ProtobufMessage, language: String?) -> String? {
        let decimals = format.uint(Field.decimalPlaces).flatMap { $0 < automaticDecimalPlaces ? Int($0) : nil }
        let grouped = format.bool(Field.showsThousandsSeparator)
        switch format.uint(Field.type) {
        case FormatType.decimal:
            let body = decimals.map { digits(decimals: $0, grouped: grouped) }
                ?? (grouped ? "#,##0.##########" : "General")
            return body == "General" ? body : signed(body, style: format.uint(Field.negativeStyle))
        case FormatType.currency:
            let code = format.string(Field.currencyCode) ?? "USD"
            let places = decimals ?? (zeroDecimalCurrencies.contains(code) ? 0 : 2)
            let symbol = "\"\(currencySymbol(code))\"" + (format.bool(Field.usesAccountingStyle) ? "* " : "")
            return signed(symbol + digits(decimals: places, grouped: grouped), style: format.uint(Field.negativeStyle))
        case FormatType.percentage:
            return digits(decimals: decimals ?? 0, grouped: grouped) + "%"
        case FormatType.scientific:
            return digits(decimals: decimals ?? 2, grouped: false) + "E+00"
        case FormatType.text:
            return "@"
        case FormatType.date:
            return format.string(Field.dateTimeFormat).flatMap { excelDateCode(fromUnicodePattern: $0, language: language) }
        default:
            return nil
        }
    }

    private static func digits(decimals: Int, grouped: Bool) -> String {
        (grouped ? "#,##0" : "0") + (decimals > 0 ? "." + String(repeating: "0", count: decimals) : "")
    }

    /// `body` with the way Numbers shows negative numbers in it: with a
    /// minus sign, in red, in parentheses, or in red parentheses.
    private static func signed(_ body: String, style: UInt64?) -> String {
        switch style {
        case 1: return "\(body);[Red]\(body)"
        case 2: return "\(body);(\(body))"
        case 3: return "\(body);[Red](\(body))"
        default: return body
        }
    }

    /// Currencies whose amounts have no minor unit.
    private static let zeroDecimalCurrencies: Set<String> = ["JPY", "KRW", "VND", "CLP", "ISK", "HUF", "TWD", "XAF", "XOF", "XPF"]

    /// How Numbers writes a currency: its symbol where it has a well-known
    /// one, its code otherwise.
    static func currencySymbol(_ code: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        return formatter.currencySymbol ?? code
    }

    // MARK: - Dates

    /// Languages whose month names are the month's number and a counter
    /// word, so `MMMM` comes out as `10月` rather than `October`.
    private static let numberedMonths: [String: String] = ["ja": "月", "zh": "月", "ko": "월"]

    /// A Unicode date pattern, as Numbers keeps one, in Excel's tokens.
    /// Everything that isn't a date or time field is quoted as it stands.
    static func excelDateCode(fromUnicodePattern pattern: String, language: String?) -> String? {
        let characters = Array(pattern)
        let counter = language.flatMap { numberedMonths[String($0.prefix(2))] }
        var code = ""
        var literal = ""
        func flushLiteral() {
            guard !literal.isEmpty else { return }
            code += "\"" + literal.replacingOccurrences(of: "\"", with: "") + "\""
            literal = ""
        }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "'" {
                // Quoted text, where '' is an apostrophe.
                index += 1
                if index < characters.count, characters[index] == "'" {
                    literal.append("'")
                    index += 1
                    continue
                }
                while index < characters.count, characters[index] != "'" {
                    literal.append(characters[index])
                    index += 1
                }
                index += 1
                continue
            }
            guard character.isASCII, character.isLetter else {
                if " -/:.,".contains(character) {
                    flushLiteral()
                    code.append(character)
                } else {
                    literal.append(character)
                }
                index += 1
                continue
            }
            var count = 1
            while index + count < characters.count, characters[index + count] == character { count += 1 }
            index += count
            let token: String?
            switch character {
            case "y", "u", "Y":
                token = count == 2 ? "yy" : "yyyy"
            case "M", "L":
                if count >= 3, let counter {
                    flushLiteral()
                    code += "m"
                    literal += counter
                    continue
                }
                token = String(repeating: "m", count: min(count, 5))
            case "d":
                token = count >= 2 ? "dd" : "d"
            case "E", "e", "c":
                token = count >= 4 ? "dddd" : "ddd"
            case "H", "k":
                token = count >= 2 ? "hh" : "h"
            case "h", "K":
                token = count >= 2 ? "hh" : "h"
            case "m":
                token = count >= 2 ? "mm" : "m"
            case "s":
                token = count >= 2 ? "ss" : "s"
            case "S":
                token = "." + String(repeating: "0", count: min(count, 3))
            case "a":
                token = "AM/PM"
            default:
                // Eras, quarters, weeks and zones have no Excel token.
                token = nil
            }
            guard let token else { continue }
            flushLiteral()
            code += token
        }
        flushLiteral()
        return CellFormatter.isDateFormat(code) ? code : nil
    }
}
