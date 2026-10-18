import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Guards the paths that only misbehave once a workbook gets big: anything that
/// would walk the whole grid, or the whole cell table, once per line.
@Suite("Large workbooks")
struct LargeWorkbookTests {

    /// A tall, sparse sheet — a few populated rows scattered through a hundred
    /// thousand — which is the shape an exported report usually arrives in.
    private func tallSheet(rows: Int, populatedEvery step: Int) -> Worksheet {
        var sheet = Worksheet(name: "Sheet 1")
        sheet.rowCount = rows
        sheet.columnCount = 8
        for row in stride(from: 0, to: rows, by: step) {
            for column in 0..<4 {
                sheet[CellAddress(row: row, column: column)] = Cell(value: .number(Double(row + column)))
            }
        }
        return sheet
    }

    // MARK: - Geometry

    @Test("A sheet of default-sized lines measures the same either way")
    func uniformMetricsAgreeWithSizedOnes() {
        var sheet = Worksheet(name: "Sheet 1")
        sheet.rowCount = 500
        sheet.columnCount = 30
        let uniform = SheetMetrics(sheet: sheet, zoom: 1.5)

        // The same sheet with one line sized explicitly to its default takes
        // the offset-array path, so the two must answer alike.
        var sized = sheet
        sized.rowHeights[499] = Worksheet.defaultRowHeight
        sized.columnWidths[29] = Worksheet.defaultColumnWidth
        let measured = SheetMetrics(sheet: sized, zoom: 1.5)

        #expect(uniform.totalWidth == measured.totalWidth)
        #expect(uniform.totalHeight == measured.totalHeight)
        for row in [0, 1, 17, 499] {
            #expect(uniform.y(ofRow: row) == measured.y(ofRow: row))
            #expect(uniform.height(ofRow: row) == measured.height(ofRow: row))
        }
        for column in [0, 1, 12, 29] {
            #expect(uniform.x(ofColumn: column) == measured.x(ofColumn: column))
            #expect(uniform.width(ofColumn: column) == measured.width(ofColumn: column))
        }
        for position in stride(from: 0.0, to: 2000, by: 37) {
            #expect(uniform.row(atY: position) == measured.row(atY: position))
            #expect(uniform.column(atX: position) == measured.column(atX: position))
        }
        #expect(uniform.rows(in: 300...900) == measured.rows(in: 300...900))
    }

    @Test("Metrics for a hundred thousand rows cost nothing to build")
    func metricsScale() {
        var sheet = Worksheet(name: "Sheet 1")
        sheet.rowCount = Worksheet.maximumRowCount
        let started = Date()
        // Pinch-zoom rebuilds these on every frame, so a whole run of them has
        // to stay far inside a frame's budget.
        for step in 0..<60 {
            let metrics = SheetMetrics(sheet: sheet, zoom: 1 + Double(step) / 60)
            #expect(metrics.rowCount == Worksheet.maximumRowCount)
        }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    // MARK: - Stored cells

    @Test("A range reports only the cells the sheet actually holds")
    func storedAddressesAreTheStoredOnes() {
        let sheet = tallSheet(rows: 5_000, populatedEvery: 500)
        let everything = CellRange(
            start: CellAddress(row: 0, column: 0),
            end: CellAddress(row: sheet.rowCount - 1, column: sheet.columnCount - 1)
        )
        #expect(Set(sheet.storedAddresses(in: everything)) == Set(sheet.cells.keys))

        // A range narrower than the sheet is full takes the other branch and
        // has to agree with it.
        let corner = CellRange(
            start: CellAddress(row: 0, column: 0), end: CellAddress(row: 600, column: 1)
        )
        let expected = sheet.cells.keys.filter { corner.contains($0) }
        #expect(Set(sheet.storedAddresses(in: corner)) == Set(expected))
    }

    // MARK: - Whole-sheet edits

    @MainActor
    @Test("Restyling a whole sheet with a no-op leaves it as sparse as it was")
    func noOpStyleDoesNotFillTheSheet() {
        var workbook = Workbook(sheets: [tallSheet(rows: 20_000, populatedEvery: 1_000)])
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        state.selectAll(in: workbook.sheets[0])
        let before = workbook.sheets[0].cells.count

        // Nothing selected is bold, so switching bold off changes nothing —
        // and must not store twenty thousand rows' worth of default styles.
        state.applyStyle(in: &workbook) { $0.isBold = false }
        #expect(workbook.sheets[0].cells.count == before)

        // A change that does show still reaches every cell it covers, stored
        // or not.
        state.selection = CellRange(
            start: CellAddress(row: 0, column: 0), end: CellAddress(row: 1, column: 1)
        )
        state.applyStyle(in: &workbook) { $0.isItalic = true }
        let corner = [
            CellAddress(row: 0, column: 0), CellAddress(row: 0, column: 1),
            CellAddress(row: 1, column: 0), CellAddress(row: 1, column: 1),
        ]
        #expect(corner.allSatisfy { workbook.sheets[0][$0].style.isItalic })
    }

    @MainActor
    @Test("Clearing a whole-sheet selection empties it without materializing it")
    func clearingAWholeSheet() {
        var workbook = Workbook(sheets: [tallSheet(rows: 20_000, populatedEvery: 1_000)])
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        state.selectAll(in: workbook.sheets[0])

        state.clearContents(in: &workbook)
        #expect(workbook.sheets[0].cells.isEmpty)
    }

    @MainActor
    @Test("Fitting a column measures its contents, not its empty rows")
    func fittingATallColumn() {
        var sheet = tallSheet(rows: 50_000, populatedEvery: 10_000)
        sheet[CellAddress(row: 30_000, column: 0)] = Cell(value: .text("a rather long entry indeed"))
        var workbook = Workbook(sheets: [sheet])
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id

        state.fitColumn(0, in: &workbook)
        let width = workbook.sheets[0].columnWidths[0] ?? 0
        #expect(width > Worksheet.defaultColumnWidth)
        #expect(width <= 420)

        // A column holding nothing falls back to the floor rather than to
        // whatever the neighbours measured.
        state.fitColumn(7, in: &workbook)
        #expect(workbook.sheets[0].columnWidths[7] == Worksheet.minimumColumnWidth)
    }

    // MARK: - Recalculation

    @Test("Recalculating a settled workbook changes nothing")
    func recalculationIsIdempotent() {
        var sheet = Worksheet(name: "Sheet 1")
        sheet.rowCount = 200
        for row in 0..<100 {
            sheet[CellAddress(row: row, column: 0)] = Cell(value: .number(Double(row)))
            var total = Cell()
            total.formula = "SUM(A1:A\(row + 1))"
            sheet[CellAddress(row: row, column: 1)] = total
        }
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()

        let settled = workbook
        workbook.recalculate()
        #expect(workbook == settled)

        // And a real change still propagates through the cached results.
        workbook.sheets[0][CellAddress(row: 0, column: 0)] = Cell(value: .number(1_000))
        workbook.recalculate()
        #expect(workbook.sheets[0][CellAddress(row: 99, column: 1)].value == .number(5_950))
    }

    // MARK: - Saving

    @Test("Saving a tall sheet does not rescan its cells once per row")
    func writingATallSheetIsLinear() throws {
        let sheet = tallSheet(rows: 40_000, populatedEvery: 4)
        let workbook = Workbook(sheets: [sheet])

        let started = Date()
        let data = try XLSXWriter.data(from: workbook)
        // Generous by two orders of magnitude against the linear cost, and far
        // inside what a scan per row would take.
        #expect(Date().timeIntervalSince(started) < 20)

        let reopened = try XLSXReader.workbook(from: data)
        #expect(reopened.sheets[0].cells.count == sheet.cells.count)
        #expect(reopened.sheets[0][CellAddress(row: 39_996, column: 3)].value == .number(39_999))
    }
}
