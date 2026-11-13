import Foundation
import Testing
@testable import TablesEngine

/// How much room a cell's text has once it is turned or stacked, and where it
/// is drawn when it has too little.
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

    @Test("Stacked text is one glyph per line")
    func stacked() {
        #expect(TextFitting.stacked("Sales") == "S\na\nl\ne\ns")
    }

    // MARK: - Clipping

    /// Where the renderer aligned the part of a line that fits: 60 wide.
    private let shown = CGRect(x: 100, y: 10, width: 60, height: 14)

    @Test("A line that fits is drawn where it was aligned")
    func fitsWhole() {
        for alignment in [HorizontalTextAlignment.leading, .center, .trailing, .automatic] {
            #expect(TextFitting.clippedLine(shown, length: 60, alignment: alignment) == shown)
            #expect(TextFitting.clippedLine(shown, length: 40, alignment: alignment) == shown)
        }
    }

    @Test("Left-aligned text too long keeps its start and runs past the right edge, with no ellipsis")
    func clipsLeading() {
        let line = TextFitting.clippedLine(shown, length: 150, alignment: .leading)
        #expect(line == CGRect(x: 100, y: 10, width: 150, height: 14))
        #expect(TextFitting.clippedLine(shown, length: 150, alignment: .automatic) == line)
    }

    @Test("Right-aligned text too long keeps its right edge and runs past the left")
    func clipsTrailing() {
        let line = TextFitting.clippedLine(shown, length: 150, alignment: .trailing)
        #expect(line == CGRect(x: 10, y: 10, width: 150, height: 14))
        #expect(line.maxX == shown.maxX)
    }

    @Test("Centred text too long stays centred and runs past both edges")
    func clipsCentred() {
        let line = TextFitting.clippedLine(shown, length: 150, alignment: .center)
        #expect(line == CGRect(x: 55, y: 10, width: 150, height: 14))
        #expect(line.midX == shown.midX)
    }

    @Test("Right-to-left text sits right, so it keeps its start on the right and is clipped on the left")
    func clipsRightToLeft() {
        let alignment = CellFormatter.alignment(for: Cell(value: .text("שלום עולם, מה שלומך היום")))
        #expect(alignment == .trailing)
        #expect(TextFitting.clippedLine(shown, length: 150, alignment: alignment).maxX == shown.maxX)
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
}
