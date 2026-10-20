import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

@Suite("Snappy")
struct SnappyTests {
    private func decompress(_ bytes: [UInt8]) throws -> String {
        String(decoding: try Snappy.decompress(bytes[...]), as: UTF8.self)
    }

    @Test("An empty block decodes to nothing")
    func empty() throws {
        #expect(try decompress([0x00]).isEmpty)
    }

    @Test("A literal is copied through")
    func literal() throws {
        #expect(try decompress([0x06, 0x14] + Array("Tables".utf8)) == "Tables")
    }

    @Test("A literal too long for its tag carries its length after it")
    func longLiteral() throws {
        let text = String(repeating: "0123456789", count: 10)
        #expect(try decompress([0x64, 0xF0, 0x63] + Array(text.utf8)) == text)
    }

    @Test("Copies with one-byte offsets repeat earlier output, overlapping it")
    func shortCopy() throws {
        // "ab", then six bytes starting two back.
        #expect(try decompress([0x08, 0x04, 0x61, 0x62, 0x09, 0x02]) == "abababab")
    }

    @Test("Copies with two-byte offsets, as the reference encoder writes them")
    func mediumCopy() throws {
        // python-snappy's output for "abc" * 10 and "spreadsheet " * 8.
        #expect(try decompress([0x1E, 0x08, 0x61, 0x62, 0x63, 0x6A, 0x03, 0x00]) == String(repeating: "abc", count: 10))
        let spreadsheet: [UInt8] = [0x60, 0x2C] + Array("spreadsheet ".utf8) + [0xFE, 0x0C, 0x00, 0x4E, 0x0C, 0x00]
        #expect(try decompress(spreadsheet) == String(repeating: "spreadsheet ", count: 8))
    }

    @Test("Copies with four-byte offsets")
    func longCopy() throws {
        #expect(try decompress([0x08, 0x04, 0x61, 0x62, 0x17, 0x02, 0x00, 0x00, 0x00]) == "abababab")
    }

    @Test("What it compresses decompresses back the same, and repeats shrink", arguments: [
        Array(String(repeating: "Numbers ", count: 2_000).utf8),
        (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) },
        Array("short".utf8),
        [],
        [UInt8](repeating: 7, count: 131),
    ] as [[UInt8]])
    func roundTrip(_ bytes: [UInt8]) throws {
        let compressed = Snappy.compress(bytes[...])
        #expect(try Snappy.decompress(compressed[...]) == bytes)
        if bytes.count > 1_000, Set(bytes).count < 20 {
            #expect(compressed.count < bytes.count / 10)
        }
    }

    @Test("Damaged blocks are rejected rather than misread", arguments: [
        // A copy reaching back before the start.
        [0x08, 0x04, 0x61, 0x62, 0x09, 0x05],
        // Fewer bytes than the header promised.
        [0x09, 0x04, 0x61, 0x62, 0x09, 0x02],
        // A literal running off the end.
        [0x06, 0x14, 0x54],
        // A length that never ends.
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
    ] as [[UInt8]])
    func rejectsDamage(_ bytes: [UInt8]) {
        #expect(throws: (any Error).self) { try Snappy.decompress(bytes[...]) }
    }
}
