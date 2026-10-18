import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Guards the places where our files have to satisfy Excel's rules rather than
/// just our own reader, and the constructs real-world workbooks use that are
/// easy to drop on the floor.
@Suite("Excel compatibility")
struct ExcelCompatibilityTests {

    // MARK: - Sheet names

    @Test("Names Excel forbids are coerced, not written out")
    func sheetNameSanitising() {
        #expect(Worksheet.sanitizedName("Sheet/With:Bad*Chars?[Brackets]") == "Sheet With Bad Chars  Brackets")
        #expect(Worksheet.sanitizedName("") == "Sheet")
        #expect(Worksheet.sanitizedName("   ") == "Sheet")
        #expect(Worksheet.sanitizedName("History") == "Sheet")
        #expect(Worksheet.sanitizedName("'quoted'") == "quoted")
        #expect(Worksheet.sanitizedName(String(repeating: "x", count: 60)).count == 31)
        #expect(Worksheet(name: "a/b").name == "a b")
    }

    @Test("Deduplicated names still fit the length limit")
    func uniqueNamesStayShort() {
        let long = String(repeating: "x", count: 31)
        var workbook = Workbook(sheets: [Worksheet(name: long)])
        for _ in 0..<3 { _ = workbook.addSheet(named: long) }

        #expect(workbook.sheets.allSatisfy { $0.name.count <= Worksheet.maximumNameLength })
        #expect(Set(workbook.sheets.map(\.name)).count == workbook.sheets.count)
    }

    // MARK: - Error values

    @Test("Only OOXML's own error literals are written")
    func errorLiterals() throws {
        // #CIRC! is ours; the format defines a closed set and rejects anything else.
        let standard = Set(["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A"])
        for error in CellError.allCases {
            #expect(standard.contains(error.ooxmlValue), "\(error.rawValue) is not a valid stored error")
        }

        var sheet = Worksheet(name: "S")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .error(.circularReference), formula: nil, style: .default)
        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let xml = String(decoding: try ZipArchive.entries(in: data)["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
        #expect(!xml.contains("#CIRC!"))
        #expect(xml.contains("#VALUE!"))
    }

    @Test("Excel is asked to recalculate what it opens")
    func recalculationRequested() throws {
        let data = try XLSXWriter.data(from: Workbook())
        let xml = String(decoding: try ZipArchive.entries(in: data)["xl/workbook.xml"]!, as: UTF8.self)
        #expect(xml.contains("fullCalcOnLoad=\"1\""))
    }

    @Test("Shared string count includes repeated cell references")
    func sharedStringCounts() throws {
        var sheet = Worksheet(name: "S")
        for column in 0..<3 {
            sheet[CellAddress(row: 0, column: column)] = Cell(value: .text("repeat"))
        }
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: Workbook(sheets: [sheet])))
        let root = try XMLLite.parse(#require(entries["xl/sharedStrings.xml"]))
        #expect(root.attribute("count") == "3")
        #expect(root.attribute("uniqueCount") == "1")
        #expect(root.children(named: "si").count == 1)
    }

    // MARK: - Shared formulas

    /// Builds a minimal but valid package around one sheet's XML.
    private func package(sheet: String, workbookProperties: String = "") throws -> Data {
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
        \(workbookProperties)<sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>
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
        <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy-mm-dd"/></numFmts>\
        <fonts count="1"><font><sz val="11"/></font></fonts>\
        <fills count="1"><fill><patternFill patternType="none"/></fill></fills>\
        <borders count="1"><border/></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>\
        </styleSheet>
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

    @Test("A filled-down shared formula reaches every cell it covers")
    func sharedFormulasExpand() throws {
        // Excel writes the text once on the host cell; the rest carry only `si`.
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
        <row r="1"><c r="A1"><v>10</v></c>\
        <c r="B1"><f t="shared" ref="B1:B3" si="0">A1*2+$D$1</f><v>20</v></c></row>\
        <row r="2"><c r="A2"><v>20</v></c><c r="B2"><f t="shared" si="0"/><v>40</v></c></row>\
        <row r="3"><c r="A3"><v>30</v></c><c r="B3"><f t="shared" si="0"/><v>60</v></c></row>\
        </sheetData></worksheet>
        """
        let workbook = try XLSXReader.workbook(from: package(sheet: sheet))
        let read = workbook.sheets[0]

        #expect(read[CellAddress(a1: "B1")!].formula == "A1*2+$D$1")
        // Relative references follow the fill; the anchored one stays put.
        #expect(read[CellAddress(a1: "B2")!].formula == "A2*2+$D$1")
        #expect(read[CellAddress(a1: "B3")!].formula == "A3*2+$D$1")
        #expect(read[CellAddress(a1: "B3")!].value == .number(60))
    }

    @Test("Filling a formula moves relative references only")
    func translation() {
        #expect(FormulaReferenceShifter.translated("A1*2", rowDelta: 2, columnDelta: 0) == "A3*2")
        #expect(FormulaReferenceShifter.translated("$A$1*2", rowDelta: 2, columnDelta: 0) == "$A$1*2")
        #expect(FormulaReferenceShifter.translated("A$1+B1", rowDelta: 1, columnDelta: 1) == "B$1+C2")
        #expect(FormulaReferenceShifter.translated("SUM(A1:A3)", rowDelta: 1, columnDelta: 0) == "SUM(A2:A4)")
        #expect(FormulaReferenceShifter.translated("\"A1\"&A1", rowDelta: 1, columnDelta: 0) == "\"A1\"&A2")
    }

    // MARK: - Date systems

    @Test("The 1904 epoch shifts dates but leaves plain numbers alone")
    func macEpoch() throws {
        // s="1" is the date-formatted style; s="0" is General.
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
        <row r="1"><c r="A1" s="1"><v>43904</v></c><c r="B1" s="0"><v>10</v></c></row>\
        </sheetData></worksheet>
        """
        let mac = try XLSXReader.workbook(from: package(sheet: sheet,
                                                        workbookProperties: "<workbookPr date1904=\"1\"/>"))
        #expect(mac.sheets[0][CellAddress(a1: "A1")!].value == .number(43904 + 1462))
        #expect(mac.sheets[0][CellAddress(a1: "B1")!].value == .number(10))

        let windows = try XLSXReader.workbook(from: package(sheet: sheet))
        #expect(windows.sheets[0][CellAddress(a1: "A1")!].value == .number(43904))
    }

    @Test("Date formats are told apart from numeric ones")
    func dateFormatDetection() {
        #expect(CellFormatter.isDateFormat("yyyy-mm-dd"))
        #expect(CellFormatter.isDateFormat("h:mm:ss"))
        #expect(CellFormatter.isDateFormat("m/d/yy h:mm"))
        #expect(!CellFormatter.isDateFormat("General"))
        #expect(!CellFormatter.isDateFormat("#,##0.00"))
        #expect(!CellFormatter.isDateFormat("0.00E+00"))
        #expect(!CellFormatter.isDateFormat("@"))
    }

    // MARK: - Other real-world constructs

    @Test("Inline strings are read like shared ones")
    func inlineStrings() throws {
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
        <row r="1"><c r="A1" t="inlineStr"><is><t>inline</t></is></c></row>\
        </sheetData></worksheet>
        """
        let workbook = try XLSXReader.workbook(from: package(sheet: sheet))
        #expect(workbook.sheets[0][CellAddress(a1: "A1")!].value == .text("inline"))
    }
}
