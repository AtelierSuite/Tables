import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// The options a sheet's `<sheetView>` sets — gridlines, headings and the
/// rest — are read into the sheet, honoured, and written back on save,
/// without disturbing the panes and selections kept beside them.
@Suite("Sheet view options")
struct SheetViewOptionsTests {

    // MARK: - Package construction

    /// A package with one worksheet per body, each holding a cell in A1 and
    /// `body` — its `<sheetViews>`, say — ahead of the cells.
    private func package(sheets bodies: [String]) throws -> Data {
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var types = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/xl/workbook.xml\" "
            + "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        var sheets = "", links = ""
        var entries: [(path: String, data: Data)] = []
        for (index, body) in bodies.enumerated() {
            let number = index + 1
            types += "<Override PartName=\"/xl/worksheets/sheet\(number).xml\" "
                + "ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            sheets += "<sheet name=\"Sheet\(number)\" sheetId=\"\(number)\" r:id=\"rId\(number)\"/>"
            links += "<Relationship Id=\"rId\(number)\" Type=\"\(relationships)/worksheet\" "
                + "Target=\"worksheets/sheet\(number).xml\"/>"
            let sheet = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"\(main)\" xmlns:r=\"\(relationships)\">"
                + body + "<sheetData><row r=\"1\"><c r=\"A1\"><v>0</v></c><c r=\"B1\"><f>1+1</f><v>2</v></c></row>"
                + "</sheetData></worksheet>"
            entries.append(("xl/worksheets/sheet\(number).xml", Data(sheet.utf8)))
        }
        types += "</Types>"
        let rootLinks = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(relationships)/officeDocument\" Target=\"xl/workbook.xml\"/>"
            + "</Relationships>"
        let workbook = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook xmlns=\"\(main)\" xmlns:r=\"\(relationships)\">"
            + "<sheets>\(sheets)</sheets></workbook>"
        let workbookLinks = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(links)</Relationships>"
        entries = [
            ("[Content_Types].xml", Data(types.utf8)),
            ("_rels/.rels", Data(rootLinks.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookLinks.utf8)),
        ] + entries
        return try ZipArchive.archive(entries: entries)
    }

    /// The `<sheetViews>` of a sheet in a saved workbook, or nil for none.
    private func savedViews(of workbook: Workbook, sheet number: Int = 1) throws -> String? {
        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        let payload = try #require(entries["xl/worksheets/sheet\(number).xml"])
        let xml = String(decoding: payload, as: UTF8.self)
        guard let start = xml.range(of: "<sheetViews"), let end = xml.range(of: "</sheetViews>") else { return nil }
        return String(xml[start.lowerBound..<end.upperBound])
    }

    private func reopened(_ workbook: Workbook) throws -> Workbook {
        try XLSXReader.workbook(from: try XLSXWriter.data(from: workbook))
    }

    // MARK: - Gridlines and headings

    @Test("Gridlines and headings are on unless the view turns them off")
    func readsGridLinesAndHeadings() throws {
        let workbook = try XLSXReader.workbook(from: try package(sheets: [
            "<sheetViews><sheetView showGridLines=\"0\" showRowColHeaders=\"false\" workbookViewId=\"0\"/></sheetViews>",
            "<sheetViews><sheetView workbookViewId=\"0\"/></sheetViews>",
            "",
        ]))
        #expect(!workbook.sheets[0].showsGridLines)
        #expect(!workbook.sheets[0].showsHeadings)
        #expect(workbook.sheets[1].showsGridLines)
        #expect(workbook.sheets[1].showsHeadings)
        #expect(workbook.sheets[2].showsGridLines)
        #expect(workbook.sheets[2].showsHeadings)
        #expect(workbook.unsupportedFeatures.isEmpty)
    }

    @Test("Turning gridlines and headings back on writes Excel's defaults, keeping the pane and selection")
    func writesGridLinesAndHeadings() throws {
        var workbook = try XLSXReader.workbook(from: try package(sheets: [
            "<sheetViews><sheetView showGridLines=\"0\" showRowColHeaders=\"0\" tabSelected=\"1\" workbookViewId=\"0\">"
                + "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
                + "<selection pane=\"bottomLeft\" activeCell=\"A3\" sqref=\"A3\"/>"
                + "</sheetView></sheetViews>",
        ]))
        let kept = try #require(try savedViews(of: workbook))
        #expect(kept.contains("showGridLines=\"0\""))
        #expect(kept.contains("showRowColHeaders=\"0\""))
        #expect(kept.contains("tabSelected=\"1\""))
        #expect(kept.contains("state=\"frozen\""))

        workbook.sheets[0].showsGridLines = true
        workbook.sheets[0].showsHeadings = true
        let saved = try #require(try savedViews(of: workbook))
        #expect(!saved.contains("showGridLines"))
        #expect(!saved.contains("showRowColHeaders"))
        #expect(saved.contains("tabSelected=\"1\""))
        #expect(saved.contains("ySplit=\"1\""))
        let reread = try reopened(workbook)
        #expect(reread.sheets[0].showsGridLines)
        #expect(reread.sheets[0].showsHeadings)
        #expect(reread.sheets[0].frozenRows == 1)
    }

    @Test("A sheet with no view of its own gets one when an option is turned off")
    func writesAViewForOptions() throws {
        var sheet = Worksheet(name: "Sheet1")
        #expect(try savedViews(of: Workbook(sheets: [sheet])) == nil)
        sheet.showsGridLines = false
        sheet.showsHeadings = false
        let saved = try #require(try savedViews(of: Workbook(sheets: [sheet])))
        #expect(saved.contains("showGridLines=\"0\""))
        #expect(saved.contains("showRowColHeaders=\"0\""))
        let reread = try reopened(Workbook(sheets: [sheet]))
        #expect(!reread.sheets[0].showsGridLines)
        #expect(!reread.sheets[0].showsHeadings)
    }

    @Test("A sheet without gridlines draws none, and still draws its borders' lines")
    func metricsLeaveOutGridLines() {
        var sheet = Worksheet(name: "Sheet1")
        let frame = CGRect(x: 0, y: 0, width: 72, height: 28)
        #expect(SheetMetrics(sheet: sheet).gridLines(of: frame).count == 2)
        sheet.showsGridLines = false
        let metrics = SheetMetrics(sheet: sheet)
        #expect(metrics.gridLines(of: frame).isEmpty)
        #expect(metrics != SheetMetrics(sheet: Worksheet(name: "Sheet1")))
    }

    @Test("The view menus' toggles change the active sheet, and only where views are kept")
    @MainActor
    func togglesChangeActiveSheet() {
        var workbook = Workbook(sheets: [Worksheet(name: "One"), Worksheet(name: "Two")])
        let state = EditorState()
        state.selectSheet(workbook.sheets[1].id, in: workbook)
        state.setViewOption(\.showsGridLines, to: false, in: &workbook)
        state.setViewOption(\.showsHeadings, to: false, in: &workbook)
        #expect(workbook.sheets[0].showsGridLines && workbook.sheets[0].showsHeadings)
        #expect(!workbook.sheets[1].showsGridLines && !workbook.sheets[1].showsHeadings)
        #expect(!state.metrics.showsGridLines)

        state.allowsFreezingPanes = false
        state.setViewOption(\.showsGridLines, to: true, in: &workbook)
        #expect(!workbook.sheets[1].showsGridLines)
    }

    // MARK: - Zoom

    @Test("A sheet's saved zoom is read, kept in Excel's range, and written back with its normal view's")
    func readsAndWritesZoom() throws {
        var workbook = try XLSXReader.workbook(from: try package(sheets: [
            "<sheetViews><sheetView zoomScale=\"150\" zoomScaleNormal=\"150\" workbookViewId=\"0\"/></sheetViews>",
            "<sheetViews><sheetView zoomScale=\"900\" workbookViewId=\"0\"/></sheetViews>",
            "<sheetViews><sheetView zoomScale=\"0\" workbookViewId=\"0\"/></sheetViews>",
        ]))
        #expect(workbook.sheets.map(\.zoomScale) == [150, 400, 100])
        #expect(try savedViews(of: workbook)?.contains("zoomScale=\"150\"") == true)

        workbook.sheets[0].zoomScale = 85
        let saved = try #require(try savedViews(of: workbook))
        #expect(saved.contains("zoomScale=\"85\""))
        #expect(saved.contains("zoomScaleNormal=\"85\""))
        workbook.sheets[0].zoomScale = 100
        let reset = try #require(try savedViews(of: workbook))
        #expect(!reset.contains("zoomScale"))
        #expect(try reopened(workbook).sheets[0].zoomScale == 100)

        var fresh = Worksheet(name: "Sheet1")
        fresh.zoomScale = 175
        #expect(try reopened(Workbook(sheets: [fresh])).sheets[0].zoomScale == 175)
    }

    @Test("A sheet opens at its saved zoom, and a zoom made on it is kept with it")
    @MainActor
    func adoptsAndKeepsZoom() {
        var first = Worksheet(name: "One")
        first.zoomScale = 150
        var second = Worksheet(name: "Two")
        second.zoomScale = 400
        var workbook = Workbook(sheets: [first, second])
        let state = EditorState()
        state.selectSheet(workbook.sheets[0].id, in: workbook)
        #expect(state.zoom == 1.5)
        #expect(state.metrics.zoom == 1.5)
        // Further in than the app goes: shown as near as it can, and kept as
        // the file had it until the zoom is changed here.
        state.selectSheet(workbook.sheets[1].id, in: workbook)
        #expect(state.zoom == EditorState.zoomRange.upperBound)
        let before = workbook
        state.keepZoom(in: &workbook)
        #expect(workbook.sheets[1].zoomScale == 300)
        state.zoom = 0.75
        state.keepZoom(in: &workbook)
        #expect(workbook.sheets[1].zoomScale == 75)
        #expect(workbook.sheets[0].zoomScale == 150)
        #expect(workbook.differsOnlyInZoom(from: before))
    }

    @Test("A change to the zoom alone is no step to undo; any other change is")
    func zoomIsNotAnEdit() {
        let workbook = Workbook(sheets: [Worksheet(name: "One")])
        var zoomed = workbook
        zoomed.sheets[0].zoomScale = 120
        #expect(zoomed.differsOnlyInZoom(from: workbook))
        #expect(!workbook.differsOnlyInZoom(from: workbook))
        var edited = zoomed
        edited.sheets[0][CellAddress(row: 0, column: 0)] = Cell(value: .number(1))
        #expect(!edited.differsOnlyInZoom(from: workbook))
        #expect(!edited.differsOnlyInZoom(from: zoomed))
    }
}
