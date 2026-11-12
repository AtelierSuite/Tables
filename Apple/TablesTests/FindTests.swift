import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

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

    // MARK: - Options

    @Test func wholeCellLeavesOutCellsThatOnlyContainTheText() {
        let options = FindOptions(matchesWholeCell: true)
        #expect(workbook().matches(for: "apples", options: options).map(\.text) == ["Apples"])
    }

    @Test func lookInFormulasOrValues() {
        let book = workbook()
        #expect(book.matches(for: "42", options: FindOptions(lookIn: .formulas)).isEmpty)
        #expect(book.matches(for: "42", options: FindOptions(lookIn: .values)).map(\.text) == ["42"])
        #expect(book.matches(for: "SUM", options: FindOptions(lookIn: .values)).isEmpty)
        #expect(book.matches(for: "SUM", options: FindOptions(lookIn: .formulas)).map(\.text) == ["=SUM(B1:B4)"])
    }

    // MARK: - Replace

    @Test func replaceAllChangesEverySheetInOneGo() {
        var book = workbook()
        let result = book.replaceAll("apple", with: "pear")
        #expect(result.replaced.count == 3)
        #expect(result.skipped.isEmpty)
        #expect(book.sheets[0][CellAddress(row: 2, column: 0)].value == .text("pears"))
        #expect(book.sheets[0][CellAddress(row: 0, column: 1)].value == .text("pear pie"))
        #expect(book.sheets[1][CellAddress(row: 0, column: 0)].value == .text("Pinepear"))
    }

    @Test func replaceMatchingCaseLeavesOtherCasingsAlone() {
        var book = workbook()
        let result = book.replaceAll("Apple", with: "Pear", options: FindOptions(matchesCase: true))
        #expect(result.replaced.count == 1)
        #expect(book.sheets[0][CellAddress(row: 2, column: 0)].value == .text("Pears"))
        #expect(book.sheets[0][CellAddress(row: 0, column: 1)].value == .text("apple pie"))
        #expect(book.sheets[1][CellAddress(row: 0, column: 0)].value == .text("Pineapple"))
    }

    @Test func replaceWholeCellReplacesTheWholeText() {
        var book = workbook()
        book.replaceAll("apple pie", with: "Tart", options: FindOptions(matchesWholeCell: true))
        #expect(book.sheets[0][CellAddress(row: 0, column: 1)].value == .text("Tart"))
        #expect(book.sheets[0][CellAddress(row: 2, column: 0)].value == .text("Apples"))
    }

    @Test func replaceOneMatchLeavesTheRest() {
        var book = workbook()
        let matches = book.matches(for: "apple")
        let result = book.replace([matches[0]], query: "apple", with: "pear")
        #expect(result.replaced == [matches[0]])
        #expect(book.sheets[0][CellAddress(row: 0, column: 1)].value == .text("pear pie"))
        #expect(book.sheets[0][CellAddress(row: 2, column: 0)].value == .text("Apples"))
    }

    @Test func replaceLeavesACellThatNoLongerMatches() {
        var book = workbook()
        let matches = book.matches(for: "apple")
        book.sheets[0][CellAddress(row: 0, column: 1)] = Cell(value: .text("cherry"))
        let result = book.replace(matches, query: "apple", with: "pear")
        #expect(result.replaced.count == 2)
        #expect(book.sheets[0][CellAddress(row: 0, column: 1)].value == .text("cherry"))
    }

    @Test func replaceInFormulaRecalculates() {
        var book = workbook()
        book.sheets[0][CellAddress(row: 0, column: 2)] = Cell(value: .number(5))
        book.recalculate()
        let result = book.replaceAll("B1:B4", with: "C1", options: FindOptions(lookIn: .formulas))
        #expect(result.replaced.count == 1)
        let cell = book.sheets[0][CellAddress(row: 1, column: 0)]
        #expect(cell.formula == "SUM(C1)")
        #expect(cell.value == .number(5))
    }

    @Test func replaceThatBreaksAFormulaSkipsTheCell() {
        var book = workbook()
        let result = book.replaceAll("(", with: "", options: FindOptions(lookIn: .formulas))
        #expect(result.replaced.isEmpty)
        #expect(result.skippedCount(.invalidFormula) == 1)
        #expect(book.sheets[0][CellAddress(row: 1, column: 0)].formula == "SUM(B1:B4)")
    }

    @Test func replaceCannotTurnAFormulaIntoAValue() {
        var book = workbook()
        let result = book.replaceAll("=", with: "", options: FindOptions(lookIn: .formulas))
        #expect(result.skippedCount(.invalidFormula) == 1)
        #expect(book.sheets[0][CellAddress(row: 1, column: 0)].formula == "SUM(B1:B4)")
    }

    @Test func replaceSkipsWhatAFormulaShows() {
        var book = workbook()
        let result = book.replaceAll("42", with: "7", options: FindOptions(lookIn: .values))
        #expect(result.replaced.isEmpty)
        #expect(result.skippedCount(.formulaResult) == 1)
        #expect(book.sheets[0][CellAddress(row: 1, column: 0)].formula == "SUM(B1:B4)")
    }

    @Test func replaceInShownNumberKeepsANumber() {
        var book = Workbook(sheets: [Worksheet(name: "Prices")])
        var style = CellStyle.default
        style.numberFormat = NumberFormatPreset.percent.code
        book.sheets[0][CellAddress(row: 0, column: 0)] = Cell(value: .number(0.5), style: style)
        book.sheets[0][CellAddress(row: 1, column: 0)] = Cell(value: .number(0.25), style: style)
        let values = FindOptions(lookIn: .values)
        #expect(book.replaceAll("50", with: "75", options: values).replaced.count == 1)
        #expect(book.sheets[0][CellAddress(row: 0, column: 0)].value == .number(0.75))
        #expect(book.sheets[0][CellAddress(row: 0, column: 0)].style.numberFormat == style.numberFormat)
        let result = book.replaceAll("25", with: "x", options: values)
        #expect(result.skippedCount(.notANumber) == 1)
        #expect(book.sheets[0][CellAddress(row: 1, column: 0)].value == .number(0.25))
    }

    @Test func replaceWithNothingFoundChangesNothing() {
        var book = workbook()
        let before = book
        let result = book.replaceAll("zebra", with: "x")
        #expect(result.replaced.isEmpty && result.skipped.isEmpty)
        #expect(book == before)
    }
}
