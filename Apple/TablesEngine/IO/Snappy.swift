import Foundation

/// Compresses and decompresses raw Snappy blocks, the compression iWork uses
/// inside its `.iwa` archives. Only the block format: iWork frames the blocks
/// itself, without Snappy's own stream framing or checksums.
public enum Snappy {
    public enum Failure: Error, Sendable {
        case corrupt
    }

    /// A ceiling on one block's declared length, so a damaged header can't
    /// ask us to reserve gigabytes.
    private static let maximumLength = 64 * 1024 * 1024

    public static func decompress(_ input: ArraySlice<UInt8>) throws -> [UInt8] {
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

    /// Compresses one block: a greedy search for repeats of four bytes or
    /// more through a hash of the last place each four-byte run was seen.
    /// Offsets are kept within two bytes, which is all a block iWork writes —
    /// at most 64 KiB — can need.
    public static func compress(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count / 2 + 16)
        var length = input.count
        while length >= 0x80 {
            output.append(UInt8(length & 0x7F) | 0x80)
            length >>= 7
        }
        output.append(UInt8(length))

        let bytes = Array(input)
        var table = [Int](repeating: -1, count: 1 << 14)
        var literalStart = 0
        var cursor = 0
        func hash(_ position: Int) -> Int {
            let word = UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
                | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
            return Int((word &* 0x1E35_A7BD) >> 18)
        }

        while cursor + 4 <= bytes.count {
            let slot = hash(cursor)
            let candidate = table[slot]
            table[slot] = cursor
            guard candidate >= 0, cursor - candidate <= 0xFFFF,
                  bytes[candidate..<(candidate + 4)] == bytes[cursor..<(cursor + 4)] else {
                cursor += 1
                continue
            }
            var matchLength = 4
            while cursor + matchLength < bytes.count, bytes[candidate + matchLength] == bytes[cursor + matchLength] {
                matchLength += 1
            }
            appendLiteral(bytes[literalStart..<cursor], to: &output)
            appendCopy(offset: cursor - candidate, length: matchLength, to: &output)
            cursor += matchLength
            literalStart = cursor
        }
        appendLiteral(bytes[literalStart...], to: &output)
        return output
    }

    private static func appendLiteral(_ literal: ArraySlice<UInt8>, to output: inout [UInt8]) {
        guard !literal.isEmpty else { return }
        let lengthLessOne = literal.count - 1
        if lengthLessOne < 60 {
            output.append(UInt8(lengthLessOne << 2))
        } else {
            var extra: [UInt8] = []
            var remaining = lengthLessOne
            while remaining > 0 {
                extra.append(UInt8(remaining & 0xFF))
                remaining >>= 8
            }
            output.append(UInt8((59 + extra.count) << 2))
            output += extra
        }
        output += literal
    }

    /// Copies of up to 64 bytes at a time, with two-byte offsets.
    private static func appendCopy(offset: Int, length: Int, to output: inout [UInt8]) {
        var remaining = length
        while remaining > 0 {
            // Never leave fewer than four bytes: a copy can't be that short.
            var chunk = min(remaining, 64)
            if (1..<4).contains(remaining - chunk) { chunk = remaining - 4 }
            output += [UInt8((chunk - 1) << 2 | 2), UInt8(offset & 0xFF), UInt8(offset >> 8)]
            remaining -= chunk
        }
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
