import Foundation
import Testing
@testable import TablesEngine

/// How much room a cell's text has once it is turned or stacked, and where it
/// is cut short when it has too little.
@Suite("Text fitting")
struct TextFittingTests {
    private let narrowTall = CGSize(width: 30, height: 120)

    private func style(rotation: Int) -> CellStyle {
        var style = CellStyle.default
        style.textRotation = rotation
        return style
    }

    @Test("Upright text has the box's width")
    func upright() {
        #expect(TextFitting.runLength(in: narrowTall, rotationDegrees: 0, lineHeight: 14) == 30)
    }

    @Test("Text turned a quarter either way has the box's height, not its width")
    func quarterTurns() {
        // 90° and the -90° that OOXML spells 180.
        for raw in [90, 180] {
            let length = TextFitting.runLength(of: style(rotation: raw), in: narrowTall, lineHeight: 14)
            #expect(length == 120, "rotation \(raw) measured \(length)")
        }
    }

    @Test("Text at an angle may be as long as keeps its turned box inside the cell")
    func angled() {
        let line = 14.0
        let box = CGSize(width: 100, height: 60)
        let length = TextFitting.runLength(of: style(rotation: 45), in: box, lineHeight: line)
        // The height is the tighter side: (60 - 14·sin45°) / sin45°.
        let half = sqrt(0.5)
        #expect(abs(length - (60 - line * half) / half) < 1e-6)
        // The turned run fills the box down and stays within it across.
        let across = length * half + line * half
        let down = length * half + line * half
        #expect(across <= box.width + 1e-6)
        #expect(abs(down - box.height) < 1e-6)
        // Turned the other way (OOXML 135, -45°) it has the same room.
        #expect(TextFitting.runLength(of: style(rotation: 135), in: box, lineHeight: line) == length)
    }

    @Test("A box too small for even the line's own height leaves no room")
    func tooSmall() {
        #expect(TextFitting.runLength(in: CGSize(width: 5, height: 5), rotationDegrees: 45, lineHeight: 14) == 0)
    }

    @Test("Stacked text runs down the box")
    func stackedRoom() {
        let stacked = style(rotation: CellStyle.stackedTextRotation)
        #expect(TextFitting.runLength(of: stacked, in: narrowTall, lineHeight: 14) == 120)
    }

    @Test("Turned text is cut short against the turned room rather than the cell's width")
    func elidesTurned() {
        // Six points a character stands in for a font: the whole run is 102.
        let text = "Quarterly Revenue"
        let width = { (candidate: String) in Double(candidate.count) * 6 }
        let upright = TextFitting.runLength(of: style(rotation: 0), in: narrowTall, lineHeight: 14)
        let turned = TextFitting.runLength(of: style(rotation: 90), in: narrowTall, lineHeight: 14)
        #expect(TextFitting.elided(text) { width($0) <= upright } == "Quar…")
        #expect(TextFitting.elided(text) { width($0) <= turned } == text)
        #expect(TextFitting.elided(text) { width($0) <= 60 } == "Quarterly…")
        #expect(TextFitting.elided(text) { _ in false } == "…")
    }

    @Test("Stacked text keeps as many glyphs as fit down the box, the ellipsis taking the last line")
    func elidesStacked() {
        let lines = { (candidate: String) in candidate.split(separator: "\n", omittingEmptySubsequences: false).count }
        #expect(TextFitting.stacked("Sales") == "S\na\nl\ne\ns")
        #expect(TextFitting.elided("Sales", stacked: true) { lines($0) <= 5 } == "S\na\nl\ne\ns")
        #expect(TextFitting.elided("Quarterly", stacked: true) { lines($0) <= 4 } == "Q\nu\na\n…")
    }

    // MARK: - Right-to-left text

    @Test("Text reads the way its first letter does; digits and punctuation have no say")
    func baseDirection() {
        let rightToLeft = ["שלום", "مرحبا بالعالم", "123 שלום", "(مرحبا)", "שלום world", "\u{200F}123"]
        for text in rightToLeft {
            #expect(TextFitting.baseDirection(of: text) == .rightToLeft, "\(text)")
        }
        let leftToRight = ["Hello", "world שלום", "123", "", "  ", "١٢٣", "日本語", "\u{2067}שלום\u{2069} world"]
        for text in leftToRight {
            #expect(TextFitting.baseDirection(of: text) == .leftToRight, "\(text)")
        }
    }

    @Test("Under automatic alignment, Arabic and Hebrew text sit right; numbers right, booleans and errors as before")
    func naturalAlignment() {
        #expect(CellFormatter.naturalAlignment(for: .text("שלום")) == .trailing)
        #expect(CellFormatter.naturalAlignment(for: .text("مرحبا")) == .trailing)
        #expect(CellFormatter.naturalAlignment(for: .text("שלום world")) == .trailing)
        #expect(CellFormatter.naturalAlignment(for: .text("Hello שלום")) == .leading)
        #expect(CellFormatter.naturalAlignment(for: .text("Hello")) == .leading)
        #expect(CellFormatter.naturalAlignment(for: .number(1)) == .trailing)
        #expect(CellFormatter.naturalAlignment(for: .boolean(true)) == .trailing)
        #expect(CellFormatter.naturalAlignment(for: .empty) == .leading)
    }

    @Test("An alignment set on the cell holds for right-to-left text too")
    func explicitAlignment() {
        var cell = Cell(value: .text("שלום"))
        #expect(CellFormatter.alignment(for: cell) == .trailing)
        for alignment in [HorizontalTextAlignment.leading, .center, .trailing] {
            cell.style.horizontalAlignment = alignment
            #expect(CellFormatter.alignment(for: cell) == alignment)
        }
    }

    @Test("Right-to-left text cut short keeps its start and ends in an ellipsis on its left")
    func elidesRightToLeft() {
        let width = { (candidate: String) in Double(candidate.count) * 6 }
        let hebrew = "שלום עולם"
        let cut = TextFitting.elided(hebrew) { width($0) <= 30 }
        // Its first letters, the right-hand ones once set right to left,
        // followed in reading order — on the left — by the ellipsis.
        #expect(cut == "שלום…")
        #expect(TextFitting.baseDirection(of: cut) == .rightToLeft)
        #expect(TextFitting.elided("مرحبا بالعالم") { width($0) <= 36 } == "مرحبا…")
        // A line that opens in Hebrew stays right to left with English in it.
        let mixed = TextFitting.elided("שלום world") { width($0) <= 48 }
        #expect(mixed == "שלום wo…")
        #expect(TextFitting.baseDirection(of: mixed) == .rightToLeft)
    }

    @Test("A cut that leaves no letter keeps the whole text's direction")
    func elidesKeepingDirection() {
        // The mark is invisible and takes no room.
        let width = { (candidate: String) in Double(candidate.unicodeScalars.filter { $0.value != 0x200F }.count) * 6 }
        let cut = TextFitting.elided("123 שלום") { width($0) <= 18 }
        #expect(cut == "\u{200F}12…")
        #expect(TextFitting.baseDirection(of: cut) == .rightToLeft)
        // Left-to-right text needs no mark: its digits read that way already.
        #expect(TextFitting.elided("123 Hello") { width($0) <= 18 } == "12…")
        #expect(TextFitting.elided("שלום") { _ in false } == "\u{200F}…")
        // Stacked glyphs have no line to set a direction for.
        #expect(TextFitting.elided("123 שלום", stacked: true) { $0.split(separator: "\n").count <= 3 } == "1\n2\n…")
    }
}
