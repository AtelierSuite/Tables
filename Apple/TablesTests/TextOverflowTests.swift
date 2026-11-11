import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Text running past its cell into empty neighbours, the way Excel draws a
/// long title over the blank cells beside it.
@Suite("Text overflow")
struct TextOverflowTests {
    private func sheet(_ entries: [String: CellValue], configure: (inout Worksheet) -> Void = { _ in /* Leave the sheet as built. */ }) throws -> Worksheet {
        var sheet = Worksheet(name: "Sheet")
        sheet.columnCount = 10
        for (reference, value) in entries {
            sheet[try #require(CellAddress(a1: reference))] = Cell(value: value)
        }
        configure(&sheet)
        return sheet
    }

    private func span(_ sheet: Worksheet, _ reference: String) throws -> ClosedRange<Int>? {
        sheet.overflowSpan(of: try #require(CellAddress(a1: reference)))
    }

    @Test("Text runs right across empty cells and stops at the next value")
    func runsRight() throws {
        let sheet = try self.sheet(["B1": .text("A long heading"), "E1": .text("x")])
        #expect(try span(sheet, "B1") == 1...3)
    }

    @Test("Formatting alone does not stop it; a value or a merge does")
    func whatStopsIt() throws {
        var styled = Cell()
        styled.style.isBold = true
        let sheet = try self.sheet(["A1": .text("Heading")]) {
            $0[CellAddress(row: 0, column: 1)] = styled
            _ = $0.merge(CellRange(a1Range: "D1:E1")!)
        }
        #expect(try span(sheet, "A1") == 0...2)
    }

    @Test("Right-aligned text runs left, centred text both ways")
    func directions() throws {
        let sheet = try self.sheet(["C1": .text("Right"), "C2": .text("Centre"), "A2": .text("x")]) {
            $0[CellAddress(row: 0, column: 2)].style.horizontalAlignment = .trailing
            $0[CellAddress(row: 1, column: 2)].style.horizontalAlignment = .center
            $0.columnCount = 5
        }
        #expect(try span(sheet, "C1") == 0...2)
        #expect(try span(sheet, "C2") == 1...4)
    }

    @Test("Numbers, wrapped text and text with nowhere to go stay in their cells")
    func staysPut() throws {
        let sheet = try self.sheet(["A1": .number(123_456_789), "A2": .text("Wrapped"), "A3": .text("Boxed"), "B3": .text("y")]) {
            $0[CellAddress(row: 1, column: 0)].style.wrapsText = true
        }
        #expect(try span(sheet, "A1") == nil)
        #expect(try span(sheet, "A2") == nil)
        #expect(try span(sheet, "A3") == nil)
    }

    /// Where text of `width` actually runs in column C of a row of 100pt
    /// columns that it may spill across from A to G.
    private func reach(
        _ width: Double, _ alignment: HorizontalTextAlignment = .leading, indent: Double = 0
    ) -> ClosedRange<Int>? {
        Worksheet.overflowReach(
            of: 2, within: 0...6, textWidth: width, alignment: alignment,
            padding: 6, indent: indent, columnWidth: { _ in 100 }
        )
    }

    @Test("Text that fits its cell crosses no gridline, however far it may run")
    func fitsItsCell() {
        #expect(reach(14) == nil)
        #expect(reach(88) == nil)
        #expect(reach(14, .center) == nil)
        #expect(reach(14, .trailing) == nil)
    }

    @Test("Text opens only the gridlines it runs across")
    func opensWhatItCrosses() {
        // From x = 6 in its cell, 120pt ends in the next column, 250pt two on.
        #expect(reach(120) == 2...3)
        #expect(reach(250) == 2...4)
        #expect(reach(120, .trailing) == 1...2)
        // Centred, 120pt pokes 4pt past both edges; 320pt a column and more each way.
        #expect(reach(120, .center) == 1...3)
        #expect(reach(320, .center) == 0...4)
    }

    @Test("Indent counts towards the reach, and the span still caps it")
    func indentAndCap() {
        #expect(reach(88, indent: 10) == 2...3)
        #expect(reach(5_000) == 2...6)
        #expect(reach(5_000, .trailing) == 0...2)
    }
}
