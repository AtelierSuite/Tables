import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Covers finding cells by what they show and by their formulas.
@Suite("Find")
struct FindTests {

    private func workbook() -> Workbook {
        var first = Worksheet(name: "Sales")
        first[CellAddress(row: 2, column: 0)] = Cell(value: .text("Apples"))
        first[CellAddress(row: 0, column: 1)] = Cell(value: .text("apple pie"))
        first[CellAddress(row: 1, column: 0)] = Cell(value: .number(42), formula: "SUM(B1:B4)")
        var second = Worksheet(name: "Notes")
        second[CellAddress(row: 0, column: 0)] = Cell(value: .text("Pineapple"))
        return Workbook(sheets: [first, second])
    }

    @Test func findsAcrossSheetsInTabAndRowOrder() {
        let book = workbook()
        let matches = book.matches(for: "apple")
        #expect(matches.map(\.address.a1) == ["B1", "A3", "A1"])
        #expect(matches.map(\.sheetID) == [book.sheets[0].id, book.sheets[0].id, book.sheets[1].id])
    }

    @Test func matchCaseLeavesOutOtherCasings() {
        let matches = workbook().matches(for: "Apple", matchesCase: true)
        #expect(matches.map(\.text) == ["Apples"])
    }

    @Test func findsFormulasAndShownValues() {
        let book = workbook()
        #expect(book.matches(for: "sum").map(\.text) == ["=SUM(B1:B4)"])
        #expect(book.matches(for: "42").map(\.text) == ["42"])
    }

    @Test func emptyQueryFindsNothing() {
        #expect(workbook().matches(for: "").isEmpty)
    }
}
