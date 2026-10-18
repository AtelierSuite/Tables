import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

@Suite("VBA compression")
struct VBACompressionTests {
    private func bytes(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    // The worked examples of [MS-OVBA] §3.2.

    @Test("Text with nothing to repeat decompresses literally")
    func noCompression() throws {
        let compressed = bytes(
            "01 19 B0 00 61 62 63 64 65 66 67 68 00 69 6A 6B 6C 6D 6E 6F 70 00 71 72 73 74 75 76 2E"
        )
        #expect(try VBACompression.decompress(compressed) == Data("abcdefghijklmnopqrstuv.".utf8))
    }

    @Test("Repeated runs decompress through copy tokens")
    func normalCompression() throws {
        let compressed = bytes(
            "01 2F B0 00 23 61 61 61 62 63 64 65 82 66 00 70 61 67 68 69 6A 01 38 08 61 6B 6C 00 30 6D 6E 6F 70 06 71 02 70 04 10 72 73 74 75 76 10 77 78 79 7A 00 3C"
        )
        let expected = "#aaabcdefaaaaghijaaaaaklaaamnopqaaaaaaaaaaaarstuvwxyzaaa"
        #expect(try VBACompression.decompress(compressed) == Data(expected.utf8))
    }

    @Test("A copy may overlap the bytes it is producing")
    func maximumCompression() throws {
        let run = Data(String(repeating: "a", count: 73).utf8)
        #expect(try VBACompression.decompress(bytes("01 03 B0 02 61 45 00")) == run)
        // One literal and one copy is as small as it gets, so ours is the same.
        #expect(VBACompression.compress(run) == bytes("01 03 B0 02 61 45 00"))
    }

    @Test("The specification's sample compresses to the same size and back")
    func compressesLikeTheSpecification() throws {
        // Where two earlier runs match equally well the encoder may pick
        // either; the size and the round trip are what have to agree.
        let text = Data("#aaabcdefaaaaghijaaaaaklaaamnopqaaaaaaaaaaaarstuvwxyzaaa".utf8)
        let compressed = VBACompression.compress(text)
        #expect(compressed.count == 51)
        #expect(try VBACompression.decompress(compressed) == text)
    }

    @Test("Several chunks, long matches and incompressible data all round-trip")
    func roundTrips() throws {
        var generator = SystemRandomNumberGenerator()
        let noise = Data((0..<10_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let source = Data(String(repeating: "Sub Test()\r\n    Range(\"A1\").Value = 1\r\nEnd Sub\r\n", count: 300).utf8)
        for sample in [Data(), Data("x".utf8), source, noise, source + noise] {
            let decompressed = try VBACompression.decompress(VBACompression.compress(sample))
            // A raw chunk is padded to full size, so noise can come back longer.
            #expect(decompressed.prefix(sample.count) == sample)
            #expect(decompressed.dropFirst(sample.count).allSatisfy { $0 == 0 })
        }
        #expect(try VBACompression.decompress(VBACompression.compress(source)) == source)
    }

    @Test("Garbage is refused rather than misread")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) { try VBACompression.decompress(Data([0x02, 0x00])) }
        #expect(throws: (any Error).self) { try VBACompression.decompress(Data([0x01, 0xFF, 0xFF])) }
        // A copy token reaching back before the start of the chunk.
        #expect(throws: (any Error).self) { try VBACompression.decompress(bytes("01 03 B0 01 FF FF")) }
    }
}
