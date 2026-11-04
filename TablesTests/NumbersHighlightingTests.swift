import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Conditional highlighting read from Numbers. What these expect of a rule —
/// the first to pass is the one applied, a blank is 0, text passes no number
/// rule — is what real documents record each cell as having been given.
@Suite("Numbers conditional highlighting")
struct NumbersHighlightingTests {
    private typealias Rule = NumbersDocumentBuilder.HighlightRule
    private static let red: (Float, Float, Float) = (1, 0, 0)
    private static let blue: (Float, Float, Float) = (0, 0, 1)
    private static let redHex = "FFFF0000"
    private static let blueHex = "FF0000FF"

    private func document(
        _ rows: [[NumbersDocumentBuilder.Cell]], rules: [Rule], identifiers: Bool = false
    ) throws -> Data {
        var document = NumbersDocumentBuilder()
        var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: rows)
        table.highlightRules = rules
        table.hasIdentifiers = identifiers
        document.addSheet("Budget", tables: [table])
        return try document.singleFile()
    }

    private func style(_ reference: String, in sheet: Worksheet) -> ConditionalStyle? {
        sheet.conditionalStyles[CellAddress(a1: reference)!]
    }

    private func save(_ workbook: Workbook, _ source: NumbersSource) throws -> Data {
        try #require(NumbersWriter.fileWrapper(for: workbook, source: source, existing: nil).regularFileContents)
    }

    @Test("A rule styles the cells naming it that pass, and only those")
    func passingCells() throws {
        let data = try document(
            [[.highlightedNumber(50)], [.highlightedNumber(150)], [.number(150, exponent: 0)]],
            rules: [Rule(comparison: 7, number: 100, textColor: Self.red, fill: Self.blue, isBold: true)]
        )
        let sheet = try NumbersReader.workbook(from: data).sheets[0]
        #expect(style("A1", in: sheet) == nil)
        #expect(style("A2", in: sheet)?.textColorHex == Self.redHex)
        #expect(style("A2", in: sheet)?.fillColorHex == Self.blueHex)
        #expect(style("A2", in: sheet)?.isBold == true)
        #expect(style("A2", in: sheet)?.isItalic == nil, "what a rule doesn't say is the cell's own")
        #expect(style("A3", in: sheet) == nil, "it passes, but doesn't name the rules")
    }

    @Test("The first rule to pass is the only one applied")
    func firstRuleWins() throws {
        let data = try document(
            [[.highlightedNumber(300)], [.highlightedNumber(150)]],
            rules: [
                Rule(comparison: 7, number: 200, textColor: Self.red),
                Rule(comparison: 7, number: 100, fill: Self.blue, isBold: true),
            ]
        )
        let sheet = try NumbersReader.workbook(from: data).sheets[0]
        #expect(style("A1", in: sheet)?.textColorHex == Self.redHex)
        #expect(style("A1", in: sheet)?.fillColorHex == nil, "nothing is taken from the later rule")
        #expect(style("A1", in: sheet)?.isBold == nil)
        #expect(style("A2", in: sheet)?.fillColorHex == Self.blueHex)
    }

    @Test("Text passes no number rule, and a blank counts as 0")
    func textAndBlanks() throws {
        let data = try document(
            [[.highlightedText("Rent")], [.highlightedEmpty]],
            rules: [Rule(comparison: 7, number: -1, fill: Self.blue)]
        )
        let sheet = try NumbersReader.workbook(from: data).sheets[0]
        #expect(style("A1", in: sheet) == nil)
        #expect(style("A2", in: sheet)?.fillColorHex == Self.blueHex)
        #expect(sheet.displayedCell(at: CellAddress(a1: "A2")!).style.fillColorHex == Self.blueHex)
    }

    @Test("A set with a rule that can't be read isn't followed at all")
    func unreadableRule() throws {
        let data = try document(
            [[.highlightedNumber(300)]],
            rules: [
                Rule(comparison: 7, number: 200, textColor: Self.red, isUnreadable: true),
                Rule(comparison: 7, number: 100, fill: Self.blue),
            ]
        )
        let (workbook, source) = try NumbersReader.document(from: data)
        #expect(workbook.sheets[0].conditionalRules.isEmpty)
        #expect(style("A1", in: workbook.sheets[0]) == nil)
        #expect(source.features.noticeMessage.contains(UnsupportedFeature.conditionalFormatting.label))
    }

    @Test("A rule testing some other cell isn't read")
    func otherTarget() throws {
        let data = try document(
            [[.highlightedNumber(300)]], rules: [Rule(comparison: 7, number: 100, fill: Self.blue, targetRowOffset: 1)]
        )
        #expect(try NumbersReader.workbook(from: data).sheets[0].conditionalRules.isEmpty)
    }

    @Test("A cell's own formula can't refer to the cell being highlighted")
    func linkedCellOnlyInRules() {
        var node = ProtobufMessage()
        node.set(1, uint: 63)
        let context = NumbersFormula.Context(host: CellAddress(row: 0, column: 0), hostTable: nil, sheetNames: [:])
        #expect(NumbersFormula.formula(from: [node], context: context) == nil)
    }

    @Test("The notice names highlighting only where there is some")
    func notice() throws {
        let plain = try document([[.number(1, exponent: 0)]], rules: [])
        let (_, source) = try NumbersReader.document(from: plain)
        #expect(!source.features.noticeMessage.contains(UnsupportedFeature.conditionalFormatting.label))
        let highlighted = try document(
            [[.highlightedNumber(1)]], rules: [Rule(comparison: 7, number: 0, fill: Self.blue)]
        )
        let (_, highlightedSource) = try NumbersReader.document(from: highlighted)
        #expect(highlightedSource.features.noticeMessage.contains(UnsupportedFeature.conditionalFormatting.label))
    }

    @Test("Editing a highlighted cell redraws it, is allowed, and keeps it naming its rules")
    func editing() throws {
        let data = try document(
            [[.highlightedNumber(50)]], rules: [Rule(comparison: 7, number: 100, fill: Self.blue)]
        )
        let (old, source) = try NumbersReader.document(from: data)
        var new = old
        new.sheets[0][CellAddress(a1: "A1")!].value = .number(150)
        new.recalculate()
        #expect(style("A1", in: new.sheets[0])?.fillColorHex == Self.blueHex)

        let (reconciled, violation) = NumbersEditPolicy.reconcile(new, from: old, source: source)
        #expect(violation == nil)
        let saved = try save(reconciled, source)
        let reopened = try NumbersReader.workbook(from: saved).sheets[0]
        #expect(reopened[CellAddress(a1: "A1")!].value == .number(150))
        #expect(style("A1", in: reopened)?.fillColorHex == Self.blueHex)
    }

    @Test("A document saved without changes keeps its highlighting exactly")
    func unchanged() throws {
        let data = try document(
            [[.highlightedNumber(150)]], rules: [Rule(comparison: 7, number: 100, fill: Self.blue)]
        )
        let (workbook, source) = try NumbersReader.document(from: data)
        #expect(try save(workbook, source) == data)
    }

    @Test("Rows inserted among highlighted cells move them and get none themselves")
    func insertedRow() throws {
        let data = try document(
            [[.highlightedNumber(150)], [.highlightedNumber(160)]],
            rules: [Rule(comparison: 7, number: 100, fill: Self.blue)], identifiers: true
        )
        let (old, source) = try NumbersReader.document(from: data)
        var new = old
        new.sheets[0].insertRows(1, at: 1)
        new.recalculate()
        #expect(style("A1", in: new.sheets[0]) != nil)
        #expect(style("A2", in: new.sheets[0]) == nil)
        #expect(style("A3", in: new.sheets[0]) != nil)

        let (reconciled, violation) = NumbersEditPolicy.reconcile(new, from: old, source: source)
        #expect(violation == nil)
        let reopened = try NumbersReader.workbook(from: try save(reconciled, source)).sheets[0]
        #expect(style("A1", in: reopened) != nil)
        #expect(style("A2", in: reopened) == nil)
        #expect(style("A3", in: reopened) != nil)
    }

    @Test("Removing the row a set's rules were read for leaves them working")
    func removedRow() throws {
        let data = try document(
            [[.highlightedNumber(50)], [.highlightedNumber(150)]],
            rules: [Rule(comparison: 7, number: 100, fill: Self.blue)]
        )
        var workbook = try NumbersReader.workbook(from: data)
        workbook.sheets[0].removeRows(0...0)
        workbook.recalculate()
        #expect(style("A1", in: workbook.sheets[0])?.fillColorHex == Self.blueHex)
    }
}
