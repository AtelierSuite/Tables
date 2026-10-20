import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Covers the two structural features real workbooks rely on that never reach a
/// cell's own contents: merged regions and hidden sheets.
@Suite("Merged cells")
struct MergedCellTests {

    // MARK: - Fixtures

    /// One sheet's worth of package description: what the workbook part says
    /// about it, and the worksheet XML itself.
    private struct SheetFixture {
        var name: String
        var state: String?
        var xml: String
    }

    /// Builds a minimal but valid package around one or more worksheet parts.
    private func packaged(_ fixtures: [SheetFixture]) throws -> Data {
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

        var sheetElements = ""
        var workbookRelationshipElements = ""
        var parts: [(String, Data)] = []
        for (position, fixture) in fixtures.enumerated() {
            let number = position + 1
            let state = fixture.state.map { " state=\"\($0)\"" } ?? ""
            sheetElements += "<sheet name=\"\(fixture.name)\" sheetId=\"\(number)\"\(state) r:id=\"rId\(number)\"/>"
            workbookRelationshipElements += """
            <Relationship Id="rId\(number)" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
            Target="worksheets/sheet\(number).xml"/>
            """
            parts.append(("xl/worksheets/sheet\(number).xml", Data(fixture.xml.utf8)))
        }

        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(sheetElements)</sheets></workbook>
        """
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(workbookRelationshipElements)</Relationships>
        """

        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
        ] + parts)
    }

    /// A worksheet part carrying one cell and whatever trailing elements are
    /// being exercised.
    private func worksheet(trailing: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
        <row r="9"><c r="A9" t="inlineStr"><is><t>Heading</t></is></c></row>\
        </sheetData>\(trailing)</worksheet>
        """
    }

    private func range(_ reference: String) -> CellRange {
        CellRange(a1Range: reference)!.normalized
    }

    private func merged(_ references: [String]) -> Worksheet {
        var sheet = Worksheet(name: "S")
        sheet.rowCount = 20
        sheet.columnCount = 8
        for reference in references {
            let accepted = sheet.merge(range(reference))
            #expect(accepted, "\(reference) should be mergeable")
        }
        return sheet
    }

    // MARK: - Reading

    @Test("A worksheet's mergeCells element becomes merged ranges")
    func readsMergeCells() throws {
        let trailing = """
        <mergeCells count="2"><mergeCell ref="A9:C9"/><mergeCell ref="E1:E4"/></mergeCells>
        """
        let workbook = try XLSXReader.workbook(from: packaged([
            SheetFixture(name: "S", state: nil, xml: worksheet(trailing: trailing)),
        ]))
        let sheet = workbook.sheets[0]

        #expect(sheet.mergedRanges.count == 2)
        #expect(sheet.mergedRanges.contains(range("A9:C9")))
        #expect(sheet.mergedRanges.contains(range("E1:E4")))
        // Clicking any covered cell has to find the whole region.
        #expect(sheet.mergedRange(containing: CellAddress(a1: "B9")!) == range("A9:C9"))
        #expect(sheet.mergedRange(containing: CellAddress(a1: "D9")!) == nil)
        // The top-left cell keeps the content; nothing else gains any.
        #expect(sheet[CellAddress(a1: "A9")!].value == .text("Heading"))
        #expect(sheet[CellAddress(a1: "B9")!].isBlank)
    }

    @Test("A merge reaching past the last populated cell grows the grid")
    func mergeExtendsGrid() throws {
        let trailing = "<mergeCells count=\"1\"><mergeCell ref=\"A30:J31\"/></mergeCells>"
        let workbook = try XLSXReader.workbook(from: packaged([
            SheetFixture(name: "S", state: nil, xml: worksheet(trailing: trailing)),
        ]))
        let sheet = workbook.sheets[0]

        #expect(sheet.rowCount >= 31)
        #expect(sheet.columnCount >= 10)
        #expect(sheet.mergedRanges == [range("A30:J31")])
    }

    @Test("Overlapping regions in a file lose the later one rather than corrupting the sheet")
    func readerRejectsOverlaps() throws {
        let trailing = """
        <mergeCells count="2"><mergeCell ref="A1:C3"/><mergeCell ref="B2:D4"/></mergeCells>
        """
        let workbook = try XLSXReader.workbook(from: packaged([
            SheetFixture(name: "S", state: nil, xml: worksheet(trailing: trailing)),
        ]))
        #expect(workbook.sheets[0].mergedRanges == [range("A1:C3")])
    }

    // MARK: - Writing

    @Test("mergeCells is written after sheetData, where the schema puts it")
    func writesMergeCellsInSchemaOrder() throws {
        var sheet = merged(["A9:C9"])
        sheet[CellAddress(a1: "A9")!] = Cell(value: .text("Heading"), formula: nil, style: .default)

        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let xml = String(decoding: try ZipArchive.entries(in: data)["xl/worksheets/sheet1.xml"]!, as: UTF8.self)

        #expect(xml.contains("<mergeCells count=\"1\"><mergeCell ref=\"A9:C9\"/></mergeCells>"))
        let sheetDataEnd = xml.range(of: "</sheetData>")!
        let mergeStart = xml.range(of: "<mergeCells")!
        #expect(sheetDataEnd.upperBound <= mergeStart.lowerBound)
    }

    @Test("A sheet with no merges writes no mergeCells element")
    func omitsEmptyMergeCells() throws {
        let data = try XLSXWriter.data(from: Workbook())
        let xml = String(decoding: try ZipArchive.entries(in: data)["xl/worksheets/sheet1.xml"]!, as: UTF8.self)
        #expect(!xml.contains("mergeCells"))
    }

    @Test("Merged regions survive a save and reopen")
    func roundTrip() throws {
        var sheet = merged(["A9:C9", "E1:E4"])
        sheet[CellAddress(a1: "A9")!] = Cell(value: .text("Heading"), formula: nil, style: .default)

        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let reopened = try XLSXReader.workbook(from: data).sheets[0]

        #expect(Set(reopened.mergedRanges) == Set([range("A9:C9"), range("E1:E4")]))
        #expect(reopened[CellAddress(a1: "A9")!].value == .text("Heading"))
    }

    // MARK: - Model rules

    @Test("Merges may not overlap, but a covering merge absorbs what it covers")
    func overlapRules() {
        var sheet = merged(["B2:C3"])

        // Crossing an existing region is refused outright.
        let crossing = sheet.merge(range("C3:D4"))
        let overlapping = sheet.merge(range("A1:B2"))
        #expect(crossing == false)
        #expect(overlapping == false)
        #expect(sheet.mergedRanges == [range("B2:C3")])

        // A single cell is not a merge, and neither is a range off the grid.
        let single = sheet.merge(CellRange(CellAddress(a1: "F6")!))
        let offGrid = sheet.merge(range("A1:Z999"))
        #expect(single == false)
        #expect(offGrid == false)

        // One that wholly covers the existing region replaces it.
        let covering = sheet.merge(range("A1:D4"))
        #expect(covering)
        #expect(sheet.mergedRanges == [range("A1:D4")])

        sheet.unmerge(range("C3"))
        #expect(sheet.mergedRanges.isEmpty)
    }

    @Test("A selection is grown until it holds every merge it touches")
    func selectionExpansion() {
        let sheet = merged(["B2:C3", "E5:F6"])

        #expect(sheet.expandedToMerges(CellRange(CellAddress(a1: "C3")!)) == range("B2:C3"))
        #expect(sheet.expandedToMerges(range("A1:B2")) == range("A1:C3"))
        // Growing to hold one merge can reach a second, which must also be held.
        #expect(sheet.expandedToMerges(range("C3:E5")) == range("B2:F6"))
        #expect(sheet.expandedToMerges(range("A8:B9")) == range("A8:B9"))
    }

    // MARK: - Structure edits

    @Test("Inserting rows moves a merge below it and stretches one around it")
    func rowInsertion() {
        var sheet = merged(["A5:C5", "A9:C11"])

        sheet.insertRows(2, at: 4)
        #expect(sheet.mergedRanges.contains(range("A7:C7")))
        #expect(sheet.mergedRanges.contains(range("A11:C13")))

        // Inserting inside a region widens it, the way Excel widens a heading.
        sheet.insertRows(1, at: 11)
        #expect(sheet.mergedRanges.contains(range("A11:C14")))
    }

    @Test("Inserting columns moves and stretches merges on the other axis")
    func columnInsertion() {
        var sheet = merged(["C1:D1", "F1:F3"])

        sheet.insertColumns(1, at: 2)
        #expect(sheet.mergedRanges.contains(range("D1:E1")))
        #expect(sheet.mergedRanges.contains(range("G1:G3")))
    }

    @Test("Deleting rows shrinks a split merge and removes a wholly deleted one")
    func rowDeletion() {
        var sheet = merged(["A2:C4", "A8:B9"])

        // Rows 3 and 4 are the middle of the first region: it shrinks.
        sheet.removeRows(2...2)
        #expect(sheet.mergedRanges.contains(range("A2:C3")))
        // Everything below closed up by one.
        #expect(sheet.mergedRanges.contains(range("A7:B8")))

        // Taking every row a region covers takes the region with it.
        sheet.removeRows(6...7)
        #expect(sheet.mergedRanges == [range("A2:C3")])
    }

    @Test("A merge shrunk to a single cell stops being a merge")
    func collapseToSingleCell() {
        var sheet = merged(["A1:B1"])
        sheet.removeColumns(1...1)
        #expect(sheet.mergedRanges.isEmpty)
    }

    @Test("Deleting columns shrinks and removes merges the same way rows do")
    func columnDeletion() {
        var sheet = merged(["B1:E1", "G1:H2"])

        sheet.removeColumns(2...2)
        #expect(sheet.mergedRanges.contains(range("B1:D1")))
        #expect(sheet.mergedRanges.contains(range("F1:G2")))

        sheet.removeColumns(5...6)
        #expect(sheet.mergedRanges == [range("B1:D1")])
    }

    @Test("Merges survive a structural edit and the file it is saved to")
    func structuralEditsRoundTrip() throws {
        var sheet = merged(["A9:C9"])
        sheet[CellAddress(a1: "A9")!] = Cell(value: .text("Heading"), formula: nil, style: .default)
        sheet.insertRows(2, at: 0)

        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let reopened = try XLSXReader.workbook(from: data).sheets[0]

        #expect(reopened.mergedRanges == [range("A11:C11")])
        #expect(reopened[CellAddress(a1: "A11")!].value == .text("Heading"))
    }

    // MARK: - Hidden sheets

    @Test("state=\"hidden\" is read off the workbook part")
    func readsHiddenState() throws {
        let workbook = try XLSXReader.workbook(from: packaged([
            SheetFixture(name: "Visible", state: nil, xml: worksheet()),
            SheetFixture(name: "Notes", state: "hidden", xml: worksheet()),
            SheetFixture(name: "Internals", state: "veryHidden", xml: worksheet()),
        ]))

        #expect(workbook.sheets.count == 3)
        #expect(workbook.sheets.map(\.isHidden) == [false, true, true])
        #expect(workbook.visibleSheets.map(\.name) == ["Visible"])
    }

    @Test("A file hiding every sheet still opens with one visible")
    func neverEveryLastSheetHidden() throws {
        let workbook = try XLSXReader.workbook(from: packaged([
            SheetFixture(name: "One", state: "hidden", xml: worksheet()),
            SheetFixture(name: "Two", state: "hidden", xml: worksheet()),
        ]))
        #expect(workbook.visibleSheets.count == 1)
        #expect(workbook.sheets[0].isHidden == false)
    }

    @Test("Hidden sheets round-trip through a save")
    func hiddenSheetsRoundTrip() throws {
        var workbook = Workbook(sheets: [Worksheet(name: "Visible"), Worksheet(name: "Notes")])
        let hid = workbook.setSheet(workbook.sheets[1].id, hidden: true)
        #expect(hid)

        let xml = String(
            decoding: try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))["xl/workbook.xml"]!,
            as: UTF8.self
        )
        #expect(xml.contains("state=\"hidden\""))

        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: workbook))
        #expect(reopened.sheets.map(\.isHidden) == [false, true])
    }

    @Test("The last visible sheet cannot be hidden")
    func lastVisibleSheetProtected() {
        var workbook = Workbook(sheets: [Worksheet(name: "One"), Worksheet(name: "Two")])
        let hidSecond = workbook.setSheet(workbook.sheets[1].id, hidden: true)
        let hidLast = workbook.setSheet(workbook.sheets[0].id, hidden: true)
        #expect(hidSecond)
        #expect(hidLast == false)
        #expect(workbook.visibleSheets.count == 1)

        // Nor may deleting one leave the workbook with nothing to show.
        workbook.removeSheet(workbook.sheets[0].id)
        #expect(workbook.visibleSheets.count == 1)
    }
}
