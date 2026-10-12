import Foundation

/// One decoded Protocol Buffers message, read without a schema: its fields
/// kept by number so the caller, which knows what each number means, can ask
/// for them as the type it expects.
///
/// Enough of the wire format for reading iWork archives. Groups, long
/// deprecated, are rejected.
struct ProtobufMessage {
    enum Failure: Error {
        case corrupt
    }

    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(ArraySlice<UInt8>)
    }

    private(set) var fields: [Int: [Value]] = [:]

    init(_ bytes: ArraySlice<UInt8>) throws {
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
            fields[number, default: []].append(value)
        }
    }

    init(_ bytes: [UInt8]) throws {
        try self.init(bytes[...])
    }

    // MARK: - Reading fields

    /// The last occurrence wins, as the format specifies for singular fields.
    func uint(_ number: Int) -> UInt64? {
        switch fields[number]?.last {
        case .varint(let value), .fixed64(let value): return value
        case .fixed32(let value): return UInt64(value)
        default: return nil
        }
    }

    func int(_ number: Int) -> Int? {
        uint(number).map { Int(truncatingIfNeeded: $0) }
    }

    func bool(_ number: Int) -> Bool {
        (uint(number) ?? 0) != 0
    }

    func float(_ number: Int) -> Float? {
        guard case .fixed32(let bits) = fields[number]?.last else { return nil }
        return Float(bitPattern: bits)
    }

    func double(_ number: Int) -> Double? {
        guard case .fixed64(let bits) = fields[number]?.last else { return nil }
        return Double(bitPattern: bits)
    }

    func bytes(_ number: Int) -> ArraySlice<UInt8>? {
        guard case .bytes(let slice) = fields[number]?.last else { return nil }
        return slice
    }

    func string(_ number: Int) -> String? {
        bytes(number).map { String(decoding: $0, as: UTF8.self) }
    }

    func strings(_ number: Int) -> [String] {
        (fields[number] ?? []).compactMap {
            guard case .bytes(let slice) = $0 else { return nil }
            return String(decoding: slice, as: UTF8.self)
        }
    }

    func message(_ number: Int) -> ProtobufMessage? {
        bytes(number).flatMap { try? ProtobufMessage($0) }
    }

    func messages(_ number: Int) -> [ProtobufMessage] {
        (fields[number] ?? []).compactMap {
            guard case .bytes(let slice) = $0 else { return nil }
            return try? ProtobufMessage(slice)
        }
    }

    /// A repeated integer field, whether written one value per key or packed
    /// into a single length-delimited run.
    func uints(_ number: Int) -> [UInt64] {
        (fields[number] ?? []).flatMap { value -> [UInt64] in
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

    // MARK: - Wire primitives

    static func readVarint(_ bytes: ArraySlice<UInt8>, at cursor: inout Int) throws -> UInt64 {
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

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}
