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

    // MARK: - Drawing

    private func drawn(_ family: String, bold: Bool = false, italic: Bool = false, zoom: Double = 1) -> CellStyle.PlatformFont {
        var style = CellStyle.default
        style.fontName = family
        style.fontSize = 13
        style.isBold = bold
        style.isItalic = italic
        return style.platformFont(zoom: zoom)
    }

    private func isBold(_ font: CellStyle.PlatformFont) -> Bool {
        #if canImport(UIKit)
        font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #else
        font.fontDescriptor.symbolicTraits.contains(.bold)
        #endif
    }

    private func isItalic(_ font: CellStyle.PlatformFont) -> Bool {
        #if canImport(UIKit)
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #else
        font.fontDescriptor.symbolicTraits.contains(.italic)
        #endif
    }

    private var systemFamily: String? {
        CellStyle.default.platformFont().familyName
    }

    @Test("A cell's family is drawn in that family, at the zoomed size",
          arguments: ["Courier", "Times New Roman", "Georgia", "Hiragino Mincho ProN"])
    func drawsFamily(_ family: String) {
        let font = drawn(family, zoom: 2)
        #expect(font.familyName == family)
        #expect(font.pointSize == 26)
    }

    @Test("Bold and italic pick the family's own faces")
    func drawsFaces() {
        let font = drawn("Times New Roman", bold: true, italic: true)
        #expect(font.familyName == "Times New Roman")
        #expect(isBold(font))
        #expect(isItalic(font))
    }

    @Test("A family is found whatever its case")
    func familyIgnoresCase() {
        #expect(drawn("courier new").familyName == "Courier New")
    }

    @Test("A family that isn't installed, and the system font, draw in the system font")
    func fallsBackToSystemFont() {
        let missing = drawn("No Such Family Tables", bold: true)
        #expect(missing.familyName == systemFamily)
        #expect(isBold(missing))
        #expect(drawn(CellStyle.systemFontName).familyName == systemFamily)
    }

    @Test("Workbooks offer fonts; Numbers documents, which can't keep them, don't")
    func formattingKinds() {
        #expect(FormattingKinds.all.contains(.fonts))
        // Every kind a Numbers table can keep, at most.
        let numbersMost: FormattingKinds = [.numberFormats, .styles]
        #expect(!numbersMost.contains(.fonts))
    }
}
