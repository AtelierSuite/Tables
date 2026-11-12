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

    // MARK: - Snapping to device pixels

    /// Whether a position falls on a pixel boundary at `scale`.
    private func isWhole(_ value: Double, at scale: Double) -> Bool {
        abs(value * scale - (value * scale).rounded()) < 1e-9
    }

    private static let zooms = [0.57, 0.8, 1.33]
    private static let scales = [1.0, 2.0, 3.0]

    @Test("Cell edges land on device pixels at a fractional zoom, without gaps", arguments: zooms, scales)
    func edgesSnapToPixels(zoom: Double, scale: Double) {
        var custom = Worksheet(name: "S")
        custom.columnWidths[1] = 55.3
        custom.rowHeights[2] = 17.25
        for sheet in [Worksheet(name: "S"), custom] {
            let metrics = SheetMetrics(sheet: sheet, zoom: zoom, pixelScale: scale)
            for column in 0..<metrics.columnCount {
                let frame = metrics.frame(for: CellAddress(row: 0, column: column))
                #expect(isWhole(frame.minX, at: scale) && isWhole(frame.width, at: scale))
                #expect(abs(frame.maxX - metrics.x(ofColumn: column + 1)) < 1e-9)
                // Hit-testing agrees with the snapped edges.
                #expect(metrics.column(atX: frame.minX) == column)
                if column > 0 { #expect(metrics.column(atX: frame.minX - 0.01) == column - 1) }
            }
            for row in 0..<10 {
                let frame = metrics.frame(for: CellAddress(row: row, column: 0))
                #expect(isWhole(frame.minY, at: scale) && isWhole(frame.height, at: scale))
                #expect(metrics.row(atY: frame.minY) == row)
                if row > 0 { #expect(metrics.row(atY: frame.minY - 0.01) == row - 1) }
            }
            // Rounding each edge on its own keeps the sheet as long as it was.
            #expect(abs(metrics.totalWidth - SheetMetrics(sheet: sheet, zoom: zoom).totalWidth) <= 0.5 / scale + 1e-9)
        }
    }

    @Test("Without a pixel scale nothing moves", arguments: zooms)
    func unsnappedIsExact(zoom: Double) {
        let metrics = SheetMetrics(sheet: Worksheet(name: "S"), zoom: zoom)
        #expect(metrics.x(ofColumn: 3) == 3 * (Worksheet.defaultColumnWidth * zoom))
        #expect(metrics.lineWidth(of: .hair) == 0.5 * zoom)
        #expect(metrics.gridLineWidth == 1)
    }

    @Test("Lines are whole device pixels wide, and a hairline at least one", arguments: zooms, scales)
    func lineWidthsAreWholePixels(zoom: Double, scale: Double) {
        let metrics = SheetMetrics(sheet: Worksheet(name: "S"), zoom: zoom, pixelScale: scale)
        #expect(metrics.gridLineWidth * scale == max(1, scale.rounded()))
        for style in BorderLineStyle.allCases {
            let width = metrics.lineWidth(of: style) * scale
            #expect(width >= 1 && width == width.rounded())
        }
        let low = SheetMetrics(sheet: Worksheet(name: "S"), zoom: 0.5, pixelScale: 2)
        #expect(low.lineWidth(of: .hair) * 2 == 1)
    }

    @Test("Borders' sides land on device pixels, the same for both cells on an edge", arguments: zooms, scales)
    func bordersSnapToPixels(zoom: Double, scale: Double) {
        let metrics = SheetMetrics(sheet: Worksheet(name: "S"), zoom: zoom, pixelScale: scale)
        let b2 = metrics.frame(for: CellAddress(row: 1, column: 1))
        let c2 = metrics.frame(for: CellAddress(row: 1, column: 2))
        let b3 = metrics.frame(for: CellAddress(row: 2, column: 1))
        for style in BorderLineStyle.allCases {
            let width = metrics.lineWidth(of: style)
            for offset in metrics.passOffsets(of: style) {
                let right = metrics.borderSegment(.trailing, of: b2, lineWidth: width, offset: offset)
                let left = metrics.borderSegment(.leading, of: c2, lineWidth: width, offset: offset)
                #expect(right.0.x == left.0.x)
                #expect(isWhole(right.0.x - width / 2, at: scale))
                #expect(isWhole(right.0.y, at: scale) && isWhole(right.1.y, at: scale))
                let bottom = metrics.borderSegment(.bottom, of: b2, lineWidth: width, offset: offset)
                let top = metrics.borderSegment(.top, of: b3, lineWidth: width, offset: offset)
                #expect(bottom.0.y == top.0.y)
                #expect(isWhole(bottom.0.y - width / 2, at: scale))
                // Within a pixel of the gridline it replaces.
                #expect(abs(bottom.0.y - offset - (b2.maxY - metrics.gridLineWidth / 2)) <= 1 / scale)
            }
            // A double rule's passes stay apart.
            let passes = metrics.passOffsets(of: style)
            if passes.count == 2 { #expect(passes[1] - passes[0] >= width + 1 / scale - 1e-9) }
        }
    }

    @Test("Gridlines fill the last pixels inside a cell", arguments: zooms, scales)
    func gridLinesSnapToPixels(zoom: Double, scale: Double) {
        let metrics = SheetMetrics(sheet: Worksheet(name: "S"), zoom: zoom, pixelScale: scale)
        let b2 = metrics.frame(for: CellAddress(row: 1, column: 1))
        let lines = metrics.gridLines(of: b2)
        let half = metrics.gridLineWidth / 2
        #expect(lines.count == 2)
        #expect(abs(lines[0].0.x + half - b2.maxX) < 1e-9)
        #expect(abs(lines[1].0.y + half - b2.maxY) < 1e-9)
        #expect(metrics.gridLines(of: b2, openEdge: true).count == 1)
    }
}
