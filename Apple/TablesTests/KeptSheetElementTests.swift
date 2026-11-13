import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Worksheet children Tables carries through a save without modelling them —
/// headers and footers, page breaks, the remembered sort, protected ranges,
/// ignored errors — and how the ones naming rows and columns follow edits.
@Suite("Kept sheet elements")
struct KeptSheetElementTests {

    // MARK: - Package construction

    private static let printChildren = """
    <phoneticPr fontId="3" type="noConversion"/>\
    <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>\
    <headerFooter differentFirst="1"><oddHeader>&amp;C&amp;"Arial,Bold"Quarterly</oddHeader>\
    <oddFooter>Page &amp;P of &amp;N</oddFooter></headerFooter>\
    <rowBreaks count="2" manualBreakCount="2"><brk id="5" max="16383" man="1"/>\
    <brk id="10" max="16383" man="1"/></rowBreaks>\
    <colBreaks count="1" manualBreakCount="1"><brk id="3" max="1048575" man="1"/></colBreaks>\
    <ignoredErrors><ignoredError sqref="A7:A9" numberStoredAsText="1"/></ignoredErrors>
    """

    /// Rows and ranges near the top of the sheet, given before the print
    /// elements and out of schema order so that echoing the input back could
    /// not pass.
    private static let rangeChildren = """
    <sortState ref="A2:C12"><sortCondition descending="1" ref="B2:B12"/></sortState>\
    <protectedRanges><protectedRange name="Inputs" sqref="C2:C12"/></protectedRanges>
    """

    private func package(
        sheetBody: String, sheetRelationships: String? = nil, extraParts: [(String, String)] = [],
        contentTypeDefaults: String = ""
    ) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\(contentTypeDefaults)\
        <Override PartName="/xl/worksheets/sheet1.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
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
        Target="worksheets/sheet1.xml"/></Relationships>
        """
        var rows = ""
        for row in 1...12 { rows += "<row r=\"\(row)\"><c r=\"A\(row)\"><v>\(row)</v></c></row>" }
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheetData>\(rows)</sheetData>\(sheetBody)</worksheet>
        """
        var entries: [(path: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ]
        if let sheetRelationships {
            let payload = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            \(sheetRelationships)</Relationships>
            """
            entries.append(("xl/worksheets/_rels/sheet1.xml.rels", Data(payload.utf8)))
        }
        for (path, xml) in extraParts { entries.append((path, Data(xml.utf8))) }
        return try ZipArchive.archive(entries: entries)
    }

    private func savedSheet(_ workbook: Workbook) throws -> (xml: String, entries: [String: Data]) {
        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        let payload = try #require(entries["xl/worksheets/sheet1.xml"])
        return (String(decoding: payload, as: UTF8.self), entries)
    }

    private func open(_ body: String) throws -> Workbook {
        try XLSXReader.workbook(from: try package(sheetBody: body))
    }

    // MARK: - Round trip

    @Test("Headers, footers, breaks, sort state and the rest survive a save in schema order")
    func roundTripKeepsElementsInOrder() throws {
        let workbook = try open(Self.printChildren + Self.rangeChildren)
        let (sheet, _) = try savedSheet(workbook)

        // `protectedRanges` precedes `sortState` in the schema.
        let schemaOrder = [
            "sheetData", "protectedRanges", "sortState", "phoneticPr", "pageMargins",
            "headerFooter", "rowBreaks", "colBreaks", "ignoredErrors",
        ]
        let positions = try schemaOrder.map { name in
            try #require(sheet.range(of: "<\(name)")?.lowerBound, "\(name) did not survive")
        }
        #expect(positions == positions.sorted())

        #expect(sheet.contains("&amp;C&amp;&quot;Arial,Bold&quot;Quarterly"))
        #expect(sheet.contains("Page &amp;P of &amp;N"))
        #expect(sheet.contains("differentFirst=\"1\""))
        #expect(sheet.contains("<brk id=\"5\" man=\"1\" max=\"16383\"/>"))
        #expect(sheet.contains("<brk id=\"3\" man=\"1\" max=\"1048575\"/>"))
        #expect(sheet.contains("ref=\"A2:C12\"><sortCondition"))
        #expect(sheet.contains("name=\"Inputs\""))
        #expect(sheet.contains("numberStoredAsText=\"1\""))
        // The phonetic font is pointed at the default font of the table we write.
        #expect(sheet.contains("fontId=\"0\" type=\"noConversion\"/>"))

        #expect(workbook.unsupportedFeatures.preserved.contains(.printSetup))
        #expect(workbook.unsupportedFeatures.preserved.contains(.sheetProtection))
        #expect(workbook.unsupportedFeatures.lost.isEmpty)
    }

    @Test("A saved file with the kept elements opens again with them intact")
    func savedFileReopens() throws {
        let first = try open(Self.printChildren + Self.rangeChildren)
        let saved = try XLSXWriter.data(from: first)
        let second = try XLSXReader.workbook(from: saved)
        let names = Set(second.sheets[0].preservedElements.map(\.name))
        for name in ["headerFooter", "rowBreaks", "colBreaks", "sortState", "protectedRanges", "ignoredErrors"] {
            #expect(names.contains(name), "\(name) was lost on the second open")
        }
    }

    // MARK: - Structural edits

    @Test("Inserting rows above a page break moves it, the sort and the ranges down")
    func insertRowsShiftsBreaks() throws {
        var workbook = try open(Self.printChildren + Self.rangeChildren)
        // Row 4 in A1 terms: above the break before zero-based row 5.
        workbook.sheets[0].insertRows(1, at: 3)
        let (sheet, _) = try savedSheet(workbook)

        #expect(sheet.contains("<brk id=\"6\" man=\"1\" max=\"16383\"/>"))
        #expect(sheet.contains("<brk id=\"11\" man=\"1\" max=\"16383\"/>"))
        #expect(sheet.contains("count=\"2\" manualBreakCount=\"2\"><brk id=\"6\""))
        // Column breaks are not on this axis.
        #expect(sheet.contains("<brk id=\"3\" man=\"1\" max=\"1048575\"/>"))
        #expect(sheet.contains("ref=\"A2:C13\"><sortCondition"))
        #expect(sheet.contains("<sortCondition descending=\"1\" ref=\"B2:B13\"/>"))
        #expect(sheet.contains("sqref=\"C2:C13\""))
        #expect(sheet.contains("sqref=\"A8:A10\""))
    }

    @Test("A row inserted at a break's own row pushes the break down with that row")
    func insertAtBreakRow() throws {
        var workbook = try open(Self.printChildren)
        workbook.sheets[0].insertRows(2, at: 5)
        let (sheet, _) = try savedSheet(workbook)
        #expect(sheet.contains("<brk id=\"7\" man=\"1\" max=\"16383\"/>"))
        #expect(sheet.contains("<brk id=\"12\" man=\"1\" max=\"16383\"/>"))
    }

    @Test("Inserting rows below every break leaves the fragment exactly as the file had it")
    func untouchedBreaksStayVerbatim() throws {
        var workbook = try open(Self.printChildren)
        let before = try #require(workbook.sheets[0].preservedElements.first { $0.name == "rowBreaks" })
        workbook.sheets[0].insertRows(1, at: 11)
        let after = try #require(workbook.sheets[0].preservedElements.first { $0.name == "rowBreaks" })
        #expect(before == after)
    }

    @Test("Removing a break's row removes the break, and the list once it is empty")
    func removeRowsDropsBreaks() throws {
        var workbook = try open(Self.printChildren)
        workbook.sheets[0].removeRows(5...5)
        var (sheet, _) = try savedSheet(workbook)
        #expect(sheet.contains("count=\"1\" manualBreakCount=\"1\"><brk id=\"9\""))
        #expect(sheet.contains("<brk id=\"9\" man=\"1\" max=\"16383\"/></rowBreaks>"))

        workbook.sheets[0].removeRows(8...9)
        (sheet, _) = try savedSheet(workbook)
        #expect(!sheet.contains("<rowBreaks"))
        #expect(sheet.contains("<colBreaks"))
    }

    @Test("Removing rows above a break moves it up")
    func removeRowsAboveBreak() throws {
        var workbook = try open(Self.printChildren)
        workbook.sheets[0].removeRows(0...1)
        let (sheet, _) = try savedSheet(workbook)
        #expect(sheet.contains("<brk id=\"3\" man=\"1\" max=\"16383\"/>"))
        #expect(sheet.contains("<brk id=\"8\" man=\"1\" max=\"16383\"/>"))
    }

    @Test("Columns move the column breaks and the sort condition, not the row breaks")
    func insertColumnsShiftsColumnBreaks() throws {
        var workbook = try open(Self.printChildren + Self.rangeChildren)
        workbook.sheets[0].insertColumns(1, at: 0)
        let (sheet, _) = try savedSheet(workbook)
        #expect(sheet.contains("<brk id=\"4\" man=\"1\" max=\"1048575\"/>"))
        #expect(sheet.contains("<brk id=\"5\" man=\"1\" max=\"16383\"/>"))
        #expect(sheet.contains("ref=\"B2:D12\"><sortCondition"))
        #expect(sheet.contains("ref=\"C2:C12\"/>"))
        #expect(sheet.contains("sqref=\"D2:D12\""))
    }

    @Test("Removing the sorted column drops its condition and with it the sort")
    func removeSortedColumnDropsSort() throws {
        var workbook = try open(Self.rangeChildren)
        workbook.sheets[0].removeColumns(1...1)
        let (sheet, _) = try savedSheet(workbook)
        #expect(!sheet.contains("<sortState"))
        // The protected range was in column C, which is now B.
        #expect(sheet.contains("sqref=\"B2:B12\""))

        var cleared = try open(Self.rangeChildren)
        cleared.sheets[0].removeRows(1...11)
        let (rows, _) = try savedSheet(cleared)
        #expect(!rows.contains("<sortState"))
        #expect(!rows.contains("<protectedRanges"))
    }

    // MARK: - Header and footer pictures

    @Test("A header picture's drawing is kept along with the sheet's relationships")
    func headerPictureSurvives() throws {
        let vml = """
        <xml xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">\
        <v:shape id="CH" o:spid="_x0000_s1025" type="#_x0000_t75"/></xml>
        """
        let data = try package(
            sheetBody: "<headerFooter><oddHeader>&amp;C&amp;G</oddHeader></headerFooter>"
                + "<legacyDrawingHF r:id=\"rId1\"/>",
            sheetRelationships: "<Relationship Id=\"rId1\" "
                + "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing\" "
                + "Target=\"../drawings/vmlDrawingHF1.vml\"/>",
            extraParts: [("xl/drawings/vmlDrawingHF1.vml", vml)],
            contentTypeDefaults: "<Default Extension=\"vml\" "
                + "ContentType=\"application/vnd.openxmlformats-officedocument.vmlDrawing\"/>"
        )
        let workbook = try XLSXReader.workbook(from: data)
        let (sheet, entries) = try savedSheet(workbook)
        #expect(sheet.contains("r:id=\"rId1\"/></worksheet>"))
        let header = try #require(sheet.range(of: "<headerFooter"))
        let drawing = try #require(sheet.range(of: "<legacyDrawingHF"))
        #expect(header.lowerBound < drawing.lowerBound)
        #expect(entries["xl/drawings/vmlDrawingHF1.vml"] != nil)
        let rels = String(decoding: try #require(entries["xl/worksheets/_rels/sheet1.xml.rels"]), as: UTF8.self)
        #expect(rels.contains("vmlDrawingHF1.vml"))
        #expect(workbook.unsupportedFeatures.lost.isEmpty)
    }

    // MARK: - Still dropped

    @Test("Custom views and embedded objects are named as lost")
    func droppedChildrenAreReported() throws {
        let workbook = try open("""
        <customSheetViews><customSheetView guid="{00000000-0000-0000-0000-000000000001}">\
        <selection activeCell="A1" sqref="A1"/></customSheetView></customSheetViews>\
        <oleObjects><oleObject progId="Word.Document.12" shapeId="1025" r:id="rId9"/></oleObjects>
        """)
        let (sheet, _) = try savedSheet(workbook)
        #expect(!sheet.contains("customSheetViews"))
        #expect(!sheet.contains("oleObjects"))
        #expect(workbook.unsupportedFeatures.lost.contains(.customViews))
        #expect(workbook.unsupportedFeatures.lost.contains(.embeddedObjects))
        #expect(workbook.unsupportedFeatures.noticeMessage.contains(UnsupportedFeature.customViews.label))
    }
}
