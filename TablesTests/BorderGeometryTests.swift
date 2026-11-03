import Foundation
import Testing
@testable import TablesEngine

@Suite("Border geometry")
struct BorderGeometryTests {
    private let metrics = SheetMetrics(sheet: Worksheet(name: "S"))

    @Test("Neighbours' borders on a shared edge land on the same line")
    func sharedEdgeIsOneLine() {
        let b4 = metrics.frame(for: CellAddress(row: 3, column: 1))
        let c4 = metrics.frame(for: CellAddress(row: 3, column: 2))
        let right = metrics.borderSegment(.trailing, of: b4, lineWidth: 2)
        let left = metrics.borderSegment(.leading, of: c4, lineWidth: 2)
        #expect(right.0.x == left.0.x)
        // On the gridline, which is a half-width inside B4's trailing edge.
        #expect(right.0.x == b4.maxX - 0.5)
    }

    @Test("Top and leading edges sit on the gridlines above and before")
    func topAndLeadingAreCentred() {
        let b2 = metrics.frame(for: CellAddress(row: 1, column: 1))
        #expect(metrics.borderSegment(.top, of: b2, lineWidth: 2).0.y == b2.minY - 0.5)
        #expect(metrics.borderSegment(.leading, of: b2, lineWidth: 2).0.x == b2.minX - 0.5)
        #expect(metrics.borderSegment(.bottom, of: b2, lineWidth: 2).0.y == b2.maxY - 0.5)
    }

    @Test("A line runs across the gridlines at its ends, closing corners")
    func linesCloseCorners() {
        let b2 = metrics.frame(for: CellAddress(row: 1, column: 1))
        let (start, end) = metrics.borderSegment(.top, of: b2, lineWidth: 2)
        #expect(start.x == b2.minX - 0.5 - 1)
        #expect(end.x == b2.maxX - 0.5 + 1)
    }

    @Test("At the outside of the table, the line stays inside the cell")
    func outerEdgesStayInside() {
        let a1 = metrics.frame(for: CellAddress(row: 0, column: 0))
        #expect(metrics.borderSegment(.top, of: a1, lineWidth: 2).0.y == 1)
        #expect(metrics.borderSegment(.leading, of: a1, lineWidth: 2).0.x == 1)
        let last = metrics.frame(for: CellAddress(row: metrics.rowCount - 1, column: metrics.columnCount - 1))
        #expect(metrics.borderSegment(.bottom, of: last, lineWidth: 2).0.y == last.maxY - 1)
        #expect(metrics.borderSegment(.trailing, of: last, lineWidth: 2).0.x == last.maxX - 1)
    }

    @Test("At the edge of the part shown, the line stays inside the cell")
    func shownEdgesStayInside() {
        let b2 = metrics.frame(for: CellAddress(row: 1, column: 1))
        let shown = metrics.frame(for: CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 1, column: 1)))
        #expect(metrics.borderSegment(.bottom, of: b2, lineWidth: 2, shown: shown).0.y == b2.maxY - 1)
        #expect(metrics.borderSegment(.trailing, of: b2, lineWidth: 2, shown: shown).0.x == b2.maxX - 1)
        #expect(metrics.borderSegment(.top, of: b2, lineWidth: 2, shown: shown).0.y == b2.minY - 0.5)
    }

    @Test("A double rule's passes straddle the gridline")
    func doubleRuleStraddles() {
        let b2 = metrics.frame(for: CellAddress(row: 1, column: 1))
        let above = metrics.borderSegment(.top, of: b2, lineWidth: 1, offset: -1)
        let below = metrics.borderSegment(.top, of: b2, lineWidth: 1, offset: 1)
        #expect(above.0.y == b2.minY - 1.5)
        #expect(below.0.y == b2.minY + 0.5)
    }

    @Test("Bordering lines reach past hidden ones")
    func borderingSkipsHiddenLines() {
        var sheet = Worksheet(name: "S")
        sheet.hiddenRows = [4, 5]
        let metrics = SheetMetrics(sheet: sheet)
        #expect(metrics.rowsBordering(2..<4) == 1..<7)
        #expect(metrics.rowsBordering(0..<3) == 0..<4)
        #expect(metrics.columnsBordering(1..<3) == 0..<4)
        // A new sheet has five columns, and there is nothing past the last.
        #expect(metrics.columnsBordering(3..<5) == 2..<5)
    }
}
