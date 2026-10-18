import Foundation

/// One decoded Protocol Buffers message, read without a schema: its fields
/// kept in the order they were written so the caller, which knows what each
/// number means, can ask for them as the type it expects — and so that a
/// message changed in one field writes back with every other field as it was.
///
/// Enough of the wire format for reading and patching iWork archives. Groups,
/// long deprecated, are rejected.
public struct ProtobufMessage: Sendable {
    public enum Failure: Error, Sendable {
        case corrupt
    }

    public enum Value: Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(ArraySlice<UInt8>)
    }

    public private(set) var fields: [(number: Int, value: Value)] = []

    public init() {}

    public init(_ bytes: ArraySlice<UInt8>) throws {
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            let key = try Self.readVarint(bytes, at: &cursor)
            let number = Int(key >> 3)
            guard number > 0 else { throw Failure.corrupt }
            let value: Value
            switch key & 0b111 {
            case 0:
                value = .varint(try Self.readVarint(bytes, at: &cursor))
            case 1:
                guard cursor + 8 <= bytes.endIndex else { throw Failure.corrupt }
                value = .fixed64(Self.littleEndian(bytes[cursor..<(cursor + 8)]))
                cursor += 8
            case 2:
                let length = try Self.readVarint(bytes, at: &cursor)
                guard length <= UInt64(bytes.endIndex - cursor) else { throw Failure.corrupt }
                let end = cursor + Int(length)
                value = .bytes(bytes[cursor..<end])
                cursor = end
            case 5:
                guard cursor + 4 <= bytes.endIndex else { throw Failure.corrupt }
                value = .fixed32(UInt32(Self.littleEndian(bytes[cursor..<(cursor + 4)])))
                cursor += 4
            default:
                throw Failure.corrupt
            }
            fields.append((number, value))
        }
    }

    public init(_ bytes: [UInt8]) throws {
        try self.init(bytes[...])
    }

    // MARK: - Reading fields

    private func values(_ number: Int) -> [Value] {
        fields.lazy.filter { $0.number == number }.map(\.value)
    }

    /// The last occurrence wins, as the format specifies for singular fields.
    private func last(_ number: Int) -> Value? {
        fields.last { $0.number == number }?.value
    }

    public func has(_ number: Int) -> Bool {
        fields.contains { $0.number == number }
    }

    public func uint(_ number: Int) -> UInt64? {
        switch last(number) {
        case .varint(let value), .fixed64(let value): return value
        case .fixed32(let value): return UInt64(value)
        default: return nil
        }
    }

    public func int(_ number: Int) -> Int? {
        uint(number).map { Int(truncatingIfNeeded: $0) }
    }

    public func bool(_ number: Int) -> Bool {
        (uint(number) ?? 0) != 0
    }

    public func float(_ number: Int) -> Float? {
        guard case .fixed32(let bits) = last(number) else { return nil }
        return Float(bitPattern: bits)
    }

    public func double(_ number: Int) -> Double? {
        guard case .fixed64(let bits) = last(number) else { return nil }
        return Double(bitPattern: bits)
    }

    public func bytes(_ number: Int) -> ArraySlice<UInt8>? {
        guard case .bytes(let slice) = last(number) else { return nil }
        return slice
    }

    public func string(_ number: Int) -> String? {
        bytes(number).map { String(decoding: $0, as: UTF8.self) }
    }

    public func strings(_ number: Int) -> [String] {
        values(number).compactMap {
            guard case .bytes(let slice) = $0 else { return nil }
            return String(decoding: slice, as: UTF8.self)
        }
    }

    public func message(_ number: Int) -> ProtobufMessage? {
        bytes(number).flatMap { try? ProtobufMessage($0) }
    }

    public func messages(_ number: Int) -> [ProtobufMessage] {
        values(number).compactMap {
            guard case .bytes(let slice) = $0 else { return nil }
            return try? ProtobufMessage(slice)
        }
    }

    /// A repeated integer field, whether written one value per key or packed
    /// into a single length-delimited run.
    public func uints(_ number: Int) -> [UInt64] {
        values(number).flatMap { value -> [UInt64] in
            switch value {
            case .varint(let value), .fixed64(let value): return [value]
            case .fixed32(let value): return [UInt64(value)]
            case .bytes(let slice):
                var cursor = slice.startIndex
                var values: [UInt64] = []
                while cursor < slice.endIndex, let value = try? Self.readVarint(slice, at: &cursor) {
                    values.append(value)
                }
                return values
            }
        }
    }

    // MARK: - Changing fields

    /// Replaces every occurrence of a field with `values`, written where the
    /// first occurrence was, or at the end when there was none.
    public mutating func set(_ number: Int, _ values: [Value]) {
        let position = fields.firstIndex { $0.number == number }
        fields.removeAll { $0.number == number }
        fields.insert(contentsOf: values.map { (number, $0) }, at: min(position ?? fields.count, fields.count))
    }

    public mutating func set(_ number: Int, uint value: UInt64) {
        set(number, [.varint(value)])
    }

    public mutating func set(_ number: Int, bool value: Bool) {
        set(number, [.varint(value ? 1 : 0)])
    }

    public mutating func set(_ number: Int, float value: Float) {
        set(number, [.fixed32(value.bitPattern)])
    }

    public mutating func set(_ number: Int, bytes value: [UInt8]) {
        set(number, [.bytes(value[...])])
    }

    public mutating func set(_ number: Int, message value: ProtobufMessage) {
        set(number, bytes: value.encoded())
    }

    public mutating func set(_ number: Int, messages values: [ProtobufMessage]) {
        set(number, values.map { .bytes($0.encoded()[...]) })
    }

    public mutating func append(_ number: Int, message value: ProtobufMessage) {
        let position = (fields.lastIndex { $0.number == number }).map { $0 + 1 } ?? fields.count
        fields.insert((number, .bytes(value.encoded()[...])), at: position)
    }

    // MARK: - Writing

    public func encoded() -> [UInt8] {
        var output: [UInt8] = []
        for (number, value) in fields {
            switch value {
            case .varint(let value):
                Self.appendVarint(UInt64(number) << 3, to: &output)
                Self.appendVarint(value, to: &output)
            case .fixed64(let value):
                Self.appendVarint(UInt64(number) << 3 | 1, to: &output)
                output += withUnsafeBytes(of: value.littleEndian, Array.init)
            case .bytes(let slice):
                Self.appendVarint(UInt64(number) << 3 | 2, to: &output)
                Self.appendVarint(UInt64(slice.count), to: &output)
                output += slice
            case .fixed32(let value):
                Self.appendVarint(UInt64(number) << 3 | 5, to: &output)
                output += withUnsafeBytes(of: value.littleEndian, Array.init)
            }
        }
        return output
    }

    // MARK: - Wire primitives

    public static func readVarint(_ bytes: ArraySlice<UInt8>, at cursor: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < bytes.endIndex, shift < 64 {
            let byte = bytes[cursor]
            cursor += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw Failure.corrupt
    }

    public static func appendVarint(_ value: UInt64, to output: inout [UInt8]) {
        var value = value
        while value >= 0x80 {
            output.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        output.append(UInt8(value))
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}
