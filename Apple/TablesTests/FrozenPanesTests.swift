import Foundation
import Testing
@testable import TablesEngine

/// Floating objects over a sheet with frozen rows and columns show in the
/// pane they are in, and one across a freeze line is cut there, so its
/// frozen part stays put while the rest scrolls.
@Suite("Frozen panes")
struct FrozenPanesTests {
    /// Two frozen rows of 20 and one frozen column of 64, as a sheet at 100%.
    private let panes = FrozenPanes(width: 64, height: 40)

    @Test("Measures the frozen rows and columns from the sheet at its zoom")
    func measuresFromSheet() {
        var sheet = Worksheet(name: "Sheet1")
        sheet.frozenRows = 2
        sheet.frozenColumns = 1
        let metrics = SheetMetrics(sheet: sheet, zoom: 2)
        let measured = FrozenPanes(sheet: sheet, metrics: metrics)
        #expect(measured.width == metrics.x(ofColumn: 1))
        #expect(measured.height == metrics.y(ofRow: 2))
        #expect(measured.panes == [.scrolling, .rows, .columns, .corner])

        sheet.frozenColumns = 0
        let rowsOnly = FrozenPanes(sheet: sheet, metrics: metrics)
        #expect(rowsOnly.width == 0)
        #expect(rowsOnly.panes == [.scrolling, .rows])

        sheet.frozenRows = 0
        let none = FrozenPanes(sheet: sheet, metrics: metrics)
        #expect(!none.isFrozen)
        #expect(none.panes == [.scrolling])
    }

    @Test("An object belongs to the pane its top-left corner is in")
    func homePane() {
        #expect(panes.home(of: CGRect(x: 10, y: 5, width: 300, height: 200)) == .corner)
        #expect(panes.home(of: CGRect(x: 100, y: 5, width: 30, height: 20)) == .rows)
        #expect(panes.home(of: CGRect(x: 10, y: 100, width: 30, height: 20)) == .columns)
        #expect(panes.home(of: CGRect(x: 100, y: 100, width: 30, height: 20)) == .scrolling)
        // The freeze line itself is the first point past it.
        #expect(panes.home(of: CGRect(x: 64, y: 40, width: 30, height: 20)) == .scrolling)
        #expect(panes.home(of: CGRect(x: 63.5, y: 39.5, width: 30, height: 20)) == .corner)
    }

    @Test("An object inside one part of the sheet is one piece, left whole")
    func wholePieces() {
        let chart = CGRect(x: 100, y: 4, width: 200, height: 30)
        #expect(panes.pieces(of: chart) == [.init(pane: .rows, frame: chart)])
        let picture = CGRect(x: 2, y: 2, width: 40, height: 30)
        #expect(panes.pieces(of: picture) == [.init(pane: .corner, frame: picture)])
        let below = CGRect(x: 2, y: 300, width: 40, height: 30)
        #expect(panes.pieces(of: below) == [.init(pane: .columns, frame: below)])
        let scrolling = CGRect(x: 400, y: 600, width: 300, height: 200)
        #expect(panes.pieces(of: scrolling) == [.init(pane: .scrolling, frame: scrolling)])
        // Ending on a freeze line does not reach past it.
        let flush = CGRect(x: 100, y: 0, width: 50, height: 40)
        #expect(panes.pieces(of: flush) == [.init(pane: .rows, frame: flush)])
    }

    @Test("An object across the frozen rows' line is cut there")
    func cutAcrossRows() {
        let chart = CGRect(x: 100, y: 20, width: 200, height: 150)
        #expect(panes.pieces(of: chart) == [
            .init(pane: .scrolling, frame: CGRect(x: 100, y: 40, width: 200, height: 130)),
            .init(pane: .rows, frame: CGRect(x: 100, y: 20, width: 200, height: 20)),
        ])
    }

    @Test("An object across the frozen columns' line is cut there")
    func cutAcrossColumns() {
        let picture = CGRect(x: 30, y: 100, width: 100, height: 50)
        #expect(panes.pieces(of: picture) == [
            .init(pane: .scrolling, frame: CGRect(x: 64, y: 100, width: 66, height: 50)),
            .init(pane: .columns, frame: CGRect(x: 30, y: 100, width: 34, height: 50)),
        ])
    }

    @Test("An object across both lines is cut into four that tile it")
    func cutAcrossBoth() {
        let chart = CGRect(x: 10, y: 10, width: 300, height: 200)
        let pieces = panes.pieces(of: chart)
        #expect(pieces.map(\.pane) == [.scrolling, .rows, .columns, .corner])
        #expect(pieces.first { $0.pane == .corner }?.frame == CGRect(x: 10, y: 10, width: 54, height: 30))
        #expect(pieces.first { $0.pane == .rows }?.frame == CGRect(x: 64, y: 10, width: 246, height: 30))
        #expect(pieces.first { $0.pane == .columns }?.frame == CGRect(x: 10, y: 40, width: 54, height: 170))
        #expect(pieces.first { $0.pane == .scrolling }?.frame == CGRect(x: 64, y: 40, width: 246, height: 170))
        // Nothing lost and nothing doubled.
        #expect(pieces.reduce(0) { $0 + $1.frame.width * $1.frame.height } == chart.width * chart.height)
        for piece in pieces { #expect(chart.contains(piece.frame)) }
    }

    @Test("Without frozen lines, everything is in the scrolling pane")
    func nothingFrozen() {
        let none = FrozenPanes(width: 0, height: 0)
        let chart = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(none.pieces(of: chart) == [.init(pane: .scrolling, frame: chart)])
        #expect(none.home(of: chart) == .scrolling)
        // Frozen rows alone cut only across.
        let rows = FrozenPanes(width: 0, height: 40)
        #expect(rows.pieces(of: chart).map(\.pane) == [.scrolling, .rows])
    }

    @Test("An empty frame has no pieces")
    func emptyFrame() {
        #expect(panes.pieces(of: CGRect(x: 10, y: 10, width: 0, height: 30)).isEmpty)
        #expect(!panes.shows(CGRect(x: 10, y: 10, width: 30, height: 0), in: .corner))
    }

    @Test("Each pane moves only along the axes it scrolls in")
    func shifts() {
        let scroll = CGPoint(x: 120, y: 900)
        #expect(panes.shift(of: .scrolling, scroll: scroll) == scroll)
        #expect(panes.shift(of: .rows, scroll: scroll) == CGPoint(x: 120, y: 0))
        #expect(panes.shift(of: .columns, scroll: scroll) == CGPoint(x: 0, y: 900))
        #expect(panes.shift(of: .corner, scroll: scroll) == .zero)
    }

    @Test("A point in the window is found in the pane over it, where the sheet is scrolled")
    func hitTesting() {
        let scroll = CGPoint(x: 120, y: 900)
        // In the frozen rows, sideways scrolled.
        let rows = panes.sheetPoint(atViewport: CGPoint(x: 100, y: 10), scroll: scroll)
        #expect(rows.pane == .rows)
        #expect(rows.point == CGPoint(x: 220, y: 10))
        // In the corner, nothing scrolled.
        let corner = panes.sheetPoint(atViewport: CGPoint(x: 10, y: 10), scroll: scroll)
        #expect(corner.pane == .corner)
        #expect(corner.point == CGPoint(x: 10, y: 10))
        // In the frozen columns, scrolled down.
        let columns = panes.sheetPoint(atViewport: CGPoint(x: 10, y: 50), scroll: scroll)
        #expect(columns.pane == .columns)
        #expect(columns.point == CGPoint(x: 10, y: 950))
        // Past both lines, scrolled both ways.
        let rest = panes.sheetPoint(atViewport: CGPoint(x: 100, y: 50), scroll: scroll)
        #expect(rest.pane == .scrolling)
        #expect(rest.point == CGPoint(x: 220, y: 950))
    }

    @Test("A chart across the freeze line looks continuous: each part lands on screen where the pane shows it")
    func continuousOnScreen() {
        let chart = CGRect(x: 100, y: 20, width: 200, height: 150)
        // Unscrolled, the two parts meet at the freeze line, one above the other.
        let still = panes.pieces(of: chart).map { piece in
            piece.frame.offsetBy(dx: -panes.shift(of: piece.pane, scroll: .zero).x,
                                 dy: -panes.shift(of: piece.pane, scroll: .zero).y)
        }
        #expect(still.contains(CGRect(x: 100, y: 20, width: 200, height: 20)))
        #expect(still.contains(CGRect(x: 100, y: 40, width: 200, height: 130)))
        // Scrolled down by 50, the frozen part stays and the rest goes up,
        // under the frozen rows, where the pane's clip cuts it at the line.
        let scroll = CGPoint(x: 0, y: 50)
        let rows = panes.pieces(of: chart).first { $0.pane == .rows }!
        let rest = panes.pieces(of: chart).first { $0.pane == .scrolling }!
        let shownRows = rows.frame.offsetBy(dx: 0, dy: -panes.shift(of: .rows, scroll: scroll).y)
        let shownRest = rest.frame.offsetBy(dx: 0, dy: -panes.shift(of: .scrolling, scroll: scroll).y)
        #expect(shownRows == CGRect(x: 100, y: 20, width: 200, height: 20))
        #expect(shownRest.minY == -10)
        #expect(shownRest.maxY == 120)
        // What the scrolling pane shows of it starts at the freeze line.
        #expect(max(shownRest.minY, panes.height) == 40)
    }
}
