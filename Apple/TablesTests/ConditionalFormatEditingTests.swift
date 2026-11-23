import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

@MainActor
@Suite("Editing conditional formats")
struct ConditionalFormatEditingTests {
    private func range(_ a1: String) -> CellRange { ConditionalRule.ranges(sqref: a1)[0] }
    private func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }

    private func reopened(_ workbook: Workbook) throws -> Workbook {
        try XLSXReader.workbook(from: try XLSXWriter.data(from: workbook))
    }

    private func numbers(_ values: [Double], in column: String = "A") -> Workbook {
        var workbook = Workbook()
        for (offset, value) in values.enumerated() {
            workbook.sheets[0][address("\(column)\(offset + 1)")] = Cell(value: .number(value))
        }
        workbook.recalculate()
        return workbook
    }

    @Test("Every kind of rule the editor makes survives a save")
    func everyKindRoundTrips() throws {
        var workbook = numbers([1, 5, 10, 20])
        let red = ConditionalStyle(fillColorHex: "FFFFC7CE", textColorHex: "FF9C0006")
        let rules = [
            ConditionalRule(ranges: [range("A1:A4")], comparison: .greaterThan, formulas: ["5"], priority: 0, style: red),
            ConditionalRule(ranges: [range("A1:A4")], comparison: .between, formulas: ["1", "\"x\""], priority: 0,
                            stopsIfTrue: true, style: ConditionalStyle(isBold: true, isItalic: false)),
            ConditionalRule(ranges: [range("A1:A4"), range("C1")], formulas: ["A1>B1"], priority: 0,
                            style: ConditionalStyle(isUnderlined: true, isStruckThrough: true)),
            ConditionalRule(ranges: [range("A1:A4")], kind: .rank(count: 2, isPercent: true, isBottom: true), priority: 0, style: red),
            ConditionalRule(ranges: [range("A1:A4")], kind: .average(isAbove: false, includesEqual: true, deviations: 1),
                            priority: 0, style: red),
            ConditionalRule(ranges: [range("A1:A4")], kind: .duplicates(isUnique: true), priority: 0, style: red),
            ConditionalRule(ranges: [range("B1:B4")], kind: .colorScale(
                thresholds: [.init(kind: .minimum), .init(kind: .percentile, value: "50"), .init(kind: .maximum)],
                colors: ["FFF8696B", "FFFFEB84", "FF63BE7B"]), priority: 0),
            ConditionalRule(ranges: [range("B1:B4")], kind: .dataBar(ConditionalDataBar(
                colorHex: "FF638EC6", minimumLength: 0, maximumLength: 100, showsValue: false)), priority: 0),
            ConditionalRule(ranges: [range("B1:B4")], kind: .iconSet(ConditionalIconSet(
                name: "3Arrows", thresholds: [.init(kind: .percent, value: "0"), .init(kind: .percent, value: "33"),
                                              .init(kind: .number, value: "10", isInclusive: false)],
                isReversed: true, showsValue: false)), priority: 0),
        ]
        workbook.setConditionalRules(rules, sheetIndex: 0)
        #expect(workbook.sheets[0].conditionalRules.map(\.priority) == Array(1...rules.count))

        let back = try reopened(workbook).sheets[0].conditionalRules
        #expect(back == workbook.sheets[0].conditionalRules)
    }

    @Test("Edited rules replace the file's own, which no longer reach the cells")
    func editsReplaceTheFile() throws {
        var source = numbers([50, 150])
        source.sheets[0].preservedElements = [PreservedElement(
            name: "conditionalFormatting",
            xml: "<conditionalFormatting sqref=\"A1:A2\"><cfRule type=\"cellIs\" dxfId=\"0\" priority=\"1\" "
                + "operator=\"greaterThan\"><formula>100</formula></cfRule></conditionalFormatting>")]
        source.preservedPackage.styleSheetElements = [PreservedElement(
            name: "dxfs", xml: "<dxfs count=\"1\"><dxf><fill><patternFill><bgColor rgb=\"FFFF0000\"/></patternFill></fill></dxf></dxfs>")]
        var workbook = try reopened(source)
        #expect(workbook.sheets[0].conditionalStyles[address("A2")]?.fillColorHex == "FFFF0000")

        var rule = workbook.sheets[0].conditionalRules[0]
        rule.comparison = .lessThan
        rule.style = ConditionalStyle(fillColorHex: "FF00FF00")
        workbook.setConditionalRules([rule], sheetIndex: 0)
        #expect(workbook.sheets[0].conditionalStyles[address("A1")]?.fillColorHex == "FF00FF00")
        #expect(workbook.sheets[0].conditionalStyles[address("A2")] == nil)

        let back = try reopened(workbook)
        #expect(back.sheets[0].conditionalRules.count == 1)
        #expect(back.sheets[0].conditionalStyles[address("A1")]?.fillColorHex == "FF00FF00")
        #expect(back.sheets[0].conditionalStyles[address("A2")] == nil)
        // The format the file had stays where it was, for whatever else points at it.
        #expect(back.preservedPackage.styleSheetElements.first { $0.name == "dxfs" }?.xml.contains("FFFF0000") == true)
    }

    @Test("Rules that look alike share one differential format")
    func sharedDifferentialFormats() {
        var workbook = numbers([1])
        let style = ConditionalStyle(fillColorHex: "FFFFC7CE")
        workbook.setConditionalRules([
            ConditionalRule(ranges: [range("A1")], comparison: .equal, formulas: ["1"], priority: 0, style: style),
            ConditionalRule(ranges: [range("A2")], comparison: .equal, formulas: ["2"], priority: 0, style: style),
        ], sheetIndex: 0)
        workbook.setConditionalRules(workbook.sheets[0].conditionalRules, sheetIndex: 0)
        let table = workbook.preservedPackage.styleSheetElements.first { $0.name == "dxfs" }?.xml ?? ""
        #expect(table.components(separatedBy: "<dxf>").count == 2)
        #expect(table.contains("count=\"1\""))
    }

    @Test("Clearing every rule takes the formats out of the save")
    func clearingRules() throws {
        var workbook = numbers([1])
        workbook.setConditionalRules(
            [ConditionalRule(ranges: [range("A1")], kind: .duplicates(isUnique: false), priority: 0,
                             style: ConditionalStyle(isBold: true))], sheetIndex: 0)
        workbook.setConditionalRules([], sheetIndex: 0)
        #expect(workbook.sheets[0].conditionalStyles.isEmpty)
        #expect(try reopened(workbook).sheets[0].conditionalRules.isEmpty)
    }

    @Test("Excel 2010's copies of the formats go once the rules are edited")
    func extendedFormatsDropped() {
        var workbook = numbers([1])
        workbook.sheets[0].preservedElements = [PreservedElement(
            name: "extLst",
            xml: "<extLst><ext uri=\"{78C0D931-6437-407d-A8EE-F0AAD5D6F7CB}\" "
                + "xmlns:x14=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/main\">"
                + "<x14:conditionalFormattings/></ext><ext uri=\"{05C60535-1F16-4fd2-B633-F4F36F0B64E0}\"><other/></ext></extLst>")]
        workbook.setConditionalRules([], sheetIndex: 0)
        let ext = workbook.sheets[0].preservedElements.first { $0.name == "extLst" }?.xml ?? ""
        #expect(!ext.contains("conditionalFormattings"))
        #expect(ext.contains("<other/>"))
    }

    // MARK: - The editor's draft

    @Test("The editor writes formatting and validation as one change, and leaves alone what it did not touch")
    func applyingADraft() {
        var workbook = numbers([1, 2, 3])
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        state.select(address("A1"), in: workbook.sheets[0])
        state.select(address("A3"), extending: true, in: workbook.sheets[0])

        var draft = state.cellRulesDraft(in: workbook)
        #expect(!draft.formattingChanged && !draft.validationChanged)
        draft.rules.append(DraftRule(rule: ConditionalRulePreset.greaterThan.rule(over: draft.selection)))
        draft.rules[0].rule.formulas = ["1"]
        var validation = ValidationDraft(rule: DataValidation(ranges: [], kind: .whole))
        validation.first = "1"
        validation.second = "2"
        draft.validation = validation
        #expect(draft.isComplete)

        let snapshot = RulePreviewSnapshot.make(draft: draft, workbook: workbook, sheetIndex: 0)
        #expect(snapshot.failing == [address("A3")])
        #expect(snapshot.workbook.sheets[0].conditionalStyles.keys.sorted() == [address("A2"), address("A3")])
        // A preview changes nothing.
        #expect(workbook.sheets[0].conditionalRules.isEmpty)

        state.applyCellRules(draft, in: &workbook)
        #expect(workbook.sheets[0].conditionalRules.count == 1)
        #expect(workbook.sheets[0].dataValidations.map(\.ranges) == [[range("A1:A3")]])
        #expect(workbook.sheets[0].conditionalStyles[address("A2")]?.fillColorHex == "FFFFC7CE")

        let unchanged = state.cellRulesDraft(in: workbook)
        #expect(!unchanged.formattingChanged && !unchanged.validationChanged)
    }

    @Test("Every preset makes a rule that reads back as the kind it offers")
    func presets() {
        let ranges = [range("B2:B10")]
        for preset in ConditionalRulePreset.allCases {
            let rule = preset.rule(over: ranges)
            #expect(rule.ranges == ranges)
            if case .test = rule.kind { #expect(!rule.formulas.isEmpty, "\(preset)") }
        }
        #expect(ConditionalRulePreset.textContains.rule(over: ranges).formulas == ["ISNUMBER(SEARCH(\"text\",B2))"])
    }

    @Test("Typed ranges are read with commas, spaces and dollar signs, and refused when malformed")
    func typedRanges() {
        #expect(CellRuleText.parseRanges("$b$2:b10, d4") == [range("B2:B10"), range("D4")])
        #expect(CellRuleText.parseRanges("B2:B10 nope") == nil)
        #expect(CellRuleText.parseRanges("  ") == nil)
    }
}
