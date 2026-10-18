import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Tables
@testable import TablesEngine

@Suite("ZIP container")
struct ZipArchiveTests {
    @Test("Entries survive a write/read round trip")
    func roundTrip() throws {
        let small = Data("hello".utf8)
        let large = Data(String(repeating: "spreadsheet ", count: 5_000).utf8)
        let binary = Data((0..<4096).map { UInt8($0 % 251) })

        let archive = try ZipArchive.archive(entries: [
            ("a.txt", small), ("nested/b.xml", large), ("c.bin", binary),
        ])
        let entries = try ZipArchive.entries(in: archive)

        #expect(entries.count == 3)
        #expect(entries["a.txt"] == small)
        #expect(entries["nested/b.xml"] == large)
        #expect(entries["c.bin"] == binary)
    }

    @Test("Entries read back in the archive's order, and can be stored uncompressed")
    func orderAndStorage() throws {
        let text = Data(String(repeating: "Index ", count: 500).utf8)
        let entries = [("Index/Document.iwa", text), ("Data/b.png", Data([1, 2])), ("Index/A.iwa", text)]
        let stored = try ZipArchive.archive(entries: entries, compressing: false)
        #expect(try ZipArchive.orderedEntries(in: stored).map(\.path) == entries.map(\.0))
        #expect(stored.count > text.count * 2, "nothing was deflated")
        #expect(try ZipArchive.archive(entries: entries).count < stored.count)
    }

    @Test("Non-archives are rejected rather than misread")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try ZipArchive.entries(in: Data(repeating: 0x41, count: 512))
        }
    }

    @Test("CRC-32 matches the known check value")
    func checksum() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

@Suite("XLSX round trip")
struct XLSXTests {
    private func sampleWorkbook() -> Workbook {
        var first = Worksheet(name: "Numbers")
        first.rowCount = 24
        first.columnCount = 6

        var bold = CellStyle.default
        bold.isBold = true
        bold.fillColorHex = "FFFFE08A"
        bold.horizontalAlignment = .center

        var currency = CellStyle.default
        currency.numberFormat = NumberFormatPreset.currency.code
        currency.borders = .all

        first[CellAddress(a1: "A1")!] = Cell(value: .text("Region"), formula: nil, style: bold)
        first[CellAddress(a1: "B1")!] = Cell(value: .text("Revenue"), formula: nil, style: bold)
        first[CellAddress(a1: "A2")!] = Cell(value: .text("North"), formula: nil, style: .default)
        first[CellAddress(a1: "B2")!] = Cell(value: .number(1200.5), formula: nil, style: currency)
        first[CellAddress(a1: "A3")!] = Cell(value: .text("South"), formula: nil, style: .default)
        first[CellAddress(a1: "B3")!] = Cell(value: .number(980), formula: nil, style: currency)
        first[CellAddress(a1: "B4")!] = Cell(value: .empty, formula: "SUM(B2:B3)", style: currency)
        first[CellAddress(a1: "C2")!] = Cell(value: .boolean(true), formula: nil, style: .default)
        first[CellAddress(a1: "C3")!] = Cell(value: .error(.notAvailable), formula: nil, style: .default)

        first.columnWidths[0] = 160
        first.rowHeights[0] = 44
        first.hiddenColumns.insert(4)
        first.hiddenRows.insert(9)

        let second = Worksheet(name: "Empty Sheet")

        var workbook = Workbook(sheets: [first, second])
        workbook.recalculate()
        return workbook
    }

    @Test("Values, formulas and structure survive a save/open cycle")
    func roundTrip() throws {
        let original = sampleWorkbook()
        let data = try XLSXWriter.data(from: original)
        let reloaded = try XLSXReader.workbook(from: data)

        #expect(reloaded.sheets.count == 2)
        #expect(reloaded.sheets[0].name == "Numbers")
        #expect(reloaded.sheets[1].name == "Empty Sheet")

        let sheet = reloaded.sheets[0]
        #expect(sheet[CellAddress(a1: "A1")!].value == .text("Region"))
        #expect(sheet[CellAddress(a1: "B2")!].value == .number(1200.5))
        #expect(sheet[CellAddress(a1: "C2")!].value == .boolean(true))
        #expect(sheet[CellAddress(a1: "C3")!].value == .error(.notAvailable))
        #expect(sheet[CellAddress(a1: "B4")!].formula == "SUM(B2:B3)")
        #expect(sheet[CellAddress(a1: "B4")!].value == .number(2180.5))

        #expect(sheet.hiddenColumns.contains(4))
        #expect(sheet.hiddenRows.contains(9))
        #expect(abs(sheet.width(ofColumn: 0) - 160) < 2)
    }

    @Test("Formatting survives a save/open cycle")
    func formatting() throws {
        let data = try XLSXWriter.data(from: sampleWorkbook())
        let sheet = try XLSXReader.workbook(from: data).sheets[0]

        let header = sheet[CellAddress(a1: "A1")!].style
        #expect(header.isBold)
        #expect(header.fillColorHex == "FFFFE08A")
        #expect(header.horizontalAlignment == .center)

        let money = sheet[CellAddress(a1: "B2")!].style
        #expect(money.numberFormat == NumberFormatPreset.currency.code)
        #expect(money.borders == .all)
    }

    @Test("The package really is a ZIP with the expected parts")
    func packageLayout() throws {
        let data = try XLSXWriter.data(from: sampleWorkbook())
        #expect(data.starts(with: [0x50, 0x4B]))

        let entries = try ZipArchive.entries(in: data)
        #expect(entries["[Content_Types].xml"] != nil)
        #expect(entries["_rels/.rels"] != nil)
        #expect(entries["xl/workbook.xml"] != nil)
        #expect(entries["xl/styles.xml"] != nil)
        #expect(entries["xl/worksheets/sheet1.xml"] != nil)
        #expect(entries["xl/worksheets/sheet2.xml"] != nil)
    }

    @Test("Sheet names needing escapes round-trip")
    func escaping() throws {
        var sheet = Worksheet(name: "R&D <2024>")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .text("a \"quoted\" & <tagged> value"),
                                             formula: nil, style: .default)
        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let reloaded = try XLSXReader.workbook(from: data)
        #expect(reloaded.sheets[0].name == "R&D <2024>")
        #expect(reloaded.sheets[0][CellAddress(a1: "A1")!].value == .text("a \"quoted\" & <tagged> value"))
    }
}

@Suite("CSV")
struct CSVTests {
    @Test("Quoting, embedded delimiters and newlines parse correctly")
    func parsing() {
        let text = """
        name,note,amount
        Ada,"Says ""hello"", loudly",10
        Bob,"multi
        line",20

        """
        let workbook = CSVCodec.workbook(from: Data(text.utf8), sheetName: "Imported")
        let sheet = workbook.sheets[0]

        #expect(sheet[CellAddress(a1: "A2")!].value == .text("Ada"))
        #expect(sheet[CellAddress(a1: "B2")!].value == .text("Says \"hello\", loudly"))
        #expect(sheet[CellAddress(a1: "C2")!].value == .number(10))
        #expect(sheet[CellAddress(a1: "B3")!].value == .text("multi\nline"))
    }

    @Test("Semicolon files are sniffed")
    func delimiterSniffing() {
        let workbook = CSVCodec.workbook(from: Data("a;b;c\n1;2;3\n".utf8), sheetName: "S")
        #expect(workbook.sheets[0][CellAddress(a1: "C2")!].value == .number(3))
    }

    @Test("Export writes displayed values and re-imports cleanly")
    func exportRoundTrip() {
        let workbook = CSVCodec.workbook(
            from: Data("x,y\n1,2\n3,=A3+B2\n".utf8), sheetName: "S"
        )
        let exported = CSVCodec.data(from: workbook.sheets[0])
        let text = String(decoding: exported, as: UTF8.self)
        #expect(text.hasPrefix("x,y"))

        let reimported = CSVCodec.workbook(from: exported, sheetName: "S")
        #expect(reimported.sheets[0][CellAddress(a1: "A2")!].value == .number(1))
    }

    @Test("CRLF line endings split rows", arguments: ["\r\n", "\n", "\r"])
    func lineEndings(separator: String) {
        let text = ["a,b", "1,2", "3,4"].joined(separator: separator) + separator
        let sheet = CSVCodec.workbook(from: Data(text.utf8), sheetName: "S").sheets[0]
        #expect(sheet[CellAddress(a1: "A2")!].value == .number(1))
        #expect(sheet[CellAddress(a1: "B3")!].value == .number(4))
    }

    @Test("Delimiters inside quotes do not outvote the real separator")
    func delimiterSniffingIgnoresQuotedText() {
        // A European export: semicolons separate, commas are decimal points.
        let european = CSVCodec.workbook(
            from: Data("a;b\n\"1,5\";\"2,5\"\n".utf8), sheetName: "S"
        ).sheets[0]
        #expect(european[CellAddress(a1: "A1")!].value == .text("a"))
        #expect(european[CellAddress(a1: "B1")!].value == .text("b"))

        // And the reverse: a comma file whose text happens to be full of semicolons.
        let commas = CSVCodec.workbook(
            from: Data("a,b\n\"x;y;z;w\",\"p;q;r;s\"\n".utf8), sheetName: "S"
        ).sheets[0]
        #expect(commas[CellAddress(a1: "A2")!].value == .text("x;y;z;w"))
        #expect(commas[CellAddress(a1: "B2")!].value == .text("p;q;r;s"))
    }

    @Test("Text encodings other than UTF-8 decode", arguments: [
        String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf16, .isoLatin1
    ])
    func encodings(encoding: String.Encoding) throws {
        let data = try #require("nom,qté\nCafé,3\n".data(using: encoding))
        let sheet = CSVCodec.workbook(from: data, sheetName: "S").sheets[0]
        #expect(sheet[CellAddress(a1: "B1")!].value == .text("qté"))
        #expect(sheet[CellAddress(a1: "A2")!].value == .text("Café"))
        #expect(sheet[CellAddress(a1: "B2")!].value == .number(3))
    }

    @Test("A UTF-8 byte order mark is not mistaken for content")
    func byteOrderMark() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("name,qty\nApple,3\n".utf8)
        let sheet = CSVCodec.workbook(from: data, sheetName: "S").sheets[0]
        #expect(sheet[CellAddress(a1: "A1")!].value == .text("name"))
    }

    @Test("A blank import still gets the default grid")
    func defaultSize() {
        let workbook = CSVCodec.workbook(from: Data(), sheetName: "Blank")
        #expect(workbook.sheets[0].rowCount == Worksheet.defaultRowCount)
        #expect(workbook.sheets[0].columnCount == Worksheet.defaultColumnCount)
    }
}

@Suite("Document types")
struct DocumentTypeTests {
    @Test("The workbook type resolves to a real xlsx type on every platform")
    func workbookType() {
        #expect(UTType.openXMLWorkbook.identifier == "org.openxmlformats.spreadsheetml.sheet")
        #expect(UTType.openXMLWorkbook.preferredFilenameExtension == "xlsx")
        #expect(TablesDocument.writableContentTypes.first == .openXMLWorkbook)
    }

    @Test("The macro-enabled type resolves to xlsm and can be read and written")
    func macroEnabledWorkbookType() {
        #expect(UTType.macroEnabledWorkbook.identifier == "org.openxmlformats.spreadsheetml.sheet.macroenabled")
        #expect(UTType.macroEnabledWorkbook.preferredFilenameExtension == "xlsm")
        #expect(TablesDocument.readableContentTypes.contains(.macroEnabledWorkbook))
        #expect(TablesDocument.writableContentTypes.contains(.macroEnabledWorkbook))
        // Saving asks about the two separately because of this.
        #expect(!UTType.macroEnabledWorkbook.conforms(to: .openXMLWorkbook))
    }

    @Test("Every readable delimited type can also be written back")
    func delimitedTypesRoundTrip() {
        for type in [UTType.commaSeparatedText, .tabSeparatedText] {
            #expect(TablesDocument.readableContentTypes.contains(type))
            // Otherwise saving one would quietly write xlsx bytes into it.
            #expect(TablesDocument.writableContentTypes.contains(type))
        }
    }

    @Test("Tab separated text is its own type, not a kind of CSV")
    func tabSeparatedIsDistinct() {
        // The write path asks about the two separately because of this.
        #expect(!UTType.tabSeparatedText.conforms(to: .commaSeparatedText))
        #expect(UTType.tabSeparatedText.preferredFilenameExtension == "tsv")
    }

    @Test("A tab separated sheet round-trips through the codec")
    func tabSeparatedRoundTrip() {
        let sheet = CSVCodec.workbook(from: Data("a\tb\n1\t2\n".utf8), sheetName: "S").sheets[0]
        let exported = CSVCodec.data(from: sheet, delimiter: "\t")
        #expect(String(decoding: exported, as: UTF8.self).hasPrefix("a\tb"))

        let reimported = CSVCodec.workbook(from: exported, sheetName: "S").sheets[0]
        #expect(reimported[CellAddress(a1: "B2")!].value == .number(2))
    }
}
