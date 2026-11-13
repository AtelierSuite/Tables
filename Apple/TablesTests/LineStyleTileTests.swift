import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// What the iOS grid's tiles paint for cells whose style comes from their
/// row or column, and that the tile cache lets go of them when it moves.
@Suite("Column and row styles in tiles")
@MainActor
struct LineStyleTileTests {
    private func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    /// Column B filled yellow with a bottom border, row 3 filled blue.
    private func sheet() -> Worksheet {
        var sheet = Worksheet(name: "S")
        var column = CellStyle.default
        column.fillColorHex = "FFFFE699"
        column.borderSides[.bottom] = BorderSide(lineStyle: .thin, colorHex: "FF000000")
        sheet.columnStyles[1] = column
        var row = CellStyle.default
        row.fillColorHex = "FF9BC2E6"
        sheet.rowStyles[2] = row
        return sheet
    }

    private let plan = SheetGridView.TilePlan(id: 0, rows: 0..<10, columns: 0..<5)

    private func contents(of sheet: Worksheet) -> TileContents {
        SheetGridView.contents(
            of: plan, in: sheet, lookup: SheetLookup(sheet), metrics: SheetMetrics(sheet: sheet, zoom: 1))
    }

    @Test("Empty cells in a formatted column or row are painted with its fill")
    func paintsInheritedFills() {
        let painted = Dictionary(uniqueKeysWithValues: contents(of: sheet()).cells.map { ($0.address, $0.cell) })
        #expect(painted[address("B6")]?.style.fillColorHex == "FFFFE699")
        #expect(painted[address("D3")]?.style.fillColorHex == "FF9BC2E6")
        #expect(painted[address("B3")]?.style.fillColorHex == "FF9BC2E6")
        #expect(painted[address("A6")] == nil)
    }

    @Test("A column's borders are drawn on its cells without a record")
    func drawsInheritedBorders() {
        let metrics = SheetMetrics(sheet: sheet(), zoom: 1)
        let frames = contents(of: sheet()).borders.map(\.frame)
        #expect(frames.contains(metrics.frame(for: address("B6"))))
        #expect(!frames.contains(metrics.frame(for: address("A6"))))
    }

    @Test("Inserting a column draws the column's style where it moved to")
    func cacheFollowsInsertedColumn() {
        var sheet = sheet()
        let cache = TileCache()
        let metrics = SheetMetrics(sheet: sheet, zoom: 1)
        let before = cache.tiles(of: sheet, metrics: metrics).contents(of: plan.range) { contents(of: sheet) }
        #expect(before.cells.contains { $0.address == address("B6") })

        sheet.insertColumns(1, at: 0)
        let moved = SheetMetrics(sheet: sheet, zoom: 1)
        let tiles = cache.tiles(of: sheet, metrics: moved)
        var rebuilt = false
        let after = tiles.contents(of: plan.range) {
            rebuilt = true
            return SheetGridView.contents(of: plan, in: sheet, lookup: tiles.lookup, metrics: moved)
        }
        #expect(rebuilt)
        #expect(!after.cells.contains { $0.address == address("B6") })
        #expect(after.cells.first { $0.address == address("C6") }?.cell.style.fillColorHex == "FFFFE699")
    }

    @Test("Changing only a column's style lets go of the kept tiles")
    func cacheFollowsStyleChange() {
        var sheet = sheet()
        let cache = TileCache()
        let metrics = SheetMetrics(sheet: sheet, zoom: 1)
        _ = cache.tiles(of: sheet, metrics: metrics).contents(of: plan.range) { contents(of: sheet) }

        sheet.columnStyles[1]?.fillColorHex = "FFFF0000"
        let tiles = cache.tiles(of: sheet, metrics: metrics)
        var rebuilt = false
        let after = tiles.contents(of: plan.range) {
            rebuilt = true
            return SheetGridView.contents(of: plan, in: sheet, lookup: tiles.lookup, metrics: metrics)
        }
        #expect(rebuilt)
        #expect(after.cells.first { $0.address == address("B6") }?.cell.style.fillColorHex == "FFFF0000")
    }
}
