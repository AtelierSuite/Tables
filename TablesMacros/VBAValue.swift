import Foundation
import TablesEngine

/// Anything a macro can hold a reference to: a worksheet, a range, a
/// collection, an instance of one of the project's own class modules.
///
/// Every object is confined to the interpreter that made it, which runs on
/// one thread from start to finish.
public protocol VBAObject: AnyObject {
    /// What `TypeName` reports.
    var typeName: String { get }
    /// Reads a property or calls a method. The empty name is the default
    /// member, which is what `obj(1)` and `x = obj` reach.
    func member(_ name: String, _ arguments: VBAArguments, in interpreter: VBAInterpreter) throws -> VBAValue
    /// Assigns a property: `obj.Name = value`, or `obj(1) = value` for the
    /// default member.
    func setMember(_ name: String, _ arguments: VBAArguments, to value: VBAValue,
                   in interpreter: VBAInterpreter) throws
    /// The items `For Each` walks.
    func elements(in interpreter: VBAInterpreter) throws -> [VBAValue]
}

extension VBAObject {
    public func setMember(_ name: String, _: VBAArguments, to _: VBAValue,
                   in _: VBAInterpreter) throws {
        throw VBAError.unsupportedMember(name.isEmpty ? typeName : name)
    }

    public func elements(in _: VBAInterpreter) throws -> [VBAValue] {
        throw VBAError(number: 438, "Object doesn't support this property or method")
    }
}

/// The arguments of a call, positional and named, as values.
public struct VBAArguments {
    /// Nil for an argument left out, as in `Foo 1, , 3`.
    public var positional: [VBAValue?] = []
    public var named: [(name: String, value: VBAValue)] = []

    public static var none: VBAArguments { VBAArguments() }

    public init(_ positional: [VBAValue?] = [], named: [(name: String, value: VBAValue)] = []) {
        self.positional = positional
        self.named = named
    }

    public var count: Int { positional.count + named.count }
    public var isEmpty: Bool { positional.isEmpty && named.isEmpty }

    /// The argument at `position`, or the one passed by `name`.
    public func value(_ position: Int, _ name: String? = nil) -> VBAValue? {
        if let name, let match = named.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match.value
        }
        guard position < positional.count, let value = positional[position] else { return nil }
        if case .missing = value { return nil }
        return value
    }

    public func required(_ position: Int, _ name: String? = nil) throws -> VBAValue {
        guard let value = value(position, name) else {
            throw VBAError(number: 449, "Argument not optional")
        }
        return value
    }
}

/// A runtime error, numbered as VBA numbers them so `Err.Number` checks in
/// the macro work as written.
public struct VBAError: Error, Hashable, Sendable {
    public var number: Int
    public var description: String
    /// The module and line it was raised on, once known.
    public var module: String?
    public var line: Int?

    public init(number: Int, _ description: String) {
        self.number = number
        self.description = description
    }

    public static let typeMismatch = VBAError(number: 13, "Type mismatch")
    public static let overflow = VBAError(number: 6, "Overflow")
    public static let divisionByZero = VBAError(number: 11, "Division by zero")
    public static let subscriptOutOfRange = VBAError(number: 9, "Subscript out of range")
    public static let objectRequired = VBAError(number: 424, "Object required")
    public static let objectNotSet = VBAError(number: 91, "Object variable or With block variable not set")
    public static let invalidUseOfNull = VBAError(number: 94, "Invalid use of Null")
    public static let invalidCall = VBAError(number: 5, "Invalid procedure call or argument")
    public static let wrongArgumentCount = VBAError(number: 450, "Wrong number of arguments or invalid property assignment")

    public static func unsupportedMember(_ name: String) -> VBAError {
        VBAError(number: 438, "Object doesn't support this property or method (\(name))")
    }

    public static func notDefined(_ name: String) -> VBAError {
        VBAError(number: 35, "Sub or Function not defined (\(name))")
    }

    public static func notSupported(_ what: String) -> VBAError {
        VBAError(number: 445, "\(what) is not supported in Tables")
    }
}

/// A multi-dimensional array with arbitrary lower bounds, stored with the
/// first index varying fastest — the order `For Each` visits it in.
public struct VBAArray {
    public var lowerBounds: [Int]
    public var lengths: [Int]
    public var elements: [VBAValue]
    /// What each element is declared as, so assignments coerce.
    public var elementType: VBAType
    /// `Dim a(1 To 3)` cannot be resized; `Dim a()` and `ReDim` can.
    public var isFixed: Bool

    public init(lowerBounds: [Int], upperBounds: [Int], elementType: VBAType = .variant, isFixed: Bool = false) {
        self.lowerBounds = lowerBounds
        lengths = zip(lowerBounds, upperBounds).map { max(0, $1 - $0 + 1) }
        self.elementType = elementType
        self.isFixed = isFixed
        elements = Array(repeating: elementType.defaultValue, count: lengths.reduce(1, *))
    }

    /// A one-dimensional array of the given values from `lowerBound`.
    public init(_ values: [VBAValue], lowerBound: Int = 0) {
        lowerBounds = [lowerBound]
        lengths = [values.count]
        elements = values
        elementType = .variant
        isFixed = false
    }

    /// An uninitialised dynamic array: `Dim a() As String` before `ReDim`.
    public static func unallocated(_ type: VBAType) -> VBAArray {
        var array = VBAArray(lowerBounds: [], upperBounds: [], elementType: type)
        array.elements = []
        return array
    }

    public var dimensions: Int { lengths.count }
    public var isAllocated: Bool { !lengths.isEmpty }

    public func upperBound(_ dimension: Int) -> Int { lowerBounds[dimension] + lengths[dimension] - 1 }

    public func offset(_ indices: [Int]) throws -> Int {
        guard indices.count == lengths.count else { throw VBAError.subscriptOutOfRange }
        var offset = 0
        var stride = 1
        for (dimension, index) in indices.enumerated() {
            let position = index - lowerBounds[dimension]
            guard position >= 0, position < lengths[dimension] else { throw VBAError.subscriptOutOfRange }
            offset += position * stride
            stride *= lengths[dimension]
        }
        return offset
    }

    public subscript(indices: [Int]) -> VBAValue {
        get throws { elements[try offset(indices)] }
    }

    public mutating func set(_ indices: [Int], _ value: VBAValue) throws {
        elements[try offset(indices)] = try elementType.coerce(value)
    }

    /// `ReDim Preserve` may only change the last dimension, keeping whatever
    /// still fits.
    public func resizedPreserving(lowerBounds newLower: [Int], upperBounds newUpper: [Int]) throws -> VBAArray {
        var resized = VBAArray(lowerBounds: newLower, upperBounds: newUpper, elementType: elementType)
        guard isAllocated else { return resized }
        guard newLower.count == dimensions,
              zip(newLower.dropLast(), lowerBounds.dropLast()).allSatisfy(==),
              zip(resized.lengths.dropLast(), lengths.dropLast()).allSatisfy(==) else {
            throw VBAError.subscriptOutOfRange
        }
        let keptLast = min(lengths[dimensions - 1], resized.lengths[dimensions - 1])
        let sliceSize = lengths.dropLast().reduce(1, *)
        let kept = sliceSize * keptLast
        resized.elements.replaceSubrange(0..<kept, with: elements[0..<kept])
        return resized
    }
}

/// A declared type, which decides how assignments to a variable coerce.
public indirect enum VBAType: Hashable, Sendable {
    case variant, boolean, byte, integer, long, longLong, single, double, currency, date, string
    /// `As Object`, `As Range`, `As Collection` and any class.
    case object(String)
    case userType(String)
    case array(VBAType)

    public static func named(_ name: String) -> VBAType {
        switch name.lowercased() {
        case "variant", "any": return .variant
        case "boolean": return .boolean
        case "byte": return .byte
        case "integer": return .integer
        case "long", "longptr": return .long
        case "longlong": return .longLong
        case "single": return .single
        case "double", "decimal": return .double
        case "currency": return .currency
        case "date": return .date
        case "string": return .string
        default: return .object(name)
        }
    }

    public var defaultValue: VBAValue {
        switch self {
        case .variant: return .empty
        case .boolean: return .boolean(false)
        case .byte, .integer, .long, .longLong: return .integer(0)
        case .single, .double, .currency: return .double(0)
        case .date: return .date(0)
        case .string: return .string("")
        case .object: return .nothing
        case .userType: return .empty
        case .array(let element): return .array(.unallocated(element))
        }
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    /// The value as it would be stored in a variable of this type: rounded
    /// and range-checked for the integer types, converted for the rest.
    public func coerce(_ value: VBAValue) throws -> VBAValue {
        switch self {
        case .variant, .userType:
            return value
        case .array:
            guard case .array = value else { throw VBAError.typeMismatch }
            return value
        case .object:
            switch value {
            case .object, .nothing: return value
            case .empty: return .nothing
            default: throw VBAError.objectRequired
            }
        case .boolean:
            return .boolean(try value.asBoolean())
        case .byte:
            return .integer(try value.asInteger(range: 0...255))
        case .integer:
            return .integer(try value.asInteger(range: -32_768...32_767))
        case .long:
            return .integer(try value.asInteger(range: -2_147_483_648...2_147_483_647))
        case .longLong:
            return .integer(try value.asInteger(range: Int.min...Int.max))
        case .single, .double:
            return .double(try value.asDouble())
        case .currency:
            return .double((try value.asDouble() * 10_000).rounded(.toNearestOrEven) / 10_000)
        case .date:
            return .date(try value.asDate())
        case .string:
            return .string(try value.asString())
        }
    }
}

/// A Variant: what every value in a running macro is.
public enum VBAValue {
    case empty
    case null
    /// An object reference that refers to nothing.
    case nothing
    /// An optional parameter that was not passed, which `IsMissing` detects.
    case missing
    case boolean(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
    case date(Double)
    case object(any VBAObject)
    case array(VBAArray)
    /// A worksheet error value, `CVErr(xlErrNA)` and friends.
    case error(Int)

    public var isObjectLike: Bool {
        switch self {
        case .object, .nothing: return true
        default: return false
        }
    }

    public var isNumeric: Bool {
        switch self {
        case .integer, .double, .boolean, .date, .empty: return true
        default: return false
        }
    }

    // MARK: - Conversions

    /// Strings convert the way `Val` would not: wholly or not at all, with
    /// `&H` prefixes and surrounding spaces allowed.
    public static func parseNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        if upper.hasPrefix("&H"), let value = Int(upper.dropFirst(2), radix: 16) { return Double(value) }
        if upper.hasPrefix("&O"), let value = Int(upper.dropFirst(2), radix: 8) { return Double(value) }
        var cleaned = trimmed.replacingOccurrences(of: ",", with: "")
        if cleaned.hasPrefix("$") { cleaned.removeFirst() }
        var scale = 1.0
        if cleaned.hasSuffix("%") {
            cleaned.removeLast()
            scale = 0.01
        }
        guard let value = Double(cleaned), cleaned.lowercased() != "nan", !cleaned.lowercased().contains("inf") else {
            return nil
        }
        return value * scale
    }

    public func asDouble() throws -> Double {
        switch self {
        case .empty, .missing: return 0
        case .boolean(let flag): return flag ? -1 : 0
        case .integer(let value): return Double(value)
        case .double(let value), .date(let value): return value
        case .string(let text):
            if let value = Self.parseNumber(text) { return value }
            if let serial = VBADate.parse(text) { return serial }
            throw VBAError.typeMismatch
        case .null: throw VBAError.invalidUseOfNull
        case .nothing: throw VBAError.objectNotSet
        case .object, .array, .error: throw VBAError.typeMismatch
        }
    }

    /// Rounds half to even, as `CLng` and every integer assignment do.
    public func asInteger(range: ClosedRange<Int> = Int.min...Int.max) throws -> Int {
        if case .integer(let value) = self {
            guard range.contains(value) else { throw VBAError.overflow }
            return value
        }
        let rounded = try asDouble().rounded(.toNearestOrEven)
        guard rounded.isFinite, rounded >= Double(range.lowerBound), rounded <= Double(range.upperBound) else {
            throw VBAError.overflow
        }
        return Int(rounded)
    }

    public func asBoolean() throws -> Bool {
        switch self {
        case .boolean(let flag): return flag
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "#true#": return true
            case "false", "#false#": return false
            default: return try asDouble() != 0
            }
        default:
            return try asDouble() != 0
        }
    }

    public func asDate() throws -> Double {
        switch self {
        case .date(let serial): return serial
        case .string(let text):
            if let serial = VBADate.parse(text) { return serial }
            if let value = Self.parseNumber(text) { return value }
            throw VBAError.typeMismatch
        default:
            return try asDouble()
        }
    }

    public func asString() throws -> String {
        switch self {
        case .empty, .missing: return ""
        case .boolean(let flag): return flag ? "True" : "False"
        case .integer(let value): return String(value)
        case .double(let value): return Self.format(value)
        case .string(let text): return text
        case .date(let serial): return Self.formatDate(serial)
        case .null: throw VBAError.invalidUseOfNull
        case .error(let code): return "Error \(code)"
        case .nothing: throw VBAError.objectNotSet
        case .object, .array: throw VBAError.typeMismatch
        }
    }

    /// Doubles print with up to fifteen significant digits, in scientific
    /// notation only when that is shorter to read, as `CStr` does.
    public static func format(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        guard value.isFinite else { return value > 0 ? "inf" : "-inf" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let magnitude = abs(value)
        if magnitude >= 1e15 || magnitude < 1e-4 {
            var text = String(format: "%.14E", value)
            // 1.50000000000000E+020 → 1.5E+20
            if let e = text.firstIndex(of: "E") {
                var mantissa = String(text[..<e])
                var exponent = String(text[text.index(after: e)...])
                while mantissa.hasSuffix("0") { mantissa.removeLast() }
                if mantissa.hasSuffix(".") { mantissa.removeLast() }
                let sign = exponent.hasPrefix("-") ? "-" : "+"
                exponent = String(exponent.drop { $0 == "+" || $0 == "-" }.drop { $0 == "0" })
                text = mantissa + "E" + sign + (exponent.isEmpty ? "0" : exponent)
            }
            return text
        }
        var text = String(format: "%.15G", value)
        if text.contains("."), !text.contains("E") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// `m/d/yyyy`, with the time after it when there is one, and only the
    /// time for a date on day zero — what VBA shows under US settings.
    public static func formatDate(_ serial: Double) -> String {
        let parts = VBADate.components(serial)
        let hasTime = serial != serial.rounded(.down)
        let datePart = "\(parts.month!)/\(parts.day!)/\(parts.year!)"
        guard hasTime else { return datePart }
        let hour = parts.hour!
        let clock = String(format: "%d:%02d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, parts.minute!, parts.second!,
                           hour < 12 ? "AM" : "PM")
        return serial.rounded(.down) == 0 ? clock : datePart + " " + clock
    }

    /// The name `TypeName` reports.
    public var typeName: String {
        switch self {
        case .empty, .missing: return "Empty"
        case .null: return "Null"
        case .nothing: return "Nothing"
        case .boolean: return "Boolean"
        case .integer(let value): return (-32_768...32_767).contains(value) ? "Integer" : "Long"
        case .double: return "Double"
        case .string: return "String"
        case .date: return "Date"
        case .object(let object): return object.typeName
        case .array(let array):
            switch array.elementType {
            case .variant: return "Variant()"
            case .object(let name): return name + "()"
            default: return "\(VBAValue.typeName(of: array.elementType))()"
            }
        case .error: return "Error"
        }
    }

    public static func typeName(of type: VBAType) -> String {
        switch type {
        case .variant: return "Variant"
        case .boolean: return "Boolean"
        case .byte: return "Byte"
        case .integer: return "Integer"
        case .long: return "Long"
        case .longLong: return "LongLong"
        case .single: return "Single"
        case .double: return "Double"
        case .currency: return "Currency"
        case .date: return "Date"
        case .string: return "String"
        case .object(let name): return name
        case .userType(let name): return name
        case .array(let element): return typeName(of: element) + "()"
        }
    }

    /// `VarType`'s numbering.
    public var varType: Int {
        switch self {
        case .empty, .missing: return 0
        case .null: return 1
        case .integer(let value): return (-32_768...32_767).contains(value) ? 2 : 3
        case .double: return 5
        case .date: return 7
        case .string: return 8
        case .object, .nothing: return 9
        case .error: return 10
        case .boolean: return 11
        case .array: return 8192 + 12
        }
    }
}

// MARK: - Operators

public enum VBAOperators {
    /// Arithmetic stays in whole numbers while both sides are whole, and
    /// moves to doubles as soon as either is not.
    private enum NumericPair {
        case integers(Int, Int)
        case doubles(Double, Double)
    }

    private static func numeric(_ lhs: VBAValue, _ rhs: VBAValue) throws -> NumericPair {
        func whole(_ value: VBAValue) -> Int? {
            switch value {
            case .integer(let number): return number
            case .boolean(let flag): return flag ? -1 : 0
            case .empty: return 0
            default: return nil
            }
        }
        if let left = whole(lhs), let right = whole(rhs) { return .integers(left, right) }
        return .doubles(try lhs.asDouble(), try rhs.asDouble())
    }

    private static func isNull(_ value: VBAValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    private static func isDate(_ value: VBAValue) -> Bool {
        if case .date = value { return true }
        return false
    }

    public static func binary(_ op: String, _ lhs: VBAValue, _ rhs: VBAValue, textCompare: Bool) throws -> VBAValue {
        switch op.lowercased() {
        case "&":
            let left = isNull(lhs) ? "" : try lhs.asString()
            let right = isNull(rhs) ? "" : try rhs.asString()
            if isNull(lhs), isNull(rhs) { return .null }
            return .string(left + right)
        case "+":
            if isNull(lhs) || isNull(rhs) { return .null }
            if case .string(let left) = lhs, case .string(let right) = rhs { return .string(left + right) }
            let result = try arithmetic(lhs, rhs, integer: { $0.addingReportingOverflow($1) }, double: +)
            return isDate(lhs) || isDate(rhs) ? .date(try result.asDouble()) : result
        case "-":
            if isNull(lhs) || isNull(rhs) { return .null }
            let result = try arithmetic(lhs, rhs, integer: { $0.subtractingReportingOverflow($1) }, double: -)
            if isDate(lhs), isDate(rhs) { return .double(try result.asDouble()) }
            return isDate(lhs) ? .date(try result.asDouble()) : result
        case "*":
            if isNull(lhs) || isNull(rhs) { return .null }
            return try arithmetic(lhs, rhs, integer: { $0.multipliedReportingOverflow(by: $1) }, double: *)
        case "/":
            if isNull(lhs) || isNull(rhs) { return .null }
            let divisor = try rhs.asDouble()
            guard divisor != 0 else { throw VBAError.divisionByZero }
            return .double(try lhs.asDouble() / divisor)
        case "\\":
            if isNull(lhs) || isNull(rhs) { return .null }
            let divisor = try rhs.asInteger()
            guard divisor != 0 else { throw VBAError.divisionByZero }
            return .integer(try lhs.asInteger() / divisor)
        case "mod":
            if isNull(lhs) || isNull(rhs) { return .null }
            let divisor = try rhs.asInteger()
            guard divisor != 0 else { throw VBAError.divisionByZero }
            return .integer(try lhs.asInteger() % divisor)
        case "^":
            if isNull(lhs) || isNull(rhs) { return .null }
            let base = try lhs.asDouble()
            let exponent = try rhs.asDouble()
            guard base >= 0 || exponent == exponent.rounded() else { throw VBAError.invalidCall }
            return .double(pow(base, exponent))
        case "=", "<>", "<", ">", "<=", ">=":
            if isNull(lhs) || isNull(rhs) { return .null }
            let order = try compare(lhs, rhs, textCompare: textCompare)
            switch op {
            case "=": return .boolean(order == .orderedSame)
            case "<>": return .boolean(order != .orderedSame)
            case "<": return .boolean(order == .orderedAscending)
            case ">": return .boolean(order == .orderedDescending)
            case "<=": return .boolean(order != .orderedDescending)
            default: return .boolean(order != .orderedAscending)
            }
        case "like":
            if isNull(lhs) || isNull(rhs) { return .null }
            return .boolean(like(try lhs.asString(), try rhs.asString(), textCompare: textCompare))
        case "is":
            return .boolean(try identical(lhs, rhs))
        case "and", "or", "xor", "eqv", "imp":
            return try logical(op.lowercased(), lhs, rhs)
        default:
            throw VBAError.notSupported("The \(op) operator")
        }
    }

    private static func arithmetic(
        _ lhs: VBAValue, _ rhs: VBAValue,
        integer: (Int, Int) -> (partialValue: Int, overflow: Bool),
        double: (Double, Double) -> Double
    ) throws -> VBAValue {
        switch try numeric(lhs, rhs) {
        case .integers(let left, let right):
            let result = integer(left, right)
            return result.overflow ? .double(double(Double(left), Double(right))) : .integer(result.partialValue)
        case .doubles(let left, let right):
            return .double(double(left, right))
        }
    }

    public static func negate(_ value: VBAValue) throws -> VBAValue {
        switch value {
        case .null: return .null
        case .integer(let number): return .integer(-number)
        case .boolean(let flag): return .integer(flag ? 1 : 0)
        case .empty: return .integer(0)
        case .date(let serial): return .date(-serial)
        default: return .double(-(try value.asDouble()))
        }
    }

    public static func not(_ value: VBAValue) throws -> VBAValue {
        switch value {
        case .null: return .null
        case .boolean(let flag): return .boolean(!flag)
        default: return .integer(~(try value.asInteger()))
        }
    }

    private static func logical(_ op: String, _ lhs: VBAValue, _ rhs: VBAValue) throws -> VBAValue {
        if case .boolean(let left) = lhs, case .boolean(let right) = rhs {
            switch op {
            case "and": return .boolean(left && right)
            case "or": return .boolean(left || right)
            case "xor": return .boolean(left != right)
            case "eqv": return .boolean(left == right)
            default: return .boolean(!left || right)
            }
        }
        // Null And False is False, Null Or True is True; otherwise Null.
        if isNull(lhs) || isNull(rhs) {
            let other = isNull(lhs) ? rhs : lhs
            if !isNull(other), let flag = try? other.asBoolean() {
                if op == "and", !flag { return .boolean(false) }
                if op == "or", flag { return .boolean(true) }
            }
            return .null
        }
        let left = try lhs.asInteger()
        let right = try rhs.asInteger()
        switch op {
        case "and": return .integer(left & right)
        case "or": return .integer(left | right)
        case "xor": return .integer(left ^ right)
        case "eqv": return .integer(~(left ^ right))
        default: return .integer(~left | right)
        }
    }

    public static func identical(_ lhs: VBAValue, _ rhs: VBAValue) throws -> Bool {
        switch (lhs, rhs) {
        case (.nothing, .nothing): return true
        case (.object(let left), .object(let right)): return left === right
        case (.object, .nothing), (.nothing, .object): return false
        default: throw VBAError.objectRequired
        }
    }

    /// Variants compare numerically when both sides are numbers, as text when
    /// both are strings, and a number always sorts before text it cannot be
    /// read as.
    public static func compare(_ lhs: VBAValue, _ rhs: VBAValue, textCompare: Bool) throws -> ComparisonResult {
        func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            if a < b { .orderedAscending } else if a > b { .orderedDescending } else { .orderedSame }
        }
        switch (lhs, rhs) {
        case (.string(let left), .string(let right)):
            return compareText(left, right, textCompare: textCompare)
        case (.string(let text), .empty):
            return compareText(text, "", textCompare: textCompare)
        case (.empty, .string(let text)):
            return compareText("", text, textCompare: textCompare)
        case (.string(let text), _) where rhs.isNumeric:
            guard let number = VBAValue.parseNumber(text) else { return .orderedDescending }
            return order(number, try rhs.asDouble())
        case (_, .string(let text)) where lhs.isNumeric:
            guard let number = VBAValue.parseNumber(text) else { return .orderedAscending }
            return order(try lhs.asDouble(), number)
        case (.error(let left), .error(let right)):
            return order(left, right)
        default:
            return order(try lhs.asDouble(), try rhs.asDouble())
        }
    }

    public static func compareText(_ lhs: String, _ rhs: String, textCompare: Bool) -> ComparisonResult {
        if textCompare { return lhs.compare(rhs, options: [.caseInsensitive]) }
        // Binary comparison orders by code unit, as VBA's does.
        if lhs.utf16.lexicographicallyPrecedes(rhs.utf16) { return .orderedAscending }
        return lhs == rhs ? .orderedSame : .orderedDescending
    }

    /// `Like` patterns: `?` any one character, `*` any run, `#` a digit,
    /// `[a-z]` and `[!a-z]` a character in or out of a set.
    public static func like(_ text: String, _ pattern: String, textCompare: Bool) -> Bool {
        let subject = Array(textCompare ? text.lowercased() : text)
        let pattern = Array(textCompare ? pattern.lowercased() : pattern)
        var memo: [Int: Bool] = [:]
        func match(_ s: Int, _ p: Int) -> Bool {
            let key = s * (pattern.count + 1) + p
            if let known = memo[key] { return known }
            let result: Bool
            if p == pattern.count {
                result = s == subject.count
            } else {
                switch pattern[p] {
                case "*":
                    result = match(s, p + 1) || (s < subject.count && match(s + 1, p))
                case "?":
                    result = s < subject.count && match(s + 1, p + 1)
                case "#":
                    result = s < subject.count && subject[s].isNumber && match(s + 1, p + 1)
                case "[":
                    guard let close = pattern[(p + 1)...].firstIndex(of: "]") else {
                        result = s < subject.count && subject[s] == "[" && match(s + 1, p + 1)
                        break
                    }
                    var set = Array(pattern[(p + 1)..<close])
                    let negated = set.first == "!"
                    if negated { set.removeFirst() }
                    guard s < subject.count else {
                        result = false
                        break
                    }
                    let character = subject[s]
                    var inSet = false
                    var index = 0
                    while index < set.count {
                        if index + 2 < set.count, set[index + 1] == "-" {
                            if set[index] <= character, character <= set[index + 2] { inSet = true }
                            index += 3
                        } else {
                            if set[index] == character { inSet = true }
                            index += 1
                        }
                    }
                    result = inSet != negated && match(s + 1, close + 1)
                default:
                    result = s < subject.count && subject[s] == pattern[p] && match(s + 1, p + 1)
                }
            }
            memo[key] = result
            return result
        }
        return match(0, 0)
    }
}
