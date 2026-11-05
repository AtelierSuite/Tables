import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Conditional highlighting read from Numbers: which cells it reaches, how
/// its rules give way to each other, and that a save leaves it in place.
@Suite("Numbers conditional highlighting")
struct NumbersConditionalFormatTests {
    private typealias Rule = NumbersDocumentBuilder.HighlightRule

    private static let red = "FFFF0000"
    private static let green = "FF00FF00"

    private static let context = NumbersFormula.Context(
        host: CellAddress(row: 0, column: 0), hostTable: nil, sheetNames: [:]
    )

    private static func node(_ type: Int) -> ProtobufMessage {
        var node = ProtobufMessage()
        node.set(1, uint: UInt64(type))
        return node
    }

    /// The nodes of a test of the cell itself against a formula, as Numbers
    /// writes one.
    private static func test(_ type: Int, _ operand: String) throws -> [ProtobufMessage] {
        let operand = try #require(NumbersFormula.nodes(for: operand, context: context))
        return [node(NumbersFormula.NodeType.ruleSubject)] + operand + [node(type)]
    }

    private static func above(_ limit: Int) throws -> [ProtobufMessage] {
        try test(NumbersFormula.NodeType.greaterThan, String(limit))
    }

    private func sheet(
        _ rows: [[NumbersDocumentBuilder.Cell]], ruleSets: [[Rule]]
    ) throws -> Worksheet {
        try NumbersReader.workbook(from: document(rows, ruleSets: ruleSets)).sheets[0]
    }

    private func document(_ rows: [[NumbersDocumentBuilder.Cell]], ruleSets: [[Rule]]) throws -> Data {
        var document = NumbersDocumentBuilder()
        var table = NumbersDocumentBuilder.Table(name: "Table 1", rows: rows)
        table.ruleSets = ruleSets
        document.addSheet("Budget", tables: [table])
        return try document.singleFile()
    }

    private func style(_ reference: String, in sheet: Worksheet) -> CellStyle {
        sheet.displayedCell(at: CellAddress(a1: reference)!).style
    }

    @Test("A rule styles the cells of its set that pass, with only what it sets")
    func passing() throws {
        let sheet = try sheet(
            [[.highlighted(150, ruleSet: 1), .highlighted(50, ruleSet: 1), .number(150, exponent: 0)]],
            ruleSets: [[Rule(nodes: Self.above(100), fill: Self.red, textColor: Self.green, isBold: true)]]
        )
        let passed = style("A1", in: sheet)
        #expect(passed.fillColorHex == Self.red)
        #expect(passed.textColorHex == Self.green)
        #expect(passed.isBold)
        #expect(!passed.isItalic)
        #expect(style("B1", in: sheet).fillColorHex == nil)
        #expect(style("C1", in: sheet).fillColorHex == nil, "a cell outside the set isn't tested")
        #expect(sheet[CellAddress(a1: "A1")!].style.fillColorHex == nil, "the cell's own style stays its own")
    }

    @Test("A cell passing several rules looks as the first says, and no more")
    func firstRuleWins() throws {
        let sheet = try sheet([[.highlighted(150, ruleSet: 1), .highlighted(75, ruleSet: 1)]], ruleSets: [[
            Rule(nodes: Self.above(100), isBold: true),
            Rule(nodes: Self.above(50), fill: Self.red),
        ]])
        #expect(style("A1", in: sheet).isBold)
        #expect(style("A1", in: sheet).fillColorHex == nil, "the second rule's fill doesn't join in")
        #expect(style("B1", in: sheet).fillColorHex == Self.red)
    }

    @Test("A blank counts as 0 and text passes no comparison with a number")
    func blanksAndText() throws {
        let below = try Self.test(NumbersFormula.NodeType.lessThan, "100")
        let sheet = try sheet(
            [[.highlightedBlank(ruleSet: 1), .highlightedText("Note", ruleSet: 1)],
             [.highlightedText("-", ruleSet: 2), .highlighted(150, ruleSet: 2)]],
            ruleSets: [
                [Rule(nodes: below, fill: Self.red)],
                [Rule(nodes: Self.above(100), fill: Self.green)],
            ]
        )
        #expect(style("A1", in: sheet).fillColorHex == Self.red)
        #expect(style("B1", in: sheet).fillColorHex == nil)
        #expect(style("A2", in: sheet).fillColorHex == nil, "formulas rank text above every number; Numbers doesn't")
        #expect(style("B2", in: sheet).fillColorHex == Self.green)
    }

    @Test("A test against text passes the same text and no number")
    func textOperand() throws {
        let equal = try Self.test(NumbersFormula.NodeType.equal, "\"Paid\"")
        let different = try Self.test(NumbersFormula.NodeType.notEqual, "\"Paid\"")
        let sheet = try sheet(
            [[.highlightedText("Paid", ruleSet: 1), .highlightedText("Due", ruleSet: 1), .highlighted(5, ruleSet: 1)],
             [.highlightedText("Due", ruleSet: 2), .highlighted(5, ruleSet: 2)]],
            ruleSets: [[Rule(nodes: equal, fill: Self.red)], [Rule(nodes: different, fill: Self.green)]]
        )
        #expect(style("A1", in: sheet).fillColorHex == Self.red)
        #expect(style("B1", in: sheet).fillColorHex == nil)
        #expect(style("C1", in: sheet).fillColorHex == nil)
        #expect(style("A2", in: sheet).fillColorHex == Self.green)
        #expect(style("B2", in: sheet).fillColorHex == nil, "a number isn't text, equal or not")
    }

    @Test("A rule's relative references move with each cell, and absolute ones stay")
    func references() throws {
        // Written for A1, the first cell of the set: the cell to its right.
        let context = NumbersFormula.Context(host: CellAddress(row: 0, column: 0), hostTable: nil, sheetNames: [:])
        let right = try #require(NumbersFormula.nodes(for: "B1", context: context))
        let absolute = try #require(NumbersFormula.nodes(for: "$B$1", context: context))
        let greater = Self.node(NumbersFormula.NodeType.greaterThan)
        let subject = Self.node(NumbersFormula.NodeType.ruleSubject)
        let rows: [[NumbersDocumentBuilder.Cell]] = [
            [.highlighted(5, ruleSet: 1), .number(1, exponent: 0), .highlighted(5, ruleSet: 2)],
            [.highlighted(5, ruleSet: 1), .number(9, exponent: 0), .highlighted(5, ruleSet: 2)],
        ]
        let sheet = try sheet(rows, ruleSets: [
            [Rule(nodes: [subject] + right + [greater], fill: Self.red)],
            [Rule(nodes: [subject] + absolute + [greater], fill: Self.green)],
        ])
        #expect(style("A1", in: sheet).fillColorHex == Self.red)
        #expect(style("A2", in: sheet).fillColorHex == nil, "5 is not above B2")
        #expect(style("C2", in: sheet).fillColorHex == Self.green, "5 is above B1, wherever the cell")
    }

    @Test("A rule Tables can't read is left out, and the rest stand")
    func unreadableRule() throws {
        let unknown = [Self.node(9_999)]
        let sheet = try sheet([[.highlighted(150, ruleSet: 1)]], ruleSets: [[
            Rule(nodes: unknown, fill: Self.green),
            Rule(nodes: Self.above(100), fill: Self.red),
        ]])
        #expect(sheet.conditionalRules.count == 1)
        #expect(style("A1", in: sheet).fillColorHex == Self.red)
    }

    @Test("Only a highlighting rule can name the cell it tests")
    func subjectNeedsARule() {
        let nodes = [Self.node(NumbersFormula.NodeType.ruleSubject)]
        #expect(NumbersFormula.formula(from: nodes, context: Self.context) == nil)
    }

    @Test("Highlighting follows the values as they change")
    func recalculation() throws {
        var workbook = try NumbersReader.workbook(from: document(
            [[.highlighted(50, ruleSet: 1)]], ruleSets: [[Rule(nodes: Self.above(100), fill: Self.red)]]
        ))
        #expect(style("A1", in: workbook.sheets[0]).fillColorHex == nil)
        workbook.sheets[0][CellAddress(a1: "A1")!].value = .number(150)
        workbook.recalculate()
        #expect(style("A1", in: workbook.sheets[0]).fillColorHex == Self.red)
    }

    @Test("Rows inserted above move the highlighting with the cells")
    func insertedRow() throws {
        var workbook = try NumbersReader.workbook(from: document(
            [[.highlighted(150, ruleSet: 1)]], ruleSets: [[Rule(nodes: Self.above(100), fill: Self.red)]]
        ))
        workbook.sheets[0].insertRows(1, at: 0)
        workbook.recalculate()
        #expect(style("A2", in: workbook.sheets[0]).fillColorHex == Self.red)
        #expect(style("A1", in: workbook.sheets[0]).fillColorHex == nil)
    }

    @Test("A document with highlighting saves unchanged, and a cell changed keeps its rules")
    func saving() throws {
        let original = try document(
            [[.highlighted(50, ruleSet: 1)]], ruleSets: [[Rule(nodes: Self.above(100), fill: Self.red)]]
        )
        var (workbook, source) = try NumbersReader.document(from: original)
        let unchanged = try NumbersWriter.fileWrapper(for: workbook, source: source, existing: nil)
        #expect(unchanged.regularFileContents == original)

        workbook.sheets[0][CellAddress(a1: "A1")!].value = .number(150)
        workbook.recalculate()
        let saved = try #require(NumbersWriter.fileWrapper(for: workbook, source: source, existing: nil).regularFileContents)
        let reopened = try NumbersReader.workbook(from: saved)
        #expect(reopened.sheets[0][CellAddress(a1: "A1")!].value == .number(150))
        #expect(style("A1", in: reopened.sheets[0]).fillColorHex == Self.red)
    }

    @Test("Scattered cells come to few ranges covering exactly them")
    func ranges() {
        func cell(_ reference: String) -> CellAddress { CellAddress(a1: reference)! }
        let ranges = NumbersConditionalFormats.ranges(covering: [
            "A1", "B1", "A2", "B2", "D1", "D3",
        ].map(cell))
        #expect(ranges == [
            CellRange(start: cell("A1"), end: cell("B2")),
            CellRange(cell("D1")),
            CellRange(cell("D3")),
        ])
    }
}
