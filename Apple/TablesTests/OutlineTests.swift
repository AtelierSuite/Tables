import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Grouped rows and columns — Excel's outline: levels and collapsed groups
/// read from `<row>` and `<col>`, kept through a save, collapsed, expanded,
/// grouped and ungrouped, and moved with their lines.
@Suite("Row and column outlines")
struct OutlineTests {

    // MARK: - Helpers

    /// Rows 2–5 are grouped, with rows 3–4 grouped again inside them and
    /// collapsed (the mark on row 5, their summary). Columns B–C are grouped
    /// and collapsed, the mark on D.
    private let sheetXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
    <sheetFormatPr defaultRowHeight="15" outlineLevelRow="2" outlineLevelCol="1"/>\
    <cols><col min="2" max="3" width="9" hidden="1" outlineLevel="1"/>\
    <col min="4" max="4" width="9" collapsed="1"/></cols><sheetData>\
    <row r="1"><c r="A1"><v>1</v></c></row>\
    <row r="2" outlineLevel="1"><c r="A2"><v>2</v></c></row>\
    <row r="3" hidden="1" outlineLevel="2"/>\
    <row r="4" hidden="1" outlineLevel="2"/>\
    <row r="5" outlineLevel="1" collapsed="1"/>\
    <row r="6"><c r="A6"><v>6</v></c></row>\
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
        Target="worksheets/sheet1.xml"/></Relationships>
        """
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ])
    }

    private func readSheet(_ xml: String? = nil) throws -> Worksheet {
        try XLSXReader.workbook(from: package(sheet: xml ?? sheetXML)).sheets[0]
    }

    private func savedSheetXML(_ sheet: Worksheet) throws -> String {
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: Workbook(sheets: [sheet])))
        return String(decoding: try #require(entries["xl/worksheets/sheet1.xml"]), as: UTF8.self)
    }

    private func roundTrip(_ sheet: Worksheet) throws -> Worksheet {
        try XLSXReader.workbook(from: XLSXWriter.data(from: Workbook(sheets: [sheet]))).sheets[0]
    }

    /// The groups of an outline as `level:first-last@summary`, for short expectations.
    private func describe(_ outline: LineOutline) -> [String] {
        outline.groups().map { "\($0.level):\($0.lines.lowerBound)-\($0.lines.upperBound)@\($0.summary)" }
    }

    // MARK: - Reading

    @Test("Outline levels and collapsed marks are read from rows and columns")
    func readsOutline() throws {
        let sheet = try readSheet()
        #expect(sheet.rowOutline.levels == [1: 1, 2: 2, 3: 2, 4: 1])
        #expect(sheet.rowOutline.collapsed == [4])
        #expect(sheet.columnOutline.levels == [1: 1, 2: 1])
        #expect(sheet.columnOutline.collapsed == [3])
        #expect(sheet.rowOutline.summaryAfter && sheet.columnOutline.summaryAfter)
    }

    @Test("Groups are runs of lines at a level or deeper, the button on the line after")
    func findsGroups() throws {
        let sheet = try readSheet()
        #expect(describe(sheet.rowOutline) == ["1:1-4@5", "2:2-3@4"])
        #expect(describe(sheet.columnOutline) == ["1:1-2@3"])
        let groups = sheet.rowOutline.groups()
        #expect(!sheet.isCollapsed(groups[0], axis: .row))
        #expect(sheet.isCollapsed(groups[1], axis: .row))
        #expect(sheet.isCollapsed(sheet.columnOutline.groups()[0], axis: .column))
    }

    @Test("Summaries above and to the left put the button before the group")
    func readsSummaryPlacement() throws {
        let xml = sheetXML.replacingOccurrences(
            of: "<sheetFormatPr",
            with: "<sheetPr><outlinePr summaryBelow=\"0\" summaryRight=\"0\"/></sheetPr><sheetFormatPr"
        )
        let sheet = try readSheet(xml)
        #expect(!sheet.rowOutline.summaryAfter)
        #expect(!sheet.columnOutline.summaryAfter)
        #expect(describe(sheet.rowOutline) == ["1:1-4@0", "2:2-3@1"])

        let saved = try savedSheetXML(sheet)
        #expect(saved.contains("<outlinePr summaryBelow=\"0\" summaryRight=\"0\"/>"))
        let reread = try roundTrip(sheet)
        #expect(!reread.rowOutline.summaryAfter && !reread.columnOutline.summaryAfter)
    }

    // MARK: - Saving

    @Test("Levels, collapsed marks and outline depth are written back")
    func writesOutline() throws {
        let xml = try savedSheetXML(try readSheet())
        #expect(xml.contains("outlineLevelRow=\"2\""))
        #expect(xml.contains("outlineLevelCol=\"1\""))
        #expect(xml.contains("<row r=\"3\" hidden=\"1\" outlineLevel=\"2\"/>"))
        #expect(xml.contains("<row r=\"5\" outlineLevel=\"1\" collapsed=\"1\"/>"))
        #expect(xml.contains("hidden=\"1\" outlineLevel=\"1\"/>"))
        #expect(xml.contains("<col min=\"4\" max=\"4\" width=\"") && xml.contains("collapsed=\"1\"/></cols>"))
        // The default placement is left unsaid.
        #expect(!xml.contains("outlinePr"))
    }

    @Test("An outline survives a save and a second read unchanged")
    func roundTrips() throws {
        let sheet = try readSheet()
        let reread = try roundTrip(sheet)
        #expect(reread.rowOutline == sheet.rowOutline)
        #expect(reread.columnOutline == sheet.columnOutline)
        #expect(reread.hiddenRows == sheet.hiddenRows)
        #expect(reread.hiddenColumns == sheet.hiddenColumns)
    }

    @Test("A collapsed mark just past the sheet's last row is kept")
    func keepsMarkPastLastRow() throws {
        var sheet = Worksheet(name: "S")
        sheet.rowCount = 10
        sheet.group(7...9, axis: .row)
        sheet.collapse(sheet.rowOutline.groups()[0], axis: .row)
        #expect(sheet.rowOutline.collapsed == [10])
        let reread = try roundTrip(sheet)
        #expect(reread.rowOutline.collapsed.contains(10))
        #expect(reread.hiddenRows.isSuperset(of: [7, 8, 9]))
    }

    @Test("A sheet with no outline writes none")
    func writesNothingWithoutOutline() throws {
        let xml = try savedSheetXML(Worksheet(name: "S"))
        #expect(!xml.contains("outlineLevel"))
        #expect(!xml.contains("collapsed"))
    }

    // MARK: - Collapsing and expanding

    @Test("Collapsing hides a group's lines and marks its summary")
    func collapses() throws {
        var sheet = try readSheet()
        let outer = sheet.rowOutline.groups()[0]
        sheet.collapse(outer, axis: .row)
        #expect(sheet.hiddenRows.isSuperset(of: [1, 2, 3, 4]))
        #expect(!sheet.hiddenRows.contains(5))
        #expect(sheet.rowOutline.collapsed.contains(5))
        #expect(sheet.isCollapsed(outer, axis: .row))
    }

    @Test("Expanding shows the group but leaves a collapsed group inside it folded")
    func expandsKeepingInnerCollapsed() throws {
        var sheet = try readSheet()
        let outer = sheet.rowOutline.groups()[0]
        sheet.collapse(outer, axis: .row)
        sheet.expand(outer, axis: .row)
        #expect(!sheet.hiddenRows.contains(1))
        #expect(!sheet.hiddenRows.contains(4))
        #expect(sheet.hiddenRows.isSuperset(of: [2, 3]))
        #expect(!sheet.rowOutline.collapsed.contains(5))

        let inner = sheet.rowOutline.groups()[1]
        sheet.expand(inner, axis: .row)
        #expect(sheet.hiddenRows.isEmpty)
        #expect(sheet.rowOutline.collapsed.isEmpty)
    }

    @Test("Expanding a collapsed column group shows its columns")
    func expandsColumns() throws {
        var sheet = try readSheet()
        sheet.expand(sheet.columnOutline.groups()[0], axis: .column)
        #expect(sheet.hiddenColumns.isEmpty)
        #expect(sheet.columnOutline.collapsed.isEmpty)
    }

    @Test("Showing levels collapses every group deeper than the level")
    func showsLevels() throws {
        var sheet = try readSheet()
        sheet.showOutlineLevels(1, axis: .row)
        #expect(sheet.hiddenRows.isSuperset(of: [1, 2, 3, 4]))
        sheet.showOutlineLevels(3, axis: .row)
        #expect(sheet.hiddenRows.isEmpty)
        sheet.showOutlineLevels(2, axis: .row)
        #expect(sheet.hiddenRows == [2, 3])
    }

    // MARK: - Grouping and ungrouping

    @Test("Grouping puts lines a level deeper, up to seven")
    func groups() {
        var sheet = Worksheet(name: "S")
        sheet.group(2...4, axis: .column)
        #expect(describe(sheet.columnOutline) == ["1:2-4@5"])
        sheet.group(3...3, axis: .column)
        #expect(describe(sheet.columnOutline) == ["1:2-4@5", "2:3-3@4"])
        for _ in 0..<10 { sheet.group(3...3, axis: .column) }
        #expect(sheet.columnOutline.level(of: 3) == LineOutline.deepestLevel)
    }

    @Test("Ungrouping takes lines a level out and shows a collapsed group they leave")
    func ungroups() throws {
        var sheet = try readSheet()
        // Rows 3–4 (zero-based 2–3) are the collapsed inner group.
        sheet.ungroup(2...3, axis: .row)
        #expect(sheet.rowOutline.levels == [1: 1, 2: 1, 3: 1, 4: 1])
        #expect(sheet.hiddenRows.isEmpty)
        #expect(sheet.rowOutline.collapsed.isEmpty)

        sheet.ungroup(1...4, axis: .row)
        #expect(sheet.rowOutline.isEmpty)
    }

    @Test("The editor groups and ungroups the selected rows") @MainActor
    func editorGroupsSelection() {
        var book = Workbook(sheets: [Worksheet(name: "S")])
        let state = EditorState()
        state.activeSheetID = book.sheets[0].id
        state.selectEntireRows(1...3, in: book.sheets[0])
        state.groupSelection(.row, in: &book)
        #expect(describe(book.sheets[0].rowOutline) == ["1:1-3@4"])
        #expect(state.canUngroupSelection(.row, in: book))

        let group = book.sheets[0].rowOutline.groups()[0]
        state.toggleOutlineGroup(group, axis: .row, in: &book)
        #expect(book.sheets[0].hiddenRows == [1, 2, 3])
        state.toggleOutlineGroup(group, axis: .row, in: &book)
        #expect(book.sheets[0].hiddenRows.isEmpty)

        state.ungroupSelection(.row, in: &book)
        #expect(book.sheets[0].rowOutline.isEmpty)
        #expect(!state.canUngroupSelection(.row, in: book))
    }

    // MARK: - Structure edits

    @Test("Inserting inside a group widens it; removing lines shrinks it")
    func movesWithStructure() throws {
        var sheet = try readSheet()
        sheet.insertRows(1, at: 3)
        #expect(describe(sheet.rowOutline) == ["1:1-5@6", "2:2-4@5"])
        #expect(sheet.rowOutline.collapsed == [5])
        sheet.removeRows(0...0)
        #expect(describe(sheet.rowOutline) == ["1:0-4@5", "2:1-3@4"])
        #expect(sheet.rowOutline.collapsed == [4])

        sheet.insertColumns(1, at: 0)
        #expect(describe(sheet.columnOutline) == ["1:2-3@4"])
        #expect(sheet.columnOutline.collapsed == [4])
        sheet.removeColumns(2...3)
        #expect(sheet.columnOutline.isEmpty)
    }
}
