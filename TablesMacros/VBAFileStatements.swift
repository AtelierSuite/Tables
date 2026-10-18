import Foundation
import TablesEngine

/// Lays out a `Print` list the way VBA does: numbers padded with a space for
/// the sign and one after, `,` jumping to the next 14-column print zone,
/// `Tab` and `Spc` moving the column, `Width` wrapping long lines.
public struct VBAPrintFormatter: Sendable {
    public static let zoneWidth = 14

    /// Characters on the current line before this output.
    public var column: Int
    public var width = 0

    /// The text, and whether the list asked for a line break at its end —
    /// it does unless it ends with `;` or `,`.
    public mutating func format(_ items: [VBAPrintItem], evaluate: (VBAExpression) throws -> VBAValue) throws
        -> (text: String, endsLine: Bool) {
        var text = ""
        func emit(_ piece: String) {
            if width > 0, column > 0, column + piece.count > width {
                text += "\r\n"
                column = 0
            }
            text += piece
            column += piece.count
        }
        func nextZone() {
            let pad = Self.zoneWidth - column % Self.zoneWidth
            text += String(repeating: " ", count: pad)
            column += pad
        }
        for item in items {
            switch item {
            case .value(let expression):
                emit(try Self.text(for: evaluate(expression)))
            case .spaces(let count):
                emit(String(repeating: " ", count: max(0, try evaluate(count).asInteger())))
            case .tab(nil):
                nextZone()
            case .tab(let target?):
                let to = max(1, try evaluate(target).asInteger()) - 1
                if column > to {
                    text += "\r\n"
                    column = 0
                }
                text += String(repeating: " ", count: to - column)
                column = to
            case .separator(let separator):
                if separator == "," { nextZone() }
            }
        }
        if case .separator? = items.last { return (text, false) }
        if case .tab(nil)? = items.last { return (text, false) }
        return (text, true)
    }

    public static func text(for value: VBAValue) throws -> String {
        switch value {
        case .integer, .double:
            let number = try value.asString()
            return (try value.asDouble() < 0 ? "" : " ") + number + " "
        case .null: return "Null"
        case .error(let code): return "Error \(code)"
        case .object, .nothing, .array: throw VBAError.typeMismatch
        default: return try value.asString()
        }
    }
}

extension VBAInterpreter {
    private var files: VBAFileSystem {
        get throws {
            guard let fileSystem else { throw VBAError.notSupported(String(localized: "Macro.Unavailable.Files", bundle: #bundle)) }
            return fileSystem
        }
    }

    private func fileNumber(_ expression: VBAExpression, _ frame: Frame) throws -> Int {
        try letValue(evaluate(expression, frame)).asInteger()
    }

    public func execute(_ statement: VBAFileStatement, _ frame: Frame) throws {
        let files = try files
        switch statement {
        case .open(let path, let mode, let number, let recordLength):
            try files.open(
                try letValue(evaluate(path, frame)).asString(), mode: mode, number: try fileNumber(number, frame),
                recordLength: try recordLength.map { try letValue(evaluate($0, frame)).asInteger() }
            )
        case .close(let numbers):
            if numbers.isEmpty {
                files.closeAll()
            } else {
                for number in numbers { try files.close(try fileNumber(number, frame)) }
            }
        case .print(let number, let items):
            let file = try files.file(try fileNumber(number, frame))
            var formatter = VBAPrintFormatter(column: file.column, width: file.width)
            let (text, endsLine) = try formatter.format(items) { try self.letValue(self.evaluate($0, frame)) }
            try files.writeText(text + (endsLine ? "\r\n" : ""), to: file)
        case .write(let number, let items):
            let file = try files.file(try fileNumber(number, frame))
            let fields = try items.map { try $0.map { try Self.writeField(letValue(evaluate($0, frame))) } ?? "" }
            try files.writeText(fields.joined(separator: ",") + "\r\n", to: file)
        case .input(let number, let targets):
            let file = try files.file(try fileNumber(number, frame))
            for target in targets {
                let field = try files.readField(from: file)
                try assignValue(Self.inputValue(field.text, wasQuoted: field.wasQuoted), to: target, isSet: false, frame)
            }
        case .lineInput(let number, let target):
            let file = try files.file(try fileNumber(number, frame))
            try assignValue(.string(try files.readLine(from: file)), to: target, isSet: false, frame)
        case .get(let number, let record, let target):
            let file = try files.file(try fileNumber(number, frame))
            guard file.mode == .binary || file.mode == .random else { throw VBAFileSystem.badFileMode }
            let start = try recordStart(record, in: file, frame)
            file.position = start
            try readTarget(target, from: file, frame)
            if file.mode == .random { file.position = start + file.recordLength }
        case .put(let number, let record, let valueExpression):
            let file = try files.file(try fileNumber(number, frame))
            guard file.mode == .binary || file.mode == .random else { throw VBAFileSystem.badFileMode }
            let start = try recordStart(record, in: file, frame)
            file.position = start
            let bytes = try encodedValue(valueExpression, randomAccess: file.mode == .random, frame)
            if file.mode == .random {
                guard bytes.count <= file.recordLength else { throw VBAError(number: 59, "Bad record length") }
                try files.write(bytes + [UInt8](repeating: 0, count: file.recordLength - bytes.count), to: file)
            } else {
                try files.write(bytes, to: file)
            }
        case .seek(let number, let positionExpression):
            let file = try files.file(try fileNumber(number, frame))
            let position = try letValue(evaluate(positionExpression, frame)).asInteger()
            guard position >= 1 else { throw VBAError(number: 63, "Bad record number") }
            file.position = file.mode == .random ? (position - 1) * file.recordLength : position - 1
            file.readPastEnd = false
        case .lock(let number):
            _ = try files.file(try fileNumber(number, frame))
        case .width(let number, let widthExpression):
            let file = try files.file(try fileNumber(number, frame))
            file.width = max(0, try letValue(evaluate(widthExpression, frame)).asInteger())
        case .rename(let from, let to):
            try files.rename(try letValue(evaluate(from, frame)).asString(), to: try letValue(evaluate(to, frame)).asString())
        }
    }

    /// Where a `Get` or `Put` starts: the record or byte given, or carry on.
    private func recordStart(_ record: VBAExpression?, in file: VBAFileSystem.OpenFile, _ frame: Frame) throws -> Int {
        guard let record else { return file.position }
        let number = try letValue(evaluate(record, frame)).asInteger()
        guard number >= 1 else { throw VBAError(number: 63, "Bad record number") }
        return file.mode == .random ? (number - 1) * file.recordLength : number - 1
    }

    // MARK: - Write # and Input #

    /// A value as `Write #` puts it: text quoted, logic and dates between
    /// `#` marks, numbers with a full stop whatever the locale.
    public static func writeField(_ value: VBAValue) throws -> String {
        switch value {
        case .empty, .missing: return ""
        case .null: return "#NULL#"
        case .boolean(let flag): return flag ? "#TRUE#" : "#FALSE#"
        case .error(let code): return "#ERROR \(code)#"
        case .string(let text): return "\"" + text + "\""
        case .date(let serial):
            let parts = VBADate.components(serial)
            let date = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
            let time = String(format: "%02d:%02d:%02d", parts.hour!, parts.minute!, parts.second!)
            let wholeDay = serial == serial.rounded(.down)
            if serial.rounded(.down) == 0 && !wholeDay { return "#" + time + "#" }
            return "#" + (wholeDay ? date : date + " " + time) + "#"
        case .integer, .double: return try value.asString()
        case .object, .nothing, .array: throw VBAError.typeMismatch
        }
    }

    /// What an `Input #` field reads as before the target's type converts it.
    public static func inputValue(_ text: String, wasQuoted: Bool) -> VBAValue {
        if wasQuoted { return .string(text) }
        let upper = text.uppercased()
        switch upper {
        case "": return .empty
        case "#TRUE#": return .boolean(true)
        case "#FALSE#": return .boolean(false)
        case "#NULL#": return .null
        default: break
        }
        if upper.hasPrefix("#ERROR "), upper.hasSuffix("#"), let code = Int(upper.dropFirst(7).dropLast()) {
            return .error(code)
        }
        if text.hasPrefix("#"), text.hasSuffix("#"), text.count > 2, let serial = VBADate.parse(String(text.dropFirst().dropLast())) {
            return .date(serial)
        }
        if let number = Double(text) {
            return number == number.rounded() && abs(number) < 9e15 ? .integer(Int(number)) : .double(number)
        }
        return .string(text)
    }

    // MARK: - Get and Put

    /// The declared type behind a target, which decides how many bytes a
    /// `Get` or `Put` moves.
    private func declaredType(of target: VBAExpression, _ frame: Frame) throws -> VBAType {
        switch target {
        case .identifier(let name):
            return existingVariable(name, frame)?.type ?? .variant
        case .call(.identifier(let name), _):
            if let variable = existingVariable(name, frame), case .array(let array) = variable.value {
                return array.elementType
            }
            return .variant
        case .member(let base, let name):
            if let base, case .object(let object) = try evaluate(base, frame), let record = object as? VBARecord {
                return record.fields[name.lowercased()]?.type ?? .variant
            }
            return .variant
        default:
            return .variant
        }
    }

    private func readTarget(_ target: VBAExpression, from file: VBAFileSystem.OpenFile, _ frame: Frame) throws {
        let current = try evaluate(target, frame)
        let random = file.mode == .random
        switch current {
        case .array(var array):
            for index in array.elements.indices {
                array.elements[index] = try readBinary(array.elementType, current: array.elements[index],
                                                       from: file, randomAccess: random)
            }
            try assignValue(.array(array), to: target, isSet: false, frame)
        case .object(let object as VBARecord):
            for name in object.order {
                guard let field = object.fields[name] else { continue }
                field.value = try readBinary(field.type, current: field.value, from: file, randomAccess: random)
            }
        default:
            let type = try declaredType(of: target, frame)
            try assignValue(try readBinary(type, current: current, from: file, randomAccess: random),
                            to: target, isSet: false, frame)
        }
    }

    private func encodedValue(_ expression: VBAExpression, randomAccess: Bool, _ frame: Frame) throws -> [UInt8] {
        let value = try evaluate(expression, frame)
        switch value {
        case .array(let array):
            return try array.elements.flatMap { try Self.encode($0, as: array.elementType, randomAccess: randomAccess) }
        case .object(let object as VBARecord):
            return try object.order.compactMap { object.fields[$0] }.flatMap {
                try Self.encode($0.value, as: $0.type, randomAccess: randomAccess)
            }
        default:
            // A Variant variable goes out with its type in front, as VBA
            // writes one; an expression goes out as the type its value has.
            var type = try declaredType(of: expression, frame)
            if case .identifier = expression {
                // A variable keeps the type it was declared with.
            } else {
                type = Self.naturalType(of: value)
            }
            return try Self.encode(try letValue(value), as: type, randomAccess: randomAccess)
        }
    }

    private static func naturalType(of value: VBAValue) -> VBAType {
        switch value {
        case .integer(let number): return (-32_768...32_767).contains(number) ? .integer : .long
        case .double: return .double
        case .date: return .date
        case .boolean: return .boolean
        case .string: return .string
        default: return .variant
        }
    }

    private static func little<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    /// Text in binary files is one byte per character, in Windows Latin, as
    /// the files VBA on Windows writes are.
    private static func bytes(of text: String) -> [UInt8] {
        [UInt8](text.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(text.utf8))
    }

    public static func encode(_ value: VBAValue, as type: VBAType, randomAccess: Bool) throws -> [UInt8] {
        switch type {
        case .byte: return [UInt8(truncatingIfNeeded: try value.asInteger(range: 0...255))]
        case .boolean: return little(Int16(try value.asBoolean() ? -1 : 0))
        case .integer: return little(Int16(try value.asInteger(range: -32_768...32_767)))
        case .long: return little(Int32(try value.asInteger(range: Int(Int32.min)...Int(Int32.max))))
        case .longLong: return little(Int64(try value.asInteger()))
        case .single: return little(Float(try value.asDouble()).bitPattern)
        case .double: return little(try value.asDouble().bitPattern)
        case .date: return little(try value.asDate().bitPattern)
        case .currency: return little(Int64((try value.asDouble() * 10_000).rounded()))
        case .string:
            let text = bytes(of: try value.asString())
            // In a random-access file a variable-length string carries its length.
            return randomAccess ? little(UInt16(clamping: text.count)) + text : text
        case .variant:
            let descriptor = little(UInt16(value.varType))
            switch value {
            case .empty, .missing: return descriptor
            case .null: return descriptor
            case .string(let text):
                let encoded = bytes(of: text)
                return descriptor + little(UInt16(clamping: encoded.count)) + encoded
            case .integer(let number):
                return descriptor + ((-32_768...32_767).contains(number)
                    ? little(Int16(number)) : little(Int32(clamping: number)))
            case .double(let number): return descriptor + little(number.bitPattern)
            case .date(let serial): return descriptor + little(serial.bitPattern)
            case .boolean(let flag): return descriptor + little(Int16(flag ? -1 : 0))
            default: throw VBAError.typeMismatch
            }
        default:
            throw VBAError.typeMismatch
        }
    }

    private func readBinary(_ type: VBAType, current: VBAValue, from file: VBAFileSystem.OpenFile,
                            randomAccess: Bool) throws -> VBAValue {
        guard let files = fileSystem else { throw VBAError.typeMismatch }
        func integer<T: FixedWidthInteger>(_: T.Type) -> T {
            let bytes = files.readBytes(MemoryLayout<T>.size, from: file)
            guard bytes.count == MemoryLayout<T>.size else { return 0 }
            return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }
        func text(count: Int) -> String {
            let bytes = files.readBytes(count, from: file)
            return String(bytes: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
        }
        switch type {
        case .byte: return .integer(Int(files.readBytes(1, from: file).first ?? 0))
        case .boolean: return .boolean(integer(Int16.self) != 0)
        case .integer: return .integer(Int(integer(Int16.self)))
        case .long: return .integer(Int(integer(Int32.self)))
        case .longLong: return .integer(Int(integer(Int64.self)))
        case .single: return .double(Double(Float(bitPattern: integer(UInt32.self))))
        case .double: return .double(Double(bitPattern: integer(UInt64.self)))
        case .date: return .date(Double(bitPattern: integer(UInt64.self)))
        case .currency: return .double(Double(integer(Int64.self)) / 10_000)
        case .string:
            // A binary read fills the string as it already is; a random one
            // reads the length written in front.
            if randomAccess { return .string(text(count: Int(integer(UInt16.self)))) }
            return .string(text(count: (try? current.asString().count) ?? 0))
        case .variant:
            switch integer(UInt16.self) {
            case 0: return .empty
            case 1: return .null
            case 2: return .integer(Int(integer(Int16.self)))
            case 3: return .integer(Int(integer(Int32.self)))
            case 5: return .double(Double(bitPattern: integer(UInt64.self)))
            case 7: return .date(Double(bitPattern: integer(UInt64.self)))
            case 8: return .string(text(count: Int(integer(UInt16.self))))
            case 11: return .boolean(integer(Int16.self) != 0)
            default: throw VBAError(number: 458, "Variable uses an Automation type not supported in Visual Basic")
            }
        default:
            throw VBAError.typeMismatch
        }
    }
}
