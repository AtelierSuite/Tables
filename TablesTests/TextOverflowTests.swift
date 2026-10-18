import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

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
}
