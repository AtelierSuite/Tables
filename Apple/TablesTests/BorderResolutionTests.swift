import Foundation
import Testing
@testable import TablesEngine

@Suite("Border resolution")
struct BorderResolutionTests {
    private let a1 = CellAddress(row: 0, column: 0)
    private let a2 = CellAddress(row: 1, column: 0)
    private let b1 = CellAddress(row: 0, column: 1)

    private func sheet(_ borders: [CellAddress: [BorderEdge: BorderSide]]) -> Worksheet {
        var sheet = Worksheet(name: "S")
        for (address, sides) in borders {
            sheet[address].style.borderSides = sides
        }
        return sheet
    }

    private func resolver(_ sheet: Worksheet) -> BorderResolver {
        BorderResolver(sheet: sheet, metrics: SheetMetrics(sheet: sheet))
    }

    private func edges(_ drawn: [DrawnBorder]) -> Set<BorderEdge> {
        Set(drawn.map(\.edge))
    }

    @Test("An edge both neighbours give a border is drawn once")
    func sharedEdgeDrawsOnce() {
        // "All Borders" on A1:A2 stores A1's bottom and A2's top.
        let thin = BorderSide(lineStyle: .thin)
        let resolver = resolver(sheet([a1: [.bottom: thin], a2: [.top: thin]]))
        let fromA1 = resolver.drawnBorders(of: CellRange(a1))
        let fromA2 = resolver.drawnBorders(of: CellRange(a2))
        #expect(fromA1.isEmpty != fromA2.isEmpty)
        #expect(fromA1.count + fromA2.count == 1)
    }

    @Test("The heavier of two borders on one edge wins, whichever side it is on")
    func heavierWins() {
        let thin = BorderSide(lineStyle: .thin, colorHex: "FF000000")
        let thick = BorderSide(lineStyle: .thick, colorHex: "FFFF0000")
        for (upper, lower) in [(thin, thick), (thick, thin)] {
            let resolver = resolver(sheet([a1: [.bottom: upper], a2: [.top: lower]]))
            #expect(resolver.resolvedSide(.bottom, of: a1) == thick)
            #expect(resolver.resolvedSide(.top, of: a2) == thick)
            let drawn = resolver.drawnBorders(of: CellRange(a1)) + resolver.drawnBorders(of: CellRange(a2))
            #expect(drawn.map(\.side) == [thick])
        }
        // A double rule outweighs a thin one, so no thin line runs through its gap.
        let double = BorderSide(lineStyle: .double)
        let resolver = resolver(sheet([a1: [.trailing: double], b1: [.leading: thin]]))
        #expect(resolver.resolvedSide(.leading, of: b1) == double)
        #expect(resolver.drawnBorders(of: CellRange(b1)).isEmpty)
    }

    @Test("Between two of the same weight, the later cell's wins")
    func laterWinsATie() {
        let black = BorderSide(lineStyle: .thin, colorHex: "FF000000")
        let red = BorderSide(lineStyle: .thin, colorHex: "FFFF0000")
        let resolver = resolver(sheet([a1: [.bottom: black, .trailing: black], a2: [.top: red], b1: [.leading: red]]))
        #expect(resolver.resolvedSide(.bottom, of: a1) == red)
        #expect(resolver.resolvedSide(.trailing, of: a1) == red)
        #expect(resolver.drawnBorders(of: CellRange(a1)).isEmpty)
        #expect(edges(resolver.drawnBorders(of: CellRange(a2))) == [.top])
        #expect(edges(resolver.drawnBorders(of: CellRange(b1))) == [.leading])
    }

    @Test("A border with nothing across from it is drawn by its own cell")
    func loneBorderIsOwn() {
        let thin = BorderSide(lineStyle: .thin)
        let resolver = resolver(sheet([a2: [.top: thin, .bottom: thin]]))
        #expect(edges(resolver.drawnBorders(of: CellRange(a2))) == [.top, .bottom])
        #expect(resolver.resolvedSide(.bottom, of: a1) == thin)
        #expect(resolver.drawnBorders(of: CellRange(a1)).isEmpty)
    }

    @Test("Across hidden rows, the next shown row is the neighbour")
    func hiddenRowsAreSkipped() {
        var sheet = sheet([a1: [.bottom: BorderSide(lineStyle: .thin)], CellAddress(row: 3, column: 0): [.top: BorderSide(lineStyle: .medium)]])
        sheet.hiddenRows = [1, 2]
        let resolver = resolver(sheet)
        #expect(resolver.drawnBorders(of: CellRange(a1)).isEmpty)
        #expect(resolver.resolvedSide(.bottom, of: a1)?.lineStyle == .medium)
    }

    @Test("A merge's edge is resolved against each neighbour along it")
    func mergeEdgeResolvesPerLine() {
        let thin = BorderSide(lineStyle: .thin)
        let thick = BorderSide(lineStyle: .thick)
        // A1:C1 merged with a thin bottom; B2 under it has a thick top.
        var sheet = sheet([a1: [.bottom: thin], CellAddress(row: 1, column: 1): [.top: thick]])
        let merge = CellRange(start: a1, end: CellAddress(row: 0, column: 2))
        sheet.mergedRanges = [merge]
        let resolver = resolver(sheet)
        let drawn = resolver.drawnBorders(of: merge)
        #expect(drawn == [
            DrawnBorder(edge: .bottom, side: thin, range: CellRange(a1)),
            DrawnBorder(edge: .bottom, side: thin, range: CellRange(CellAddress(row: 0, column: 2))),
        ])
        #expect(resolver.drawnBorders(of: CellRange(CellAddress(row: 1, column: 1))) == [
            DrawnBorder(edge: .top, side: thick, range: CellRange(CellAddress(row: 1, column: 1))),
        ])
        // The covered cells under the merge answer for it.
        #expect(resolver.resolvedSide(.bottom, of: CellAddress(row: 0, column: 2)) == thin)
    }

    @Test("One border running along a merge's edge is drawn as one line")
    func mergeEdgeRunsJoin() {
        let thin = BorderSide(lineStyle: .thin)
        var sheet = sheet([a1: [.bottom: thin]])
        let merge = CellRange(start: a1, end: CellAddress(row: 0, column: 2))
        sheet.mergedRanges = [merge]
        #expect(resolver(sheet).drawnBorders(of: merge) == [DrawnBorder(edge: .bottom, side: thin, range: merge)])
    }
}
