import AppIntents
import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

@Suite("Combining workbooks")
struct CombineWorkbooksTests {
    // MARK: - Fixtures

    /// A workbook as a file would hold it: written out as an `.xlsx` and read
    /// back, the way a shortcut hands one to the action.
    private func saved(_ workbook: Workbook) throws -> Workbook {
        try XLSXReader.workbook(from: try XLSXWriter.data(from: workbook))
    }

    private func cell(_ text: String, style: CellStyle = .default) -> Cell {
        var cell = CellInputParser.cell(from: text, inheriting: style)
        cell.style = style
        return cell
    }

    private func sheet(_ name: String, _ cells: [String: String], style: CellStyle = .default) -> Worksheet {
        var sheet = Worksheet(name: name)
        for (address, text) in cells { sheet[CellAddress(a1: address)!] = cell(text, style: style) }
        return sheet
    }

    private func value(_ workbook: Workbook, _ sheet: String, _ address: String) -> CellValue {
        workbook.sheet(named: sheet)?[CellAddress(a1: address)!].value ?? .empty
    }

    private func formula(_ workbook: Workbook, _ sheet: String, _ address: String) -> String? {
        workbook.sheet(named: sheet)?[CellAddress(a1: address)!].formula
    }

    /// A package with one table on its single sheet, a differential format,
    /// and a conditional format using it — the parts a sheet brings along
    /// that live outside the sheet itself.
    private func tablePackage(amounts: [Int], highlight: String) throws -> Data {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var rows = "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Item</t></is></c>"
            + "<c r=\"B1\" t=\"inlineStr\"><is><t>Amount</t></is></c>"
            + "<c r=\"D1\"><f>SUM(Table1[Amount])</f><v>0</v></c></row>"
        for (index, amount) in amounts.enumerated() {
            rows += "<row r=\"\(index + 2)\"><c r=\"A\(index + 2)\" t=\"inlineStr\"><is><t>Item \(index)</t></is></c>"
                + "<c r=\"B\(index + 2)\"><v>\(amount)</v></c></row>"
        }
        let last = amounts.count + 1
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="\(main)" xmlns:r="\(relationships)"><sheetData>\(rows)</sheetData>\
        <conditionalFormatting sqref="B2:B\(last)"><cfRule type="cellIs" dxfId="0" priority="1" operator="greaterThan">\
        <formula>10</formula></cfRule></conditionalFormatting>\
        <tableParts count="1"><tablePart r:id="rId1"/></tableParts></worksheet>
        """
        let table = """
        <?xml version="1.0" encoding="UTF-8"?>
        <table xmlns="\(main)" id="1" name="Table1" displayName="Table1" ref="A1:B\(last)" totalsRowShown="0">\
        <autoFilter ref="A1:B\(last)"/><tableColumns count="2"><tableColumn id="1" name="Item"/>\
        <tableColumn id="2" name="Amount"/></tableColumns></table>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="\(main)"><fonts count="1"><font><sz val="11"/></font></fonts>\
        <fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
        <dxfs count="1"><dxf><fill><patternFill><bgColor rgb="\(highlight)"/></patternFill></fill></dxf></dxfs>\
        </styleSheet>
        """
        let entries: [(String, Data)] = [
            ("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            <Override PartName="/xl/tables/table1.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/></Types>
            """.utf8)),
            ("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(relationships)/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """.utf8)),
            ("xl/workbook.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="\(main)" xmlns:r="\(relationships)">\
            <sheets><sheet name="Sales" sheetId="1" r:id="rId1"/></sheets></workbook>
            """.utf8)),
            ("xl/_rels/workbook.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(relationships)/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
            """.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
            ("xl/worksheets/_rels/sheet1.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(relationships)/table" Target="../tables/table1.xml"/></Relationships>
            """.utf8)),
            ("xl/tables/table1.xml", Data(table.utf8)),
        ]
        return try ZipArchive.archive(entries: entries)
    }

    private func text(_ entries: [String: Data], _ path: String) throws -> String {
        String(decoding: try #require(entries[path], "\(path) is missing"), as: UTF8.self)
    }

    // MARK: - Sheets, formulas, styles and names

    @Test("Sheets come across in order with their values, formulas and formatting; clashing names are renamed")
    func sheetsAndFormulas() throws {
        var bold = CellStyle.default
        bold.isBold = true
        bold.fillColorHex = "FFFFCC00"
        let january = try saved(Workbook(sheets: [
            sheet("Sales", ["A1": "Pen", "B1": "10", "B2": "20", "C1": "=SUM(B1:B2)"], style: bold),
            sheet("Notes", ["A1": "January"]),
        ]))
        let february = try saved(Workbook(sheets: [
            sheet("Sales", ["A1": "Ink", "B1": "3", "B2": "4"]),
            sheet("Summary", ["A1": "=SUM(Sales!B1:B2)", "A2": "='Sales'!A1&\" sold\"", "A3": "=Notes!A1"]),
        ]))

        let combined = Workbook.combining([january, february])
        #expect(combined.sheets.map(\.name) == ["Sales", "Notes", "Sales 2", "Summary"])

        // The first workbook is untouched.
        #expect(value(combined, "Sales", "C1") == .number(30))
        #expect(combined.sheet(named: "Sales")?[CellAddress(a1: "A1")!].style.isBold == true)
        #expect(combined.sheet(named: "Sales")?[CellAddress(a1: "A1")!].style.fillColorHex == "FFFFCC00")

        // February's formulas follow its renamed sheet and still add up its own numbers.
        #expect(formula(combined, "Summary", "A1") == "SUM('Sales 2'!B1:B2)")
        #expect(value(combined, "Summary", "A1") == .number(7))
        #expect(value(combined, "Summary", "A2") == .text("Ink sold"))
        // A sheet the second workbook did not have keeps pointing where it did.
        #expect(formula(combined, "Summary", "A3") == "Notes!A1")
        #expect(value(combined, "Sales 2", "A1") == .text("Ink"))

        // And it all survives being saved.
        let reopened = try saved(combined)
        #expect(reopened.sheets.map(\.name) == ["Sales", "Notes", "Sales 2", "Summary"])
        #expect(formula(reopened, "Summary", "A1") == "SUM('Sales 2'!B1:B2)")
        #expect(value(reopened, "Summary", "A1") == .number(7))
        #expect(reopened.sheet(named: "Sales")?[CellAddress(a1: "A1")!].style.isBold == true)
    }

    @Test("A name that means something else in the first workbook stays with the sheets it came with")
    func definedNames() throws {
        let first = try saved(Workbook(
            sheets: [sheet("Prices", ["A1": "0.1", "B1": "=100*Rate"])],
            definedNames: [DefinedName(name: "Rate", formula: "Prices!$A$1", scope: nil)]))
        let second = try saved(Workbook(
            sheets: [sheet("Prices", ["A1": "0.5", "B1": "=100*Rate", "C1": "=Bonus"]),
                     sheet("Other", ["A1": "=10*Rate"])],
            definedNames: [DefinedName(name: "Rate", formula: "Prices!$A$1", scope: nil),
                           DefinedName(name: "Bonus", formula: "Prices!$A$1*2", scope: nil)]))

        let combined = Workbook.combining([first, second])
        #expect(combined.sheets.map(\.name) == ["Prices", "Prices 2", "Other"])
        #expect(value(combined, "Prices", "B1") == .number(10))
        #expect(value(combined, "Prices 2", "B1") == .number(50))
        #expect(value(combined, "Other", "A1") == .number(5))
        #expect(value(combined, "Prices 2", "C1") == .number(1))
        // A name only the second had is a workbook name in the result.
        #expect(combined.definedNames.contains { $0.name == "Bonus" && $0.scope == nil
            && $0.formula == "'Prices 2'!$A$1*2" })

        let reopened = try saved(combined)
        #expect(value(reopened, "Prices", "B1") == .number(10))
        #expect(value(reopened, "Prices 2", "B1") == .number(50))
        #expect(value(reopened, "Other", "A1") == .number(5))
    }

    @Test("A workbook combined with itself gets copies of its sheets")
    func combiningWithItself() throws {
        let book = try saved(Workbook(sheets: [sheet("Data", ["A1": "2", "A2": "=A1*3"])]))
        let combined = Workbook.combining([book, book])
        #expect(combined.sheets.map(\.name) == ["Data", "Data 2"])
        #expect(Set(combined.sheets.map(\.id)).count == 2)
        #expect(value(combined, "Data 2", "A2") == .number(6))
    }

    // MARK: - Parts outside the sheet

    @Test("Tables and conditional formats come across, renamed and renumbered where they clash")
    func tablesAndConditionalFormats() throws {
        let first = try XLSXReader.workbook(from: try tablePackage(amounts: [1, 2], highlight: "FFFF0000"))
        let second = try XLSXReader.workbook(from: try tablePackage(amounts: [30, 40, 50], highlight: "FF00FF00"))
        #expect(first.tables.map(\.name) == ["Table1"])

        let combined = Workbook.combining([first, second])
        #expect(combined.sheets.map(\.name) == ["Sales", "Sales 2"])
        #expect(combined.tables.map(\.name) == ["Table1", "Table1_2"])
        #expect(formula(combined, "Sales", "D1") == "SUM(Table1[Amount])")
        #expect(formula(combined, "Sales 2", "D1") == "SUM(Table1_2[Amount])")
        #expect(value(combined, "Sales", "D1") == .number(3))
        #expect(value(combined, "Sales 2", "D1") == .number(120))

        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: combined))
        let firstTable = try text(entries, "xl/tables/table1.xml")
        let secondTable = try text(entries, "xl/tables/table2.xml")
        #expect(firstTable.contains("id=\"1\"") && firstTable.contains("displayName=\"Table1\""))
        #expect(secondTable.contains("id=\"2\"") && secondTable.contains("displayName=\"Table1_2\""))
        #expect(secondTable.contains("ref=\"A1:B4\""))
        #expect(try text(entries, "xl/worksheets/_rels/sheet2.xml.rels").contains("../tables/table2.xml"))
        #expect(try text(entries, "[Content_Types].xml").contains("/xl/tables/table2.xml"))

        // The second workbook's highlight is added after the first's, and its
        // rule points at it.
        let styles = try text(entries, "xl/styles.xml")
        #expect(styles.contains("<dxfs count=\"2\">"))
        let red = try #require(styles.range(of: "FFFF0000"))
        let green = try #require(styles.range(of: "FF00FF00"))
        #expect(red.lowerBound < green.lowerBound)
        #expect(try text(entries, "xl/worksheets/sheet1.xml").contains("dxfId=\"0\""))
        #expect(try text(entries, "xl/worksheets/sheet2.xml").contains("dxfId=\"1\""))

        // Reopened, both tables are there and the formulas still find them.
        let reopened = try XLSXReader.workbook(from: try ZipArchive.archive(
            entries: entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        #expect(reopened.tables.map(\.name).sorted() == ["Table1", "Table1_2"])
        #expect(value(reopened, "Sales 2", "D1") == .number(120))
        #expect(reopened.unsupportedFeatures.lost.isEmpty)
    }

    // MARK: - Formula text

    @Test("Renaming reaches sheet and table names in formulas and nothing else")
    func formulaRenaming() {
        let sheets = ["sales": "Sales 2", "jan": "Jan 2"]
        let tables = ["table1": "Table1_2"]
        func rename(_ formula: String) -> String {
            FormulaNameRewriter.rewrite(formula, sheets: sheets, tables: tables)
        }
        #expect(rename("Sales!A1+'Sales'!B2") == "'Sales 2'!A1+'Sales 2'!B2")
        #expect(rename("SUM(Jan:Mar!A1)") == "SUM('Jan 2:Mar'!A1)")
        #expect(rename("SUM('Jan:Mar'!A1)") == "SUM('Jan 2:Mar'!A1)")
        #expect(rename("Other!A1&\"Sales!A1\"") == "Other!A1&\"Sales!A1\"")
        #expect(rename("[1]Sales!A1") == "[1]Sales!A1")
        #expect(rename("SUM(Table1[Amount])+Table1") == "SUM(Table1_2[Amount])+Table1")
        #expect(rename("SALES!A1") == "'Sales 2'!A1")
    }

    // MARK: - The action

    @Test("The Combine Workbooks action joins the workbooks it is given, and needs at least one")
    func action() async throws {
        func open(_ csv: String, _ filename: String) async throws -> WorkbookEntity {
            var get = GetWorkbookIntent()
            get.file = IntentFile(data: Data(csv.utf8), filename: filename, type: .commaSeparatedText)
            return try #require(try await get.perform().value)
        }
        var combine = CombineWorkbooksIntent()
        combine.workbooks = [try await open("Item,Qty\nPen,10\n", "January.csv"),
                             try await open("Item,Qty\nInk,3\n", "February.csv"),
                             try await open("Item,Qty\nPad,7\n", "January.csv")]
        combine.name = "Quarter"
        let combined = try #require(try await combine.perform().value)
        #expect(combined.name == "Quarter")
        #expect(combined.sheetNames == ["January", "February", "January 2"])
        #expect(combined.file.filename == "Quarter.xlsx")
        let book = try combined.load()
        #expect(value(book, "January 2", "A2") == .text("Pad"))

        combine.workbooks = []
        await #expect(throws: WorkbookAutomation.Failure.noWorkbooks) { _ = try await combine.perform() }
    }
}
