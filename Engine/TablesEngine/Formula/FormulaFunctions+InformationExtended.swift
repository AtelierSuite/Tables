import Foundation

extension FormulaFunctions {
    public static let informationExtendedFunctions: [String: FunctionSpec] = [
        "ISNA": FunctionSpec(1...1) { call throws(CellError) in .boolean(call.scalar(0).errorValue == .notAvailable) },
        "ISERR": FunctionSpec(1...1) { call throws(CellError) in
            let error = call.scalar(0).errorValue
            return .boolean(error != nil && error != .notAvailable)
        },
        "ISNONTEXT": FunctionSpec(1...1) { call throws(CellError) in .boolean(!call.scalar(0).isText) },
        "ISREF": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in .boolean(call.isReference(0)) },
        "ISFORMULA": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            guard let reference = call.reference(0) else { throw .valueError }
            return .boolean(call.context.cell(at: reference.range.start, sheetName: reference.sheet)?.formula != nil)
        },
        "ERROR.TYPE": FunctionSpec(1...1) { call throws(CellError) in
            guard let error = call.scalar(0).errorValue else { throw .notAvailable }
            return .number(Double(error.typeNumber))
        },
        "N": FunctionSpec(1...1) { call throws(CellError) in
            switch call.scalar(0) {
            case .number(let number): return .number(number)
            case .boolean(let flag): return .number(flag ? 1 : 0)
            case .error(let error): throw error
            case .text, .empty: return .number(0)
            }
        },
        "TYPE": FunctionSpec(1...1, lifts: .none) { call throws(CellError) in
            let value = call.value(0)
            switch value {
            case .lambda: return .number(128)
            case .matrix where value.isArray: return .number(64)
            default:
                switch value.single {
                case .number, .empty: return .number(1)
                case .text: return .number(2)
                case .boolean: return .number(4)
                case .error: return .number(16)
                }
            }
        },
        "SHEET": FunctionSpec(0...1, lifts: .none) { call throws(CellError) in
            guard !call.isMissing(0) else {
                guard let number = call.context.sheetNumber(named: nil) else { throw .notAvailable }
                return .number(Double(number))
            }
            if let reference = call.reference(0) {
                guard let number = call.context.sheetNumber(named: reference.sheet) else { throw .referenceError }
                return .number(Double(number))
            }
            guard case .text(let name) = call.scalar(0), let number = call.context.sheetNumber(named: name) else {
                throw .notAvailable
            }
            return .number(Double(number))
        },
        "SHEETS": FunctionSpec(0...1, lifts: .none) { call throws(CellError) in
            guard !call.isMissing(0) else { return .number(Double(call.context.sheetCount)) }
            if case .sheetSpan(let first, let last, _, _) = call.nodes[0] {
                guard let sheets = call.context.sheetNames(from: first, to: last) else { throw .referenceError }
                return .number(Double(sheets.count))
            }
            guard call.reference(0) != nil else { throw .valueError }
            return .number(1)
        },
        "CELL": FunctionSpec(1...2, lifts: .only([0])) { call throws(CellError) in
            try FormulaInformation.cell(call)
        },
        "INFO": FunctionSpec(1...1) { call throws(CellError) in
            switch try call.text(0).lowercased() {
            case "directory": return .text("")
            case "numfile": return .number(Double(call.context.sheetCount))
            case "origin": return .text("$A:$A$1")
            case "osversion":
                let version = ProcessInfo.processInfo.operatingSystemVersion
                return .text("Macintosh (Intel) Version \(version.majorVersion).\(version.minorVersion)")
            case "recalc": return .text("Automatic")
            case "release": return .text("16.0")
            case "system": return .text("mac")
            default: throw .valueError
            }
        },
    ]
}

extension FormulaInformation {
    /// `CELL`: facts about a cell's position, contents and formatting.
    public static func cell(_ call: FunctionCall) throws(CellError) -> FormulaValue {
        let info = try call.text(0).lowercased()
        let reference: FormulaReference
        if call.isMissing(1) {
            guard let address = call.evaluator.currentAddress else { throw .valueError }
            reference = FormulaReference(sheet: nil, address: address)
        } else {
            guard let named = call.reference(1) else { throw .valueError }
            reference = named
        }
        let address = reference.range.start
        let stored = call.context.cell(at: address, sheetName: reference.sheet) ?? Cell()
        let value = call.context.value(at: address, sheetName: reference.sheet)
        switch info {
        case "address":
            var text = "$" + CellAddress.columnName(address.column) + "$" + String(address.row + 1)
            if let sheet = reference.sheet, sheet.caseInsensitiveCompare(call.context.currentSheetName) != .orderedSame {
                text = FormulaReferenceText.quotedSheet(sheet) + "!" + text
            }
            return .text(text)
        case "col": return .number(Double(address.column + 1))
        case "row": return .number(Double(address.row + 1))
        case "contents": return .scalar(value)
        case "type":
            if stored.formula == nil, value.isEmpty { return .text("b") }
            return .text(value.isText ? "l" : "v")
        case "width":
            let width = call.context.columnWidth(address.column, sheetName: reference.sheet) ?? 8.43
            return .number(width.rounded(.down))
        case "prefix":
            guard value.isText else { return .text("") }
            switch stored.style.horizontalAlignment {
            case .center: return .text("^")
            case .trailing: return .text("\"")
            default: return .text("'")
            }
        case "format": return .text(formatCode(stored.style.numberFormat))
        case "color":
            return .number(stored.style.numberFormat.contains("[Red]") ? 1 : 0)
        case "parentheses":
            return .number(stored.style.numberFormat.split(separator: ";").first?.contains("(") == true ? 1 : 0)
        case "protect": return .number(1)
        case "filename": return .text("")
        default: throw .valueError
        }
    }

    /// The short code `CELL("format")` gives for a number format: G for
    /// General, F for fixed, `,` for grouped, C for currency, P for percent,
    /// S for scientific and D1–D9 for the date and time styles.
    public static func formatCode(_ format: String) -> String {
        let code = format.trimmingCharacters(in: .whitespaces)
        if code.isEmpty || code.caseInsensitiveCompare("General") == .orderedSame { return "G" }
        let positive = String(code.split(separator: ";", omittingEmptySubsequences: false).first ?? "")
        let lowered = positive.lowercased()
        var suffix = ""
        if code.contains("[Red]") || code.contains("[RED]") { suffix += "-" }
        if positive.contains("(") { suffix += "()" }
        if CellFormatter.isDateFormat(code) {
            let hasTime = lowered.contains("h") || lowered.contains("s")
            let hasMeridiem = lowered.contains("am/pm") || lowered.contains("a/p")
            if hasTime {
                if lowered.contains("s") { return (hasMeridiem ? "D6" : "D8") + suffix }
                return (hasMeridiem ? "D7" : "D9") + suffix
            }
            if lowered.contains("y") {
                if lowered.contains("mmm") { return (lowered.contains("d") ? "D1" : "D3") + suffix }
                return "D4" + suffix
            }
            return (lowered.contains("mmm") ? "D2" : "D5") + suffix
        }
        let decimals: Int
        if let point = positive.firstIndex(of: ".") {
            decimals = positive[positive.index(after: point)...].prefix { $0 == "0" || $0 == "#" }.count
        } else {
            decimals = 0
        }
        if positive.contains("%") { return "P\(decimals)" + suffix }
        if positive.uppercased().contains("E+") || positive.uppercased().contains("E-") { return "S\(decimals)" + suffix }
        if positive.contains("$") || positive.contains("€") || positive.contains("£") || positive.contains("¥") {
            return "C\(decimals)" + suffix
        }
        if positive.contains(",") { return ",\(decimals)" + suffix }
        return "F\(decimals)" + suffix
    }
}
