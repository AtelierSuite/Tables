import Foundation

/// Decompresses raw Snappy blocks, the compression iWork uses inside its
/// `.iwa` archives. Only the block format: iWork frames the blocks itself,
/// without Snappy's own stream framing or checksums.
enum Snappy {
    enum Failure: Error {
        case corrupt
    }

    /// A ceiling on one block's declared length, so a damaged header can't
    /// ask us to reserve gigabytes.
    private static let maximumLength = 64 * 1024 * 1024

    static func decompress(_ input: ArraySlice<UInt8>) throws -> [UInt8] {
        var cursor = input.startIndex
        let length = try readLength(input, at: &cursor)
        guard length <= maximumLength else { throw Failure.corrupt }

        var output: [UInt8] = []
        output.reserveCapacity(length)
        while cursor < input.endIndex {
            let tag = input[cursor]
            cursor += 1
            switch tag & 0b11 {
            case 0:
                // A literal: the length is in the tag, or in the 1–4 bytes
                // after it when it doesn't fit.
                var literalLength = Int(tag >> 2)
                if literalLength >= 60 {
                    let byteCount = literalLength - 59
                    guard cursor + byteCount <= input.endIndex else { throw Failure.corrupt }
                    literalLength = 0
                    for index in 0..<byteCount {
                        literalLength |= Int(input[cursor + index]) << (8 * index)
                    }
                    cursor += byteCount
                }
                literalLength += 1
                guard cursor + literalLength <= input.endIndex else { throw Failure.corrupt }
                output.append(contentsOf: input[cursor..<(cursor + literalLength)])
                cursor += literalLength
            case 1:
                guard cursor < input.endIndex else { throw Failure.corrupt }
                let copyLength = Int((tag >> 2) & 0b111) + 4
                let offset = Int(tag >> 5) << 8 | Int(input[cursor])
                cursor += 1
                try copy(offset: offset, length: copyLength, into: &output)
            case 2:
                guard cursor + 2 <= input.endIndex else { throw Failure.corrupt }
                let offset = Int(input[cursor]) | Int(input[cursor + 1]) << 8
                cursor += 2
                try copy(offset: offset, length: Int(tag >> 2) + 1, into: &output)
            default:
                guard cursor + 4 <= input.endIndex else { throw Failure.corrupt }
                var offset = 0
                for index in 0..<4 { offset |= Int(input[cursor + index]) << (8 * index) }
                cursor += 4
                try copy(offset: offset, length: Int(tag >> 2) + 1, into: &output)
            }
            guard output.count <= length else { throw Failure.corrupt }
        }
        guard output.count == length else { throw Failure.corrupt }
        return output
    }

    /// The uncompressed length, a little-endian base-128 varint.
    private static func readLength(_ input: ArraySlice<UInt8>, at cursor: inout Int) throws -> Int {
        var value = 0
        var shift = 0
        while cursor < input.endIndex, shift < 35 {
            let byte = input[cursor]
            cursor += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw Failure.corrupt
    }

    /// Repeats bytes already written. The ranges may overlap, which is how
    /// Snappy encodes runs, so this goes a byte at a time.
    private static func copy(offset: Int, length: Int, into output: inout [UInt8]) throws {
        guard offset > 0, offset <= output.count else { throw Failure.corrupt }
        let start = output.count - offset
        for index in 0..<length {
            output.append(output[start + index])
        }
    }
}
