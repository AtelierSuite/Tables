import Foundation
import Testing
@testable import TablesEngine

/// Conditional formats read from a file: which cells they reach, what they
/// change, and that the rules on screen and the XML in a save stay in step.
@Suite("Conditional formats")
struct ConditionalFormatTests {
    private static let red = "FFFF0000"
    private static let blue = "FF0000FF"

    /// `dxf 0` fills red, `1` fills green and bolds, `2` colours text blue.
    private static let dxfs = """
    <dxfs count="3">\
    <dxf><fill><patternFill><bgColor rgb="FFFF0000"/></patternFill></fill></dxf>\
    <dxf><font><b/></font><fill><patternFill><bgColor rgb="FF00FF00"/></patternFill></fill></dxf>\
    <dxf><font><color rgb="FF0000FF"/></font></dxf>\
    </dxfs>
    """

    private func format(_ sqref: String, _ rules: String) -> String {
        "<conditionalFormatting sqref=\"\(sqref)\">\(rules)</conditionalFormatting>"
    }

    private func rule(
        _ type: String, dxf: Int = 0, priority: Int = 1, extra: String = "", _ formulas: String...
    ) -> String {
        "<cfRule type=\"\(type)\" dxfId=\"\(dxf)\" priority=\"\(priority)\" \(extra)>"
            + formulas.map { "<formula>\($0)</formula>" }.joined() + "</cfRule>"
    }

    /// Reads a workbook whose first sheet holds `cells` and `formats`, going
    /// through a real file so the reader is what finds the rules.
    private func workbook(
        cells: [String: CellValue], formats: [String], dxfs: String? = ConditionalFormatTests.dxfs,
        rowCount: Int = 20, columnCount: Int = 5, extraSheet: Bool = false
    ) throws -> Workbook {
        var sheet = Worksheet(name: "Sheet1")
        sheet.rowCount = rowCount
        sheet.columnCount = columnCount
        for (reference, value) in cells {
            sheet[try #require(CellAddress(a1: reference))] = Cell(value: value)
        }
        sheet.preservedElements = formats.map { PreservedElement(name: "conditionalFormatting", xml: $0) }
        var source = Workbook(sheets: extraSheet ? [sheet, Worksheet(name: "Other")] : [sheet])
        if let dxfs { source.preservedPackage.styleSheetElements = [PreservedElement(name: "dxfs", xml: dxfs)] }
        return try XLSXReader.workbook(from: try XLSXWriter.data(from: source))
    }

    private func style(_ reference: String, in workbook: Workbook, sheet: Int = 0) throws -> ConditionalStyle? {
        workbook.sheets[sheet].conditionalStyles[try #require(CellAddress(a1: reference))]
    }

    private func fill(_ reference: String, in workbook: Workbook) throws -> String? {
        try style(reference, in: workbook)?.fillColorHex
    }

    private func sheetXML(of workbook: Workbook) throws -> String {
        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        return String(decoding: try #require(entries["xl/worksheets/sheet1.xml"]), as: UTF8.self)
    }

    // MARK: - Tests

    @Test("A cell value rule styles only the cells that pass")
    func cellValueRule() throws {
        let book = try workbook(
            cells: ["A1": .number(50), "A2": .number(150)],
            formats: [format("A1:A2", rule("cellIs", extra: "operator=\"greaterThan\"", "100"))]
        )
        #expect(try fill("A1", in: book) == nil)
        #expect(try fill("A2", in: book) == Self.red)
    }

    @Test("Between takes both of its operands, inclusively")
    func betweenRule() throws {
        let book = try workbook(
            cells: ["A1": .number(1), "A2": .number(5), "A3": .number(10), "A4": .number(11)],
            formats: [format("A1:A4", rule("cellIs", extra: "operator=\"between\"", "5", "10"))]
        )
        #expect(try fill("A1", in: book) == nil)
        #expect(try fill("A2", in: book) == Self.red)
        #expect(try fill("A3", in: book) == Self.red)
        #expect(try fill("A4", in: book) == nil)
    }

    @Test("A comparison treats a blank as 0 and passes no error")
    func comparisonSemantics() throws {
        let book = try workbook(
            cells: ["A2": .error(.divideByZero)],
            formats: [format("A1:A2", rule("cellIs", extra: "operator=\"lessThan\"", "5"))]
        )
        #expect(try fill("A1", in: book) == Self.red)
        #expect(try fill("A2", in: book) == nil)
    }

    @Test("A formula's relative references move with the cell, and blanks can be styled")
    func formulaRule() throws {
        let book = try workbook(
            cells: ["B1": .number(5), "B2": .number(50)],
            formats: [format("A1:B2", rule("expression", "$B1&gt;10"))]
        )
        #expect(try fill("A1", in: book) == nil)
        #expect(try fill("B1", in: book) == nil)
        #expect(try fill("A2", in: book) == Self.red)
        #expect(try fill("B2", in: book) == Self.red)
        let blank = book.sheets[0].displayedCell(at: try #require(CellAddress(a1: "A2")))
        #expect(blank.isBlank && !blank.isEmptyEntirely)
    }

    @Test("Several ranges share the top-left corner of them all")
    func severalRanges() throws {
        let book = try workbook(
            cells: ["A1": .number(1), "C3": .number(1), "A3": .number(0)],
            formats: [format("C3 A1", rule("expression", "A1=1"))]
        )
        #expect(try fill("A1", in: book) == Self.red)
        #expect(try fill("C3", in: book) == Self.red)
    }

    @Test("A text rule is tested by the formula Excel wrote for it")
    func textRule() throws {
        let book = try workbook(
            cells: ["A1": .text("overdue invoice"), "A2": .text("paid")],
            formats: [format("A1:A2", rule(
                "containsText", extra: "operator=\"containsText\" text=\"overdue\"",
                "NOT(ISERROR(SEARCH(\"overdue\",A1)))"
            ))]
        )
        #expect(try fill("A1", in: book) == Self.red)
        #expect(try fill("A2", in: book) == nil)
    }

    @Test("The first rule to settle a property keeps it, and others fill in the rest")
    func priorityMergesProperties() throws {
        let book = try workbook(
            cells: ["A1": .number(1)],
            formats: [
                format("A1", rule("expression", dxf: 1, priority: 2, "TRUE")),
                format("A1", rule("expression", dxf: 0, priority: 1, "TRUE")
                    + rule("expression", dxf: 2, priority: 3, "TRUE")),
            ]
        )
        let result = try #require(try style("A1", in: book))
        #expect(result.fillColorHex == Self.red)
        #expect(result.isBold == true)
        #expect(result.textColorHex == Self.blue)
    }

    @Test("Stop if true keeps later rules off the cell")
    func stopIfTrue() throws {
        let book = try workbook(
            cells: ["A1": .number(1)],
            formats: [format("A1", rule("expression", dxf: 0, priority: 1, extra: "stopIfTrue=\"1\"", "TRUE")
                + rule("expression", dxf: 2, priority: 2, "TRUE"))]
        )
        #expect(try style("A1", in: book)?.textColorHex == nil)
    }

    @Test("Differential formats read theme colours and switched-off font flags")
    func differentialFormats() throws {
        let dxfs = "<dxfs count=\"1\"><dxf><font><b val=\"0\"/><i/><u/><strike/></font></dxf></dxfs>"
        var book = try workbook(
            cells: ["A1": .number(1)], formats: [format("A1", rule("expression", "TRUE"))], dxfs: dxfs
        )
        let address = try #require(CellAddress(a1: "A1"))
        book.sheets[0][address].style.isBold = true
        let shown = book.sheets[0].displayedCell(at: address).style
        #expect(!shown.isBold)
        #expect(shown.isItalic && shown.isUnderlined && shown.isStruckThrough)
    }

    @Test("Results follow the values on recalculation")
    func recalculation() throws {
        var book = try workbook(
            cells: ["A1": .number(1)],
            formats: [format("A1", rule("cellIs", extra: "operator=\"greaterThan\"", "100"))]
        )
        let address = try #require(CellAddress(a1: "A1"))
        #expect(try fill("A1", in: book) == nil)
        book.sheets[0][address].value = .number(200)
        book.recalculate()
        #expect(try fill("A1", in: book) == Self.red)
        book.sheets[0][address].value = .number(2)
        book.recalculate()
        #expect(try fill("A1", in: book) == nil)
    }

    @Test("A whole column is tested no further than the sheet")
    func wholeColumn() throws {
        let book = try workbook(
            cells: ["A1": .number(1)],
            formats: [format("A1:A1048576", rule("expression", "TRUE"))]
        )
        #expect(book.sheets[0].conditionalStyles.count == book.sheets[0].rowCount)
    }

    @Test("Conditional styles stay out of the cells and the saved styles")
    func staysOutOfStoredStyles() throws {
        let book = try workbook(
            cells: ["A1": .number(1)], formats: [format("A1", rule("expression", "TRUE"))]
        )
        let address = try #require(CellAddress(a1: "A1"))
        #expect(book.sheets[0][address].style.fillColorHex == nil)
        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: book))
        #expect(reopened.sheets[0][address].style.fillColorHex == nil)
        #expect(try fill("A1", in: reopened) == Self.red)
    }

    @Test("Kinds not read here draw nothing but are kept")
    func unreadKinds() throws {
        // One of Excel 2010's icon sets, which has no drawing here.
        let stars = "<cfRule type=\"iconSet\" priority=\"1\"><iconSet iconSet=\"3Stars\"><cfvo type=\"percent\" val=\"0\"/>"
            + "<cfvo type=\"percent\" val=\"33\"/><cfvo type=\"percent\" val=\"67\"/></iconSet></cfRule>"
        let book = try workbook(cells: ["A1": .number(1)], formats: [format("A1:A5", stars)])
        #expect(book.sheets[0].conditionalRules.isEmpty)
        #expect(book.sheets[0].conditionalStyles.isEmpty)
        #expect(try sheetXML(of: book).contains("3Stars"))
    }

    @Test("A rule naming a differential format that is not there is not read")
    func missingDifferentialFormat() throws {
        let book = try workbook(
            cells: ["A1": .number(1)], formats: [format("A1", rule("expression", dxf: 9, "TRUE"))]
        )
        #expect(book.sheets[0].conditionalRules.isEmpty)
    }

    // MARK: - Filling a parsed test

    private func fill(of formula: String) throws -> FormulaFill? {
        let probe = FormulaReferenceShifter.translated(formula, rowDelta: 1, columnDelta: 1)
        return FormulaFill(origin: try FormulaParser.parse(formula), probe: try FormulaParser.parse(probe))
    }

    @Test(
        "A filled test is what parsing the filled text gives",
        arguments: [
            "A1>5", "$A1>5", "A$1>5", "$A$1>5", "(A1)>(100)", "-A1%", "SUM(A1:B2)>0", "SUM($A$1:B2)>0",
            "SUM($A1:B$2)>0", "COUNTIF($A$1:$A$100,A1)>1", "COUNTIF(A:A,A1)>1", "SUM($A:B)>0", "SUM(1:2)>0",
            "SUM($1:2)>0", "Other!A1>0", "'My Sheet'!$B2=A1", "SUM(Jan:Mar!B2)>0", "SUM(Jan:Mar!$B$2:C3)>0",
            "AND(A1>=(5),A1<=(10))", "NOT(ISERROR(SEARCH(\"x\",A1)))", "LEN(TRIM(A1))=0", "$B1=\"late\"",
            "ROW()>1", "MOD(ROW(),2)=0", "TRUE", "1", "IF(A1,,2)", "{1,2;3,A1}=1", "SUM((A1:A3,C1:C3))>0",
            "LET(x,A1,x>1)", "LAMBDA(x,x+A1)(2)>0", "SomeName>A1", "@A1:A5>0", "A1#>0", "A1:INDEX(B:B,3)",
            "A1 B1", "XFD1>0", "A1048576>0", "$XFD$1048576>0", "#REF!>0",
        ]
    )
    func filledMatchesParsedText(formula: String) throws {
        guard let fill = try fill(of: formula) else { return }
        for (rows, columns) in [(0, 0), (1, 0), (0, 1), (1, 1), (7, 3), (250, 40), (100_000, 2_000), (2_000_000, 20_000)] {
            guard let node = fill.node(rowDelta: rows, columnDelta: columns) else { continue }
            let text = FormulaReferenceShifter.translated(formula, rowDelta: rows, columnDelta: columns)
            #expect(node == (try FormulaParser.parse(text)), "\(formula) by \(rows), \(columns) is \(text)")
        }
    }

    @Test("A fill stands aside where only the text can say")
    func fillFallsBack() throws {
        let edge = try #require(try fill(of: "XFD1>0"))
        #expect(edge.node(rowDelta: 0, columnDelta: 0) != nil)
        #expect(edge.node(rowDelta: 0, columnDelta: 1) == nil)
        let crossing = try #require(try fill(of: "SUM($A1:A$5)>0"))
        #expect(crossing.node(rowDelta: 4, columnDelta: 0) != nil)
        #expect(crossing.node(rowDelta: 10, columnDelta: 0) == nil)
    }

    @Test("Cells past where a fill can go are still tested")
    func testedWithoutAFill() throws {
        // Filled down, the range's ends cross: `$A4:A$3` must read as rows 3 and 4.
        let book = try workbook(
            cells: ["A1": .number(1), "A2": .number(1), "A3": .number(1), "A4": .number(1)],
            formats: [format("B1:B4", rule("expression", "SUM($A1:A$2)=2"))]
        )
        #expect(try fill("B1", in: book) == Self.red)
        #expect(try fill("B2", in: book) == nil)
        #expect(try fill("B3", in: book) == Self.red)
        #expect(try fill("B4", in: book) == nil)
    }

    @Test("ROW reports each cell a rule is tested at")
    func rowInATest() throws {
        let book = try workbook(
            cells: ["A1": .number(1)], formats: [format("A1:A4", rule("expression", "MOD(ROW(),2)=0"))]
        )
        #expect(try fill("A1", in: book) == nil)
        #expect(try fill("A2", in: book) == Self.red)
        #expect(try fill("A3", in: book) == nil)
        #expect(try fill("A4", in: book) == Self.red)
    }

    // MARK: - Structural edits

    @Test("An inserted row moves the rule on screen and in the save")
    func insertRow() throws {
        var book = try workbook(
            cells: ["A2": .number(150), "A3": .number(1)],
            formats: [format("A2:A3", rule("expression", "A2&gt;100"))]
        )
        book.sheets[0].insertRows(1, at: 0)
        book.recalculate()
        #expect(try fill("A2", in: book) == nil)
        #expect(try fill("A3", in: book) == Self.red)
        let xml = try sheetXML(of: book)
        #expect(xml.contains("sqref=\"A3:A4\""))
        #expect(xml.contains("A3&gt;100"))
    }

    @Test("A column removed before the range moves it left")
    func removeColumn() throws {
        var book = try workbook(
            cells: ["C1": .number(150)],
            formats: [format("C1", rule("expression", "C1&gt;100"))]
        )
        book.sheets[0].removeColumns(0...0)
        book.recalculate()
        #expect(try fill("B1", in: book) == Self.red)
        #expect(try sheetXML(of: book).contains("sqref=\"B1\""))
    }

    @Test("Removing the row a rule was written for leaves the rest of it working")
    func removeBaseRow() throws {
        var book = try workbook(
            cells: ["A1": .number(1), "A2": .number(150), "A3": .number(2)],
            formats: [format("A1:A3", rule("expression", "A1&gt;100"))]
        )
        book.sheets[0].removeRows(0...0)
        book.recalculate()
        #expect(try fill("A1", in: book) == Self.red)
        #expect(try fill("A2", in: book) == nil)
        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: book))
        #expect(try fill("A1", in: reopened) == Self.red)
        #expect(try fill("A2", in: reopened) == nil)
    }

    @Test("Removing every cell of a rule removes it from the save")
    func removeWholeRange() throws {
        var book = try workbook(
            cells: ["A1": .number(1), "A9": .number(1)],
            formats: [format("A2:A3", rule("expression", "TRUE"))]
        )
        book.sheets[0].removeRows(1...2)
        book.recalculate()
        #expect(book.sheets[0].conditionalRules.isEmpty)
        #expect(!(try sheetXML(of: book).contains("conditionalFormatting")))
    }

    @Test("A range to Excel's last row does not run past it")
    func lastRow() throws {
        var book = try workbook(
            cells: ["A1": .number(1)],
            formats: [format("A1:A1048576", rule("expression", "TRUE"))]
        )
        book.sheets[0].insertRows(1, at: 0)
        #expect(try sheetXML(of: book).contains("sqref=\"A2:A1048576\""))
    }

    @Test("A fragment no edit reaches stays as the file had it")
    func untouchedFragment() throws {
        let fragment = format("A1", rule("expression", "A1&gt;0"))
        var book = try workbook(cells: ["A1": .number(1)], formats: [fragment])
        let kept = try #require(book.sheets[0].preservedElements.first { $0.name == "conditionalFormatting" })
        book.sheets[0].insertRows(1, at: 5)
        #expect(book.sheets[0].preservedElements.first { $0.name == "conditionalFormatting" } == kept)
    }

    @Test("A rule reading another sheet follows that sheet's edits and stays put")
    func followsAnotherSheet() throws {
        var book = try workbook(
            cells: ["A1": .number(1)],
            formats: [format("A1:A2", rule("expression", "Other!A3&gt;100"))],
            extraSheet: true
        )
        let other = book.sheets[1].id
        let value = try #require(CellAddress(a1: "A3"))
        book.sheets[1][value] = Cell(value: .number(150))
        book.recalculate()
        #expect(try fill("A1", in: book) == Self.red)

        let snapshot = book
        book.sheets[1].removeRows(0...0)
        book.chartsFollow(.remove(range: 0...0), axis: .row, on: other, before: snapshot)
        book.recalculate()
        #expect(book.sheets[0].conditionalRules.first?.formulas == ["Other!A2>100"])
        #expect(book.sheets[0].conditionalRules.first?.ranges == [try #require(CellRange(a1Range: "A1:A2"))])
        #expect(try fill("A1", in: book) == Self.red)
        #expect(try sheetXML(of: book).contains("Other!A2&gt;100"))
    }
}
