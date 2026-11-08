import SwiftUI
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

@Suite("Dark sheet colours")
struct AdaptiveColorTests {
    private func luminance(_ color: Color) -> Double {
        let resolved = color.resolve(in: EnvironmentValues())
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(Double(resolved.red))
            + 0.7152 * linear(Double(resolved.green))
            + 0.0722 * linear(Double(resolved.blue))
    }

    private func contrast(_ text: Color, _ fill: Color) -> Double {
        let first = luminance(text)
        let second = luminance(fill)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    @Test("White text stays legible on a coloured fill in dark mode")
    func whiteTextOnBlue() throws {
        let text = try #require(AdaptiveColor.resolveText(
            hex: "FFFFFFFF", on: "FF4472C4", for: .dark
        ))
        let fill = try #require(AdaptiveColor.resolve(hex: "FF4472C4", for: .dark, isText: false))
        #expect(contrast(text, fill) >= 4.5)
    }

    @Test("Black text stays legible on a light fill after adaptation")
    func blackTextOnWhite() throws {
        let text = try #require(AdaptiveColor.resolveText(
            hex: "FF000000", on: "FFFFFFFF", for: .dark
        ))
        let fill = try #require(AdaptiveColor.resolve(hex: "FFFFFFFF", for: .dark, isText: false))
        #expect(contrast(text, fill) >= 4.5)
    }

    private func sheet(fill: String?, text: String?, rows: Int, filledRows: Int? = nil) -> Worksheet {
        var sheet = Worksheet(name: "Sheet1")
        for row in 0..<rows {
            var style = CellStyle.default
            if row < (filledRows ?? rows) { style.fillColorHex = fill }
            style.textColorHex = text
            sheet.cells[CellAddress(row: row, column: 0)] = Cell(value: .text("Row \(row)"), style: style)
        }
        return sheet
    }

    @Test("A sheet made dark already is drawn as authored in dark mode")
    func darkSheetKeepsItsColours() {
        let dark = sheet(fill: "FF1E1E1E", text: "FFFFFFFF", rows: 10)
        #expect(dark.isAuthoredDark)
        #expect(dark.colorScheme(for: .dark) == .light)
        #expect(dark.colorScheme(for: .light) == .light)
    }

    @Test("A light sheet with a dark header row is still adapted in dark mode")
    func lightSheetWithDarkHeader() {
        let light = sheet(fill: "FF1F3864", text: nil, rows: 10, filledRows: 1)
        #expect(!light.isAuthoredDark)
        #expect(light.colorScheme(for: .dark) == .dark)
    }

    @Test("A sheet on white fills is adapted in dark mode")
    func whiteSheetIsAdapted() {
        let light = sheet(fill: "FFFFFFFF", text: "FF000000", rows: 10)
        #expect(!light.isAuthoredDark)
        #expect(light.colorScheme(for: .dark) == .dark)
    }
}
