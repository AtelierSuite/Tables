import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Table styles: what an XLSX table's `tableStyleInfo` and totals row are
/// read as, what the built-in styles give each cell, and that a save keeps
/// them.
@Suite("Table styles, banding and totals rows")
@MainActor
struct TableStyleTests {
    private func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    /// A theme colour at a tint, as the engine works it out for any cell.
    /// Excel rounds its own a step differently: D9E1F2 where this gives DAE3F3.
    private func tinted(_ rgb: String, _ tint: Double) -> String { "FF" + ThemeColorPalette.tinted(rgb, by: tint) }
    private var paleBlue: String { tinted("4472C4", 0.8) }
    private var softBlue: String { tinted("4472C4", 0.4) }

    private static let tableRelationship = """
    <Relationship Id="rId1" \
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/table" \
    Target="../tables/table1.xml"/>
    """

    /// A table over A1:C6: a header row, four rows of data and a totals row.
    private static func tableXML(
        style: String = "TableStyleMedium2", rowStripes: Bool = true, columnStripes: Bool = false,
        firstColumn: Bool = false, lastColumn: Bool = false
    ) -> String {
        func flag(_ value: Bool) -> String { value ? "1" : "0" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="1" name="Sales" \
        displayName="Sales" ref="A1:C6" totalsRowCount="1"><autoFilter ref="A1:C5"/>\
        <tableColumns count="3">\
        <tableColumn id="1" name="Item" totalsRowLabel="Total"/>\
        <tableColumn id="2" name="Price" totalsRowFunction="average"/>\
        <tableColumn id="3" name="Double" totalsRowFunction="sum">\
        <calculatedColumnFormula>Sales[[#This Row],[Price]]*2</calculatedColumnFormula></tableColumn>\
        </tableColumns>\
        <tableStyleInfo name="\(style)" showFirstColumn="\(flag(firstColumn))" \
        showLastColumn="\(flag(lastColumn))" showRowStripes="\(flag(rowStripes))" \
        showColumnStripes="\(flag(columnStripes))"/></table>
        """
    }

    /// A one-sheet workbook holding that table. B3 has a yellow fill of its
    /// own and C3 red text; every other cell is in the default style, whose
    /// text is the theme's black.
    private func package(table: String = TableStyleTests.tableXML()) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/styles.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        <Override PartName="/xl/tables/table1.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/></Types>
        """
        let rootRels = """
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
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRels = """
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
        <fonts count="2"><font><sz val="11"/><color theme="1"/><name val="Calibri"/></font>\
        <font><sz val="11"/><color rgb="FFFF0000"/><name val="Calibri"/></font></fonts>\
        <fills count="3"><fill><patternFill patternType="none"/></fill>\
        <fill><patternFill patternType="gray125"/></fill>\
        <fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/></patternFill></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyFill="1"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
        </styleSheet>
        """
        var rows = "<row r=\"1\"><c r=\"A1\" t=\"str\"><v>Item</v></c><c r=\"B1\" t=\"str\"><v>Price</v></c>"
            + "<c r=\"C1\" t=\"str\"><v>Double</v></c></row>"
        for row in 2...5 {
            let fill = row == 3 ? " s=\"1\"" : ""
            let text = row == 3 ? " s=\"2\"" : ""
            rows += "<row r=\"\(row)\"><c r=\"A\(row)\" t=\"str\"><v>Item \(row)</v></c>"
                + "<c r=\"B\(row)\"\(fill)><v>\(row * 10)</v></c><c r=\"C\(row)\"\(text)><v>\(row * 20)</v></c></row>"
        }
        rows += "<row r=\"6\"><c r=\"A6\" t=\"str\"><v>Total</v></c>"
            + "<c r=\"B6\"><f>SUBTOTAL(101,B2:B5)</f><v>35</v></c><c r=\"C6\"><f>SUBTOTAL(109,C2:C5)</f><v>280</v></c></row>"
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheetData>\(rows)</sheetData><tableParts count="1"><tablePart r:id="rId1"/></tableParts></worksheet>
        """
        let sheetRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(Self.tableRelationship)</Relationships>
        """
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
            ("xl/worksheets/_rels/sheet1.xml.rels", Data(sheetRels.utf8)),
            ("xl/tables/table1.xml", Data(table.utf8)),
        ])
    }

    private func open(_ table: String = TableStyleTests.tableXML()) throws -> Workbook {
        try XLSXReader.workbook(from: try package(table: table))
    }

    private func style(_ name: String) throws -> TableStyleDefinition {
        try #require(TableStyleDefinition.builtIn(named: name, theme: .office))
    }

    /// A 6-row, 3-column table at A1 with one header row and one totals row.
    private func format(
        _ name: String, rowStripes: Bool = true, columnStripes: Bool = false,
        firstColumn: Bool = false, lastColumn: Bool = false, totals: Int = 1
    ) throws -> TableFormat {
        TableFormat(
            range: CellRange(start: address("A1"), end: address("C6")), headerRowCount: 1, totalsRowCount: totals,
            info: TableStyleInfo(
                name: name, showsFirstColumn: firstColumn, showsLastColumn: lastColumn,
                showsRowStripes: rowStripes, showsColumnStripes: columnStripes),
            definition: try style(name))
    }

    // MARK: - Reading

    @Test("A table's style, its switches and its totals row are read")
    func readsStyleAndTotals() throws {
        let workbook = try open(Self.tableXML(style: "TableStyleLight9", columnStripes: true, firstColumn: true))
        let table = try #require(workbook.tables.first)
        #expect(table.style == TableStyleInfo(
            name: "TableStyleLight9", showsFirstColumn: true, showsLastColumn: false,
            showsRowStripes: true, showsColumnStripes: true))
        #expect(table.totalsRowCount == 1)
        #expect(table.columns == ["Item", "Price", "Double"])
        #expect(table.columnDetails.map(\.totalsLabel) == ["Total", nil, nil])
        #expect(table.columnDetails.map(\.totalsFunction) == [nil, "average", "sum"])
        #expect(table.columnDetails[2].calculatedFormula == "Sales[[#This Row],[Price]]*2")

        let format = try #require(workbook.sheets[0].tableFormats.first)
        #expect(workbook.sheets[0].tableFormats.count == 1)
        #expect(format.range == CellRange(start: address("A1"), end: address("C6")))
        #expect(format.headerRowCount == 1)
        #expect(format.totalsRowCount == 1)
        #expect(format.info == table.style)
        #expect(format.defaultTextColorHex == "FF000000")
    }

    @Test("A style the workbook defines itself draws nothing")
    func customStyleIsNotDrawn() throws {
        let workbook = try open(Self.tableXML(style: "My Own Style"))
        #expect(workbook.tables.first?.style?.name == "My Own Style")
        #expect(workbook.sheets[0].tableFormats.isEmpty)
        #expect(workbook.sheets[0].displayedCell(at: address("A1")).style.fillColorHex == nil)
    }

    @Test("Every built-in style name resolves, and no other")
    func builtInNames() {
        for (family, count) in [("Light", 21), ("Medium", 28), ("Dark", 11)] {
            for number in 1...count {
                #expect(TableStyleDefinition.builtIn(named: "TableStyle\(family)\(number)", theme: .office) != nil)
            }
            #expect(TableStyleDefinition.builtIn(named: "TableStyle\(family)\(count + 1)", theme: .office) == nil)
            #expect(TableStyleDefinition.builtIn(named: "TableStyle\(family)0", theme: .office) == nil)
        }
        #expect(TableStyleDefinition.builtIn(named: "PivotStyleLight16", theme: .office) == nil)
    }

    // MARK: - What a style gives a cell

    @Test("Medium 2 is drawn in Excel's colours for the Office theme")
    func mediumTwoMatchesExcel() throws {
        let sheet = try open().sheets[0]
        let header = sheet.displayedCell(at: address("B1")).style
        #expect(header.fillColorHex == "FF4472C4")
        #expect(header.textColorHex == "FFFFFFFF")
        #expect(header.isBold)

        // Bands on the first, third… rows of data, and nothing between.
        #expect(sheet.displayedCell(at: address("A2")).style.fillColorHex == paleBlue)
        #expect(sheet.displayedCell(at: address("A3")).style.fillColorHex == nil)
        #expect(sheet.displayedCell(at: address("A4")).style.fillColorHex == paleBlue)
        #expect(sheet.displayedCell(at: address("A5")).style.fillColorHex == nil)
        #expect(!sheet.displayedCell(at: address("A2")).style.isBold)

        let total = sheet.displayedCell(at: address("C6")).style
        #expect(total.isBold)
        #expect(total.fillColorHex == nil)

        let look = try #require(sheet.tableFormats[0].look(at: address("B6")))
        #expect(look.borderSides[.top] == BorderSide(lineStyle: .double, colorHex: "FF4472C4"))
        #expect(look.borderSides[.bottom] == BorderSide(lineStyle: .thin, colorHex: softBlue))
    }

    @Test("A cell's own fill and text colour stay over the table's")
    func ownFormattingWins() throws {
        let sheet = try open(Self.tableXML(style: "TableStyleDark2")).sheets[0]
        // Dark 2 fills every cell and makes its text white.
        #expect(sheet.displayedCell(at: address("A3")).style.textColorHex == "FFFFFFFF")
        #expect(sheet.displayedCell(at: address("A3")).style.fillColorHex == "FF4472C4")
        #expect(sheet.displayedCell(at: address("B3")).style.fillColorHex == "FFFFFF00")
        #expect(sheet.displayedCell(at: address("C3")).style.textColorHex == "FFFF0000")
        // The cells keep what they had: the style is only laid under them.
        #expect(sheet[address("A3")].style.fillColorHex == nil)
        #expect(sheet[address("B1")].style.isBold == false)
    }

    @Test("A conditional format is drawn over the table's style")
    func conditionalFormatWins() throws {
        var sheet = try open().sheets[0]
        sheet.conditionalStyles[address("A2")] = ConditionalStyle(fillColorHex: "FFFF0000")
        #expect(sheet.displayedCell(at: address("A2")).style.fillColorHex == "FFFF0000")
    }

    @Test("Row bands follow the switch")
    func rowBanding() throws {
        let banded = try format("TableStyleMedium2")
        let plain = try format("TableStyleMedium2", rowStripes: false)
        #expect(banded.look(at: address("A2"))?.fillColorHex != nil)
        #expect(banded.look(at: address("A3"))?.fillColorHex == nil)
        for row in 2...5 { #expect(plain.look(at: address("A\(row)"))?.fillColorHex == nil) }
        // Never on the header or the totals row.
        #expect(banded.look(at: address("A6"))?.fillColorHex == nil)
        #expect(banded.look(at: address("A1"))?.fillColorHex == "FF4472C4")
    }

    @Test("Column bands follow the switch, and row bands lie over them")
    func columnBanding() throws {
        let columns = try format("TableStyleMedium9", rowStripes: false, columnStripes: true)
        let pale = try #require(try style("TableStyleMedium9").wholeTable.fillColorHex)
        let band = try #require(try style("TableStyleMedium9").firstColumnStripe.fillColorHex)
        #expect(pale != band)
        #expect(columns.look(at: address("A3"))?.fillColorHex == band)
        #expect(columns.look(at: address("B3"))?.fillColorHex == pale)
        #expect(columns.look(at: address("C3"))?.fillColorHex == band)
        #expect(columns.look(at: address("A1"))?.fillColorHex == "FF4472C4")

        let both = try format("TableStyleMedium9", rowStripes: true, columnStripes: true)
        #expect(both.look(at: address("B2"))?.fillColorHex == band)
        #expect(both.look(at: address("B3"))?.fillColorHex == pale)
    }

    @Test("First and last column emphasis follow their switches")
    func columnEmphasis() throws {
        let plain = try format("TableStyleLight1")
        #expect(plain.look(at: address("A3"))?.isBold == false)
        #expect(plain.look(at: address("C3"))?.isBold == false)
        let emphasized = try format("TableStyleLight1", firstColumn: true, lastColumn: true)
        #expect(emphasized.look(at: address("A3"))?.isBold == true)
        #expect(emphasized.look(at: address("B3"))?.isBold == false)
        #expect(emphasized.look(at: address("C3"))?.isBold == true)

        // Medium 9 fills them like its header.
        let filled = try format("TableStyleMedium9", firstColumn: true)
        #expect(filled.look(at: address("A3"))?.fillColorHex == "FF4472C4")
        #expect(filled.look(at: address("A3"))?.textColorHex == "FFFFFFFF")
    }

    @Test("A table without a totals row bands its last row and has no totals look")
    func withoutTotalsRow() throws {
        let table = try format("TableStyleMedium2", totals: 0)
        let last = try #require(table.look(at: address("A6")))
        #expect(last.fillColorHex == paleBlue)
        #expect(!last.isBold)
        #expect(last.borderSides[.top]?.lineStyle == .thin)
    }

    @Test("The families differ as Excel's do")
    func families() throws {
        // Light 1: no header fill, rules above and below, grey bands.
        let light = try format("TableStyleLight1")
        #expect(light.look(at: address("A1"))?.fillColorHex == nil)
        #expect(light.look(at: address("A1"))?.borderSides[.bottom]?.lineStyle == .thin)
        #expect(light.look(at: address("A2"))?.fillColorHex == "FFD9D9D9")
        #expect(light.look(at: address("B3"))?.borderSides.isEmpty == true)

        // Light 9: a filled header, and rules between banded rows rather than fills.
        let ruled = try format("TableStyleLight9")
        #expect(ruled.look(at: address("B1"))?.fillColorHex == "FF4472C4")
        #expect(ruled.look(at: address("B3"))?.fillColorHex == nil)
        #expect(ruled.look(at: address("B3"))?.borderSides[.top] == BorderSide(lineStyle: .thin, colorHex: "FF4472C4"))
        #expect(try format("TableStyleLight9", rowStripes: false).look(at: address("B3"))?.borderSides[.top] == nil)

        // Light 16: a full grid.
        let grid = try format("TableStyleLight16")
        #expect(grid.look(at: address("B3"))?.borderSides.count == 4)

        // The accents run in order: Medium 3 is the theme's second accent.
        #expect(try format("TableStyleMedium3").look(at: address("A1"))?.fillColorHex == "FFED7D31")
        #expect(try format("TableStyleMedium7").look(at: address("A1"))?.fillColorHex == "FF70AD47")
        // The first of each group is black and grey.
        #expect(try format("TableStyleMedium1").look(at: address("A1"))?.fillColorHex == "FF000000")

        // Dark 9 pairs two accents: the body in the first, the header in the second.
        let paired = try format("TableStyleDark9")
        #expect(paired.look(at: address("A1"))?.fillColorHex == "FFED7D31")
        #expect(paired.look(at: address("A3"))?.fillColorHex == paleBlue)
    }

    @Test("A style takes its colours from the workbook's theme")
    func followsTheme() throws {
        let xml = """
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:themeElements>\
        <a:clrScheme name="T"><a:accent1><a:srgbClr val="112233"/></a:accent1></a:clrScheme>\
        </a:themeElements></a:theme>
        """
        let theme = ThemeColorScheme(themeXML: try XMLLite.parse(Data(xml.utf8)))
        let style = try #require(TableStyleDefinition.builtIn(named: "TableStyleMedium2", theme: theme))
        #expect(style.headerRow.fillColorHex == "FF112233")
    }

    // MARK: - Borders

    @Test("The table's borders are drawn where a cell has none of its own")
    func bordersResolve() throws {
        var sheet = try open().sheets[0]
        let metrics = SheetMetrics(sheet: sheet, zoom: 1)
        var resolver = BorderResolver(sheet: sheet, metrics: metrics)
        // The outline, and the rule between rows.
        #expect(resolver.resolvedSide(.leading, of: address("A3")) == BorderSide(lineStyle: .thin, colorHex: softBlue))
        #expect(resolver.resolvedSide(.bottom, of: address("B3")) == BorderSide(lineStyle: .thin, colorHex: softBlue))
        // Medium 2 has no rules between columns.
        #expect(resolver.resolvedSide(.trailing, of: address("A3")) == nil)
        // The totals row's double rule wins over the row above it.
        #expect(resolver.resolvedSide(.bottom, of: address("B5"))?.lineStyle == .double)
        // Nothing outside the table.
        #expect(resolver.resolvedSide(.bottom, of: address("E3")) == nil)

        sheet[address("B3")].style.borderSides[.bottom] = BorderSide(lineStyle: .thick, colorHex: "FFFF0000")
        resolver = BorderResolver(sheet: sheet, metrics: metrics)
        #expect(resolver.resolvedSide(.bottom, of: address("B3")) == BorderSide(lineStyle: .thick, colorHex: "FFFF0000"))
    }

    // MARK: - Edits and saving

    @Test("Inserting and removing rows and columns moves the style with the table")
    func followsStructuralEdits() throws {
        var sheet = try open().sheets[0]
        sheet.insertRows(2, at: 0)
        sheet.insertColumns(1, at: 0)
        #expect(sheet.tableFormats[0].range == CellRange(start: address("B3"), end: address("D8")))
        #expect(sheet.displayedCell(at: address("B3")).style.fillColorHex == "FF4472C4")
        #expect(sheet.displayedCell(at: address("A1")).style.fillColorHex == nil)

        sheet.removeRows(0...1)
        sheet.removeColumns(0...0)
        #expect(sheet.tableFormats[0].range == CellRange(start: address("A1"), end: address("C6")))

        // A row put inside the table makes it one longer.
        sheet.insertRows(1, at: 3)
        #expect(sheet.tableFormats[0].range == CellRange(start: address("A1"), end: address("C7")))
        #expect(sheet.displayedCell(at: address("C7")).style.isBold)

        sheet.removeRows(0...6)
        #expect(sheet.tableFormats.isEmpty)
    }

    @Test("A save keeps the table's style, banding and totals row")
    func survivesSave() throws {
        let table = Self.tableXML(style: "TableStyleMedium9", columnStripes: true, lastColumn: true)
        let first = try open(table)
        let saved = try XLSXWriter.data(from: first)
        let entries = try ZipArchive.entries(in: saved)
        let part = String(decoding: try #require(entries["xl/tables/table1.xml"]), as: UTF8.self)
        #expect(part == table)
        #expect(part.contains("<tableStyleInfo name=\"TableStyleMedium9\" showFirstColumn=\"0\" showLastColumn=\"1\" "
            + "showRowStripes=\"1\" showColumnStripes=\"1\"/>"))
        #expect(part.contains("totalsRowCount=\"1\""))
        #expect(part.contains("totalsRowFunction=\"average\""))
        let sheetXML = String(decoding: try #require(entries["xl/worksheets/sheet1.xml"]), as: UTF8.self)
        #expect(sheetXML.contains("<tablePart"))
        #expect(sheetXML.contains("SUBTOTAL(101,B2:B5)"))

        let second = try XLSXReader.workbook(from: saved)
        #expect(second.tables.first?.style == first.tables.first?.style)
        #expect(second.tables.first?.columnDetails == first.tables.first?.columnDetails)
        // The default text colour may be written differently; it means the same.
        #expect(second.sheets[0].tableFormats.map(\.info) == first.sheets[0].tableFormats.map(\.info))
        #expect(second.sheets[0].tableFormats.map(\.range) == first.sheets[0].tableFormats.map(\.range))
        #expect(second.sheets[0].tableFormats.map(\.definition) == first.sheets[0].tableFormats.map(\.definition))
        #expect(second.sheets[0].tableFormats.map(\.totalsRowCount) == [1])
        #expect(second.sheets[0].displayedCell(at: address("A6")).value == first.sheets[0].displayedCell(at: address("A6")).value)
    }

    @Test("A save after an edit still keeps the table's style")
    func survivesSaveAfterEdit() throws {
        var workbook = try open()
        workbook.sheets[0][address("B2")].value = .number(99)
        let second = try XLSXReader.workbook(from: try XLSXWriter.data(from: workbook))
        #expect(second.sheets[0].tableFormats.map(\.info) == workbook.sheets[0].tableFormats.map(\.info))
        #expect(second.sheets[0].tableFormats.map(\.range) == workbook.sheets[0].tableFormats.map(\.range))
        #expect(second.sheets[0][address("B2")].value == .number(99))
    }

    // MARK: - Drawing

    @Test("The iOS grid's tiles paint a table's fills and borders")
    func tilesPaintTheStyle() throws {
        // An empty sheet, so that every cell painted is painted for the table alone.
        var sheet = Worksheet(name: "S")
        sheet.tableFormats = [try format("TableStyleMedium2")]
        let plan = SheetGridView.TilePlan(id: 0, rows: 0..<10, columns: 0..<5)
        let metrics = SheetMetrics(sheet: sheet, zoom: 1)
        let contents = SheetGridView.contents(of: plan, in: sheet, lookup: SheetLookup(sheet), metrics: metrics)
        let painted = Dictionary(uniqueKeysWithValues: contents.cells.map { ($0.address, $0.cell) })
        #expect(painted[address("B1")]?.style.fillColorHex == "FF4472C4")
        #expect(painted[address("B2")]?.style.fillColorHex == paleBlue)
        #expect(painted[address("E2")] == nil)
        let frames = contents.borders.map(\.frame)
        #expect(frames.contains(metrics.frame(for: address("B3"))))
        #expect(!frames.contains(metrics.frame(for: address("E3"))))
    }

    @Test("Changing a table's style lets go of the kept tiles")
    func drawingKeyFollowsStyle() throws {
        var sheet = Worksheet(name: "S")
        sheet.tableFormats = [try format("TableStyleMedium2")]
        let before = SheetDrawingKey(sheet)
        #expect(before == SheetDrawingKey(sheet))
        sheet.tableFormats[0].info.showsRowStripes = false
        #expect(before != SheetDrawingKey(sheet))
    }
}
