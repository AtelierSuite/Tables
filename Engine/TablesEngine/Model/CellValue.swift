import Foundation

/// The evaluated content of a cell.
public enum CellValue: Hashable, Sendable {
    case empty
    case number(Double)
    case text(String)
    case boolean(Bool)
    case error(CellError)

    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }

    /// Numeric coercion used by arithmetic and most functions.
    public var numericValue: Double? {
        switch self {
        case .empty: return 0
        case .number(let value): return value
        case .boolean(let flag): return flag ? 1 : 0
        case .text(let string):
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : Double(trimmed)
        case .error: return nil
        }
    }

    /// String coercion used by text functions and concatenation.
    public var stringValue: String {
        switch self {
        case .empty: return ""
        case .number(let value): return Self.plainNumberString(value)
        case .text(let string): return string
        case .boolean(let flag): return flag ? "TRUE" : "FALSE"
        case .error(let error): return error.rawValue
        }
    }

    public var errorValue: CellError? {
        if case .error(let error) = self { return error }
        return nil
    }

    /// Renders a double the way a spreadsheet does by default: no trailing zeros,
    /// scientific notation only for extreme magnitudes.
    public static func plainNumberString(_ value: Double) -> String {
        if value.isNaN { return CellError.numberError.rawValue }
        if value.isInfinite { return CellError.divideByZero.rawValue }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        let magnitude = abs(value)
        if magnitude != 0, magnitude < 1e-9 || magnitude >= 1e15 {
            return String(format: "%.8E", value)
        }
        var text = String(format: "%.10f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// The classic spreadsheet error sentinels.
public enum CellError: String, Hashable, Sendable, CaseIterable {
    case divideByZero = "#DIV/0!"
    case valueError = "#VALUE!"
    case referenceError = "#REF!"
    case nameError = "#NAME?"
    case numberError = "#NUM!"
    case notAvailable = "#N/A"
    case nullError = "#NULL!"
    /// A dynamic array result with no room to spill into.
    case spill = "#SPILL!"
    /// A calculation Excel's engine cannot represent, such as an empty array
    /// or a LAMBDA left uncalled in a cell.
    case calc = "#CALC!"
    /// Shown in the grid when a formula depends on itself. Excel has no such
    /// literal — it reports circularity out of band — so this one is ours.
    case circularReference = "#CIRC!"

    /// The literal to store in a workbook. OOXML defines a closed set of error
    /// values, and writing anything outside it makes the file unreadable, so the
    /// newer errors — which Excel itself stores as `#VALUE!` plus metadata —
    /// and the app's own sentinel are mapped onto the nearest standard one.
    public var ooxmlValue: String {
        switch self {
        case .spill, .calc, .circularReference: return CellError.valueError.rawValue
        default: return rawValue
        }
    }

    /// The number `ERROR.TYPE` reports.
    public var typeNumber: Int {
        switch self {
        case .nullError: return 1
        case .divideByZero: return 2
        case .valueError, .circularReference: return 3
        case .referenceError: return 4
        case .nameError: return 5
        case .numberError: return 6
        case .notAvailable: return 7
        case .spill: return 9
        case .calc: return 14
        }
    }
}

/// Errors travel through formula functions as thrown values.
extension CellError: Error {}
