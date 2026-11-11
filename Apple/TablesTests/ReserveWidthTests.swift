import Foundation
import Testing
@testable import TablesEngine

/// A format's `_x` reserves the width of `x` without drawing it, so an
/// accounting format pads a positive amount by the `)` a negative one ends
/// in and their decimals line up.
@Suite("Reserve-width tokens")
struct ReserveWidthTests {
    private let accounting = #"_(* #,##0.00_);_(* (#,##0.00);_(* "-"??_);_(@_)"#

    private func cell(_ value: CellValue, format: String) -> Cell {
        var cell = Cell(value: value, formula: nil, style: .default)
        cell.style.numberFormat = format
        return cell
    }

    /// What is laid out, with each reserved character in brackets.
    private func laidOut(_ cell: Cell) -> String {
        CellFormatter.reservedRuns(in: CellFormatter.layoutText(for: cell))
            .map { $0.isReserved ? "[\($0.text)]" : $0.text }
            .joined()
    }

    @Test("A positive amount reserves the width of the bracket a negative one is closed by")
    func paddingMatchesNegativeBracket() {
        #expect(laidOut(cell(.number(1234.5), format: "#,##0.00_);(#,##0.00)")) == "1,234.50[)]")
        #expect(laidOut(cell(.number(-1234.5), format: "#,##0.00_);(#,##0.00)")) == "(1,234.50)")
        #expect(laidOut(cell(.number(7), format: "_-0_-")) == "[-]7[-]")
    }

    @Test("Accounting formats keep their reserves on both sides of the fill")
    func accountingFill() throws {
        let positive = try #require(CellFormatter.filledText(for: cell(.number(1234.5), format: accounting), reservingWidth: true))
        #expect(CellFormatter.reservedRuns(in: positive.leading).map(\.isReserved) == [true])
        #expect(CellFormatter.reservedRuns(in: positive.trailing).map(\.text) == ["1,234.50", ")"])
        #expect(CellFormatter.reservedRuns(in: positive.trailing).map(\.isReserved) == [false, true])
        let negative = try #require(CellFormatter.filledText(for: cell(.number(-1234.5), format: accounting), reservingWidth: true))
        #expect(CellFormatter.reservedRuns(in: negative.trailing).map(\.text) == ["(1,234.50)"])
        // Without asking for them, the parts are just what the cell reads as.
        let plain = try #require(CellFormatter.filledText(for: cell(.number(1234.5), format: accounting)))
        #expect(plain.leading == "" && plain.trailing == "1,234.50")
    }

    @Test("Text sections reserve their padding too")
    func textSection() {
        #expect(laidOut(cell(.text("Total"), format: accounting)) == "[(]Total[)]")
    }

    @Test("The plain text a cell reads as leaves the reserved characters out")
    func displayTextOmitsReserves() {
        #expect(CellFormatter.displayText(for: .number(1234.5), format: accounting) == "1,234.50")
        #expect(CellFormatter.displayText(for: .number(-1234.5), format: accounting) == "(1,234.50)")
        #expect(CellFormatter.displayText(for: .text("Total"), format: accounting) == "Total")
        #expect(CellFormatter.displayText(for: .number(5), format: "0_)") == "5")
    }

    @Test("Excel's built-in bracketed and accounting formats keep their reserves")
    func builtInFormats() {
        let formats = XLSXReader.builtInNumberFormats
        #expect(formats[39] == "#,##0.00_);(#,##0.00)")
        #expect(laidOut(cell(.number(-7.1), format: formats[43] ?? "")) == "[(](7.10)")
        #expect(laidOut(cell(.number(7.1), format: formats[39] ?? "")) == "7.10[)]")
    }

    @Test("Adjacent reserves join one run, and a mark cut off by elision draws nothing")
    func runs() {
        let mark = String(CellFormatter.reserveMark)
        #expect(CellFormatter.reservedRuns(in: "1\(mark))\(mark)-").map(\.text) == ["1", ")-"])
        #expect(CellFormatter.reservedRuns(in: "Tot\(mark)").map(\.text) == ["Tot"])
        #expect(CellFormatter.reservedRuns(in: "plain").map(\.isReserved) == [false])
    }
}
