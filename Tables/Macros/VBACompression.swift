import Foundation
import TablesEngine

/// The run-length scheme of [MS-OVBA] §2.4.1, which every piece of source
/// text and the `dir` stream in a macro project is stored with.
///
/// Data is cut into chunks of 4096 bytes, each compressed on its own: a flag
/// byte says which of the next eight tokens are literal bytes and which are
/// copies of something earlier in the same chunk.
enum VBACompression {
    struct FormatError: LocalizedError {
        var errorDescription: String? { "The macro project holds malformed compressed data." }
    }

    private static let chunkSize = 4096

    // MARK: - Decompression

    static func decompress(_ data: Data) throws -> Data {
        try decompress([UInt8](data)[...])
    }

    static func decompress(_ input: ArraySlice<UInt8>) throws -> Data {
        guard input.first == 0x01 else { throw FormatError() }
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 2)
        var position = input.startIndex + 1
        while position + 2 <= input.endIndex {
            let header = UInt16(input[position]) | UInt16(input[position + 1]) << 8
            // A zero header is padding some writers leave after the last chunk.
            if header == 0 { break }
            guard header >> 12 & 0b111 == 0b011 else { throw FormatError() }
            let size = Int(header & 0x0FFF) + 3
            let end = min(position + size, input.endIndex)
            let isCompressed = header & 0x8000 != 0
            position += 2
            let chunkStart = output.count
            if !isCompressed {
                output += input[position..<min(position + chunkSize, end)]
                position = end
                continue
            }
            while position < end {
                let flags = input[position]
                position += 1
                for bit in 0..<8 where position < end {
                    if flags >> bit & 1 == 0 {
                        output.append(input[position])
                        position += 1
                        continue
                    }
                    guard position + 2 <= end else { throw FormatError() }
                    let token = UInt16(input[position]) | UInt16(input[position + 1]) << 8
                    position += 2
                    let (offset, length) = unpack(token, distance: output.count - chunkStart)
                    guard offset <= output.count - chunkStart else { throw FormatError() }
                    // Byte by byte: a copy may overlap the bytes it produces.
                    let source = output.count - offset
                    for step in 0..<length { output.append(output[source + step]) }
                }
            }
            position = end
        }
        return Data(output)
    }

    /// How many of a copy token's sixteen bits are offset rather than length
    /// depends on how far into the chunk it sits: more room behind, more bits.
    private static func bitCount(distance: Int) -> Int {
        var bits = 0
        while 1 << bits < distance { bits += 1 }
        return max(bits, 4)
    }

    private static func unpack(_ token: UInt16, distance: Int) -> (offset: Int, length: Int) {
        let bits = bitCount(distance: distance)
        let lengthMask = UInt16(0xFFFF) >> bits
        return (Int((token & ~lengthMask) >> (16 - bits)) + 1, Int(token & lengthMask) + 3)
    }

    // MARK: - Compression

    static func compress(_ data: Data) -> Data {
        let input = [UInt8](data)
        var output: [UInt8] = [0x01]
        var start = 0
        while start < input.count {
            let end = min(start + chunkSize, input.count)
            output += compressChunk(input, from: start, to: end)
            start = end
        }
        return Data(output)
    }

    private static func compressChunk(_ input: [UInt8], from start: Int, to end: Int) -> [UInt8] {
        var body: [UInt8] = []
        var current = start
        while current < end {
            let flagIndex = body.count
            body.append(0)
            var flags: UInt8 = 0
            for bit in 0..<8 where current < end {
                let (offset, length) = longestMatch(input, at: current, chunkStart: start, end: end)
                if length >= 3 {
                    let bits = bitCount(distance: current - start)
                    let token = UInt16(offset - 1) << (16 - bits) | UInt16(length - 3)
                    body += [UInt8(token & 0xFF), UInt8(token >> 8)]
                    flags |= 1 << bit
                    current += length
                } else {
                    body.append(input[current])
                    current += 1
                }
            }
            body[flagIndex] = flags
        }
        // A chunk that will not shrink is stored raw, which the format only
        // allows at full size: a short last chunk is padded out with zeros.
        if body.count + 2 > chunkSize + 2 {
            var raw = Array(input[start..<end])
            raw += [UInt8](repeating: 0, count: chunkSize - raw.count)
            let header = UInt16(chunkSize - 1) | 0x3000
            return [UInt8(header & 0xFF), UInt8(header >> 8)] + raw
        }
        let header = UInt16(body.count + 2 - 3) | 0x3000 | 0x8000
        return [UInt8(header & 0xFF), UInt8(header >> 8)] + body
    }

    /// The longest earlier run matching the bytes at `current`, nearest first
    /// on a tie, capped at what a token at this position can express.
    private static func longestMatch(
        _ input: [UInt8], at current: Int, chunkStart: Int, end: Int
    ) -> (offset: Int, length: Int) {
        let bits = bitCount(distance: current - chunkStart)
        let maximumLength = Int(UInt16(0xFFFF) >> bits) + 3
        let maximumOffset = 1 << bits
        var bestLength = 0
        var bestOffset = 0
        var candidate = current - 1
        while candidate >= chunkStart, current - candidate <= maximumOffset {
            var length = 0
            while current + length < end, length < maximumLength, input[candidate + length] == input[current + length] {
                length += 1
            }
            if length > bestLength {
                bestLength = length
                bestOffset = current - candidate
            }
            candidate -= 1
        }
        return (bestOffset, bestLength)
    }
}
