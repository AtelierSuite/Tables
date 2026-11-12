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
        var sheet = sheet([
            a1: [.bottom: thin], b1: [.bottom: thin], CellAddress(row: 0, column: 2): [.bottom: thin],
            CellAddress(row: 1, column: 1): [.top: thick],
        ])
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
        var sheet = sheet([a1: [.bottom: thin], b1: [.bottom: thin], CellAddress(row: 0, column: 2): [.bottom: thin]])
        let merge = CellRange(start: a1, end: CellAddress(row: 0, column: 2))
        sheet.mergedRanges = [merge]
        #expect(resolver(sheet).drawnBorders(of: merge) == [DrawnBorder(edge: .bottom, side: thin, range: merge)])
    }

    /// A1:C3, as Excel stores an outline around it: each side on the cells along it.
    private let a1c3 = CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 2, column: 2))

    private func outlined(_ range: CellRange, with side: BorderSide) -> [CellAddress: [BorderEdge: BorderSide]] {
        var borders: [CellAddress: [BorderEdge: BorderSide]] = [:]
        range.forEachAddress { address in
            if address.row == range.start.row { borders[address, default: [:]][.top] = side }
            if address.row == range.end.row { borders[address, default: [:]][.bottom] = side }
            if address.column == range.start.column { borders[address, default: [:]][.leading] = side }
            if address.column == range.end.column { borders[address, default: [:]][.trailing] = side }
        }
        return borders
    }

    @Test("A merge's outline comes from the cells along each of its edges")
    func mergeOutlineFromEdgeCells() {
        let medium = BorderSide(lineStyle: .medium)
        var sheet = sheet(outlined(a1c3, with: medium))
        sheet.mergedRanges = [a1c3]
        let resolver = resolver(sheet)
        #expect(Set(resolver.drawnBorders(of: a1c3)) == [
            DrawnBorder(edge: .top, side: medium, range: a1c3),
            DrawnBorder(edge: .leading, side: medium, range: a1c3),
            DrawnBorder(edge: .bottom, side: medium, range: a1c3),
            DrawnBorder(edge: .trailing, side: medium, range: a1c3),
        ])
        #expect(resolver.resolvedSide(.trailing, of: CellAddress(row: 1, column: 1)) == medium)
        #expect(resolver.resolvedSide(.bottom, of: a1) == medium)
    }

    @Test("A merge's bottom edge can change border along its length")
    func mergeBottomVariesAlongItsLength() {
        let thin = BorderSide(lineStyle: .thin)
        let thick = BorderSide(lineStyle: .thick, colorHex: "FFFF0000")
        let a3 = CellAddress(row: 2, column: 0), b3 = CellAddress(row: 2, column: 1)
        // C3 has no bottom border.
        var sheet = sheet([a3: [.bottom: thin], b3: [.bottom: thick]])
        sheet.mergedRanges = [a1c3]
        let column = { (column: Int) in
            CellRange(start: CellAddress(row: 0, column: column), end: CellAddress(row: 2, column: column))
        }
        #expect(resolver(sheet).drawnBorders(of: a1c3) == [
            DrawnBorder(edge: .bottom, side: thin, range: column(0)),
            DrawnBorder(edge: .bottom, side: thick, range: column(1)),
        ])
    }

    @Test("The first cell's own box reaches only the part of the merge's edges it lies on")
    func firstCellBordersStayOnItsPart() {
        // As Excel draws it: the first cell's bottom and trailing sides are
        // inside the merge, and its top and leading cover one column and row.
        let thin = BorderSide(lineStyle: .thin)
        var sheet = sheet([a1: [.top: thin, .leading: thin, .bottom: thin, .trailing: thin]])
        sheet.mergedRanges = [a1c3]
        #expect(Set(resolver(sheet).drawnBorders(of: a1c3)) == [
            DrawnBorder(edge: .top, side: thin, range: CellRange(start: a1, end: CellAddress(row: 2, column: 0))),
            DrawnBorder(edge: .leading, side: thin, range: CellRange(start: a1, end: CellAddress(row: 0, column: 2))),
        ])
    }
}
