import Foundation
import Testing
@testable import TablesEngine

/// A printed sheet breaks between rows and between columns, never through
/// one, and takes in the charts and pictures floating over it.
@Suite("Print pagination")
struct PrintPaginationTests {
    @Test("Gathers lines into bands that each fit a page")
    func gathersBands() {
        let sizes: [Double] = [20, 20, 30, 40, 10, 50]
        let bands = PrintPagination.bands(of: 0..<6, length: 70) { sizes[$0] }
        #expect(bands == [0..<3, 3..<5, 5..<6])
    }

    @Test("Gives a line taller than a page a page of its own")
    func oversizedLine() {
        let sizes: [Double] = [10, 200, 10]
        let bands = PrintPagination.bands(of: 0..<3, length: 50) { sizes[$0] }
        #expect(bands == [0..<1, 1..<2, 2..<3])
    }

    @Test("Keeps hidden lines with the lines before them")
    func hiddenLines() {
        let sizes: [Double] = [30, 30, 0, 0, 30]
        let bands = PrintPagination.bands(of: 0..<5, length: 60) { sizes[$0] }
        #expect(bands == [0..<4, 4..<5])
    }

    @Test("Fills a page exactly when the lines add up to it")
    func exactFit() {
        let bands = PrintPagination.bands(of: 0..<4, length: 40) { _ in 20 }
        #expect(bands == [0..<2, 2..<4])
    }

    @Test("Starts the bands where the range does")
    func offsetRange() {
        let bands = PrintPagination.bands(of: 5..<9, length: 40) { _ in 20 }
        #expect(bands == [5..<7, 7..<9])
        #expect(PrintPagination.bands(of: 3..<3, length: 40) { _ in 20 }.isEmpty)
    }

    @Test("Numbers pages down the rows, then across, each on whole rows and columns")
    func pageOrder() {
        var sheet = Worksheet(name: "Sheet1")
        sheet.standardRowHeight = 20
        sheet.rowHeights[1] = 45
        let metrics = SheetMetrics(sheet: sheet)
        let range = CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 5, column: 3))
        // Room for three rows of 20 and two and a half columns.
        let size = CGSize(width: metrics.width(ofColumn: 0) * 2.5, height: 60)
        let pagination = PrintPagination(range: range, metrics: metrics, pageSize: size)

        #expect(pagination.columnBands == [0..<2, 2..<4])
        // The tall second row doesn't fit after the first and the third.
        #expect(pagination.rowBands == [0..<1, 1..<2, 2..<5, 5..<6])
        #expect(pagination.pages.map(\.rows) == pagination.rowBands + pagination.rowBands)
        #expect(pagination.pages.map(\.columns) == Array(repeating: 0..<2, count: 4) + Array(repeating: 2..<4, count: 4))
        for page in pagination.pages {
            #expect(page.frame.height <= size.height)
            #expect(page.frame.width <= size.width)
            #expect(Double(page.frame.minY) == metrics.y(ofRow: page.rows.lowerBound))
            #expect(Double(page.frame.maxY) == metrics.y(ofRow: page.rows.upperBound))
            #expect(Double(page.frame.minX) == metrics.x(ofColumn: page.columns.lowerBound))
            #expect(Double(page.frame.maxX) == metrics.x(ofColumn: page.columns.upperBound))
        }
    }

    @Test("Prints out to the last cell in use")
    func printedRangeOfCells() {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(row: 9, column: 2)] = Cell(value: .text("x"))
        sheet[CellAddress(row: 3, column: 6)] = Cell(value: .text("y"))
        let range = PrintPagination.printedRange(of: sheet, objectFrames: [], metrics: SheetMetrics(sheet: sheet))
        #expect(range == CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 9, column: 6)))
    }

    @Test("Stretches the printed range to take in floating objects")
    func printedRangeWithObjects() {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(row: 1, column: 1)] = Cell(value: .text("x"))
        let metrics = SheetMetrics(sheet: sheet)
        // From the middle of C3 to exactly the end of E12.
        let frame = CGRect(
            x: metrics.x(ofColumn: 2) + 5, y: metrics.y(ofRow: 2) + 5,
            width: metrics.x(ofColumn: 5) - metrics.x(ofColumn: 2) - 5,
            height: metrics.y(ofRow: 12) - metrics.y(ofRow: 2) - 5)
        let range = PrintPagination.printedRange(of: sheet, objectFrames: [frame], metrics: metrics)
        #expect(range == CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 11, column: 4)))
    }

    @Test("Prints nothing of an empty sheet")
    func emptySheet() {
        let sheet = Worksheet(name: "Sheet1")
        #expect(PrintPagination.printedRange(of: sheet, objectFrames: [], metrics: SheetMetrics(sheet: sheet)) == nil)
    }
}
