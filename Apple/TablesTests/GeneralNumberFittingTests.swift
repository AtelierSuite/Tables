import Foundation
import Testing
@testable import TablesEngine

/// A General number too wide for its cell is rounded to fit, as Excel does,
/// before it gives way to a row of #s.
@Suite("General number fitting")
struct GeneralNumberFittingTests {
    /// The text a General number shows in a cell `width` characters wide.
    private func fitted(_ number: Double, width: Int, format: String = "General") -> String? {
        var cell = Cell(value: .number(number))
        cell.style.numberFormat = format
        return CellFormatter.fittedGeneralText(for: cell) { $0.count <= width }
    }

    @Test("A third drops decimals to fit the cell")
    func dropsDecimals() {
        #expect(fitted(1.0 / 3, width: 8) == "0.333333")
        #expect(fitted(1.0 / 3, width: 4) == "0.33")
        #expect(fitted(-2.0 / 3, width: 6) == "-0.667")
    }

    @Test("A number that already fits is left as General writes it")
    func leavesFittingNumbers() {
        #expect(fitted(1.5, width: 10) == "1.5")
        #expect(fitted(42, width: 2) == "42")
    }

    @Test("Rounding carries into the whole part and drops the trailing zeros")
    func roundsUp() {
        #expect(fitted(9.996, width: 4) == "10")
        #expect(fitted(1.2001, width: 4) == "1.2")
    }

    @Test("A long whole number switches to scientific notation")
    func wholeNumberGoesScientific() {
        #expect(fitted(123_456_789_012, width: 8) == "1.23E+11")
        #expect(fitted(123_456_789_012, width: 5) == "1E+11")
    }

    @Test("A tiny number goes scientific rather than reading as zero")
    func tinyNumberNeverZero() {
        #expect(fitted(0.000012345, width: 7) == "1.2E-05")
        #expect(fitted(0.000012345, width: 4) == nil)
    }

    @Test("Nothing fits, so the cell falls back to #s")
    func nothingFits() {
        #expect(fitted(123_456_789_012, width: 3) == nil)
    }

    @Test("Only General numbers are rounded to fit")
    func onlyGeneral() {
        #expect(fitted(1.0 / 3, width: 4, format: "0.000000") == nil)
        #expect(fitted(1.0 / 3, width: 4, format: "") == "0.33")
        var text = Cell(value: .text("A long heading"))
        text.style.numberFormat = "General"
        #expect(CellFormatter.fittedGeneralText(for: text) { _ in true } == nil)
    }
}
