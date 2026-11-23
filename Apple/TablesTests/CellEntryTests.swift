import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

@MainActor
@Suite("Cell entry")
struct CellEntryTests {

    private func address(_ text: String) -> CellAddress { CellAddress(a1: text)! }

    private func commitUnchanged(_ cell: Cell) -> Cell {
        var workbook = Workbook()
        workbook.sheets[0][address("B2")] = cell
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        state.beginEditing(address("B2"), in: workbook)
        state.commitEditing(in: &workbook)
        return workbook.sheets[0][address("B2")]
    }

    @Test("Text that reads as a number opens with an apostrophe and stays text")
    func numericTextStaysText() {
        for text in ["00123", "TRUE", "50%", "1,000", "=A1", "#N/A", "'quoted"] {
            let cell = Cell(value: .text(text))
            #expect(cell.entryText == "'" + text)
            #expect(commitUnchanged(cell).value == cell.value)
            let retyped = CellInputParser.cell(from: "'" + text, replacing: Cell())
            #expect(retyped.value == .text(text))
            #expect(retyped.style.hasQuotePrefix)
            #expect(retyped.style.numberFormat == CellStyle.default.numberFormat)
        }
        #expect(Cell(value: .text("plain")).entryText == "plain")
    }

    @Test("Typing over a quote-prefixed cell keeps it text only when asked")
    func quotePrefixFollowsInput() {
        var style = CellStyle()
        style.hasQuotePrefix = true
        let cell = Cell(value: .text("007"), style: style)
        #expect(cell.entryText == "'007")
        #expect(CellInputParser.cell(from: "'008", replacing: cell).value == .text("008"))
        let number = CellInputParser.cell(from: "8", replacing: cell)
        #expect(number.value == .number(8))
        #expect(!number.style.hasQuotePrefix)
    }
}
