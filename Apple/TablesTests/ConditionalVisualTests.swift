import Foundation
import Testing
@testable import TablesEngine

/// Conditional formats that measure a cell against the rest of its range:
/// ranking rules, colour scales, data bars and icon sets.
@Suite("Conditional formats over a range")
struct ConditionalVisualTests {
    private static let red = "FFFF0000"
    private static let dxfs = """
    <dxfs count="1"><dxf><fill><patternFill><bgColor rgb="FFFF0000"/></patternFill></fill></dxf></dxfs>
    """

    private func format(_ sqref: String, _ rules: String) -> String {
        "<conditionalFormatting sqref=\"\(sqref)\">\(rules)</conditionalFormatting>"
    }

    private func rule(_ type: String, priority: Int = 1, extra: String = "", _ body: String = "") -> String {
        "<cfRule type=\"\(type)\" priority=\"\(priority)\" \(extra)>\(body)</cfRule>"
    }

    /// Reads a workbook whose first sheet holds `values` down column A from
    /// A1 and `formats`, going through a real file so the reader finds the rules.
    private func workbook(_ values: [CellValue], formats: [String], extensions: String? = nil) throws -> Workbook {
        var sheet = Worksheet(name: "Sheet1")
        sheet.rowCount = 20
        sheet.columnCount = 5
        for (row, value) in values.enumerated() { sheet[CellAddress(row: row, column: 0)] = Cell(value: value) }
        sheet.preservedElements = formats.map { PreservedElement(name: "conditionalFormatting", xml: $0) }
        if let extensions { sheet.preservedElements.append(PreservedElement(name: "extLst", xml: extensions)) }
        var source = Workbook(sheets: [sheet])
        source.preservedPackage.styleSheetElements = [PreservedElement(name: "dxfs", xml: Self.dxfs)]
        return try XLSXReader.workbook(from: try XLSXWriter.data(from: source))
    }

    private func numbers(_ values: Double...) -> [CellValue] { values.map { .number($0) } }

    private func style(_ row: Int, in workbook: Workbook) -> ConditionalStyle? {
        workbook.sheets[0].conditionalStyles[CellAddress(row: row, column: 0)]
    }

    /// The rows of column A the rules filled, from 0.
    private func filled(in workbook: Workbook) -> [Int] {
        workbook.sheets[0].conditionalStyles.filter { $0.value.fillColorHex != nil }.map(\.key.row).sorted()
    }

    private func sheetXML(of workbook: Workbook) throws -> String {
        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        return String(decoding: try #require(entries["xl/worksheets/sheet1.xml"]), as: UTF8.self)
    }

    // MARK: - Ranking rules

    @Test("Top and bottom rules take so many values, ties with the last included")
    func topAndBottom() throws {
        let values = numbers(5, 9, 1, 9, 7, 3)
        let top = try workbook(values, formats: [format("A1:A6", rule("top10", extra: "dxfId=\"0\" rank=\"2\""))])
        #expect(filled(in: top) == [1, 3])
        let three = try workbook(values, formats: [format("A1:A6", rule("top10", extra: "dxfId=\"0\" rank=\"1\""))])
        #expect(filled(in: three) == [1, 3])
        let bottom = try workbook(
            values, formats: [format("A1:A6", rule("top10", extra: "dxfId=\"0\" rank=\"2\" bottom=\"1\""))]
        )
        #expect(filled(in: bottom) == [2, 5])
    }

    @Test("A percentage of the values is at least one of them")
    func topPercent() throws {
        let values = numbers(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
        let fifth = try workbook(
            values, formats: [format("A1:A10", rule("top10", extra: "dxfId=\"0\" rank=\"20\" percent=\"1\""))]
        )
        #expect(filled(in: fifth) == [8, 9])
        let few = try workbook(
            values, formats: [format("A1:A10", rule("top10", extra: "dxfId=\"0\" rank=\"1\" percent=\"1\" bottom=\"1\""))]
        )
        #expect(filled(in: few) == [0])
    }

    @Test("Above and below average leave out the mean itself unless asked")
    func average() throws {
        let values = numbers(1, 2, 3, 4, 5)
        let above = try workbook(values, formats: [format("A1:A5", rule("aboveAverage", extra: "dxfId=\"0\""))])
        #expect(filled(in: above) == [3, 4])
        let below = try workbook(
            values, formats: [format("A1:A5", rule("aboveAverage", extra: "dxfId=\"0\" aboveAverage=\"0\""))]
        )
        #expect(filled(in: below) == [0, 1])
        let orEqual = try workbook(
            values, formats: [format("A1:A5", rule("aboveAverage", extra: "dxfId=\"0\" equalAverage=\"1\""))]
        )
        #expect(filled(in: orEqual) == [2, 3, 4])
        // The spread of 1…5 is √2, so only 5 is more than one deviation above 3.
        let deviation = try workbook(
            values, formats: [format("A1:A5", rule("aboveAverage", extra: "dxfId=\"0\" stdDev=\"1\""))]
        )
        #expect(filled(in: deviation) == [4])
    }

    @Test("Duplicates and unique values are told apart, text without regard to case")
    func duplicates() throws {
        let values: [CellValue] = [.number(1), .text("Tea"), .number(2), .text("tea"), .number(1), .empty, .text("Milk")]
        let repeated = try workbook(values, formats: [format("A1:A8", rule("duplicateValues", extra: "dxfId=\"0\""))])
        #expect(filled(in: repeated) == [0, 1, 3, 4])
        let single = try workbook(values, formats: [format("A1:A8", rule("uniqueValues", extra: "dxfId=\"0\""))])
        #expect(filled(in: single) == [2, 6])
    }

    @Test("A ranking rule with no differential format is not read")
    func rankingNeedsAStyle() throws {
        let book = try workbook(numbers(1, 2), formats: [format("A1:A2", rule("top10", extra: "rank=\"1\""))])
        #expect(book.sheets[0].conditionalRules.isEmpty)
    }

    // MARK: - Colour scales

    private func scale(_ points: String, _ colors: String...) -> String {
        rule("colorScale", "<colorScale>\(points)" + colors.map { "<color rgb=\"\($0)\"/>" }.joined() + "</colorScale>")
    }

    @Test("A two-colour scale blends from the lowest value to the highest")
    func twoColourScale() throws {
        let book = try workbook(
            numbers(0, 50, 100) + [.text("n/a")],
            formats: [format("A1:A5", scale("<cfvo type=\"min\"/><cfvo type=\"max\"/>", "FFFF0000", "FF0000FF"))]
        )
        #expect(style(0, in: book)?.fillColorHex == "FFFF0000")
        #expect(style(1, in: book)?.fillColorHex == "FF800080")
        #expect(style(2, in: book)?.fillColorHex == "FF0000FF")
        // Text and blanks have no place on the scale.
        #expect(style(3, in: book) == nil)
        #expect(style(4, in: book) == nil)
    }

    @Test("A three-colour scale turns at its middle threshold")
    func threeColourScale() throws {
        let points = "<cfvo type=\"min\"/><cfvo type=\"percentile\" val=\"50\"/><cfvo type=\"max\"/>"
        let book = try workbook(
            numbers(0, 10, 20, 30, 1000),
            formats: [format("A1:A5", scale(points, "FFFF0000", "FFFFFF00", "FF00FF00"))]
        )
        #expect(style(0, in: book)?.fillColorHex == "FFFF0000")
        #expect(style(1, in: book)?.fillColorHex == "FFFF8000")
        #expect(style(2, in: book)?.fillColorHex == "FFFFFF00")
        #expect(style(4, in: book)?.fillColorHex == "FF00FF00")
    }

    @Test("Thresholds can be numbers, percentages and formulas")
    func thresholdKinds() throws {
        let points = "<cfvo type=\"num\" val=\"10\"/><cfvo type=\"formula\" val=\"$A$1*2\"/>"
        let book = try workbook(
            numbers(20, 5, 25, 60),
            formats: [format("A2:A4", scale(points, "FF000000", "FFFFFFFF"))]
        )
        #expect(style(1, in: book)?.fillColorHex == "FF000000")
        #expect(style(2, in: book)?.fillColorHex == "FF808080")
        #expect(style(3, in: book)?.fillColorHex == "FFFFFFFF")

        let percent = "<cfvo type=\"percent\" val=\"25\"/><cfvo type=\"percent\" val=\"75\"/>"
        let other = try workbook(numbers(0, 50, 100), formats: [format("A1:A3", scale(percent, "FF000000", "FFFFFFFF"))])
        #expect(style(0, in: other)?.fillColorHex == "FF000000")
        #expect(style(1, in: other)?.fillColorHex == "FF808080")
    }

    @Test("A scale's fill shows on the cell and follows its value")
    func scaleIsDrawnAndRecalculated() throws {
        var book = try workbook(
            numbers(0, 100),
            formats: [format("A1:A2", scale("<cfvo type=\"min\"/><cfvo type=\"max\"/>", "FFFF0000", "FF0000FF"))]
        )
        let first = CellAddress(row: 0, column: 0)
        #expect(book.sheets[0].displayedCell(at: first).style.fillColorHex == "FFFF0000")
        book.sheets[0][first].value = .number(200)
        book.recalculate()
        #expect(book.sheets[0].displayedCell(at: first).style.fillColorHex == "FF0000FF")
        #expect(book.sheets[0][first].style.fillColorHex == nil)
    }

    @Test("A rule ahead of a scale keeps its fill")
    func priorityOverAScale() throws {
        let points = "<cfvo type=\"min\"/><cfvo type=\"max\"/>"
        let book = try workbook(numbers(0, 100), formats: [
            format("A1:A2", rule(
                "colorScale", priority: 2,
                "<colorScale>\(points)<color rgb=\"FF00FF00\"/><color rgb=\"FF0000FF\"/></colorScale>"
            )),
            format("A1:A2", rule("top10", priority: 1, extra: "dxfId=\"0\" rank=\"1\"")),
        ])
        #expect(style(0, in: book)?.fillColorHex == "FF00FF00")
        #expect(style(1, in: book)?.fillColorHex == Self.red)
    }

    // MARK: - Data bars

    private func bar(_ attributes: String = "", extra: String = "") -> String {
        rule("dataBar", "<dataBar \(attributes)><cfvo type=\"min\"/><cfvo type=\"max\"/>"
            + "<color rgb=\"FF638EC6\"/></dataBar>\(extra)")
    }

    @Test("An Excel 2007 bar runs from a tenth of the cell to nine tenths")
    func dataBar() throws {
        let book = try workbook(numbers(0, 50, 100) + [.text("x")], formats: [format("A1:A4", bar())])
        #expect(style(0, in: book)?.dataBar == ConditionalBar(start: 0, end: 0.1, colorHex: "FF638EC6"))
        #expect(style(1, in: book)?.dataBar == ConditionalBar(start: 0, end: 0.5, colorHex: "FF638EC6"))
        #expect(style(2, in: book)?.dataBar == ConditionalBar(start: 0, end: 0.9, colorHex: "FF638EC6"))
        #expect(style(3, in: book) == nil)
        #expect(style(1, in: book)?.fillColorHex == nil)
    }

    @Test("A bar shown alone hides the value on screen and keeps it in the cell")
    func barWithoutValue() throws {
        let book = try workbook(numbers(1, 2), formats: [format("A1:A2", bar("showValue=\"0\""))])
        let address = CellAddress(row: 1, column: 0)
        #expect(book.sheets[0].displayedCell(at: address).value == .empty)
        #expect(book.sheets[0][address].value == .number(2))
    }

    @Test("An Excel 2010 bar measures from zero, and negatives run back from the axis")
    func extendedDataBar() throws {
        let id = "{DA7ABA51-AAAA-BBBB-0001-000000000001}"
        let link = "<extLst><ext uri=\"{B025F937-C7B1-47D3-B67F-A62EFF666E3E}\" "
            + "xmlns:x14=\"http://schemas.microsoft.com/office/spreadsheetml/2009/9/main\">"
            + "<x14:id>\(id)</x14:id></ext></extLst>"
        let extensions = """
        <extLst><ext uri="{78C0D931-6437-407d-A8EE-F0AAD7539E65}" \
        xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">\
        <x14:conditionalFormattings><x14:conditionalFormatting \
        xmlns:xm="http://schemas.microsoft.com/office/excel/2006/main">\
        <x14:cfRule type="dataBar" id="\(id)"><x14:dataBar minLength="0" maxLength="100" gradient="0">\
        <x14:cfvo type="autoMin"/><x14:cfvo type="autoMax"/>\
        <x14:negativeFillColor rgb="FFAA0000"/><x14:axisColor rgb="FF000000"/></x14:dataBar></x14:cfRule>\
        <xm:sqref>A1:A3</xm:sqref></x14:conditionalFormatting></x14:conditionalFormattings></ext></extLst>
        """
        let book = try workbook(numbers(-50, 50, 150), formats: [format("A1:A3", bar(extra: link))], extensions: extensions)
        #expect(style(0, in: book)?.dataBar == ConditionalBar(start: 0, end: 0.25, colorHex: "FFAA0000"))
        #expect(style(1, in: book)?.dataBar == ConditionalBar(start: 0.25, end: 0.5, colorHex: "FF638EC6"))
        #expect(style(2, in: book)?.dataBar == ConditionalBar(start: 0.25, end: 1, colorHex: "FF638EC6"))

        // With nothing below zero the bars start at the edge and are in proportion.
        let positive = try workbook(numbers(50, 100), formats: [format("A1:A2", bar(extra: link))], extensions: extensions)
        #expect(style(0, in: positive)?.dataBar == ConditionalBar(start: 0, end: 0.5, colorHex: "FF638EC6"))
        #expect(style(1, in: positive)?.dataBar == ConditionalBar(start: 0, end: 1, colorHex: "FF638EC6"))
    }

    // MARK: - Icon sets

    private func icons(_ name: String?, _ attributes: String = "", third: String = "") -> String {
        rule("iconSet", "<iconSet \(name.map { "iconSet=\"\($0)\"" } ?? "") \(attributes)>"
            + "<cfvo type=\"percent\" val=\"0\"/><cfvo type=\"percent\" val=\"33\"/>"
            + "<cfvo type=\"percent\" val=\"67\" \(third)/></iconSet>")
    }

    @Test("An icon set gives each value the icon of the highest threshold it reaches")
    func iconSet() throws {
        let book = try workbook(numbers(0, 33, 50, 67, 100) + [.text("x")], formats: [format("A1:A6", icons("3Arrows"))])
        let shapes = (0..<5).map { style($0, in: book)?.icon?.shape }
        let down = ConditionalIcon.Shape.arrow(degrees: 180), level = ConditionalIcon.Shape.arrow(degrees: 90)
        let up = ConditionalIcon.Shape.arrow(degrees: 0)
        #expect(shapes == [down, level, level, up, up])
        #expect(style(5, in: book) == nil)
        #expect(style(0, in: book)?.icon?.colorHex != style(4, in: book)?.icon?.colorHex)
    }

    @Test("An icon set can run backwards, test past a threshold, and stand alone")
    func iconSetOptions() throws {
        let values = numbers(0, 67, 100)
        let reversed = try workbook(values, formats: [format("A1:A3", icons("3Arrows", "reverse=\"1\""))])
        #expect(style(0, in: reversed)?.icon?.shape == .arrow(degrees: 0))
        #expect(style(2, in: reversed)?.icon?.shape == .arrow(degrees: 180))

        let exclusive = try workbook(values, formats: [format("A1:A3", icons("3Arrows", third: "gte=\"0\""))])
        #expect(style(1, in: exclusive)?.icon?.shape == .arrow(degrees: 90))
        #expect(style(2, in: exclusive)?.icon?.shape == .arrow(degrees: 0))

        let alone = try workbook(values, formats: [format("A1:A3", icons(nil, "showValue=\"0\""))])
        #expect(style(1, in: alone)?.icon?.shape == .circle)
        #expect(alone.sheets[0].displayedCell(at: CellAddress(row: 1, column: 0)).isBlank)
    }

    @Test(
        "Every set Excel 2007 has is drawn with one icon to a threshold",
        arguments: [
            ("3Arrows", 3), ("3ArrowsGray", 3), ("3Flags", 3), ("3TrafficLights1", 3), ("3TrafficLights2", 3),
            ("3Signs", 3), ("3Symbols", 3), ("3Symbols2", 3), ("4Arrows", 4), ("4ArrowsGray", 4),
            ("4RedToBlack", 4), ("4Rating", 4), ("4TrafficLights", 4), ("5Arrows", 5), ("5ArrowsGray", 5),
            ("5Rating", 5), ("5Quarters", 5),
        ]
    )
    func everySet(name: String, count: Int) {
        let icons = ConditionalIcon.icons(ofSet: name)
        #expect(icons.count == count)
        #expect(Set(icons).count == count)
        let square = CGRect(x: 10, y: 20, width: 12, height: 12)
        for icon in icons {
            let marks = icon.marks(in: square)
            #expect(!marks.isEmpty)
            for point in marks.flatMap(\.points) {
                #expect(square.insetBy(dx: -1.5, dy: -1.5).contains(point), "\(name) leaves its square")
            }
        }
    }

    // MARK: - Drawing and saving

    @Test("A bar and an icon are laid out inside the cell")
    func marksStayInTheCell() {
        var style = ConditionalStyle()
        #expect(!style.hasMarks)
        style.dataBar = ConditionalBar(start: 0.25, end: 0.75, colorHex: "FF638EC6")
        style.icon = ConditionalIcon.icons(ofSet: "3Flags")[0]
        #expect(style.hasMarks)
        let frame = CGRect(x: 100, y: 40, width: 104, height: 20)
        let marks = style.marks(in: frame, zoom: 1)
        let bar = marks.first
        #expect(bar?.colorHex == "FF638EC6")
        #expect(bar?.points.map(\.x).min() == 127)
        #expect(bar?.points.map(\.x).max() == 177)
        #expect(marks.count > 1)
        for point in marks.flatMap(\.points) { #expect(frame.contains(point)) }
        // A bar of no length draws nothing.
        var empty = ConditionalStyle()
        empty.dataBar = ConditionalBar(start: 0.5, end: 0.5, colorHex: "FF638EC6")
        #expect(empty.marks(in: frame, zoom: 1).isEmpty)
    }

    @Test("Scales, bars and icon sets are written back as the file had them")
    func keptOnSave() throws {
        let points = "<cfvo type=\"min\"/><cfvo type=\"max\"/>"
        let book = try workbook(numbers(1, 2, 3), formats: [
            format("A1:A3", scale(points, "FFFF0000", "FF0000FF")),
            format("B1:B3", bar()),
            format("C1:C3", icons("3Flags")),
            format("D1:D3", rule("top10", extra: "dxfId=\"0\" rank=\"1\"")),
        ])
        #expect(book.sheets[0].conditionalRules.count == 4)
        let xml = try sheetXML(of: book)
        for kept in ["<colorScale>", "<dataBar", "iconSet=\"3Flags\"", "type=\"top10\""] {
            #expect(xml.contains(kept), "\(kept) did not survive")
        }
        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: book))
        #expect(reopened.sheets[0].conditionalRules == book.sheets[0].conditionalRules)
        #expect(reopened.sheets[0].conditionalStyles == book.sheets[0].conditionalStyles)
    }

    @Test("Rows inserted above move a scale with its cells")
    func insertedRows() throws {
        var book = try workbook(
            numbers(0, 100),
            formats: [format("A1:A2", scale("<cfvo type=\"min\"/><cfvo type=\"max\"/>", "FFFF0000", "FF0000FF"))]
        )
        book.sheets[0].insertRows(1, at: 0)
        book.recalculate()
        #expect(style(0, in: book) == nil)
        #expect(style(1, in: book)?.fillColorHex == "FFFF0000")
        #expect(style(2, in: book)?.fillColorHex == "FF0000FF")
        #expect(try sheetXML(of: book).contains("sqref=\"A2:A3\""))
    }
}
