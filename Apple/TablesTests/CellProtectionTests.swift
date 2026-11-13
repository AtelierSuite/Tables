import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Cell protection flags, reading order and the quote prefix: what the reader
/// makes of them, what the writer puts back, and how reading order sets text.
@Suite("Cell protection, reading order and quote prefix")
struct CellProtectionTests {

    // MARK: - Helpers

    /// A package whose A1, A2… use the `<xf>` elements given, in order.
    private func package(formats: [String]) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/></Types>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="xl/workbook.xml"/></Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" \
        Target="styles.xml"/></Relationships>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill>\
        <fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border/></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="\(formats.count)">\(formats.joined())</cellXfs></styleSheet>
        """
        let rows = formats.indices.map { index in
            "<row r=\"\(index + 1)\"><c r=\"A\(index + 1)\" s=\"\(index)\" t=\"inlineStr\"><is><t>x</t></is></c></row>"
        }
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetData>\(rows.joined())</sheetData></worksheet>
        """
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ])
    }

    private func read(formats: [String]) throws -> [CellStyle] {
        let sheet = try XLSXReader.workbook(from: package(formats: formats)).sheets[0]
        return formats.indices.map { sheet[CellAddress(row: $0, column: 0)].style }
    }

    private func saved(_ styles: [CellStyle]) throws -> Data {
        var sheet = Worksheet(name: "S")
        sheet.rowCount = max(sheet.rowCount, styles.count)
        for (row, style) in styles.enumerated() {
            sheet[CellAddress(row: row, column: 0)] = Cell(value: .text("x"), formula: nil, style: style)
        }
        return try XLSXWriter.data(from: Workbook(sheets: [sheet]))
    }

    private func roundTripped(_ styles: [CellStyle]) throws -> [CellStyle] {
        let read = try XLSXReader.workbook(from: saved(styles)).sheets[0]
        return styles.indices.map { read[CellAddress(row: $0, column: 0)].style }
    }

    private func stylesXML(_ styles: [CellStyle]) throws -> String {
        let entries = try ZipArchive.entries(in: saved(styles))
        let data = try #require(entries["xl/styles.xml"])
        return String(decoding: data, as: UTF8.self)
    }

    private func style(_ change: (inout CellStyle) -> Void) -> CellStyle {
        var style = CellStyle()
        change(&style)
        return style
    }

    // MARK: - Reading

    @Test("Protection flags are read, with locked on unless a file turns it off")
    func protectionIsRead() throws {
        let styles = try read(formats: [
            "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>",
            "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" applyProtection=\"1\"><protection locked=\"0\"/></xf>",
            "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" applyProtection=\"1\"><protection hidden=\"1\"/></xf>",
            "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"><protection locked=\"false\" hidden=\"true\"/></xf>",
        ])
        #expect(styles[0].isLocked && !styles[0].isFormulaHidden)
        #expect(!styles[1].isLocked && !styles[1].isFormulaHidden)
        #expect(styles[2].isLocked && styles[2].isFormulaHidden)
        #expect(!styles[3].isLocked && styles[3].isFormulaHidden)
    }

    @Test("Reading order and the quote prefix are read")
    func readingOrderAndQuotePrefixAreRead() throws {
        let styles = try read(formats: [
            "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"><alignment readingOrder=\"0\"/></xf>",
            "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"><alignment readingOrder=\"1\"/></xf>",
            "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"><alignment readingOrder=\"2\"/></xf>",
            "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"><alignment readingOrder=\"7\"/></xf>",
            "<xf numFmtId=\"49\" fontId=\"0\" fillId=\"0\" borderId=\"0\" quotePrefix=\"1\"/>",
        ])
        #expect(styles.map(\.readingOrder) == [.context, .leftToRight, .rightToLeft, .context, .context])
        #expect(styles.map(\.hasQuotePrefix) == [false, false, false, false, true])
    }

    // MARK: - Writing

    @Test("All three survive a save")
    func roundTrip() throws {
        let styles = [
            CellStyle(),
            style { $0.isLocked = false },
            style { $0.isFormulaHidden = true },
            style { $0.isLocked = false; $0.isFormulaHidden = true },
            style { $0.readingOrder = .leftToRight },
            style { $0.readingOrder = .rightToLeft; $0.horizontalAlignment = .center },
            style { $0.hasQuotePrefix = true; $0.numberFormat = "@" },
        ]
        #expect(try roundTripped(styles) == styles)
    }

    @Test("The saved formats carry the attributes where Excel expects them")
    func writtenXML() throws {
        let xml = try stylesXML([
            CellStyle(),
            style { $0.isLocked = false; $0.isFormulaHidden = true },
            style { $0.readingOrder = .rightToLeft },
            style { $0.hasQuotePrefix = true },
        ])
        #expect(xml.contains("<protection locked=\"0\" hidden=\"1\"/></xf>"))
        #expect(xml.contains("applyProtection=\"1\""))
        #expect(xml.contains("readingOrder=\"2\"/></xf>"))
        #expect(xml.contains("quotePrefix=\"1\""))
        // A default cell keeps the defaults implicit.
        #expect(xml.components(separatedBy: "<protection").count == 2)
        #expect(!xml.contains("readingOrder=\"0\""))
    }

    // MARK: - Querying

    @Test("A sheet answers whether a cell is locked or hides its formula")
    func perCellQuery() {
        var sheet = Worksheet(name: "S")
        let unlocked = CellAddress(row: 0, column: 0)
        let hidden = CellAddress(row: 1, column: 0)
        sheet[unlocked] = Cell(value: .number(1), formula: nil, style: style { $0.isLocked = false })
        sheet[hidden] = Cell(value: .number(2), formula: "1+1", style: style { $0.isFormulaHidden = true })
        #expect(!sheet.isLocked(at: unlocked))
        #expect(sheet.isLocked(at: hidden))
        #expect(sheet.isFormulaHidden(at: hidden))
        #expect(!sheet.isFormulaHidden(at: unlocked))
        // A cell that was never formatted is locked, as in Excel.
        #expect(sheet.isLocked(at: CellAddress(row: 9, column: 9)))
        #expect(!sheet.isFormulaHidden(at: CellAddress(row: 9, column: 9)))
    }

    // MARK: - Drawing

    @Test("Reading order sets the direction text is drawn in")
    func readingOrderSetsDirection() {
        let latin = "Hello, world!"
        let hebrew = "שלום עולם!"
        func cell(_ text: String, _ order: ReadingOrder) -> Cell {
            Cell(value: .text(text), formula: nil, style: style { $0.readingOrder = order })
        }
        // Context leaves the text alone, to be read from its first letter.
        #expect(CellFormatter.directed(latin, for: cell(latin, .context)) == latin)
        #expect(CellFormatter.directed(hebrew, for: cell(hebrew, .context)) == hebrew)
        // An order the text already reads in needs no mark.
        #expect(CellFormatter.directed(latin, for: cell(latin, .leftToRight)) == latin)
        #expect(CellFormatter.directed(hebrew, for: cell(hebrew, .rightToLeft)) == hebrew)
        // One it does not is led by the mark that sets it, on every line.
        let rtl = CellFormatter.directed(latin, for: cell(latin, .rightToLeft))
        #expect(rtl == "\u{200F}" + latin)
        #expect(TextFitting.baseDirection(of: rtl) == .rightToLeft)
        let ltr = CellFormatter.directed(hebrew, for: cell(hebrew, .leftToRight))
        #expect(ltr == "\u{200E}" + hebrew)
        #expect(TextFitting.baseDirection(of: ltr) == .leftToRight)
        #expect(ReadingOrder.rightToLeft.directed("a\nb") == "\u{200F}a\n\u{200F}b")
        // A number keeps the order its format gives it.
        let number = Cell(value: .number(-5), formula: nil, style: style { $0.readingOrder = .rightToLeft })
        #expect(CellFormatter.directed("-5", for: number) == "-5")
    }

    @Test("Under automatic alignment text goes to its reading order's start")
    func readingOrderSetsAlignment() {
        func alignment(_ text: String, _ order: ReadingOrder) -> HorizontalTextAlignment {
            CellFormatter.alignment(for: Cell(value: .text(text), formula: nil, style: style { $0.readingOrder = order }))
        }
        #expect(alignment("Hello", .context) == .leading)
        #expect(alignment("مرحبا", .context) == .trailing)
        #expect(alignment("Hello", .rightToLeft) == .trailing)
        #expect(alignment("مرحبا", .leftToRight) == .leading)
        // An alignment of the cell's own is kept.
        let centred = Cell(value: .text("Hello"), formula: nil, style: style {
            $0.readingOrder = .rightToLeft; $0.horizontalAlignment = .center
        })
        #expect(CellFormatter.alignment(for: centred) == .center)
        // Numbers stay where General puts them.
        let number = Cell(value: .number(1), formula: nil, style: style { $0.readingOrder = .rightToLeft })
        #expect(CellFormatter.alignment(for: number) == .trailing)
    }
}
