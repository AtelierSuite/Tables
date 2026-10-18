import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Covers dragging a selection's fill handle and dragging the selection
/// itself: what series carry on, and how formulas follow the cells they read.
@MainActor
@Suite("Fill and move")
struct AutoFillTests {

    private func address(_ text: String) -> CellAddress {
        CellAddress(a1: text)!
    }

    private func range(_ text: String) -> CellRange {
        let parts = text.split(separator: ":").map { address(String($0)) }
        return CellRange(start: parts[0], end: parts.count > 1 ? parts[1] : parts[0])
    }

    private func sheet(_ values: [String: CellValue], formulas: [String: String] = [:]) -> Worksheet {
        var sheet = Worksheet(name: "Sheet1")
        sheet.rowCount = 30
        sheet.columnCount = 10
        for (key, value) in values { sheet[address(key)] = Cell(value: value) }
        for (key, formula) in formulas { sheet[address(key)] = Cell(formula: formula) }
        return sheet
    }

    // MARK: - The handle's reach

    @Test("The fill grows along whichever axis the pointer is further out on")
    func targetFollowsTheLongerAxis() {
        let source = range("B2:C3")
        #expect(AutoFill.target(extending: source, toward: address("C8")) == range("B2:C8"))
        #expect(AutoFill.target(extending: source, toward: address("F4")) == range("B2:F3"))
        #expect(AutoFill.target(extending: source, toward: address("B1")) == range("B1:C3"))
        #expect(AutoFill.target(extending: source, toward: address("A2")) == range("A2:C3"))
        #expect(AutoFill.target(extending: source, toward: address("C3")) == range("B2:C3"))
    }

    // MARK: - Series

    @Test("Two numbers carry on their step, one number repeats")
    func numbers() {
        var sheet = sheet(["A1": .number(1), "A2": .number(3), "B1": .number(7)])
        sheet.autoFill(from: range("A1:B2"), to: range("A1:B5"))
        #expect(sheet[address("A5")].value == .number(9))
        #expect(sheet[address("B3")].value == .number(7))
        #expect(sheet[address("B4")].value == .empty)
        #expect(sheet[address("B5")].value == .number(7))
    }

    @Test("A trend that isn't even continues its best-fitting line")
    func trend() {
        var sheet = sheet(["A1": .number(1), "A2": .number(2), "A3": .number(4)])
        sheet.autoFill(from: range("A1:A3"), to: range("A1:A4"))
        guard case .number(let next) = sheet[address("A4")].value else { Issue.record("not a number"); return }
        #expect(abs(next - 16.0 / 3.0) < 1e-9)
    }

    @Test("Decimal steps carry on without floating-point noise")
    func decimals() {
        var sheet = sheet(["A1": .number(0.1), "A2": .number(0.2)])
        sheet.autoFill(from: range("A1:A2"), to: range("A1:A3"))
        #expect(sheet[address("A3")].value == .number(0.3))
    }

    @Test("Filling backwards counts down")
    func backwards() {
        var sheet = sheet(["A5": .number(10), "A6": .number(20)])
        sheet.autoFill(from: range("A5:A6"), to: range("A3:A6"))
        #expect(sheet[address("A4")].value == .number(0))
        #expect(sheet[address("A3")].value == .number(-10))
    }

    @Test("A lone date steps a day at a time")
    func dates() {
        var sheet = sheet([:])
        var cell = Cell(value: .number(45_000))
        cell.style.numberFormat = "yyyy-mm-dd"
        sheet[address("A1")] = cell
        sheet.autoFill(from: range("A1"), to: range("A1:A3"))
        #expect(sheet[address("A3")].value == .number(45_002))
        #expect(sheet[address("A3")].style.numberFormat == "yyyy-mm-dd")
    }

    @Test("Day and month names count on, wrapping and keeping their case")
    func namedLists() {
        var sheet = self.sheet(["A1": .text("Friday"), "B1": .text("NOV")])
        sheet.autoFill(from: range("A1:B1"), to: range("A1:B4"))
        #expect(sheet[address("A3")].value == .text("Sunday"))
        #expect(sheet[address("B3")].value == .text("JAN"))
        sheet = self.sheet(["A1": .text("Mon"), "A2": .text("Wed")])
        sheet.autoFill(from: range("A1:A2"), to: range("A1:A4"))
        #expect(sheet[address("A4")].value == .text("Sun"))
    }

    @Test("Text ending in a number counts on, keeping its padding")
    func numberedText() {
        var sheet = sheet(["A1": .text("Week 1"), "B1": .text("ID-007"), "C1": .text("Total")])
        sheet.autoFill(from: range("A1:C1"), to: range("A1:C3"))
        #expect(sheet[address("A3")].value == .text("Week 3"))
        #expect(sheet[address("B2")].value == .text("ID-008"))
        #expect(sheet[address("C3")].value == .text("Total"))
    }

    @Test("Formulas repeat with their relative references moved")
    func formulas() {
        var sheet = sheet(["A1": .number(1), "A2": .number(2), "A3": .number(3)], formulas: ["B1": "A1*$A$1"])
        sheet.autoFill(from: range("B1"), to: range("B1:B3"))
        #expect(sheet[address("B3")].formula == "A3*$A$1")
    }

    @Test("Dragging the handle back inside the selection clears what it left")
    func shrinking() {
        var sheet = sheet(["A1": .number(1), "A2": .number(2), "A3": .number(3)])
        sheet.autoFill(from: range("A1:A3"), to: range("A1:A1"))
        #expect(sheet[address("A1")].value == .number(1))
        #expect(sheet[address("A2")].value == .empty)
        #expect(sheet[address("A3")].value == .empty)
    }

    @Test("The editor fills from its selection and selects the result")
    func editorFill() {
        var book = Workbook(sheets: [sheet(["A1": .number(2), "A2": .number(4)])])
        let state = EditorState()
        state.activeSheetID = book.sheets[0].id
        state.select(address("A1"), in: book.sheets[0])
        state.select(address("A2"), extending: true, in: book.sheets[0])
        state.fillSelection(to: range("A1:A4"), in: &book)
        #expect(book.sheets[0][address("A4")].value == .number(8))
        #expect(state.selection == range("A1:A4"))
    }

    // MARK: - Moving

    @Test("Moved cells carry their contents, and formulas reading them follow")
    func move() {
        var book = Workbook(sheets: [
            sheet(["A1": .number(5), "A2": .number(6)], formulas: ["C1": "SUM(A1:A2)", "C2": "A1+A3"]),
        ])
        var other = Worksheet(name: "Other")
        other[address("A1")] = Cell(formula: "Sheet1!A2*2")
        book.sheets.append(other)
        let moved = book.moveCells(range("A1:A2"), on: book.sheets[0].id, to: address("E5"))
        #expect(moved)
        let sheet = book.sheets[0]
        #expect(sheet[address("A1")].value == .empty)
        #expect(sheet[address("E5")].value == .number(5))
        #expect(sheet[address("C1")].formula == "SUM(E5:E6)")
        #expect(sheet[address("C2")].formula == "E5+A3")
        #expect(book.sheets[1][address("A1")].formula == "Sheet1!E6*2")
        #expect(sheet[address("C1")].value == .number(11))
    }

    @Test("A moved formula keeps reading the cells it read")
    func movedFormulaKeepsItsInputs() {
        var book = Workbook(sheets: [sheet(["A1": .number(5)], formulas: ["B1": "A1*2"])])
        let moved = book.moveCells(range("B1"), on: book.sheets[0].id, to: address("D4"))
        #expect(moved)
        #expect(book.sheets[0][address("D4")].formula == "A1*2")
        #expect(book.sheets[0][address("D4")].value == .number(10))
    }

    @Test("Copying leaves the original and moves the copy's references like a paste")
    func copy() {
        var book = Workbook(sheets: [sheet(["A1": .number(5)], formulas: ["B1": "A1*2"])])
        let moved = book.moveCells(range("B1"), on: book.sheets[0].id, to: address("B3"), copying: true)
        #expect(moved)
        #expect(book.sheets[0][address("B1")].formula == "A1*2")
        #expect(book.sheets[0][address("B3")].formula == "A3*2")
    }

    @Test("A move overlapping its own block lands whole")
    func overlappingMove() {
        var book = Workbook(sheets: [sheet(["A1": .number(1), "A2": .number(2), "A3": .number(3)])])
        let moved = book.moveCells(range("A1:A3"), on: book.sheets[0].id, to: address("A2"))
        #expect(moved)
        let sheet = book.sheets[0]
        #expect(sheet[address("A1")].value == .empty)
        #expect([2, 3, 4].map { sheet[CellAddress(row: $0 - 1, column: 0)].value } == [.number(1), .number(2), .number(3)])
    }

    @Test("A move off the sheet is refused")
    func moveOffTheSheet() {
        var book = Workbook(sheets: [sheet(["A1": .number(1)])])
        let moved = book.moveCells(range("A1:A3"), on: book.sheets[0].id, to: address("A29"))
        #expect(!moved)
    }
}
