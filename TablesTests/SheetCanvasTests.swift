import Foundation
import Testing
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
}
