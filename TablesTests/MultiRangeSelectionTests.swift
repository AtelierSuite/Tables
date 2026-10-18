import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Covers a selection made of several ranges: what edits reach, and what puts
/// the extra ranges away again.
@MainActor
@Suite("Multi-range selection")
struct MultiRangeSelectionTests {

    private func workbook() -> Workbook {
        var sheet = Worksheet(name: "Sheet1")
        sheet.rowCount = 40
        sheet.columnCount = 12
        for row in 0..<8 {
            for column in 0..<6 {
                sheet[CellAddress(row: row, column: column)] = Cell(value: .number(Double(row * 10 + column)))
            }
        }
        return Workbook(sheets: [sheet])
    }

    private func editor(for workbook: Workbook) -> EditorState {
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        return state
    }

    private func range(_ from: (Int, Int), _ to: (Int, Int)) -> CellRange {
        CellRange(
            start: CellAddress(row: from.0, column: from.1),
            end: CellAddress(row: to.0, column: to.1)
        )
    }

    // MARK: - Building a selection

    @Test("Each held range stays selected, and the newest one is the active one")
    func rangesAccumulate() {
        let book = workbook()
        let state = editor(for: book)
        let sheet = book.sheets[0]

        state.select(CellAddress(row: 0, column: 0), in: sheet)
        state.select(CellAddress(row: 1, column: 1), extending: true, in: sheet)
        state.addRange(startingAt: CellAddress(row: 4, column: 4), in: sheet)
        state.select(CellAddress(row: 5, column: 5), extending: true, in: sheet)
        state.addRange(startingAt: CellAddress(row: 7, column: 0), in: sheet)

        #expect(state.selectedRanges.count == 3)
        #expect(state.hasMultipleSelections)
        #expect(state.selection == CellRange(CellAddress(row: 7, column: 0)))
        #expect(state.selectedAddress == CellAddress(row: 7, column: 0))
        #expect(state.isSelected(CellAddress(row: 1, column: 0)))
        #expect(state.isSelected(CellAddress(row: 5, column: 4)))
        #expect(!state.isSelected(CellAddress(row: 3, column: 3)))
    }

    @Test("An ordinary tap puts the extra ranges away")
    func plainSelectionResets() {
        let book = workbook()
        let state = editor(for: book)
        let sheet = book.sheets[0]

        state.addRange(startingAt: CellAddress(row: 4, column: 4), in: sheet)
        #expect(state.hasMultipleSelections)

        state.select(CellAddress(row: 2, column: 2), in: sheet)
        #expect(!state.hasMultipleSelections)
        #expect(state.selectedRanges == [CellRange(CellAddress(row: 2, column: 2))])
    }

    @Test("Repeating a range that is already held does not hold it twice")
    func identicalRangesCollapse() {
        let book = workbook()
        let state = editor(for: book)
        let sheet = book.sheets[0]

        state.select(CellAddress(row: 3, column: 3), in: sheet)
        state.addRange(startingAt: CellAddress(row: 3, column: 3), in: sheet)
        state.addRange(startingAt: CellAddress(row: 3, column: 3), in: sheet)

        #expect(state.selectedRanges.count == 2)
    }

    // MARK: - What edits reach

    @Test("Styling reaches every range and no cell outside them")
    func stylingSpansEveryRange() {
        var book = workbook()
        let state = editor(for: book)
        let sheet = book.sheets[0]

        state.select(CellAddress(row: 0, column: 0), in: sheet)
        state.select(CellAddress(row: 1, column: 1), extending: true, in: sheet)
        state.addRange(startingAt: CellAddress(row: 4, column: 4), in: sheet)
        state.select(CellAddress(row: 5, column: 5), extending: true, in: sheet)

        state.applyStyle(in: &book) { $0.isBold = true }

        for range in [self.range((0, 0), (1, 1)), self.range((4, 4), (5, 5))] {
            for address in range.addresses {
                #expect(book.sheets[0][address].style.isBold, "\(address.a1) should be bold")
            }
        }
        #expect(!book.sheets[0][CellAddress(row: 3, column: 3)].style.isBold)
    }

    @Test("A cell in two overlapping ranges is edited once")
    func overlapsAreEditedOnce() {
        var book = workbook()
        let state = editor(for: book)
        let sheet = book.sheets[0]

        state.select(CellAddress(row: 0, column: 0), in: sheet)
        state.select(CellAddress(row: 2, column: 2), extending: true, in: sheet)
        state.addRange(startingAt: CellAddress(row: 1, column: 1), in: sheet)
        state.select(CellAddress(row: 3, column: 3), extending: true, in: sheet)

        let start = book.sheets[0][CellAddress(row: 1, column: 1)].style.fontSize
        // Reads the cell it writes, so a second visit would show up as a
        // second step.
        state.applyStyle(in: &book) { $0.fontSize -= 1 }

        #expect(book.sheets[0][CellAddress(row: 1, column: 1)].style.fontSize == start - 1)
        #expect(book.sheets[0][CellAddress(row: 0, column: 0)].style.fontSize == start - 1)
        #expect(book.sheets[0][CellAddress(row: 3, column: 3)].style.fontSize == start - 1)
    }

    @Test("Clearing contents empties every range")
    func clearingSpansEveryRange() {
        var book = workbook()
        let state = editor(for: book)
        let sheet = book.sheets[0]

        state.select(CellAddress(row: 0, column: 0), in: sheet)
        state.addRange(startingAt: CellAddress(row: 5, column: 5), in: sheet)

        state.clearContents(in: &book)

        #expect(book.sheets[0][CellAddress(row: 0, column: 0)].value == .empty)
        #expect(book.sheets[0][CellAddress(row: 5, column: 5)].value == .empty)
        #expect(book.sheets[0][CellAddress(row: 2, column: 2)].value != .empty)
    }

    // MARK: - Structure

    @Test("Removing rows keeps the extra ranges inside the sheet")
    func clampingKeepsEveryRange() {
        var book = workbook()
        let state = editor(for: book)
        let sheet = book.sheets[0]

        state.select(CellAddress(row: 1, column: 1), in: sheet)
        state.addRange(startingAt: CellAddress(row: 39, column: 0), in: sheet)

        book.sheets[0].removeRows(20...39)
        state.clampSelection(to: book.sheets[0])

        let bounds = CellRange(
            start: CellAddress(row: 0, column: 0),
            end: CellAddress(row: book.sheets[0].rowCount - 1, column: book.sheets[0].columnCount - 1)
        )
        #expect(state.selectedRanges.allSatisfy { bounds.contains($0.start) && bounds.contains($0.end) })
    }
}
