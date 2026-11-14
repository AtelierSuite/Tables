import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Data validation: reading the rules from a workbook, keeping them through
/// a save, testing entries against them, and editing them.
@Suite("Data validation")
@MainActor
struct DataValidationTests {

    // MARK: - Package construction

    /// A two-sheet workbook: `Sheet1` with numbers down column A, a zero in H1, and
    /// `sheetBody` after its cells, and `Lists` with three fruits in A1:A3.
    private func package(sheetBody: String) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/worksheets/sheet2.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="xl/workbook.xml"/></Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/>\
        <sheet name="Lists" sheetId="2" r:id="rId2"/></sheets></workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet2.xml"/></Relationships>
        """
        var rows = ""
        for row in 1...12 {
            // A cell in column H makes the grid wide enough for every rule.
            let wide = row == 1 ? "<c r=\"H1\"><v>0</v></c>" : ""
            rows += "<row r=\"\(row)\"><c r=\"A\(row)\"><v>\(row)</v></c>\(wide)</row>"
        }
        let namespaces = """
        xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        """
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet \(namespaces)><sheetData>\(rows)</sheetData>\(sheetBody)</worksheet>
        """
        var fruit = ""
        for (index, name) in ["Apple", "Banana", "Cherry"].enumerated() {
            fruit += "<row r=\"\(index + 1)\"><c r=\"A\(index + 1)\" t=\"inlineStr\"><is><t>\(name)</t></is></c></row>"
        }
        let lists = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet \(namespaces)><sheetData>\(fruit)</sheetData></worksheet>
        """
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
            ("xl/worksheets/sheet2.xml", Data(lists.utf8)),
        ])
    }

    /// Four rules in the main list, given after the page margins so that
    /// echoing the input back could not put them in schema order.
    private static let mainRules = """
    <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>\
    <dataValidations count="4">\
    <dataValidation type="list" allowBlank="1" showInputMessage="1" showErrorMessage="1" \
    errorTitle="Not a size" error="Pick S, M or L." promptTitle="Size" prompt="Choose a size" sqref="B2:B10">\
    <formula1>"S,M,L"</formula1></dataValidation>\
    <dataValidation type="whole" errorStyle="warning" allowBlank="1" showErrorMessage="1" sqref="C2:C10 E2">\
    <formula1>1</formula1><formula2>10</formula2></dataValidation>\
    <dataValidation type="decimal" operator="greaterThan" showDropDown="1" sqref="D2:D10">\
    <formula1>A2</formula1></dataValidation>\
    <dataValidation type="textLength" operator="lessThanOrEqual" errorStyle="information" \
    showErrorMessage="1" imeMode="hiragana" sqref="F2"><formula1>5</formula1></dataValidation>\
    </dataValidations>
    """

    /// The Excel 2010 form, for a list on another sheet, beside an
    /// extension that has nothing to do with validation.
    private static let extensionRules = """
    <extLst><ext uri="{CCE6A557-97BC-4b89-ADB6-D9C93CAAB3DF}" \
    xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">\
    <x14:dataValidations count="1" xmlns:xm="http://schemas.microsoft.com/office/excel/2006/main">\
    <x14:dataValidation type="list" allowBlank="1" showInputMessage="1" showErrorMessage="1">\
    <x14:formula1><xm:f>Lists!$A$1:$A$3</xm:f></x14:formula1><xm:sqref>G2:G10</xm:sqref>\
    </x14:dataValidation></x14:dataValidations></ext>\
    <ext uri="{05C60535-1F16-4fd2-B633-F4F36F0B64E0}" \
    xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">\
    <x14:sparklineGroups xmlns:xm="http://schemas.microsoft.com/office/excel/2006/main">\
    <x14:sparklineGroup><x14:sparklines><x14:sparkline><xm:f>Sheet1!A1:A5</xm:f><xm:sqref>H1</xm:sqref>\
    </x14:sparkline></x14:sparklines></x14:sparklineGroup></x14:sparklineGroups></ext></extLst>
    """

    private func open(_ body: String = mainRules + extensionRules) throws -> Workbook {
        try XLSXReader.workbook(from: try package(sheetBody: body))
    }

    private func savedSheet(_ workbook: Workbook) throws -> String {
        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        return String(decoding: try #require(entries["xl/worksheets/sheet1.xml"]), as: UTF8.self)
    }

    private func address(_ a1: String) -> CellAddress { CellAddress(a1: a1)! }
    private func range(_ a1: String) -> CellRange { ConditionalRule.ranges(sqref: a1)[0] }

    /// Whether typing `text` into a cell of the first sheet is turned away.
    private func isRefused(_ text: String, at a1: String, in workbook: Workbook) -> Bool {
        let cell = CellInputParser.cell(from: text, inheriting: .default)
        return workbook.dataValidationFailure(entering: cell, at: address(a1), sheetIndex: 0) != nil
    }

    // MARK: - Reading

    @Test("Rules are read from the main list and from the Excel 2010 extension")
    func readsRules() throws {
        let rules = try open().sheets[0].dataValidations
        try #require(rules.count == 5)

        let list = rules[0]
        #expect(list.kind == .list)
        #expect(list.ranges == [range("B2:B10")])
        #expect(list.formula1 == "\"S,M,L\"")
        #expect(list.literalItems == ["S", "M", "L"])
        #expect(list.allowsBlank && list.showsDropDown && list.showsInputMessage && list.showsErrorMessage)
        #expect(list.alertStyle == .stop)
        #expect(list.errorTitle == "Not a size")
        #expect(list.errorMessage == "Pick S, M or L.")
        #expect(list.promptTitle == "Size")
        #expect(list.promptMessage == "Choose a size")

        let whole = rules[1]
        #expect(whole.kind == .whole)
        #expect(whole.comparison == .between)
        #expect(whole.ranges == [range("C2:C10"), range("E2")])
        #expect(whole.formula1 == "1" && whole.formula2 == "10")
        #expect(whole.alertStyle == .warning)

        let decimal = rules[2]
        #expect(decimal.kind == .decimal)
        #expect(decimal.comparison == .greaterThan)
        // `showDropDown` says the opposite of its name.
        #expect(!decimal.showsDropDown)
        #expect(!decimal.showsErrorMessage && !decimal.allowsBlank)

        let length = rules[3]
        #expect(length.kind == .textLength)
        #expect(length.comparison == .lessThanOrEqual)
        #expect(length.alertStyle == .information)
        #expect(length.imeMode == "hiragana")

        let remote = rules[4]
        #expect(remote.kind == .list)
        #expect(remote.ranges == [range("G2:G10")])
        #expect(remote.formula1 == "Lists!$A$1:$A$3")
        #expect(remote.literalItems == nil)
    }

    @Test("A workbook with validation rules no longer reports them as unsupported")
    func rulesAreNotReportedAsUnsupported() throws {
        let workbook = try open(Self.mainRules)
        #expect(workbook.unsupportedFeatures.isEmpty)
    }

    // MARK: - Saving

    @Test("Rules survive a save, once, in schema order, with the other extensions kept")
    func roundTrip() throws {
        let workbook = try open()
        let sheet = try savedSheet(workbook)

        // Both lists come back as the one element, between the cells and the margins.
        #expect(sheet.components(separatedBy: "<dataValidations").count == 2)
        #expect(sheet.contains("<dataValidations count=\"5\">"))
        let data = try #require(sheet.range(of: "</sheetData>"))
        let rules = try #require(sheet.range(of: "<dataValidations"))
        let margins = try #require(sheet.range(of: "<pageMargins"))
        #expect(data.lowerBound < rules.lowerBound && rules.lowerBound < margins.lowerBound)

        #expect(sheet.contains("<formula1>&quot;S,M,L&quot;</formula1>"))
        #expect(sheet.contains("errorTitle=\"Not a size\""))
        #expect(sheet.contains("prompt=\"Choose a size\""))
        #expect(sheet.contains("errorStyle=\"warning\""))
        #expect(sheet.contains("sqref=\"C2:C10 E2\""))
        #expect(sheet.contains("<formula1>Lists!$A$1:$A$3</formula1>"))
        #expect(sheet.contains("imeMode=\"hiragana\""))
        // The validation extension is gone; the sparklines beside it stay.
        #expect(!sheet.contains("CCE6A557"))
        #expect(sheet.contains("sparklineGroups"))

        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: workbook))
        #expect(reopened.sheets[0].dataValidations == workbook.sheets[0].dataValidations)
    }

    @Test("Messages with line breaks and quotes come back as written")
    func messagesKeepLineBreaks() throws {
        var workbook = Workbook()
        workbook.sheets[0].dataValidations = [DataValidation(
            ranges: [range("A1")], kind: .custom, formula1: "LEN(A1)>2",
            errorTitle: "\"Too short\"", errorMessage: "Line one\nLine two & more",
            promptTitle: "<Hint>", promptMessage: "At least 3")]
        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: workbook))
        #expect(reopened.sheets[0].dataValidations == workbook.sheets[0].dataValidations)
    }

    @Test("A sheet without rules writes no validation element")
    func noRulesNoElement() throws {
        let sheet = try savedSheet(try open(""))
        #expect(!sheet.contains("dataValidation"))
    }

    // MARK: - Testing entries

    @Test("A typed list takes its entries to the letter, and blanks")
    func literalList() throws {
        let workbook = try open()
        #expect(!isRefused("M", at: "B2", in: workbook))
        #expect(isRefused("m", at: "B2", in: workbook))
        #expect(isRefused("XL", at: "B5", in: workbook))
        #expect(!isRefused("", at: "B2", in: workbook))
        // Outside the rule's cells nothing is checked.
        #expect(!isRefused("XL", at: "B11", in: workbook))
        #expect(workbook.dataValidationItems(
            for: workbook.sheets[0].dataValidations[0], at: address("B2"), sheetIndex: 0) == ["S", "M", "L"])
    }

    @Test("A list read from cells on another sheet matches without regard to case")
    func rangeList() throws {
        let workbook = try open()
        let rule = workbook.sheets[0].dataValidations[4]
        #expect(workbook.dataValidationItems(for: rule, at: address("G4"), sheetIndex: 0)
                == ["Apple", "Banana", "Cherry"])
        #expect(!isRefused("Banana", at: "G4", in: workbook))
        #expect(!isRefused("banana", at: "G4", in: workbook))
        #expect(isRefused("Durian", at: "G4", in: workbook))
    }

    @Test("A numeric list offers its numbers as they are shown, and takes them as numbers")
    func numericList() throws {
        var workbook = Workbook()
        workbook.sheets[0][address("D1")] = CellInputParser.cell(from: "0.5", inheriting: .default)
        workbook.sheets[0][address("D1")].style.numberFormat = NumberFormatPreset.percent.code
        workbook.sheets[0][address("D2")] = CellInputParser.cell(from: "0.75", inheriting: .default)
        workbook.sheets[0][address("D2")].style.numberFormat = NumberFormatPreset.percent.code
        let rule = DataValidation(ranges: [range("A1")], kind: .list, formula1: "$D$1:$D$3")
        workbook.sheets[0].dataValidations = [rule]
        // The blank third cell is not offered.
        #expect(workbook.dataValidationItems(for: rule, at: address("A1"), sheetIndex: 0) == ["50%", "75%"])
        #expect(!isRefused("50%", at: "A1", in: workbook))
        #expect(!isRefused("0.75", at: "A1", in: workbook))
        #expect(isRefused("0.6", at: "A1", in: workbook))
    }

    @Test("Whole numbers, decimals and text lengths are compared as the rule says")
    func comparisons() throws {
        let workbook = try open()
        // Whole number between 1 and 10.
        #expect(!isRefused("1", at: "C2", in: workbook))
        #expect(!isRefused("10", at: "E2", in: workbook))
        #expect(isRefused("11", at: "C2", in: workbook))
        #expect(isRefused("2.5", at: "C2", in: workbook))
        #expect(isRefused("two", at: "C2", in: workbook))
        // A formula is judged by what it comes to.
        #expect(!isRefused("=2+3", at: "C3", in: workbook))
        #expect(isRefused("=A12*2", at: "C3", in: workbook))
        // Text of at most five characters.
        #expect(!isRefused("abcde", at: "F2", in: workbook))
        #expect(isRefused("abcdef", at: "F2", in: workbook))
        #expect(!isRefused("12345", at: "F2", in: workbook))
        // The decimal rule has its alert switched off, so it lets anything by.
        #expect(!isRefused("-5", at: "D2", in: workbook))
    }

    @Test("A rule's formulas move with the cell they are read for")
    func relativeOperands() throws {
        var workbook = try open()
        // Greater than the number beside it in column A: A2 is 2, A9 is 9.
        workbook.sheets[0].dataValidations[2].showsErrorMessage = true
        #expect(!isRefused("2.5", at: "D2", in: workbook))
        #expect(isRefused("2.5", at: "D9", in: workbook))
        #expect(!isRefused("9.5", at: "D9", in: workbook))
    }

    @Test("Every comparison passes and fails where it should")
    func everyComparison() {
        let cases: [(DataValidation.Comparison, pass: String, fail: String)] = [
            (.between, "5", "11"), (.notBetween, "11", "5"), (.equal, "3", "4"), (.notEqual, "4", "3"),
            (.greaterThan, "4", "3"), (.lessThan, "2", "3"), (.greaterThanOrEqual, "3", "2"),
            (.lessThanOrEqual, "3", "4"),
        ]
        for (comparison, pass, fail) in cases {
            var workbook = Workbook()
            workbook.sheets[0].dataValidations = [DataValidation(
                ranges: [range("A1")], kind: .decimal, comparison: comparison, formula1: "3", formula2: "10")]
            #expect(!isRefused(pass, at: "A1", in: workbook), "\(comparison) should take \(pass)")
            #expect(isRefused(fail, at: "A1", in: workbook), "\(comparison) should refuse \(fail)")
        }
    }

    @Test("Dates and times are tested as the numbers they are")
    func datesAndTimes() {
        var workbook = Workbook()
        workbook.sheets[0].dataValidations = [
            DataValidation(ranges: [range("A1")], kind: .date, comparison: .greaterThanOrEqual, formula1: "DATE(2026,1,1)"),
            DataValidation(ranges: [range("B1")], kind: .time, comparison: .lessThan, formula1: "0.5"),
        ]
        #expect(!isRefused("=DATE(2026,6,1)", at: "A1", in: workbook))
        #expect(isRefused("=DATE(2025,6,1)", at: "A1", in: workbook))
        #expect(isRefused("someday", at: "A1", in: workbook))
        #expect(!isRefused("0.25", at: "B1", in: workbook))
        #expect(isRefused("0.75", at: "B1", in: workbook))
    }

    @Test("A custom formula sees the entry in its cell, wherever in the range that is")
    func customFormula() {
        var workbook = Workbook()
        workbook.sheets[0][address("A1")] = CellInputParser.cell(from: "10", inheriting: .default)
        workbook.sheets[0][address("A2")] = CellInputParser.cell(from: "20", inheriting: .default)
        // No more than the number to the left.
        workbook.sheets[0].dataValidations = [
            DataValidation(ranges: [range("B1:B2")], kind: .custom, formula1: "B1<=A1")
        ]
        #expect(!isRefused("10", at: "B1", in: workbook))
        #expect(isRefused("11", at: "B1", in: workbook))
        #expect(!isRefused("11", at: "B2", in: workbook))
        #expect(isRefused("21", at: "B2", in: workbook))
    }

    @Test("A rule that only shows a message refuses nothing")
    func anyValue() {
        var workbook = Workbook()
        let rule = DataValidation(ranges: [range("A1")], kind: .any, promptTitle: "Note", promptMessage: "Anything")
        workbook.sheets[0].dataValidations = [rule]
        #expect(!isRefused("whatever", at: "A1", in: workbook))
        #expect(rule.hasInputMessage)
        #expect(!DataValidation(ranges: [range("A1")], kind: .any).hasInputMessage)
    }

    @Test("A merged cell answers to the rule on its first cell")
    func mergedCell() {
        var workbook = Workbook()
        workbook.sheets[0].merge(range("A1:B2"))
        workbook.sheets[0].dataValidations = [
            DataValidation(ranges: [range("A1")], kind: .list, formula1: "\"Yes,No\"")
        ]
        #expect(workbook.sheets[0].dataValidation(at: address("B2"))?.kind == .list)
    }

    // MARK: - Rows and columns

    @Test("Rules follow rows inserted and removed, their formulas with them")
    func rulesFollowRows() throws {
        var workbook = try open()
        workbook.sheets[0].insertRows(2, at: 0)
        var rules = workbook.sheets[0].dataValidations
        #expect(rules[0].ranges == [range("B4:B12")])
        #expect(rules[1].ranges == [range("C4:C12"), range("E4")])
        #expect(rules[2].formula1 == "A4")

        // Taking away the row the one-cell rules stand on takes them too.
        workbook.sheets[0].removeRows(3...3)
        rules = workbook.sheets[0].dataValidations
        #expect(rules.count == 4)
        #expect(rules[0].ranges == [range("B4:B11")])
        #expect(rules[1].ranges == [range("C4:C11")])
        #expect(!rules.contains { $0.kind == .textLength })

        let sheet = try savedSheet(workbook)
        #expect(sheet.contains("sqref=\"B4:B11\""))
        #expect(sheet.contains("<dataValidations count=\"4\">"))
    }

    @Test("Rules follow columns inserted and removed")
    func rulesFollowColumns() throws {
        var workbook = try open()
        workbook.sheets[0].insertColumns(1, at: 0)
        #expect(workbook.sheets[0].dataValidations[0].ranges == [range("C2:C10")])
        #expect(workbook.sheets[0].dataValidations[2].formula1 == "B2")
        workbook.sheets[0].removeColumns(2...2)
        #expect(workbook.sheets[0].dataValidations.count == 4)
        #expect(workbook.sheets[0].dataValidations[0].kind == .whole)
    }

    @Test("A list on another sheet follows rows inserted above it there")
    func listFollowsItsSheet() throws {
        var workbook = try open()
        let before = workbook
        let lists = workbook.sheets[1].id
        workbook.sheets[1].insertRows(1, at: 0)
        workbook.chartsFollow(.insert(index: 0, count: 1), axis: .row, on: lists, before: before)
        workbook.recalculate()
        let rule = workbook.sheets[0].dataValidations[4]
        #expect(rule.formula1 == "Lists!$A$2:$A$4")
        #expect(rule.ranges == [range("G2:G10")])
        #expect(workbook.dataValidationItems(for: rule, at: address("G2"), sheetIndex: 0)
                == ["Apple", "Banana", "Cherry"])
    }

    // MARK: - Editing rules

    @Test("A new rule takes its cells from the rules that had them")
    func settingARuleCarvesOthers() {
        var sheet = Worksheet(name: "Sheet1")
        sheet.dataValidations = [
            DataValidation(ranges: [range("A1:C5")], kind: .decimal, comparison: .greaterThan, formula1: "A1")
        ]
        let list = DataValidation(ranges: [], kind: .list, formula1: "\"a,b\"")
        sheet.setDataValidation(list, for: [range("A1:B2")])

        #expect(sheet.dataValidations.count == 2)
        #expect(sheet.dataValidation(at: address("A1"))?.kind == .list)
        #expect(sheet.dataValidation(at: address("B2"))?.kind == .list)
        #expect(sheet.dataValidation(at: address("C1"))?.kind == .decimal)
        #expect(sheet.dataValidation(at: address("A3"))?.kind == .decimal)
        // The corner of what is left is still A1, so each cell is still
        // compared with itself.
        let old = sheet.dataValidations[0]
        #expect(old.base == address("A1"))
        #expect(old.formula(old.formula1, at: address("A3")) == "A3")
        #expect(old.formula(old.formula1, at: address("C2")) == "C2")
        #expect(Set(old.ranges) == [range("C1:C2"), range("A3:C5")])
    }

    @Test("Clearing takes the rule off the cells, and away when none are left")
    func clearingARule() {
        var sheet = Worksheet(name: "Sheet1")
        sheet.dataValidations = [DataValidation(ranges: [range("A1:A4")], kind: .list, formula1: "\"a,b\"")]
        sheet.setDataValidation(nil, for: [range("A2:A3")])
        #expect(sheet.dataValidations[0].ranges == [range("A1"), range("A4")])
        sheet.setDataValidation(nil, for: [range("A1:A10")])
        #expect(sheet.dataValidations.isEmpty)
    }

    @Test("What is typed into the rule editor becomes a formula and reads back the same")
    func editorInput() {
        #expect(DataValidation.formula(fromInput: "Yes, No ,Maybe", kind: .list) == "\"Yes,No,Maybe\"")
        #expect(DataValidation.formula(fromInput: "=$D$1:$D$5", kind: .list) == "$D$1:$D$5")
        #expect(DataValidation.formula(fromInput: " 10 ", kind: .whole) == "10")
        #expect(DataValidation.formula(fromInput: "50%", kind: .decimal) == "0.5")
        #expect(DataValidation.formula(fromInput: "=TODAY()", kind: .date) == "TODAY()")
        #expect(DataValidation.formula(fromInput: "A1>0", kind: .custom) == "A1>0")
        #expect(DataValidation.formula(fromInput: "  ", kind: .whole) == nil)

        #expect(DataValidation.input(for: "\"Yes,No,Maybe\"") == "Yes,No,Maybe")
        #expect(DataValidation.input(for: "$D$1:$D$5") == "=$D$1:$D$5")
        #expect(DataValidation.input(for: "10") == "10")
        #expect(DataValidation.input(for: nil) == "")
    }

    // MARK: - In the editor

    private func editor(_ rule: DataValidation) -> (EditorState, Workbook) {
        var workbook = Workbook()
        workbook.sheets[0].dataValidations = [rule]
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        state.refreshMetrics(in: workbook)
        return (state, workbook)
    }

    private func type(_ text: String, into a1: String, _ state: EditorState, _ workbook: inout Workbook) {
        state.beginEditing(address(a1), in: workbook, replacingWith: text)
        state.commitEditing(in: &workbook)
    }

    @Test("A stop rule keeps a failed entry out, stays on the cell and raises its own alert")
    func stopRefusesEntry() {
        var (state, workbook) = editor(DataValidation(
            ranges: [range("A1")], kind: .list, formula1: "\"Yes,No\"",
            errorTitle: "Yes or no", errorMessage: "Answer the question."))

        type("Maybe", into: "A1", state, &workbook)
        #expect(workbook.sheets[0][address("A1")].value == .empty)
        #expect(state.editingAddress == nil)
        #expect(state.selectedAddress == address("A1"))
        let alert = state.validationAlert
        #expect(alert?.style == .stop)
        #expect(alert?.title == "Yes or no")
        #expect(alert?.message == "Answer the question.")
        #expect(alert?.offersKeeping == false)

        // A stop cannot be overridden.
        if let alert { state.keepEntry(of: alert, in: &workbook) }
        #expect(workbook.sheets[0][address("A1")].value == .empty)

        state.validationAlert = nil
        type("Yes", into: "A1", state, &workbook)
        #expect(workbook.sheets[0][address("A1")].value == .text("Yes"))
        #expect(state.validationAlert == nil)
        // A good entry moves on as usual.
        #expect(state.selectedAddress == address("A2"))
    }

    @Test("A warning holds the entry back until the person keeps it")
    func warningKeepsOnRequest() throws {
        var (state, workbook) = editor(DataValidation(
            ranges: [range("A1")], kind: .whole, comparison: .lessThan, formula1: "10", alertStyle: .warning))

        type("25", into: "A1", state, &workbook)
        #expect(workbook.sheets[0][address("A1")].value == .empty)
        let alert = try #require(state.validationAlert)
        #expect(alert.style == .warning)
        #expect(alert.offersKeeping)
        // With no message of its own the rule falls back on the app's.
        #expect(!alert.title.isEmpty && !alert.message.isEmpty)

        state.keepEntry(of: alert, in: &workbook)
        #expect(workbook.sheets[0][address("A1")].value == .number(25))
    }

    @Test("The selected cell offers its list and its input message")
    func dropDownAndInputMessage() {
        var (state, workbook) = editor(DataValidation(
            ranges: [range("A1:A3")], kind: .list, formula1: "\"Red,Green\"",
            promptTitle: "Colour", promptMessage: "Pick one"))

        state.select(address("A2"), in: workbook.sheets[0])
        #expect(state.dropDownItems(in: workbook) == ["Red", "Green"])
        #expect(state.inputMessage(in: workbook)?.title == "Colour")
        #expect(state.inputMessage(in: workbook)?.message == "Pick one")

        state.enter("Green", in: &workbook)
        #expect(workbook.sheets[0][address("A2")].value == .text("Green"))
        #expect(state.selectedAddress == address("A2"))

        state.select(address("B2"), in: workbook.sheets[0])
        #expect(state.dropDownItems(in: workbook) == nil)
        #expect(state.inputMessage(in: workbook) == nil)

        // A list with its arrow hidden still checks entries, but offers nothing.
        workbook.sheets[0].dataValidations[0].showsDropDown = false
        state.select(address("A2"), in: workbook.sheets[0])
        #expect(state.dropDownItems(in: workbook) == nil)
    }

    @Test("The rule editor's result is set on, and cleared from, every selected range")
    func editingRulesFromTheSelection() {
        var workbook = Workbook()
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        state.select(address("A1"), in: workbook.sheets[0])
        state.select(address("B3"), extending: true, in: workbook.sheets[0])

        state.setDataValidation(DataValidation(ranges: [], kind: .list, formula1: "\"a,b\""), in: &workbook)
        #expect(workbook.sheets[0].dataValidations.map(\.ranges) == [[range("A1:B3")]])
        #expect(state.selectedDataValidation(in: workbook)?.kind == .list)

        state.setDataValidation(nil, in: &workbook)
        #expect(workbook.sheets[0].dataValidations.isEmpty)

        // A document with nowhere to keep rules has none to show or enforce.
        state.setDataValidation(DataValidation(ranges: [], kind: .list, formula1: "\"a,b\""), in: &workbook)
        state.allowsDataValidation = false
        #expect(state.selectedDataValidation(in: workbook) == nil)
        type("zzz", into: "A1", state, &workbook)
        #expect(workbook.sheets[0][address("A1")].value == .text("zzz"))
    }
}
