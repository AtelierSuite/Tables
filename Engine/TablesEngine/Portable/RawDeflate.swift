import Foundation

/// Raw DEFLATE (RFC 1951) in plain Swift, for platforms without Apple's
/// Compression framework, such as WebAssembly. ZIP entries in XLSX and Numbers
/// files are raw DEFLATE streams.
///
/// Inflating handles stored, fixed and dynamic Huffman blocks. Deflating uses
/// LZ77 matching with the fixed Huffman code: simpler than dynamic tables and
/// still compresses spreadsheet XML well.
enum RawDeflate {
    private struct Failure: Error {}

    // MARK: - Tables

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                             3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                              257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                              8193, 12289, 16385, 24577]
    private static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                               7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// A canonical Huffman code, decoded a bit at a time (as zlib's `puff` does).
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        init?(lengths: ArraySlice<Int>) {
            symbols = [Int](repeating: 0, count: lengths.count)
            for length in lengths { counts[length] += 1 }
            var left = 1
            for length in 1...15 {
                left <<= 1
                left -= counts[length]
                if left < 0 { return nil }      // over-subscribed
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }
    }

    private static let fixedLiterals: Huffman = {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return Huffman(lengths: lengths[...])!
    }()

    private static let fixedDistances = Huffman(lengths: [Int](repeating: 5, count: 30)[...])!

    // MARK: - Inflate

    /// Inflates a raw DEFLATE stream. Output stops at `limit` bytes; a stream that
    /// ends early returns what was decoded so far, so callers' CRC checks can reject it.
    /// Returns nil only for a stream that is malformed before producing anything.
    static func inflate(_ data: Data, limit: Int = .max) -> Data? {
        data.withUnsafeBytes { raw -> Data? in
            var inflater = Inflater(input: raw.bindMemory(to: UInt8.self), limit: limit)
            do {
                try inflater.run()
            } catch {
                if inflater.output.isEmpty { return nil }
            }
            return Data(inflater.output)
        }
    }

    private struct Inflater {
        let input: UnsafeBufferPointer<UInt8>
        let limit: Int
        var position = 0
        var bitBuffer = 0
        var bitCount = 0
        var output: [UInt8] = []

        init(input: UnsafeBufferPointer<UInt8>, limit: Int) {
            self.input = input
            self.limit = limit
            output.reserveCapacity(min(limit, max(input.count * 4, 1024)))
        }

        var full: Bool { output.count >= limit }

        mutating func bits(_ need: Int) throws -> Int {
            while bitCount < need {
                guard position < input.count else { throw Failure() }
                bitBuffer |= Int(input[position]) << bitCount
                position += 1
                bitCount += 8
            }
            let value = bitBuffer & ((1 << need) - 1)
            bitBuffer >>= need
            bitCount -= need
            return value
        }

        mutating func decode(_ code: Huffman) throws -> Int {
            var value = 0, first = 0, index = 0
            for length in 1...15 {
                value |= try bits(1)
                let count = code.counts[length]
                if value - count < first { return code.symbols[index + (value - first)] }
                index += count
                first += count
                first <<= 1
                value <<= 1
            }
            throw Failure()
        }

        mutating func run() throws {
            var last = 0
            repeat {
                last = try bits(1)
                switch try bits(2) {
                case 0: try stored()
                case 1: try codes(RawDeflate.fixedLiterals, RawDeflate.fixedDistances)
                case 2: try dynamic()
                default: throw Failure()
                }
            } while last == 0 && !full
        }

        mutating func stored() throws {
            bitBuffer = 0
            bitCount = 0
            guard position + 4 <= input.count else { throw Failure() }
            let length = Int(input[position]) | Int(input[position + 1]) << 8
            let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
            position += 4
            guard length == (~complement & 0xFFFF) else { throw Failure() }
            let available = min(length, input.count - position, limit - output.count)
            output.append(contentsOf: input[position..<(position + available)])
            position += available
            if available < length, !full { throw Failure() }
        }

        mutating func dynamic() throws {
            let literalCount = try bits(5) + 257
            let distanceCount = try bits(5) + 1
            let codeCount = try bits(4) + 4
            guard literalCount <= 286, distanceCount <= 30 else { throw Failure() }

            var lengths = [Int](repeating: 0, count: 320)
            for i in 0..<codeCount { lengths[RawDeflate.codeLengthOrder[i]] = try bits(3) }
            for i in codeCount..<19 { lengths[RawDeflate.codeLengthOrder[i]] = 0 }
            guard let lengthCode = Huffman(lengths: lengths[0..<19]) else { throw Failure() }

            var index = 0
            while index < literalCount + distanceCount {
                var symbol = try decode(lengthCode)
                if symbol < 16 {
                    lengths[index] = symbol
                    index += 1
                    continue
                }
                var value = 0
                if symbol == 16 {
                    guard index > 0 else { throw Failure() }
                    value = lengths[index - 1]
                    symbol = 3 + (try bits(2))
                } else if symbol == 17 {
                    symbol = 3 + (try bits(3))
                } else {
                    symbol = 11 + (try bits(7))
                }
                guard index + symbol <= literalCount + distanceCount else { throw Failure() }
                for _ in 0..<symbol {
                    lengths[index] = value
                    index += 1
                }
            }
            guard lengths[256] != 0,
                  let literals = Huffman(lengths: lengths[0..<literalCount]),
                  let distances = Huffman(lengths: lengths[literalCount..<(literalCount + distanceCount)])
            else { throw Failure() }
            try codes(literals, distances)
        }

        mutating func codes(_ literals: Huffman, _ distances: Huffman) throws {
            while true {
                var symbol = try decode(literals)
                if symbol < 256 {
                    output.append(UInt8(symbol))
                    if full { return }
                } else if symbol == 256 {
                    return
                } else {
                    symbol -= 257
                    guard symbol < 29 else { throw Failure() }
                    let length = RawDeflate.lengthBase[symbol] + (try bits(RawDeflate.lengthExtra[symbol]))
                    let distanceSymbol = try decode(distances)
                    guard distanceSymbol < 30 else { throw Failure() }
                    let distance = RawDeflate.distanceBase[distanceSymbol] + (try bits(RawDeflate.distanceExtra[distanceSymbol]))
                    guard distance <= output.count else { throw Failure() }
                    let start = output.count - distance
                    let count = min(length, limit - output.count)
                    for i in 0..<count { output.append(output[start + i]) }
                    if full { return }
                }
            }
        }
    }

    // MARK: - Deflate

    private static let windowSize = 32768
    private static let minimumMatch = 3
    private static let maximumMatch = 258
    private static let maximumChain = 64
    private static let hashBits = 15

    /// The length symbol (257...285), extra bit count and extra value for each match length.
    private static let lengthCodes: [(symbol: Int, extraBits: Int, extra: Int)] = {
        var table = [(Int, Int, Int)](repeating: (0, 0, 0), count: maximumMatch + 1)
        for length in minimumMatch...maximumMatch {
            var code = lengthBase.count - 1
            while lengthBase[code] > length { code -= 1 }
            table[length] = (257 + code, lengthExtra[code], length - lengthBase[code])
        }
        return table
    }()

    private struct BitWriter {
        var bytes: [UInt8] = []
        var buffer = 0
        var count = 0

        mutating func write(_ value: Int, _ bitCount: Int) {
            buffer |= value << count
            count += bitCount
            while count >= 8 {
                bytes.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                count -= 8
            }
        }

        /// Huffman codes go most-significant bit first.
        mutating func writeCode(_ code: Int, _ length: Int) {
            var reversed = 0
            var value = code
            for _ in 0..<length {
                reversed = (reversed << 1) | (value & 1)
                value >>= 1
            }
            write(reversed, length)
        }

        mutating func finish() -> [UInt8] {
            if count > 0 { bytes.append(UInt8(buffer & 0xFF)) }
            buffer = 0
            count = 0
            return bytes
        }
    }

    private static func writeLiteral(_ symbol: Int, to writer: inout BitWriter) {
        switch symbol {
        case 0..<144: writer.writeCode(0x30 + symbol, 8)
        case 144..<256: writer.writeCode(0x190 + symbol - 144, 9)
        case 256..<280: writer.writeCode(symbol - 256, 7)
        default: writer.writeCode(0xC0 + symbol - 280, 8)
        }
    }

    private static func writeDistance(_ distance: Int, to writer: inout BitWriter) {
        var code = distanceBase.count - 1
        while distanceBase[code] > distance { code -= 1 }
        writer.writeCode(code, 5)
        writer.write(distance - distanceBase[code], distanceExtra[code])
    }

    /// Compresses `data` into a single fixed-Huffman DEFLATE block.
    static func deflate(_ data: Data) -> Data {
        data.withUnsafeBytes { raw -> Data in
            let input = raw.bindMemory(to: UInt8.self)
            let count = input.count
            var writer = BitWriter()
            writer.bytes.reserveCapacity(count / 2 + 64)
            writer.write(1, 1)      // final block
            writer.write(1, 2)      // fixed Huffman codes

            let hashSize = 1 << hashBits
            var head = [Int32](repeating: -1, count: hashSize)
            var previous = [Int32](repeating: -1, count: windowSize)

            func hash(_ i: Int) -> Int {
                ((Int(input[i]) << 10) ^ (Int(input[i + 1]) << 5) ^ Int(input[i + 2])) & (hashSize - 1)
            }
            func insert(_ i: Int) {
                guard i + minimumMatch <= count else { return }
                let h = hash(i)
                previous[i & (windowSize - 1)] = head[h]
                head[h] = Int32(i)
            }

            var i = 0
            while i < count {
                var bestLength = 0
                var bestDistance = 0
                if i + minimumMatch <= count {
                    var candidate = Int(head[hash(i)])
                    var chain = maximumChain
                    let maxLength = min(maximumMatch, count - i)
                    while candidate >= 0, i - candidate <= windowSize, chain > 0 {
                        if input[candidate + bestLength] == input[i + bestLength] || bestLength == 0 {
                            var length = 0
                            while length < maxLength, input[candidate + length] == input[i + length] { length += 1 }
                            if length > bestLength {
                                bestLength = length
                                bestDistance = i - candidate
                                if length == maxLength { break }
                            }
                        }
                        let next = Int(previous[candidate & (windowSize - 1)])
                        if next >= candidate { break }
                        candidate = next
                        chain -= 1
                    }
                }

                if bestLength >= minimumMatch {
                    let code = lengthCodes[bestLength]
                    writeLiteral(code.symbol, to: &writer)
                    writer.write(code.extra, code.extraBits)
                    writeDistance(bestDistance, to: &writer)
                    for j in i..<(i + bestLength) { insert(j) }
                    i += bestLength
                } else {
                    writeLiteral(Int(input[i]), to: &writer)
                    insert(i)
                    i += 1
                }
            }
            writeLiteral(256, to: &writer)
            return Data(writer.finish())
        }
    }
}
