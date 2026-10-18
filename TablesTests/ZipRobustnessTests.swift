import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// A hand-rolled ZIP writer for the shapes `ZipArchive.archive` never produces:
/// ZIP64 records, encrypted flags and deliberately damaged payloads.
private struct TestZipBuilder {
    struct Entry {
        var name: String
        /// The bytes as they appear on disk, already compressed if `method` says so.
        var payload: Data
        var method: UInt16 = 0
        var crc: UInt32
        var uncompressedSize: Int
        var flags: UInt16 = 0

        static func stored(_ name: String, _ content: Data, flags: UInt16 = 0) -> Entry {
            Entry(name: name, payload: content, method: 0, crc: ZipArchive.crc32(content),
                  uncompressedSize: content.count, flags: flags)
        }
    }

    /// When true the central directory saturates its 32-bit fields and the real
    /// values move into ZIP64 extra fields and a ZIP64 end-of-directory record.
    var usesZip64 = false

    func build(_ entries: [Entry]) -> Data {
        var output = Data()
        var directory = Data()
        var localOffsets: [Int] = []

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            localOffsets.append(output.count)

            var header = Data()
            header.appendLittleEndian(UInt32(0x0403_4B50))
            header.appendLittleEndian(UInt16(usesZip64 ? 45 : 20))
            header.appendLittleEndian(entry.flags)
            header.appendLittleEndian(entry.method)
            header.appendLittleEndian(UInt16(0))
            header.appendLittleEndian(UInt16(0x21))
            header.appendLittleEndian(entry.crc)
            header.appendLittleEndian(UInt32(entry.payload.count))
            header.appendLittleEndian(UInt32(entry.uncompressedSize))
            header.appendLittleEndian(UInt16(nameBytes.count))
            header.appendLittleEndian(UInt16(0))
            header.append(contentsOf: nameBytes)
            output.append(header)
            output.append(entry.payload)
        }

        for (index, entry) in entries.enumerated() {
            let nameBytes = Array(entry.name.utf8)
            var extra = Data()
            if usesZip64 {
                extra.appendLittleEndian(UInt16(0x0001))
                extra.appendLittleEndian(UInt16(24))
                extra.appendLittleEndian(UInt64(entry.uncompressedSize))
                extra.appendLittleEndian(UInt64(entry.payload.count))
                extra.appendLittleEndian(UInt64(localOffsets[index]))
            }

            var record = Data()
            record.appendLittleEndian(UInt32(0x0201_4B50))
            record.appendLittleEndian(UInt16(usesZip64 ? 45 : 20))
            record.appendLittleEndian(UInt16(usesZip64 ? 45 : 20))
            record.appendLittleEndian(entry.flags)
            record.appendLittleEndian(entry.method)
            record.appendLittleEndian(UInt16(0))
            record.appendLittleEndian(UInt16(0x21))
            record.appendLittleEndian(entry.crc)
            record.appendLittleEndian(usesZip64 ? UInt32(0xFFFF_FFFF) : UInt32(entry.payload.count))
            record.appendLittleEndian(usesZip64 ? UInt32(0xFFFF_FFFF) : UInt32(entry.uncompressedSize))
            record.appendLittleEndian(UInt16(nameBytes.count))
            record.appendLittleEndian(UInt16(extra.count))
            record.appendLittleEndian(UInt16(0))
            record.appendLittleEndian(UInt16(0))
            record.appendLittleEndian(UInt16(0))
            record.appendLittleEndian(UInt32(0))
            record.appendLittleEndian(usesZip64 ? UInt32(0xFFFF_FFFF) : UInt32(localOffsets[index]))
            record.append(contentsOf: nameBytes)
            record.append(extra)
            directory.append(record)
        }

        let directoryOffset = output.count
        output.append(directory)

        if usesZip64 {
            let recordOffset = output.count
            output.appendLittleEndian(UInt32(0x0606_4B50))
            output.appendLittleEndian(UInt64(44))            // size of the remainder of this record
            output.appendLittleEndian(UInt16(45))
            output.appendLittleEndian(UInt16(45))
            output.appendLittleEndian(UInt32(0))
            output.appendLittleEndian(UInt32(0))
            output.appendLittleEndian(UInt64(entries.count))
            output.appendLittleEndian(UInt64(entries.count))
            output.appendLittleEndian(UInt64(directory.count))
            output.appendLittleEndian(UInt64(directoryOffset))

            output.appendLittleEndian(UInt32(0x0706_4B50))
            output.appendLittleEndian(UInt32(0))
            output.appendLittleEndian(UInt64(recordOffset))
            output.appendLittleEndian(UInt32(1))
        }

        output.appendLittleEndian(UInt32(0x0605_4B50))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(UInt16(0))
        output.appendLittleEndian(usesZip64 ? UInt16(0xFFFF) : UInt16(entries.count))
        output.appendLittleEndian(usesZip64 ? UInt16(0xFFFF) : UInt16(entries.count))
        output.appendLittleEndian(usesZip64 ? UInt32(0xFFFF_FFFF) : UInt32(directory.count))
        output.appendLittleEndian(usesZip64 ? UInt32(0xFFFF_FFFF) : UInt32(directoryOffset))
        output.appendLittleEndian(UInt16(0))
        return output
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        for shift in stride(from: 0, to: value.bitWidth, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> T(shift)))
        }
    }
}

/// Pulls a genuine DEFLATE stream back out of an archive the writer produced,
/// so tests can reuse it in packages the writer would never build.
private func deflatedStream(for source: Data) throws -> Data {
    let archive = try ZipArchive.archive(entries: [("source.bin", source)])
    let bytes = [UInt8](archive)
    func uint16(_ offset: Int) -> Int { Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) }
    func uint32(_ offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | (Int(bytes[offset + $1]) << (8 * $1)) }
    }
    try #require(uint16(8) == 8, "the writer was expected to deflate this payload")
    let start = 30 + uint16(26) + uint16(28)
    return Data(bytes[start..<(start + uint32(18))])
}

private extension ZipError {
    var isNotAnArchive: Bool {
        if case .notAnArchive = self { return true }
        return false
    }

    var isProtectedOrLegacyWorkbook: Bool {
        if case .protectedOrLegacyWorkbook = self { return true }
        return false
    }

    var encryptedEntryName: String? {
        if case .encryptedEntry(let name) = self { return name }
        return nil
    }
}

@Suite("ZIP robustness")
struct ZipRobustnessTests {

    // MARK: - ZIP64

    @Test("A ZIP64 central directory reads through the extra fields")
    func zip64StoredEntries() throws {
        let first = Data("content types go here".utf8)
        let second = Data((0..<2048).map { UInt8($0 % 251) })
        let archive = TestZipBuilder(usesZip64: true).build([
            .stored("[Content_Types].xml", first),
            .stored("xl/media/image1.bin", second),
        ])

        let entries = try ZipArchive.entries(in: archive)
        #expect(entries.count == 2)
        #expect(entries["[Content_Types].xml"] == first)
        #expect(entries["xl/media/image1.bin"] == second)
    }

    @Test("A ZIP64 deflated entry inflates to the size named in the extra field")
    func zip64DeflatedEntry() throws {
        let source = Data(String(repeating: "spreadsheet ", count: 5_000).utf8)
        let stream = try deflatedStream(for: source)
        let archive = TestZipBuilder(usesZip64: true).build([
            TestZipBuilder.Entry(name: "xl/worksheets/sheet1.xml", payload: stream, method: 8,
                                 crc: ZipArchive.crc32(source), uncompressedSize: source.count),
        ])

        #expect(try ZipArchive.entries(in: archive)["xl/worksheets/sheet1.xml"] == source)
    }

    @Test("The ZIP64 locator, not the saturated classic field, finds the directory")
    func zip64LocatorIsFollowed() throws {
        let payload = Data("located via zip64".utf8)
        var archive = TestZipBuilder(usesZip64: true).build([.stored("a.txt", payload)])

        // Without the locator the classic record's 0xFFFFFFFF offset is unusable,
        // so breaking its signature must break reading — proving it was used.
        #expect(try ZipArchive.entries(in: archive)["a.txt"] == payload)
        let locatorSignature = archive.count - 22 - 20
        archive[locatorSignature] = 0x00
        #expect(throws: (any Error).self) {
            _ = try ZipArchive.entries(in: archive)
        }
    }

    @Test("A ZIP64 extra field too short for its declared values is rejected")
    func zip64TruncatedExtraField() throws {
        let payload = Data("short extra".utf8)
        var archive = TestZipBuilder(usesZip64: true).build([.stored("a.txt", payload)])

        // Shrink the extra field's declared body from 24 bytes to 8, leaving the
        // compressed size and local offset with nowhere to come from.
        guard let field = archive.range(of: Data([0x01, 0x00, 0x18, 0x00])) else {
            Issue.record("expected a ZIP64 extra field header in the built archive")
            return
        }
        archive[field.lowerBound + 2] = 0x08
        #expect(throws: (any Error).self) {
            _ = try ZipArchive.entries(in: archive)
        }
    }

    // MARK: - Diagnosing non-ZIP and protected input

    @Test("An OLE compound file is named as protected or legacy, not as invalid")
    func compoundFileIsDiagnosed() {
        var file = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        file.append(Data(repeating: 0x00, count: 4096))

        let error = #expect(throws: ZipError.self) { try ZipArchive.entries(in: file) }
        #expect(error?.isProtectedOrLegacyWorkbook == true)
    }

    @Test("A compound file wins over the generic message even when ZIP-like bytes follow")
    func compoundFileBeatsTrailingZipBytes() throws {
        let inner = TestZipBuilder().build([.stored("a.txt", Data("hi".utf8))])
        var file = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        file.append(inner)

        let error = #expect(throws: ZipError.self) { try ZipArchive.entries(in: file) }
        #expect(error?.isProtectedOrLegacyWorkbook == true)
    }

    @Test("An encrypted entry is named rather than decoded into noise")
    func encryptedEntryIsDiagnosed() {
        let archive = TestZipBuilder().build([
            .stored("[Content_Types].xml", Data("plain".utf8)),
            .stored("xl/workbook.xml", Data("scrambled".utf8), flags: 1),
        ])

        let error = #expect(throws: ZipError.self) { try ZipArchive.entries(in: archive) }
        #expect(error?.encryptedEntryName == "xl/workbook.xml")
    }

    @Test("Plain garbage still reports the generic package message")
    func garbageKeepsGenericMessage() {
        let error = #expect(throws: ZipError.self) {
            try ZipArchive.entries(in: Data(repeating: 0x41, count: 512))
        }
        #expect(error?.isNotAnArchive == true)
    }

    // MARK: - Damaged payloads

    @Test("A truncated DEFLATE stream throws instead of returning short data")
    func truncatedDeflateThrows() throws {
        let source = Data(String(repeating: "spreadsheet ", count: 5_000).utf8)
        let stream = try deflatedStream(for: source)
        let truncated = stream.prefix(stream.count / 2)

        let archive = TestZipBuilder().build([
            TestZipBuilder.Entry(name: "xl/worksheets/sheet1.xml", payload: Data(truncated), method: 8,
                                 crc: ZipArchive.crc32(source), uncompressedSize: source.count),
        ])

        #expect(throws: (any Error).self) {
            _ = try ZipArchive.entries(in: archive)
        }
    }

    @Test("A DEFLATE stream with no declared size still round-trips when intact")
    func missingDeclaredSizeStillInflates() throws {
        let source = Data(String(repeating: "totals and subtotals ", count: 3_000).utf8)
        let stream = try deflatedStream(for: source)

        // Some writers leave the directory sizes at zero and rely on the reader
        // growing its own buffer; the CRC still has to match afterwards.
        let archive = TestZipBuilder().build([
            TestZipBuilder.Entry(name: "sheet.xml", payload: stream, method: 8,
                                 crc: ZipArchive.crc32(source), uncompressedSize: 0),
        ])

        #expect(try ZipArchive.entries(in: archive)["sheet.xml"] == source)
    }

    @Test("A payload whose bytes were altered fails the checksum")
    func corruptedPayloadFailsChecksum() throws {
        let source = Data(String(repeating: "quarterly ", count: 4_000).utf8)
        var stream = try deflatedStream(for: source)
        stream[stream.count / 2] ^= 0xFF

        let archive = TestZipBuilder().build([
            TestZipBuilder.Entry(name: "sheet.xml", payload: stream, method: 8,
                                 crc: ZipArchive.crc32(source), uncompressedSize: source.count),
        ])

        #expect(throws: (any Error).self) {
            _ = try ZipArchive.entries(in: archive)
        }
    }

    @Test("A compressed size running past the end of the file is rejected")
    func overlongCompressedSizeIsRejected() {
        let content = Data("hello".utf8)
        var entry = TestZipBuilder.Entry.stored("a.txt", content)
        entry.uncompressedSize = 5
        var archive = TestZipBuilder().build([entry])

        // Inflate the directory's compressed size well past the archive itself.
        guard let record = archive.range(of: Data([0x50, 0x4B, 0x01, 0x02])) else {
            Issue.record("expected a central directory record in the built archive")
            return
        }
        archive.replaceSubrange((record.lowerBound + 20)..<(record.lowerBound + 24),
                                with: [0x00, 0x00, 0x10, 0x00])
        #expect(throws: (any Error).self) {
            _ = try ZipArchive.entries(in: archive)
        }
    }

    // MARK: - Round trips

    @Test("Classic archives written by the app still read back unchanged")
    func classicRoundTripStillWorks() throws {
        let small = Data("hello".utf8)
        let large = Data(String(repeating: "spreadsheet ", count: 5_000).utf8)
        let empty = Data()

        let archive = try ZipArchive.archive(entries: [
            ("a.txt", small), ("nested/b.xml", large), ("empty.txt", empty),
        ])
        let entries = try ZipArchive.entries(in: archive)

        #expect(entries["a.txt"] == small)
        #expect(entries["nested/b.xml"] == large)
        #expect(entries["empty.txt"] == empty)
    }

    @Test("A saved workbook still opens after the reader changes")
    func workbookRoundTripStillWorks() throws {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .text("Region"), formula: nil, style: .default)
        sheet[CellAddress(a1: "B1")!] = Cell(value: .number(42), formula: nil, style: .default)

        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let reloaded = try XLSXReader.workbook(from: data)
        #expect(reloaded.sheets[0][CellAddress(a1: "A1")!].value == .text("Region"))
        #expect(reloaded.sheets[0][CellAddress(a1: "B1")!].value == .number(42))
    }
}
