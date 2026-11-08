import Compression
import Foundation

public enum ZipError: LocalizedError, Sendable {
    case notAnArchive
    case unsupportedCompression(UInt16)
    case corruptEntry(String)
    case decompressionFailed(String)
    case compressionFailed(String)
    /// The file is an OLE compound document: either a password-protected
    /// workbook or a legacy `.xls` one. Both look nothing like a ZIP.
    case protectedOrLegacyWorkbook
    case encryptedEntry(String)

    public var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "This file isn’t a valid Office Open XML package."
        case .unsupportedCompression(let method):
            return "The package uses an unsupported compression method (\(method))."
        case .corruptEntry(let name):
            return "The package entry “\(name)” is damaged."
        case .decompressionFailed(let name):
            return "Couldn’t decompress “\(name)”."
        case .compressionFailed(let name):
            return "Couldn’t compress “\(name)”."
        case .protectedOrLegacyWorkbook:
            return """
                This file looks password-protected, or saved in the older .xls format. \
                Tables can’t open either one. Remove the password or re-save it as .xlsx, then try again.
                """
        case .encryptedEntry(let name):
            return """
                The package entry “\(name)” is password-protected. \
                Tables can’t open protected workbooks — remove the password and save the file again.
                """
        }
    }
}

/// A minimal ZIP reader and writer covering the subset OOXML packages use:
/// stored and deflated entries, no encryption, no spanning.
public enum ZipArchive {

    // MARK: - Format constants

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50

    /// Header id of the ZIP64 extended information extra field.
    private static let zip64ExtraFieldID: UInt16 = 0x0001

    /// The value a 32-bit size or offset carries when the real one lives in the
    /// ZIP64 extra field instead.
    private static let zip64Placeholder: UInt32 = 0xFFFF_FFFF

    /// OLE compound file signature, which is what password-protected and legacy
    /// `.xls` workbooks start with.
    private static let compoundFileSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    /// A ceiling on how much we will allocate for one inflated entry, so a
    /// damaged or hostile header can't ask us to reserve gigabytes.
    private static let maximumInflatedSize = 512 * 1024 * 1024

    // MARK: - Reading

    /// Reads every entry into a path-keyed table.
    public static func entries(in data: Data) throws -> [String: Data] {
        Dictionary(try orderedEntries(in: data), uniquingKeysWith: { _, last in last })
    }

    /// Reads every entry in the order the archive lists them, for writing an
    /// archive back as it was.
    public static func orderedEntries(in data: Data) throws -> [(path: String, data: Data)] {
        let bytes = [UInt8](data)
        guard !bytes.starts(with: compoundFileSignature) else { throw ZipError.protectedOrLegacyWorkbook }
        guard let directoryStart = locateCentralDirectory(bytes) else { throw ZipError.notAnArchive }

        var result: [(path: String, data: Data)] = []
        var offset = directoryStart
        while offset + 46 <= bytes.count, readUInt32(bytes, offset) == centralDirectorySignature {
            let record = try directoryRecord(bytes, at: offset)

            // Bit 0 of the general purpose flags means the entry's bytes are
            // encrypted; decompressing them anyway would yield noise.
            guard record.flags & 1 == 0 else { throw ZipError.encryptedEntry(record.name) }

            if !record.name.hasSuffix("/") {
                result.append((record.name, try extract(bytes, record: record)))
            }
            offset += record.length
        }
        guard !result.isEmpty else { throw ZipError.notAnArchive }
        return result
    }

    /// Everything one central directory record says about a single entry.
    private struct DirectoryRecord {
        var name: String
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
        /// Byte length of the record itself, for walking to the next one.
        var length: Int
    }

    private static func directoryRecord(_ bytes: [UInt8], at offset: Int) throws -> DirectoryRecord {
        let nameLength = Int(readUInt16(bytes, offset + 28))
        let extraLength = Int(readUInt16(bytes, offset + 30))
        let commentLength = Int(readUInt16(bytes, offset + 32))

        guard offset + 46 + nameLength + extraLength <= bytes.count else { throw ZipError.notAnArchive }
        let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)

        let compressed = readUInt32(bytes, offset + 20)
        let uncompressed = readUInt32(bytes, offset + 24)
        let localOffset = readUInt32(bytes, offset + 42)

        var record = DirectoryRecord(
            name: name,
            flags: readUInt16(bytes, offset + 8),
            method: readUInt16(bytes, offset + 10),
            crc: readUInt32(bytes, offset + 16),
            compressedSize: Int(compressed),
            uncompressedSize: Int(uncompressed),
            localHeaderOffset: Int(localOffset),
            length: 46 + nameLength + extraLength + commentLength
        )

        if compressed == zip64Placeholder || uncompressed == zip64Placeholder || localOffset == zip64Placeholder {
            let extra = (offset + 46 + nameLength)..<(offset + 46 + nameLength + extraLength)
            guard var cursor = zip64ExtraField(bytes, in: extra) else { throw ZipError.corruptEntry(name) }

            // The field carries only the saturated values, always in this order.
            if uncompressed == zip64Placeholder {
                record.uncompressedSize = try readZip64Value(bytes, at: &cursor, name: name)
            }
            if compressed == zip64Placeholder {
                record.compressedSize = try readZip64Value(bytes, at: &cursor, name: name)
            }
            if localOffset == zip64Placeholder {
                record.localHeaderOffset = try readZip64Value(bytes, at: &cursor, name: name)
            }
        }
        return record
    }

    /// Locates the body of the ZIP64 extended information field inside an extra
    /// field block, returning a cursor over its 64-bit values.
    private static func zip64ExtraField(_ bytes: [UInt8], in range: Range<Int>) -> Zip64Cursor? {
        var offset = range.lowerBound
        while offset + 4 <= range.upperBound {
            let identifier = readUInt16(bytes, offset)
            let size = Int(readUInt16(bytes, offset + 2))
            let body = (offset + 4)..<min(offset + 4 + size, range.upperBound)
            if identifier == zip64ExtraFieldID { return Zip64Cursor(offset: body.lowerBound, end: body.upperBound) }
            offset += 4 + size
        }
        return nil
    }

    /// Walks the fixed-order 64-bit values of a ZIP64 extended information field.
    private struct Zip64Cursor {
        var offset: Int
        let end: Int
    }

    private static func readZip64Value(_ bytes: [UInt8], at cursor: inout Zip64Cursor, name: String) throws -> Int {
        guard cursor.offset + 8 <= cursor.end else { throw ZipError.corruptEntry(name) }
        let value = readUInt64(bytes, cursor.offset)
        guard value <= UInt64(Int.max) else { throw ZipError.corruptEntry(name) }
        cursor.offset += 8
        return Int(value)
    }

    private static func extract(_ bytes: [UInt8], record: DirectoryRecord) throws -> Data {
        let name = record.name
        guard record.localHeaderOffset >= 0, record.localHeaderOffset + 30 <= bytes.count,
              readUInt32(bytes, record.localHeaderOffset) == localHeaderSignature else {
            throw ZipError.corruptEntry(name)
        }
        let nameLength = Int(readUInt16(bytes, record.localHeaderOffset + 26))
        let extraLength = Int(readUInt16(bytes, record.localHeaderOffset + 28))
        let start = record.localHeaderOffset + 30 + nameLength + extraLength
        guard record.compressedSize >= 0, start + record.compressedSize <= bytes.count else {
            throw ZipError.corruptEntry(name)
        }
        let payload = Data(bytes[start..<(start + record.compressedSize)])

        let content: Data
        switch record.method {
        case 0:
            content = payload
        case 8:
            // An entry that deflates to nothing decodes to zero bytes, which the
            // Compression framework reports the same way it reports failure. A
            // zero size with a real CRC means the writer just omitted the size.
            if record.uncompressedSize == 0, record.crc == 0 {
                content = Data()
            } else if let inflated = inflate(payload, expectedSize: record.uncompressedSize) {
                content = inflated
            } else {
                throw ZipError.decompressionFailed(name)
            }
        default:
            throw ZipError.unsupportedCompression(record.method)
        }

        // The CRC is the only thing that catches a stream which merely stopped
        // early: a truncated DEFLATE body still decodes, just to fewer bytes.
        guard crc32(content) == record.crc else { throw ZipError.corruptEntry(name) }
        return content
    }

    /// Scans backwards for the end-of-central-directory record, preferring the
    /// ZIP64 record behind it when the archive has one.
    private static func locateCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowerBound = max(0, bytes.count - 22 - 65_535)
        var offset = bytes.count - 22
        while offset >= lowerBound {
            if readUInt32(bytes, offset) == endOfCentralDirectorySignature {
                if let zip64Start = zip64CentralDirectoryStart(bytes, endOfCentralDirectory: offset) {
                    return zip64Start
                }
                let start = readUInt32(bytes, offset + 16)
                // A saturated offset with no usable ZIP64 record behind it is a lie.
                guard start != zip64Placeholder else { return nil }
                return Int(start)
            }
            offset -= 1
        }
        return nil
    }

    /// Follows the ZIP64 locator that sits immediately before the classic
    /// end-of-central-directory record.
    private static func zip64CentralDirectoryStart(_ bytes: [UInt8], endOfCentralDirectory: Int) -> Int? {
        let locator = endOfCentralDirectory - 20
        guard locator >= 0, readUInt32(bytes, locator) == zip64LocatorSignature else { return nil }

        guard let record = offsetWithin(bytes, readUInt64(bytes, locator + 8)),
              record + 56 <= bytes.count,
              readUInt32(bytes, record) == zip64EndOfCentralDirectorySignature else { return nil }
        return offsetWithin(bytes, readUInt64(bytes, record + 48))
    }

    private static func offsetWithin(_ bytes: [UInt8], _ value: UInt64) -> Int? {
        guard value <= UInt64(bytes.count) else { return nil }
        return Int(value)
    }

    // MARK: - Writing

    /// Builds an archive. Entries are written in the order given, which matters
    /// for OOXML readers that expect `[Content_Types].xml` first. Without
    /// `compressing`, every entry is stored as it is, as iWork stores them.
    public static func archive(entries: [(path: String, data: Data)], compressing: Bool = true) throws -> Data {
        var output = Data()
        var directory = Data()
        var count: UInt16 = 0

        for entry in entries {
            let nameBytes = Array(entry.path.utf8)
            let crc = crc32(entry.data)
            let localOffset = UInt32(output.count)

            var payload = entry.data
            var method: UInt16 = 0
            if compressing, entry.data.count > 64, let deflated = deflate(entry.data), deflated.count < entry.data.count {
                payload = deflated
                method = 8
            }

            var header = Data()
            header.appendUInt32(0x0403_4B50)
            header.appendUInt16(20)             // version needed
            header.appendUInt16(0)              // flags
            header.appendUInt16(method)
            header.appendUInt16(0)              // modification time
            header.appendUInt16(0x21)           // modification date (1980-01-01)
            header.appendUInt32(crc)
            header.appendUInt32(UInt32(payload.count))
            header.appendUInt32(UInt32(entry.data.count))
            header.appendUInt16(UInt16(nameBytes.count))
            header.appendUInt16(0)              // extra field length
            header.append(contentsOf: nameBytes)
            output.append(header)
            output.append(payload)

            var record = Data()
            record.appendUInt32(0x0201_4B50)
            record.appendUInt16(20)             // version made by
            record.appendUInt16(20)             // version needed
            record.appendUInt16(0)              // flags
            record.appendUInt16(method)
            record.appendUInt16(0)
            record.appendUInt16(0x21)
            record.appendUInt32(crc)
            record.appendUInt32(UInt32(payload.count))
            record.appendUInt32(UInt32(entry.data.count))
            record.appendUInt16(UInt16(nameBytes.count))
            record.appendUInt16(0)              // extra
            record.appendUInt16(0)              // comment
            record.appendUInt16(0)              // disk number
            record.appendUInt16(0)              // internal attributes
            record.appendUInt32(0)              // external attributes
            record.appendUInt32(localOffset)
            record.append(contentsOf: nameBytes)
            directory.append(record)
            count += 1
        }

        let directoryOffset = UInt32(output.count)
        output.append(directory)
        output.appendUInt32(0x0605_4B50)
        output.appendUInt16(0)                  // this disk
        output.appendUInt16(0)                  // disk with central directory
        output.appendUInt16(count)
        output.appendUInt16(count)
        output.appendUInt32(UInt32(directory.count))
        output.appendUInt32(directoryOffset)
        output.appendUInt16(0)                  // comment length
        return output
    }

    // MARK: - DEFLATE

    /// ZIP stores raw DEFLATE streams, which is exactly `COMPRESSION_ZLIB` here.
    ///
    /// A `nil` result means the decoder produced nothing usable. Output that is
    /// merely short — a truncated stream — still comes back here; the caller's
    /// CRC check is what rejects it.
    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }

        // The central directory usually tells us the exact output size, but a
        // damaged header can name an absurd one, so don't reserve it blindly.
        if expectedSize > 0, expectedSize <= maximumInflatedSize,
           let exact = decode(data, into: expectedSize), exact.count == expectedSize {
            return exact
        }
        // Otherwise grow the buffer until the output fits with room to spare,
        // which is how we know the buffer, not the stream, ended it.
        var capacity = max(min(data.count, maximumInflatedSize / 8) * 8, 64 * 1024)
        while capacity <= maximumInflatedSize {
            if let decoded = decode(data, into: capacity), decoded.count < capacity {
                return decoded
            }
            capacity *= 4
        }
        return nil
    }

    private static func decode(_ data: Data, into capacity: Int) -> Data? {
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    private static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: - Byte access

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset + 8 <= bytes.count else { return 0 }
        return UInt64(readUInt32(bytes, offset)) | (UInt64(readUInt32(bytes, offset + 4)) << 32)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
