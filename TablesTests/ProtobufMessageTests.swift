import Foundation
import Testing
@testable import Tables

@Suite("Protocol Buffers messages")
struct ProtobufMessageTests {
    @Test("Each wire type reads back as the type its field is asked for")
    func wireTypes() throws {
        let message = try ProtobufMessage(
            ProtobufWriter()
                .varint(1, 300)
                .string(2, "Sheet 1")
                .double(3, 12.5)
                .float(4, 98)
                .bool(5, true)
                .bytes
        )
        #expect(message.uint(1) == 300)
        #expect(message.string(2) == "Sheet 1")
        #expect(message.double(3) == 12.5)
        #expect(message.float(4) == 98)
        #expect(message.bool(5))
        #expect(!message.bool(6))
        #expect(message.int(6) == nil)
    }

    @Test("Nested and repeated messages")
    func nested() throws {
        let message = try ProtobufMessage(
            ProtobufWriter()
                .message(1, ProtobufWriter().varint(1, 7))
                .message(1, ProtobufWriter().varint(1, 8))
                .string(2, "a")
                .string(2, "b")
                .bytes
        )
        #expect(message.messages(1).map { $0.int(1) } == [7, 8])
        #expect(message.message(1)?.int(1) == 8, "the last occurrence of a singular field wins")
        #expect(message.strings(2) == ["a", "b"])
    }

    @Test("Repeated integers, packed or one per key")
    func repeatedIntegers() throws {
        let packed = try ProtobufMessage(ProtobufWriter().packed(1, [1, 150, 3]).bytes)
        #expect(packed.uints(1) == [1, 150, 3])
        let unpacked = try ProtobufMessage(ProtobufWriter().varint(1, 1).varint(1, 2).bytes)
        #expect(unpacked.uints(1) == [1, 2])
    }

    @Test("Damaged messages are rejected", arguments: [
        // A length running past the end.
        [0x0A, 0x05, 0x61],
        // A varint that never ends.
        [0x08, 0xFF],
        // A group, which the format deprecated long ago.
        [0x0B],
        // Field number zero.
        [0x00, 0x01],
    ] as [[UInt8]])
    func rejectsDamage(_ bytes: [UInt8]) {
        #expect(throws: (any Error).self) { try ProtobufMessage(bytes) }
    }
}

/// Writes Protocol Buffers messages, for building the documents the readers
/// are tested against.
struct ProtobufWriter {
    var bytes: [UInt8] = []

    func varint(_ field: Int, _ value: UInt64) -> Self {
        var copy = self
        copy.key(field, wireType: 0)
        copy.appendVarint(value)
        return copy
    }

    func varint(_ field: Int, _ value: Int) -> Self {
        varint(field, UInt64(bitPattern: Int64(value)))
    }

    func bool(_ field: Int, _ value: Bool) -> Self {
        varint(field, value ? 1 : 0)
    }

    func double(_ field: Int, _ value: Double) -> Self {
        var copy = self
        copy.key(field, wireType: 1)
        copy.bytes += withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init)
        return copy
    }

    func float(_ field: Int, _ value: Float) -> Self {
        fixed32(field, value.bitPattern)
    }

    func fixed32(_ field: Int, _ value: UInt32) -> Self {
        var copy = self
        copy.key(field, wireType: 5)
        copy.bytes += withUnsafeBytes(of: value.littleEndian, Array.init)
        return copy
    }

    func bytes(_ field: Int, _ value: [UInt8]) -> Self {
        var copy = self
        copy.key(field, wireType: 2)
        copy.appendVarint(UInt64(value.count))
        copy.bytes += value
        return copy
    }

    func string(_ field: Int, _ value: String) -> Self {
        bytes(field, Array(value.utf8))
    }

    func message(_ field: Int, _ value: ProtobufWriter) -> Self {
        bytes(field, value.bytes)
    }

    func packed(_ field: Int, _ values: [UInt64]) -> Self {
        var body = ProtobufWriter()
        for value in values { body.appendVarint(value) }
        return bytes(field, body.bytes)
    }

    private mutating func key(_ field: Int, wireType: UInt64) {
        appendVarint(UInt64(field) << 3 | wireType)
    }

    mutating func appendVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
    }
}
