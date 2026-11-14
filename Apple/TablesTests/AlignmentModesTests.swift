import CoreGraphics
import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Shrink to fit, justify, distributed and centre across selection: read from
/// an XLSX, kept through a save, and laid out the way Excel lays them out.
@Suite("Alignment modes")
struct AlignmentModesTests {

    // MARK: - Helpers

    private func address(_ reference: String) throws -> CellAddress {
        try #require(CellAddress(a1: reference))
    }

    /// A1 holding text in `style`, saved, its `<alignment>` rewritten to
    /// `alignment`, and read back: what the reader makes of a file Excel wrote.
    private func readStyle(alignment: String) throws -> CellStyle {
        var sheet = Worksheet(name: "S")
        var style = CellStyle()
        style.horizontalAlignment = .center
        sheet[try address("A1")] = Cell(value: .text("x"), formula: nil, style: style)
        var entries = try ZipArchive.entries(in: try XLSXWriter.data(from: Workbook(sheets: [sheet])))
        let styles = String(decoding: try #require(entries["xl/styles.xml"]), as: UTF8.self)
        let replaced = styles.replacingOccurrences(
            of: "<alignment horizontal=\"center\" vertical=\"center\"/>", with: "<alignment \(alignment)/>"
        )
        #expect(replaced != styles)
        entries["xl/styles.xml"] = Data(replaced.utf8)
        let ordered = entries.sorted { lhs, rhs in
            lhs.key == "[Content_Types].xml" || (rhs.key != "[Content_Types].xml" && lhs.key < rhs.key)
        }
        let data = try ZipArchive.archive(entries: ordered.map { ($0.key, $0.value) })
        return try XLSXReader.workbook(from: data).sheets[0][try address("A1")].style
    }

    /// Saves a style on A1 and returns the `<alignment>` the save wrote and
    /// the style read back from it.
    private func roundTripped(_ style: CellStyle) throws -> (xml: String, style: CellStyle) {
        var sheet = Worksheet(name: "S")
        sheet[try address("A1")] = Cell(value: .text("x"), formula: nil, style: style)
        let data = try XLSXWriter.data(from: Workbook(sheets: [sheet]))
        let styles = String(decoding: try #require(try ZipArchive.entries(in: data)["xl/styles.xml"]), as: UTF8.self)
        let read = try XLSXReader.workbook(from: data).sheets[0][try address("A1")].style
        return (styles, read)
    }

    /// Every UTF-16 unit 10 wide, so layouts can be worked out by hand.
    private func measure(_ range: Range<Int>) -> Double { Double(range.count) * 10 }

    private func texts(_ pieces: [TextFitting.PlacedPiece], in text: String) -> [String] {
        let units = Array(text.utf16)
        return pieces.map { String(decoding: units[$0.range], as: UTF16.self) }
    }

    // MARK: - Reading

    @Test("Justify, distributed and centre across selection are read with the alignment they fall back to")
    func readsHorizontalModes() throws {
        let justify = try readStyle(alignment: "horizontal=\"justify\"")
        #expect(justify.horizontalSpread == .justify)
        #expect(justify.horizontalAlignment == .leading)
        let distributed = try readStyle(alignment: "horizontal=\"distributed\"")
        #expect(distributed.horizontalSpread == .distributed)
        #expect(distributed.horizontalAlignment == .center)
        let across = try readStyle(alignment: "horizontal=\"centerContinuous\"")
        #expect(across.horizontalSpread == .centerAcrossSelection)
        #expect(across.horizontalAlignment == .center)
        #expect(try readStyle(alignment: "horizontal=\"center\"").horizontalSpread == nil)
    }

    @Test("Vertical justify and distributed and shrink to fit are read")
    func readsVerticalModesAndShrink() throws {
        let justify = try readStyle(alignment: "vertical=\"justify\"")
        #expect(justify.verticalSpread == .justify)
        #expect(justify.verticalAlignment == .top)
        let distributed = try readStyle(alignment: "vertical=\"distributed\"")
        #expect(distributed.verticalSpread == .distributed)
        #expect(distributed.verticalAlignment == .middle)
        #expect(try readStyle(alignment: "shrinkToFit=\"1\"").shrinksToFit)
        #expect(try readStyle(alignment: "shrinkToFit=\"true\"").shrinksToFit)
        #expect(try !readStyle(alignment: "vertical=\"top\"").shrinksToFit)
    }

    // MARK: - Saving

    @Test("Every mode is written as Excel spells it and read back the same")
    func modesSurviveASave() throws {
        let horizontal: [(HorizontalTextSpread, String)] = [
            (.justify, "horizontal=\"justify\""), (.distributed, "horizontal=\"distributed\""),
            (.centerAcrossSelection, "horizontal=\"centerContinuous\""),
        ]
        for (spread, attribute) in horizontal {
            var style = CellStyle()
            style.horizontalAlignment = .center
            style.horizontalSpread = spread
            let saved = try roundTripped(style)
            #expect(saved.xml.contains(attribute))
            #expect(saved.style.horizontalSpread == spread)
        }
        for (spread, attribute) in [(VerticalTextSpread.justify, "vertical=\"justify\""),
                                    (.distributed, "vertical=\"distributed\"")] {
            var style = CellStyle()
            style.verticalSpread = spread
            let saved = try roundTripped(style)
            #expect(saved.xml.contains(attribute))
            #expect(saved.style.verticalSpread == spread)
        }
        var shrinking = CellStyle()
        shrinking.shrinksToFit = true
        let saved = try roundTripped(shrinking)
        #expect(saved.xml.contains("shrinkToFit=\"1\""))
        #expect(saved.style.shrinksToFit)
        #expect(try !roundTripped(CellStyle()).xml.contains("shrinkToFit"))
    }

    @Test("Picking left, centre or right, or top, middle or bottom, replaces a spread")
    func pickingAnAlignmentClearsTheSpread() {
        var style = CellStyle()
        style.horizontalSpread = .distributed
        style.verticalSpread = .justify
        style.horizontalAlignment = .center
        style.verticalAlignment = .top
        #expect(style.horizontalSpread == nil)
        #expect(style.verticalSpread == nil)
    }

    // MARK: - Indent and shrink

    @Test("Centred and justified text takes no indent; distributed text is indented from both edges")
    func indents() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 20)
        #expect(TextFitting.indented(box, by: 10, alignment: .leading, spread: nil) == CGRect(x: 10, y: 0, width: 90, height: 20))
        #expect(TextFitting.indented(box, by: 10, alignment: .trailing, spread: nil) == CGRect(x: 0, y: 0, width: 90, height: 20))
        #expect(TextFitting.indented(box, by: 10, alignment: .center, spread: nil) == box)
        #expect(TextFitting.indented(box, by: 10, alignment: .leading, spread: .justify) == box)
        #expect(TextFitting.indented(box, by: 10, alignment: .center, spread: .distributed)
                == CGRect(x: 10, y: 0, width: 80, height: 20))
    }

    @Test("Shrink to fit scales only text too wide for an unwrapped cell")
    func shrinkScale() {
        var style = CellStyle()
        #expect(TextFitting.shrinkScale(of: style, width: 200, room: 100) == 1)
        style.shrinksToFit = true
        #expect(TextFitting.shrinkScale(of: style, width: 200, room: 100) == 0.5)
        #expect(TextFitting.shrinkScale(of: style, width: 80, room: 100) == 1)
        style.wrapsText = true
        #expect(TextFitting.shrinkScale(of: style, width: 200, room: 100) == 1)
    }

    // MARK: - Wrapping and spreading

    @Test("Lines wrap at spaces, at line breaks, and inside a word too long for the line")
    func wrapsLines() {
        let text = "aa bb cc\nabcdefgh"
        let lines = TextFitting.wrappedLines(of: text, width: 50, measure: measure)
        let units = Array(text.utf16)
        #expect(lines.map { String(decoding: units[$0.range], as: UTF16.self) } == ["aa bb", "cc", "abcde", "fgh"])
        #expect(lines.map(\.endsParagraph) == [false, true, false, true])
    }

    @Test("Justify stretches every line but a paragraph's last between its words")
    func justifies() {
        var style = CellStyle()
        style.horizontalAlignment = .leading
        style.horizontalSpread = .justify
        style.verticalAlignment = .top
        let text = "aa b cc dd"
        let pieces = TextFitting.spreadPieces(
            of: text, in: CGSize(width: 80, height: 100), lineHeight: 10, style: style,
            alignment: .leading, rightToLeft: false, measure: measure
        )
        // "aa b cc" (70) is 10 short over two gaps; "dd" is last, at the left.
        #expect(texts(pieces, in: text) == ["aa", "b", "cc", "dd"])
        #expect(pieces.map(\.origin) == [
            CGPoint(x: 0, y: 0), CGPoint(x: 35, y: 0), CGPoint(x: 60, y: 0), CGPoint(x: 0, y: 10),
        ])
    }

    @Test("Distributed spreads a single word's characters and centres a single character")
    func distributes() {
        var style = CellStyle()
        style.horizontalAlignment = .center
        style.horizontalSpread = .distributed
        style.verticalAlignment = .top
        let word = TextFitting.spreadPieces(
            of: "東京都", in: CGSize(width: 90, height: 20), lineHeight: 10, style: style,
            alignment: .center, rightToLeft: false, measure: measure
        )
        #expect(word.map(\.origin.x) == [0, 40, 80])
        let single = TextFitting.spreadPieces(
            of: "東", in: CGSize(width: 90, height: 20), lineHeight: 10, style: style,
            alignment: .center, rightToLeft: false, measure: measure
        )
        #expect(single.map(\.origin.x) == [40])
    }

    @Test("Right-to-left text is spread from the right")
    func spreadsRightToLeft() {
        var style = CellStyle()
        style.horizontalSpread = .distributed
        let text = "אב גד"
        let pieces = TextFitting.spreadPieces(
            of: text, in: CGSize(width: 100, height: 10), lineHeight: 10, style: style,
            alignment: .trailing, rightToLeft: true, measure: measure
        )
        #expect(texts(pieces, in: text) == ["אב", "גד"])
        #expect(pieces.map(\.origin.x) == [80, 0])
    }

    @Test("Vertical justify spreads lines from top to bottom; a single distributed line sits in the middle")
    func spreadsDown() {
        var style = CellStyle()
        style.verticalSpread = .justify
        let lines = TextFitting.spreadPieces(
            of: "a\nb\nc", in: CGSize(width: 50, height: 70), lineHeight: 10, style: style,
            alignment: .leading, rightToLeft: false, measure: measure
        )
        #expect(lines.map(\.origin.y) == [0, 30, 60])

        var distributed = CellStyle()
        distributed.verticalAlignment = .middle
        distributed.verticalSpread = .distributed
        let one = TextFitting.spreadPieces(
            of: "a", in: CGSize(width: 50, height: 70), lineHeight: 10, style: distributed,
            alignment: .leading, rightToLeft: false, measure: measure
        )
        #expect(one.map(\.origin) == [CGPoint(x: 0, y: 30)])
    }

    // MARK: - Centre across selection

    private func acrossSheet() throws -> Worksheet {
        var sheet = Worksheet(name: "S")
        sheet.columnCount = 10
        var across = CellStyle()
        across.horizontalAlignment = .center
        across.horizontalSpread = .centerAcrossSelection
        sheet[try address("B1")] = Cell(value: .text("Title"), formula: nil, style: across)
        sheet[try address("C1")] = Cell(value: .empty, formula: nil, style: across)
        sheet[try address("D1")] = Cell(value: .empty, formula: nil, style: across)
        // E1 is empty but not set to centre across, so the selection ends at D.
        sheet[try address("B2")] = Cell(value: .number(42), formula: nil, style: across)
        sheet[try address("C2")] = Cell(value: .empty, formula: nil, style: across)
        sheet[try address("D2")] = Cell(value: .text("x"), formula: nil, style: across)
        return sheet
    }

    @Test("Centre across selection spans the empty cells after it set the same way")
    func spansSelection() throws {
        let sheet = try acrossSheet()
        #expect(sheet.centerAcrossSpan(of: try address("B1")) == 1...3)
        // Stopped by D2's value; a number is centred across too.
        #expect(sheet.centerAcrossSpan(of: try address("B2")) == 1...2)
        #expect(sheet.centerAcrossSpan(of: try address("C1")) == nil)
        #expect(sheet.centerAcrossSpan(of: try address("D2")) == 3...3)
        // The text may then run on either side like any centred text.
        #expect(sheet.overflowSpan(of: try address("B1")) == 0...9)
        #expect(sheet.overflowSpan(of: try address("B2")) == 1...2)
    }

    @Test("Short text centred across a selection opens only the gridlines it crosses")
    func reachAcrossSelection() {
        // Columns 100 wide; B:D centred around x = 150 from B's left edge.
        let short = Worksheet.overflowReach(
            of: 1, within: 0...9, textWidth: 20, alignment: .center, padding: 6, selection: 1...3,
            columnWidth: { _ in 100 }
        )
        #expect(short == nil)
        let long = Worksheet.overflowReach(
            of: 1, within: 0...9, textWidth: 120, alignment: .center, padding: 6, selection: 1...3,
            columnWidth: { _ in 100 }
        )
        #expect(long == 1...3)
    }

    @Test("Shrink to fit keeps text from spilling into its neighbours")
    func shrinkingTextStaysInItsCell() throws {
        var sheet = Worksheet(name: "S")
        sheet.columnCount = 5
        var style = CellStyle()
        style.shrinksToFit = true
        sheet[try address("A1")] = Cell(value: .text("A long heading"), formula: nil, style: style)
        #expect(sheet.overflowSpan(of: try address("A1")) == nil)
    }
}
