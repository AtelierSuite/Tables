import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

@Suite("Sheet canvases")
struct SheetCanvasTests {
    private func workbook(_ names: String...) -> Workbook {
        Workbook(sheets: names.map { Worksheet(name: $0) })
    }

    @Test("A Numbers sheet of several tables is a canvas of them, under the sheet's name")
    func numbersSheetsBecomeCanvases() throws {
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [.init(name: "Table 1", rows: [[.text("Rent")]])])
        document.addSheet("Plans", tables: [
            .init(name: "Trips", rows: [[.text("Kyoto")]]),
            .init(name: "Extra", rows: [[.text("Second")]]),
        ])
        let workbook = try NumbersReader.workbook(from: document.singleFile())

        #expect(workbook.canvases.count == 1)
        let canvas = try #require(workbook.canvases.first)
        #expect(canvas.name == "Plans")
        #expect(canvas.tables.map(\.sheetID) == [workbook.sheets[1].id, workbook.sheets[2].id])
        #expect(workbook.tableName(of: workbook.sheets[1].id) == "Trips")
        #expect(workbook.canvas(containing: workbook.sheets[0].id) == nil)
        // Placed apart, one below the other, when the file says nothing.
        #expect(canvas.tables[1].y > canvas.tables[0].y + workbook.sheets[1].totalHeight)
    }

    @Test("Placing a sheet with another starts a canvas, the new table below, the tabs kept together")
    func placingStartsACanvas() {
        var book = workbook("A", "B", "C")
        let (a, b, c) = (book.sheets[0].id, book.sheets[1].id, book.sheets[2].id)
        let started = book.placeSheet(c, onCanvasWith: a)
        #expect(started)

        let canvas = book.canvases.first
        #expect(canvas?.name == "A")
        #expect(canvas?.tables.map(\.sheetID) == [a, c])
        #expect(book.sheets.map(\.id) == [a, c, b])
        #expect((canvas?.tables[1].y ?? 0) > (canvas?.tables[0].y ?? 0) + book.sheets[0].totalHeight)

        // A third joins the same canvas.
        let joined = book.placeSheet(b, onCanvasWith: c)
        #expect(joined)
        #expect(book.canvases.count == 1)
        #expect(book.canvases[0].tables.map(\.sheetID) == [a, c, b])
    }

    @Test("A canvas left with one table is a sheet again")
    func canvasesDissolve() {
        var book = workbook("A", "B", "C")
        let (a, b) = (book.sheets[0].id, book.sheets[1].id)
        book.placeSheet(b, onCanvasWith: a)
        book.removeFromCanvas(b)
        #expect(book.canvases.isEmpty)

        book.placeSheet(b, onCanvasWith: a)
        let removed = book.removeSheet(a)
        #expect(removed)
        #expect(book.canvases.isEmpty)
    }

    @Test("Moving one of a canvas's sheets in the tabs moves them all")
    func canvasesMoveTogether() {
        var book = workbook("A", "B", "C", "D")
        let ids = book.sheets.map(\.id)
        book.placeSheet(ids[1], onCanvasWith: ids[0])
        book.moveSheet(ids[0], to: 3)
        #expect(book.sheets.map(\.id) == [ids[2], ids[3], ids[0], ids[1]])

        // And another sheet never lands between them.
        book.moveSheet(ids[2], to: 2)
        #expect(book.sheets.map(\.id) == [ids[3], ids[0], ids[1], ids[2]])
    }

    @Test("Chart sheets have no cells to lay out")
    func chartSheetsStayApart() {
        var book = workbook("A")
        var chart = Worksheet(name: "Chart")
        chart.kind = .chart
        book.sheets.append(chart)
        let placed = book.placeSheet(chart.id, onCanvasWith: book.sheets[0].id)
        #expect(!placed)
        #expect(book.canvases.isEmpty)
    }

    // MARK: - Excel files

    private func canvasWorkbook() -> Workbook {
        var book = workbook("Summary", "Sales", "Costs", "Notes")
        book.placeSheet(book.sheets[1].id, onCanvasWith: book.sheets[0].id)
        book.moveTable(book.sheets[1].id, toX: 420, y: 60)
        book.canvases[0].tables[1].showsName = false
        book.renameCanvas(book.canvases[0].id, to: "Overview")
        return book
    }

    @Test("Canvases come back from an Excel file as they were saved")
    func excelRoundTrip() throws {
        let book = canvasWorkbook()
        let read = try XLSXReader.workbook(from: XLSXWriter.data(from: book))

        let canvas = try #require(read.canvases.first)
        #expect(read.canvases.count == 1)
        #expect(canvas.name == "Overview")
        #expect(canvas.tables.map { read[$0.sheetID]?.name } == ["Summary", "Sales"])
        #expect(canvas.tables[1].x == 420 && canvas.tables[1].y == 60)
        #expect(canvas.tables[1].showsName == false)
        #expect(canvas.tables[0].showsName)
    }

    @Test("The canvases are a custom XML part beside the sheets, which stay sheets")
    func excelPackage() throws {
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: canvasWorkbook()))
        let part = try #require(entries["customXml/item1.xml"].map { String(decoding: $0, as: UTF8.self) })
        #expect(part.contains("<canvas name=\"Overview\">"))
        #expect(entries["customXml/itemProps1.xml"] != nil)
        let relationships = String(decoding: entries["xl/_rels/workbook.xml.rels"] ?? Data(), as: UTF8.self)
        #expect(relationships.contains("Target=\"../customXml/item1.xml\""))
        let types = String(decoding: entries["[Content_Types].xml"] ?? Data(), as: UTF8.self)
        #expect(types.contains("/customXml/itemProps1.xml"))
        let workbookPart = String(decoding: entries["xl/workbook.xml"] ?? Data(), as: UTF8.self)
        #expect(workbookPart.components(separatedBy: "<sheet ").count - 1 == 4)

        // Nothing at all without a canvas.
        let plain = try ZipArchive.entries(in: XLSXWriter.data(from: workbook("A", "B")))
        #expect(!plain.keys.contains { $0.hasPrefix("customXml/") })
    }

    @Test("A sheet renamed elsewhere stays on its canvas; one deleted takes the canvas with it")
    func excelEditedElsewhere() throws {
        var entries = try ZipArchive.entries(in: XLSXWriter.data(from: canvasWorkbook()))
        var workbookXML = String(decoding: entries["xl/workbook.xml"] ?? Data(), as: UTF8.self)
        workbookXML = workbookXML.replacingOccurrences(of: "name=\"Sales\"", with: "name=\"Revenue\"")
        entries["xl/workbook.xml"] = Data(workbookXML.utf8)
        let renamed = try XLSXReader.workbook(from: ZipArchive.archive(entries: entries.map { ($0.key, $0.value) }))
        #expect(renamed.canvases.first?.tables.compactMap { renamed[$0.sheetID]?.name } == ["Summary", "Revenue"])

        var book = canvasWorkbook()
        let saved = try XLSXReader.workbook(from: XLSXWriter.data(from: book))
        #expect(saved.sheets.map(\.fileSheetID) == [1, 2, 3, 4])
        book = saved
        _ = book.removeSheet(book.sheets[0].id)
        let reread = try XLSXReader.workbook(from: XLSXWriter.data(from: book))
        #expect(reread.canvases.isEmpty)
        // The sheets that are left keep their numbers.
        #expect(reread.sheets.map(\.fileSheetID) == [2, 3, 4])
    }

    @Test("A Numbers document's canvases go into the Excel file it is exported as")
    func numbersToExcel() throws {
        var document = NumbersDocumentBuilder()
        document.addSheet("Plans", tables: [
            .init(name: "Trips", rows: [[.text("Kyoto")]]),
            .init(name: "Extra", rows: [[.text("Second")]]),
        ])
        let numbers = try NumbersReader.workbook(from: document.singleFile())
        let excel = try XLSXReader.workbook(from: XLSXWriter.data(from: numbers))
        #expect(excel.canvases.first?.name == "Plans")
        #expect(excel.canvases.first?.tables.count == 2)
    }

    // MARK: - Numbers files

    private func plans() throws -> (Workbook, NumbersSource) {
        var document = NumbersDocumentBuilder()
        var trips = NumbersDocumentBuilder.Table(name: "Trips", rows: [[.text("Kyoto")]])
        trips.origin = (40, 60)
        trips.showsName = true
        var extra = NumbersDocumentBuilder.Table(name: "Extra", rows: [[.text("Second")]])
        extra.origin = (40, 300)
        document.addSheet("Plans", tables: [trips, extra])
        return try NumbersReader.document(from: document.singleFile())
    }

    private func saved(_ workbook: Workbook, _ source: NumbersSource) throws -> Workbook {
        let data = try #require(NumbersWriter.fileWrapper(for: workbook, source: source, existing: nil).regularFileContents)
        return try NumbersReader.workbook(from: data)
    }

    @Test("Tables moved, named and shown or hidden on a Numbers sheet are saved into it") @MainActor
    func numbersLayoutSaves() throws {
        var (book, source) = try plans()
        let canvas = try #require(book.canvases.first)
        #expect(canvas.tables.map(\.x) == [40, 40] && canvas.tables.map(\.y) == [60, 300])
        let (trips, extra) = (canvas.tables[0].sheetID, canvas.tables[1].sheetID)

        let state = EditorState()
        state.moveTable(extra, toX: 420, y: 60, in: &book)
        state.setTableNameShown(false, for: trips, in: &book)
        state.setTableNameShown(true, for: extra, in: &book)
        state.renameTable(extra, to: "Hotels", in: &book)
        state.renameCanvas(containing: trips, to: "Holiday", in: &book)
        #expect(NumbersEditPolicy.reconcile(book, from: source.imported, source: source).violation == nil)

        let read = try saved(book, source)
        let layout = try #require(read.canvases.first)
        #expect(layout.name == "Holiday")
        #expect(layout.tables[1].x == 420 && layout.tables[1].y == 60)
        #expect(layout.tables[0].x == 40 && layout.tables[0].y == 60)
        #expect(layout.tables.map(\.showsName) == [false, true])
        #expect(read.tableName(of: layout.tables[1].sheetID) == "Hotels")
        // The cells are as they were.
        #expect(read[layout.tables[1].sheetID]?[CellAddress(row: 0, column: 0)].value == .text("Second"))
    }

    @Test("Which tables a Numbers sheet holds stays as Numbers has it")
    func numbersRegroupingRefused() throws {
        let (book, source) = try plans()
        var regrouped = book
        regrouped.removeFromCanvas(book.sheets[1].id)
        let result = NumbersEditPolicy.reconcile(regrouped, from: book, source: source)
        #expect(result.violation == .structure)
        #expect(result.workbook.canvases == book.canvases)
    }
}
