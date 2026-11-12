import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Formats given to whole columns (`<col style>`) and rows (`<row s
/// customFormat>`): read, shown on the cells without a record of their own,
/// taken on by what is typed there, moved with their lines and saved back.
@Suite("Column and row styles")
struct LineStyleTests {

    // MARK: - Helpers

    /// Column B is filled yellow with a currency format, row 3 is bold and
    /// filled blue, and every column from F on is italic.
    private let styles = """
    <?xml version="1.0" encoding="UTF-8"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <numFmts count="1"><numFmt numFmtId="164" formatCode="&quot;$&quot;#,##0.00"/></numFmts>\
    <fonts count="3"><font><sz val="11"/></font><font><b/><sz val="11"/></font><font><i/><sz val="11"/></font></fonts>\
    <fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/></patternFill></fill>\
    <fill><patternFill patternType="solid"><fgColor rgb="FF9BC2E6"/></patternFill></fill></fills>\
    <borders count="1"><border/></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
    <xf numFmtId="164" fontId="0" fillId="2" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>\
    <xf numFmtId="0" fontId="1" fillId="3" borderId="0" xfId="0" applyFont="1" applyFill="1"/>\
    <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
    </styleSheet>
    """

    private let sheetXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <cols><col min="2" max="2" width="12" style="1" customWidth="1"/>\
    <col min="6" max="16384" width="9" style="3"/></cols><sheetData>\
    <row r="1"><c r="A1"><v>1</v></c></row>\
    <row r="3" s="2" customFormat="1"/>\
    <row r="4" s="2"/>\
    <row r="7"><c r="B7"/></row>\
    </sheetData></worksheet>
    """

    private func package(sheet: String) throws -> Data {
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
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ])
    }

    private func readSheet() throws -> Worksheet {
        try XLSXReader.workbook(from: package(sheet: sheetXML)).sheets[0]
    }

    private func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    // MARK: - Reading

    @Test("Empty cells show their column's and row's format, the row's winning")
    func readsLineStyles() throws {
        let sheet = try readSheet()
        let column = sheet[address("B10")].style
        #expect(column.fillColorHex == "FFFFFF00")
        #expect(column.numberFormat == "\"$\"#,##0.00")
        let row = sheet[address("D3")].style
        #expect(row.isBold)
        #expect(row.fillColorHex == "FF9BC2E6")
        // Where they cross, the row's format wins, as in Excel.
        #expect(sheet[address("B3")].style == row)
        #expect(sheet[address("A10")].style.isDefault)
        #expect(sheet[address("H2")].style.isItalic)
        // None of it costs a record per cell.
        #expect(sheet.cells.count == 2)
    }

    @Test("A row's `s` without customFormat is no format of the row's")
    func ignoresRowStyleWithoutCustomFormat() throws {
        let sheet = try readSheet()
        #expect(sheet.rowStyles[3] == nil)
        #expect(sheet[address("D4")].style.isDefault)
    }

    @Test("A cell's own record, even with no style, wins over its column's")
    func ownRecordWins() throws {
        let sheet = try readSheet()
        #expect(sheet.cells[address("B7")] != nil)
        #expect(sheet[address("B7")].style.isDefault)
    }

    @Test("A format over every column there is stays one run")
    func wholeRowRunStaysBounded() throws {
        let sheet = try readSheet()
        #expect(sheet.columnStyles.keys.allSatisfy { $0 < Worksheet.maximumColumnCount })
        let xml = try savedSheetXML(sheet)
        #expect(xml.contains("<col min=\"6\" max=\"\(Worksheet.maximumColumnCount)\""))
    }

    // MARK: - Editing

    @Test("A value typed into a formatted column takes the column's format")
    func typedValueTakesColumnFormat() throws {
        var sheet = try readSheet()
        let target = address("B12")
        sheet[target] = CellInputParser.cell(from: "1234.5", inheriting: sheet[target].style)
        #expect(sheet[target].value == .number(1234.5))
        #expect(sheet[target].style.numberFormat == "\"$\"#,##0.00")
        #expect(CellFormatter.displayText(for: sheet[target]) == "$1,234.50")
    }

    @Test("A blank cell styled as its line is no record; clearing its format makes one")
    func blankCellsFollowTheirLine() throws {
        var sheet = try readSheet()
        let target = address("B12")
        sheet[target] = Cell(value: .number(5), style: sheet[target].style)
        var cleared = sheet[target]
        cleared.value = .empty
        sheet[target] = cleared
        #expect(sheet.cells[target] == nil)

        var plain = sheet[target]
        plain.style = .default
        sheet[target] = plain
        #expect(sheet.cells[target] != nil)
        #expect(sheet[target].style.isDefault)
    }

    @Test("Column and row formats move with their lines")
    func stylesFollowStructureEdits() throws {
        var sheet = try readSheet()
        let column = sheet.columnStyles[1]
        let row = sheet.rowStyles[2]

        sheet.insertColumns(1, at: 0)
        #expect(sheet.columnStyles[1] == nil)
        #expect(sheet.columnStyles[2] == column)
        #expect(sheet[address("C10")].style.fillColorHex == "FFFFFF00")
        #expect(sheet[address("B10")].style.isDefault)

        sheet.insertRows(2, at: 0)
        #expect(sheet.rowStyles[4] == row)
        #expect(sheet[address("A5")].style.isBold)

        sheet.removeRows(0...1)
        #expect(sheet.rowStyles[2] == row)
        sheet.removeRows(2...2)
        #expect(sheet.rowStyles.isEmpty)

        sheet.removeColumns(0...0)
        #expect(sheet.columnStyles[1] == column)
        sheet.removeColumns(1...1)
        #expect(sheet.columnStyles[1] == nil)
        #expect(sheet.columnStyles.values.allSatisfy { $0.isItalic })
    }

    @Test("Moving cells out of a formatted column leaves its format behind")
    func movedCellsLeaveLineFormat() throws {
        var workbook = Workbook(sheets: [try readSheet()])
        let id = workbook.sheets[0].id
        workbook.sheets[0][address("B12")] = Cell(value: .number(7), style: .default)
        let moved = workbook.moveCells(CellRange(address("B12")), on: id, to: address("A12"))
        #expect(moved)
        #expect(workbook.sheets[0].cells[address("B12")] == nil)
        #expect(workbook.sheets[0][address("B12")].style.fillColorHex == "FFFFFF00")
    }

    // MARK: - Drawing

    @Test("A change to a line's format redraws the sheet's tiles")
    func drawingKeyNotesLineStyles() throws {
        var sheet = try readSheet()
        let before = SheetDrawingKey(sheet)
        #expect(SheetDrawingKey(sheet) == before)
        sheet.columnStyles[1] = nil
        #expect(SheetDrawingKey(sheet) != before)
        sheet = try readSheet()
        let unchanged = SheetDrawingKey(sheet)
        sheet.rowStyles[2]?.isItalic = true
        #expect(SheetDrawingKey(sheet) != unchanged)
    }

    @Test("A column's borders are drawn on the cells without a record")
    func columnBordersResolve() {
        var sheet = Worksheet(name: "S")
        var style = CellStyle.default
        style.borderSides[.bottom] = BorderSide(lineStyle: .thin, colorHex: "FF000000")
        sheet.columnStyles[1] = style
        let resolver = BorderResolver(sheet: sheet, metrics: SheetMetrics(sheet: sheet, zoom: 1))
        #expect(resolver.assignedSide(.bottom, of: CellRange(address("B4")), at: 1) != nil)
        #expect(resolver.assignedSide(.bottom, of: CellRange(address("A4")), at: 0) == nil)
    }

    // MARK: - Saving

    private func savedSheetXML(_ sheet: Worksheet) throws -> String {
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: Workbook(sheets: [sheet])))
        return String(decoding: try #require(entries["xl/worksheets/sheet1.xml"]), as: UTF8.self)
    }

    @Test("Column and row formats are written back and read again")
    func roundTrips() throws {
        let sheet = try readSheet()
        let xml = try savedSheetXML(sheet)
        #expect(xml.contains("<col min=\"2\" max=\"2\""))
        #expect(xml.contains("style=\""))
        #expect(xml.contains("customFormat=\"1\""))

        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let reread = try XLSXReader.workbook(from: data).sheets[0]
        #expect(reread.columnStyles[1] == sheet.columnStyles[1])
        #expect(reread.rowStyles[2] == sheet.rowStyles[2])
        #expect(reread[address("B3")].style == sheet[address("B3")].style)
        #expect(reread[address("B7")].style.isDefault)
        #expect(reread.columnStyles.count == sheet.columnStyles.count)
    }
}
