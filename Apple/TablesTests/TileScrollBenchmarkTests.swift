import Foundation
import SwiftUI
import Testing
@testable import Tables
@testable import TablesEngine

/// Scrolling must not rebuild what the tiles draw: what a tile holds is kept
/// until the sheet changes, merges and comments are found without a walk of
/// them all, and a frame at a new scroll offset only looks tiles up.
@Suite("Tile cache")
@MainActor
struct TileScrollBenchmarkTests {
    /// 200 rows by 50 columns, mostly filled, with long text that spills,
    /// a merge every few rows, comments and a frozen first row and column.
    static func benchmarkSheet() -> Worksheet {
        var sheet = Worksheet(name: "Benchmark")
        sheet.rowCount = 200
        sheet.columnCount = 50
        sheet.frozenRows = 1
        sheet.frozenColumns = 1
        for row in 0..<200 {
            for column in 0..<50 where (row + column) % 7 != 0 {
                var cell = Cell(value: column % 3 == 0 ? .text("Label \(row)-\(column)") : .number(Double(row * column)))
                if column % 9 == 0 { cell = Cell(value: .text("A long heading that runs on")) }
                if row % 11 == 0 { cell.style.fillColorHex = "FF203040" }
                sheet[CellAddress(row: row, column: column)] = cell
            }
        }
        for row in stride(from: 2, to: 200, by: 5) {
            for column in stride(from: 3, to: 48, by: 10) {
                _ = sheet.merge(CellRange(start: CellAddress(row: row, column: column),
                                          end: CellAddress(row: row + 1, column: column + 2)))
            }
        }
        for row in stride(from: 0, to: 200, by: 3) {
            for column in stride(from: 1, to: 50, by: 6) {
                sheet.comments[CellAddress(row: row, column: column)] = CellComment(
                    kind: row % 2 == 0 ? .note : .thread,
                    entries: [.init(author: "A", text: "Comment \(row) \(column)")])
            }
        }
        return sheet
    }

    /// The scroll offsets of a sweep down the sheet and then across it, a few
    /// points a frame, as a finger drags it.
    static func sweep(over metrics: SheetMetrics, viewport: CGSize, step: Double = 8) -> [CGPoint] {
        var offsets: [CGPoint] = []
        for y in stride(from: 0, through: max(0, metrics.totalHeight - viewport.height), by: step) {
            offsets.append(CGPoint(x: 0, y: y))
        }
        for x in stride(from: 0, through: max(0, metrics.totalWidth - viewport.width), by: step) {
            offsets.append(CGPoint(x: x, y: 0))
        }
        return offsets
    }

    /// The work one frame of the grid does: the tiles in the window, and the
    /// frozen row, column and corner panes over them.
    private static func frame(
        at offset: CGPoint, viewport: CGSize, metrics: SheetMetrics,
        tiles: (SheetGridView.TilePlan) -> TileContents
    ) -> Int {
        let rows = metrics.rows(in: offset.y...(offset.y + viewport.height))
        let columns = metrics.columns(in: offset.x...(offset.x + viewport.width))
        var drawn = 0
        for (paneRows, paneColumns) in [(rows, columns), (0..<1, columns), (rows, 0..<1), (0..<1, 0..<1)] {
            for plan in SheetGridView.tilePlans(rows: paneRows, columns: paneColumns, metrics: metrics) {
                drawn += tiles(plan).cells.count
            }
        }
        return drawn
    }

    @Test("A scroll sweep through the cache builds each tile once and is far quicker than rebuilding")
    func scrollSweep() {
        let sheet = Self.benchmarkSheet()
        let viewport = CGSize(width: 390, height: 844)
        for zoom in [1.0, 0.5] {
            let metrics = SheetMetrics(sheet: sheet, zoom: zoom)
            let offsets = Self.sweep(over: metrics, viewport: viewport)

            // As the grid does now, with a frame's panes sharing one sheet's tiles.
            let cache = TileCache()
            var builds = 0
            var cached: [Int] = []
            let cachedStart = Date()
            for offset in offsets {
                let drawing = cache.tiles(of: sheet, metrics: metrics)
                for _ in 0..<4 { _ = drawing.scheme(for: .dark) }
                cached.append(Self.frame(at: offset, viewport: viewport, metrics: metrics) { plan in
                    drawing.contents(of: plan.range) {
                        builds += 1
                        return SheetGridView.contents(of: plan, in: sheet, lookup: drawing.lookup, metrics: metrics)
                    }
                })
            }
            let cachedTime = Date().timeIntervalSince(cachedStart) / Double(offsets.count)

            // As the grid used to: every tile of every frame worked out again,
            // and the colour scheme sampled again for each pane. Timed over
            // every eighth frame, which is plenty to see the difference.
            var rebuilt: [Int] = []
            let sampled = stride(from: 0, to: offsets.count, by: 8).map { $0 }
            let rebuildStart = Date()
            for index in sampled {
                let lookup = SheetLookup(sheet)
                for _ in 0..<4 { _ = sheet.colorScheme(for: .dark) }
                rebuilt.append(Self.frame(at: offsets[index], viewport: viewport, metrics: metrics) { plan in
                    SheetGridView.contents(of: plan, in: sheet, lookup: lookup, metrics: metrics)
                })
            }
            let rebuildTime = Date().timeIntervalSince(rebuildStart) / Double(sampled.count)

            print(String(
                format: "Tile sweep at zoom %.1f, %d frames: rebuilt %.3f ms/frame, cached %.4f ms/frame, %d tiles built",
                zoom, offsets.count, rebuildTime * 1000, cachedTime * 1000, builds))

            #expect(sampled.map { cached[$0] } == rebuilt)
            let distinct = Set(offsets.flatMap { offset in
                let rows = metrics.rows(in: offset.y...(offset.y + viewport.height))
                let columns = metrics.columns(in: offset.x...(offset.x + viewport.width))
                return [(rows, columns), (0..<1, columns), (rows, 0..<1), (0..<1, 0..<1)].flatMap {
                    SheetGridView.tilePlans(rows: $0.0, columns: $0.1, metrics: metrics).map(\.range)
                }
            })
            #expect(builds == distinct.count)
            #expect(cachedTime < rebuildTime)
        }
    }

    // MARK: - Lookups

    @Test("The merge index finds the same merges a walk of them does")
    func mergeIndexMatchesWalk() {
        var sheet = Self.benchmarkSheet()
        // A merge spanning several blocks of the index.
        _ = sheet.merge(CellRange(start: CellAddress(row: 60, column: 0), end: CellAddress(row: 199, column: 1)))
        let index = MergeIndex(sheet.mergedRanges)
        for row in 0..<sheet.rowCount {
            for column in 0..<sheet.columnCount {
                let address = CellAddress(row: row, column: column)
                #expect(index.range(containing: address) == sheet.mergedRange(containing: address)?.normalized)
            }
        }
        for area in [
            CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 13, column: 5)),
            CellRange(start: CellAddress(row: 150, column: 40), end: CellAddress(row: 63, column: 2)),
            CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 199, column: 49)),
            CellRange(start: CellAddress(row: 190, column: 0), end: CellAddress(row: 199, column: 0)),
        ] {
            let walked = sheet.mergedRanges.map(\.normalized).filter { $0.intersects(area) }
            #expect(index.ranges(intersecting: area) == walked)
        }
    }

    @Test("Text overflow and comment marks come out the same through a lookup")
    func lookupMatchesSheet() {
        var sheet = Self.benchmarkSheet()
        sheet.hiddenRows = [9]
        sheet.hiddenColumns = [7]
        // A comment on a merge's first cell, and one on a cell it covers.
        sheet.comments[CellAddress(row: 2, column: 3)] = CellComment(kind: .note, entries: [.init(author: "A", text: "x")])
        sheet.comments[CellAddress(row: 3, column: 4)] = CellComment(kind: .note, entries: [.init(author: "A", text: "y")])
        let lookup = SheetLookup(sheet)
        for row in 0..<sheet.rowCount {
            for column in 0..<sheet.columnCount {
                let address = CellAddress(row: row, column: column)
                #expect(sheet.overflowSpan(of: address, lookup: lookup) == sheet.overflowSpan(of: address))
            }
        }
        func marks(_ found: [(address: CellAddress, comment: CellComment, range: CellRange)]) -> Set<String> {
            Set(found.map { "\($0.address.a1) \($0.range.a1) \($0.comment.entries.first?.text ?? "")" })
        }
        for (rows, columns) in [(0..<14, 0..<6), (0..<200, 0..<50), (2..<3, 4..<5), (190..<200, 44..<50)] {
            #expect(marks(sheet.commentMarks(rows: rows, columns: columns, lookup: lookup))
                == marks(sheet.commentMarks(rows: rows, columns: columns)))
        }
        #expect(lookup.colorScheme(for: .dark) == sheet.colorScheme(for: .dark))
        #expect(lookup.colorScheme(for: .light) == sheet.colorScheme(for: .light))
    }

    // MARK: - Keeping tiles in step with the sheet

    @Test("Tiles are kept while nothing changes, and built again after any change they show")
    func invalidation() {
        let cache = TileCache()
        let sheet = Self.benchmarkSheet()
        let metrics = SheetMetrics(sheet: sheet, zoom: 1)
        let kept = cache.tiles(of: sheet, metrics: metrics)
        // A copy of the same sheet, as every frame reads it out of the workbook.
        let copy = sheet
        #expect(cache.tiles(of: copy, metrics: metrics) === kept)
        // Scrolling, selecting, moving a chart: none of them change what is drawn.
        var unrelated = sheet
        unrelated.charts = []
        unrelated.frozenRows = 3
        #expect(cache.tiles(of: unrelated, metrics: metrics) === kept)

        let a1 = CellAddress(row: 0, column: 0)
        let edits: [(String, (inout Worksheet) -> Void)] = [
            ("value", { $0[a1] = Cell(value: .text("Edited")) }),
            ("style", { $0[a1].style.isBold.toggle() }),
            ("conditional style", { $0.conditionalStyles[a1] = ConditionalStyle(fillColorHex: "FFFF0000") }),
            ("merge", { _ = $0.merge(CellRange(start: CellAddress(row: 40, column: 0), end: CellAddress(row: 41, column: 1))) }),
            ("unmerge", { $0.unmerge(CellRange(start: CellAddress(row: 2, column: 3), end: CellAddress(row: 2, column: 3))) }),
            ("comment", { $0.comments[a1] = CellComment(kind: .note, entries: [.init(author: "A", text: "New")]) }),
            ("hidden row", { $0.hiddenRows.insert(4) }),
            ("hidden column", { $0.hiddenColumns.insert(4) }),
            ("column count", { $0.columnCount += 1 }),
            ("page colour", { $0.backgroundColorHex = "FF101010" }),
        ]
        for (name, edit) in edits {
            var edited = sheet
            edit(&edited)
            let rebuilt = cache.tiles(of: edited, metrics: metrics)
            #expect(rebuilt !== kept, "\(name)")
            // Back to the sheet as it was, as an undo leaves it.
            #expect(cache.tiles(of: sheet, metrics: metrics) !== rebuilt, "undoing \(name)")
        }

        // Resizing a line or zooming changes the metrics, and with them the tiles.
        var resized = sheet
        resized.rowHeights[3] = 60
        #expect(cache.tiles(of: sheet, metrics: SheetMetrics(sheet: resized, zoom: 1)) !== cache.tiles(of: sheet, metrics: metrics))
        let current = cache.tiles(of: sheet, metrics: metrics)
        #expect(cache.tiles(of: sheet, metrics: SheetMetrics(sheet: sheet, zoom: 1.5)) !== current)
    }

    @Test("An edit shows in the tile it falls in")
    func editReachesTile() throws {
        let cache = TileCache()
        var sheet = Self.benchmarkSheet()
        let metrics = SheetMetrics(sheet: sheet, zoom: 1)
        let plan = try #require(SheetGridView.tilePlans(rows: 0..<1, columns: 0..<1, metrics: metrics).first)
        func cell(_ address: CellAddress) -> Cell? {
            let drawing = cache.tiles(of: sheet, metrics: metrics)
            let contents = drawing.contents(of: plan.range) {
                SheetGridView.contents(of: plan, in: sheet, lookup: drawing.lookup, metrics: metrics)
            }
            return contents.cells.first { $0.address == address }?.cell
        }
        let b2 = CellAddress(row: 1, column: 1)
        #expect(cell(b2)?.value == .number(1))
        sheet[b2] = Cell(value: .text("Changed"))
        #expect(cell(b2)?.value == .text("Changed"))
        sheet[b2] = Cell()
        #expect(cell(b2) == nil)
    }
}
