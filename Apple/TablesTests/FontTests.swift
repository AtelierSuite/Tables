import Foundation
import Testing
@testable import TablesEngine

/// Cells set in a typeface of their own, and the system font as the default.
@Suite("Fonts")
struct FontTests {
    private func roundTripped(_ style: CellStyle) throws -> CellStyle {
        var sheet = Worksheet(name: "S")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .text("x"), formula: nil, style: style)
        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        return try XLSXReader.workbook(from: data).sheets[0][CellAddress(a1: "A1")!].style
    }

    @Test("A new cell is set in the system font")
    func defaultIsSystemFont() {
        let style = CellStyle.default
        #expect(style.usesSystemFont)
        #expect(style.displayFontName == nil)
    }

    @Test("A chosen family is drawn in that family")
    func chosenFamily() {
        var style = CellStyle.default
        style.fontName = "Georgia"
        #expect(!style.usesSystemFont)
        #expect(style.displayFontName == "Georgia")
    }

    @Test("An empty family name means the system font")
    func emptyFamily() {
        var style = CellStyle.default
        style.fontName = ""
        #expect(style.usesSystemFont)
    }

    @Test("Families survive saving as XLSX", arguments: ["Georgia", "Hiragino Mincho ProN", "Calibri"])
    func roundTrip(_ family: String) throws {
        var style = CellStyle.default
        style.fontName = family
        style.isBold = true
        let back = try roundTripped(style)
        #expect(back.fontName == family)
        #expect(back.isBold)
    }

    @Test("The system font survives saving as XLSX")
    func systemFontRoundTrip() throws {
        #expect(try roundTripped(.default).usesSystemFont)
    }

    @Test("Workbooks offer fonts; Numbers documents, which can't keep them, don't")
    func formattingKinds() {
        #expect(FormattingKinds.all.contains(.fonts))
        // Every kind a Numbers table can keep, at most.
        let numbersMost: FormattingKinds = [.numberFormats, .styles]
        #expect(!numbersMost.contains(.fonts))
    }
}
