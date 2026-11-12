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
}
