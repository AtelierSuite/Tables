import Compression
import CryptoKit
import Foundation
import Testing
@testable import TablesEngine

/// The plain-Swift DEFLATE and SHA-256 the engine uses where Apple's frameworks
/// don't exist (WebAssembly), checked against those frameworks here.
@Suite("Portable codecs")
struct PortableCodecTests {
    private static let samples: [Data] = {
        var samples: [Data] = [
            Data(),
            Data("a".utf8),
            Data("abcabcabcabcabcabcabcabcabcabc".utf8),
            Data(String(repeating: "<c r=\"A1\" t=\"s\"><v>12</v></c>", count: 2_000).utf8),
        ]
        var generator = SystemRandomNumberGenerator()
        samples.append(Data((0..<70_000).map { _ in UInt8.random(in: 0...255, using: &generator) }))
        // Long runs and matches near the 32 KB window edge.
        var mixed = Data(repeating: 0x41, count: 40_000)
        mixed.append(Data((0..<40_000).map { UInt8($0 % 251) }))
        mixed.append(mixed.prefix(33_000))
        samples.append(mixed)
        return samples
    }()

    private static func appleDeflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(bytes: destination, count: written)
    }

    private static func appleInflate(_ data: Data, size: Int) -> Data {
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 1))
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, max(size, 1), base, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(bytes: destination, count: written)
    }

    @Test("Inflates what Apple's Compression deflates", arguments: samples.filter { !$0.isEmpty })
    func inflatesAppleStreams(_ sample: Data) {
        let compressed = Self.appleDeflate(sample)
        #expect(RawDeflate.inflate(compressed) == sample)
    }

    @Test("Apple's Compression inflates what it deflates", arguments: samples.filter { !$0.isEmpty })
    func deflatesForApple(_ sample: Data) {
        let compressed = RawDeflate.deflate(sample)
        #expect(Self.appleInflate(compressed, size: sample.count) == sample)
        #expect(RawDeflate.inflate(compressed) == sample)
    }

    @Test("Compresses repetitive XML")
    func compressesXML() {
        let xml = Self.samples[3]
        #expect(RawDeflate.deflate(xml).count < xml.count / 10)
    }

    @Test("Stops at the output limit")
    func honoursLimit() {
        let compressed = Self.appleDeflate(Self.samples[3])
        #expect(RawDeflate.inflate(compressed, limit: 100) == Self.samples[3].prefix(100))
    }

    @Test("Rejects a stream that is not DEFLATE")
    func rejectsGarbage() {
        #expect(RawDeflate.inflate(Data([0xFF, 0xFF, 0xFF, 0xFF])) == nil)
    }

    @Test("SHA-256 matches CryptoKit", arguments: ["", "abc", "Ada Lovelace", String(repeating: "x", count: 1_000)])
    func sha256(_ text: String) {
        let data = Data(text.utf8)
        #expect(SHA256Digest.hash(data) == Array(SHA256.hash(data: data)))
    }
}
