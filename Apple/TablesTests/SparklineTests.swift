import Foundation
import Testing
@testable import TablesEngine

@Suite("Sparklines")
struct SparklineTests {

    // MARK: - Package

    private static let groups = """
    <extLst><ext uri="{78C0D931-6437-407d-A8EE-F0AAD7539E65}" \
    xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">\
    <x14:conditionalFormattings/></ext>\
    <ext uri="{05C60535-1F16-4fd2-B633-F4F36F0B64E0}" \
    xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">\
    <x14:sparklineGroups xmlns:xm="http://schemas.microsoft.com/office/excel/2006/main">\
    <x14:sparklineGroup lineWeight="1.5" displayEmptyCellsAs="gap" markers="1" high="1" low="1">\
    <x14:colorSeries theme="4" tint="-0.5"/><x14:colorNegative rgb="FFFF0000"/>\
    <x14:colorMarkers rgb="FF00B050"/><x14:colorHigh rgb="FF0000FF"/><x14:colorLow rgb="FFFFC000"/>\
    <x14:sparklines><x14:sparkline><xm:f>Sheet1!A1:E1</xm:f><xm:sqref>F1</xm:sqref></x14:sparkline>\
    <x14:sparkline><xm:f>Sheet1!A2:E2</xm:f><xm:sqref>F2</xm:sqref></x14:sparkline></x14:sparklines>\
    </x14:sparklineGroup>\
    <x14:sparklineGroup type="column" negative="1" displayXAxis="1" minAxisType="group" maxAxisType="group">\
    <x14:colorSeries rgb="FF376092"/><x14:colorNegative rgb="FFD00000"/><x14:colorAxis rgb="FF000000"/>\
    <x14:sparklines><x14:sparkline><xm:f>Sheet1!A3:E3</xm:f><xm:sqref>F3</xm:sqref></x14:sparkline>\
    </x14:sparklines></x14:sparklineGroup>\
    <x14:sparklineGroup type="stacked"><x14:colorSeries rgb="FF00B050"/>\
    <x14:sparklines><x14:sparkline><xm:f>'Sheet1'!A4:E4</xm:f><xm:sqref>F4</xm:sqref></x14:sparkline>\
    </x14:sparklines></x14:sparklineGroup>\
    </x14:sparklineGroups></ext></extLst>
    """

    private static let rows: [[Double?]] = [
        [1, 3, nil, 2, 5],
        [4, 4, 4, 4, 4],
        [2, -1, 3, -2, 1],
        [1, -1, 0, 1, -1],
    ]

    private func workbookFile(extensions: String = groups) throws -> Data {
        var sheetData = ""
        for (index, row) in Self.rows.enumerated() {
            sheetData += "<row r=\"\(index + 1)\">"
            for (column, value) in row.enumerated() {
                guard let value else { continue }
                sheetData += "<c r=\"\(CellAddress(row: index, column: column).a1)\"><v>\(value)</v></c>"
            }
            sheetData += "</row>"
        }
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheetData>\(sheetData)</sheetData>\(extensions)</worksheet>
        """
        let entries: [(path: String, data: Data)] = [
            ("[Content_Types].xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
            """.utf8)),
            ("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
            Target="xl/workbook.xml"/></Relationships>
            """.utf8)),
            ("xl/workbook.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
            """.utf8)),
            ("xl/_rels/workbook.xml.rels", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
            Target="worksheets/sheet1.xml"/></Relationships>
            """.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ]
        return try ZipArchive.archive(entries: entries)
    }

    private func sheetXML(_ workbook: Workbook) throws -> String {
        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        let payload = try #require(entries["xl/worksheets/sheet1.xml"])
        return String(decoding: payload, as: UTF8.self)
    }

    // MARK: - Reading

    @Test("Groups are read with their type, options, colours and sparklines")
    func readsGroups() throws {
        let sheet = try XLSXReader.workbook(from: try workbookFile()).sheets[0]
        #expect(sheet.sparklineGroups.count == 3)
        let line = sheet.sparklineGroups[0]
        #expect(line.kind == .line)
        #expect(line.lineWeight == 1.5)
        #expect(line.emptyCells == .gap)
        #expect(line.markers && line.high && line.low && !line.first)
        #expect(line.seriesColor?.attributes == ["theme": "4", "tint": "-0.5"])
        // Theme 4 is accent 1; a tint of -0.5 darkens it.
        #expect(line.seriesColor?.hex != nil)
        #expect(line.markersColor?.hex == "FF00B050")
        #expect(line.sparklines.map(\.location) == [CellAddress(a1: "F1"), CellAddress(a1: "F2")])
        #expect(line.sparklines[0].formula == "Sheet1!A1:E1")

        let column = sheet.sparklineGroups[1]
        #expect(column.kind == .column)
        #expect(column.negative && column.displaysXAxis)
        #expect(column.minAxis == .group && column.maxAxis == .group)
        #expect(sheet.sparklineGroups[2].kind == .stacked)
        #expect(sheet.sparkline(at: CellAddress(row: 3, column: 5))?.group.kind == .stacked)
    }

    @Test("Values come from the cells, quoted sheet names included, with blanks as nil")
    func readsValues() throws {
        let sheet = try XLSXReader.workbook(from: try workbookFile()).sheets[0]
        let (group, sparkline) = try #require(sheet.sparkline(at: CellAddress(row: 0, column: 5)))
        #expect(sheet.sparklineValues(sparkline, group: group) == [1, 3, nil, 2, 5])
        let winLoss = try #require(sheet.sparkline(at: CellAddress(row: 3, column: 5)))
        #expect(sheet.sparklineValues(winLoss.sparkline, group: winLoss.group) == [1, -1, 0, 1, -1])
    }

    // MARK: - Saving

    @Test("A save writes the groups back in their extension, beside the file's other extensions")
    func roundTrips() throws {
        let workbook = try XLSXReader.workbook(from: try workbookFile())
        let xml = try sheetXML(workbook)
        #expect(xml.components(separatedBy: "{05C60535-1F16-4fd2-B633-F4F36F0B64E0}").count == 2)
        #expect(xml.contains("<x14:colorSeries theme=\"4\" tint=\"-0.5\"/>"))
        #expect(xml.contains("<xm:f>Sheet1!A1:E1</xm:f><xm:sqref>F1</xm:sqref>"))
        // Excel's conditional formats come first, as Excel writes them.
        let conditional = try #require(xml.range(of: "{78C0D931-6437-407d-A8EE-F0AAD7539E65}"))
        let sparklines = try #require(xml.range(of: "{05C60535-1F16-4fd2-B633-F4F36F0B64E0}"))
        #expect(conditional.lowerBound < sparklines.lowerBound)

        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: workbook))
        #expect(reopened.sheets[0].sparklineGroups == workbook.sheets[0].sparklineGroups)
    }

    @Test("A sheet given sparklines gets an extension list of its own")
    func writesNewGroups() throws {
        var sheet = Worksheet(name: "Data")
        var group = SparklineGroup()
        group.kind = .column
        group.seriesColor = SparklineColor(hex: "FF112233")
        group.sparklines = [Sparkline(formula: "Data!A1:C1", location: CellAddress(row: 0, column: 3))]
        sheet.sparklineGroups = [group]
        let xml = try sheetXML(Workbook(sheets: [sheet]))
        #expect(xml.contains("<extLst><ext uri=\"{05C60535-1F16-4fd2-B633-F4F36F0B64E0}\""))
        #expect(xml.contains("<x14:sparklineGroup type=\"column\">"))
        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: Workbook(sheets: [sheet])))
        #expect(reopened.sheets[0].sparklineGroups == [group])
    }

    // MARK: - Structural edits

    @Test("Inserting and removing rows moves sparklines and their data, and removes those that lose their cell")
    func followsRowEdits() throws {
        var sheet = try XLSXReader.workbook(from: try workbookFile()).sheets[0]
        sheet.insertRows(1, at: 0)
        #expect(sheet.sparklineGroups[0].sparklines[0].location == CellAddress(row: 1, column: 5))
        #expect(sheet.sparklineGroups[0].sparklines[0].formula == "Sheet1!A2:E2")
        sheet.removeRows(4...4)
        // The win/loss sparkline sat on the removed row, and its group went with it.
        #expect(sheet.sparklineGroups.count == 2)
        let xml = try sheetXML(Workbook(sheets: [sheet]))
        #expect(xml.contains("<xm:f>Sheet1!A2:E2</xm:f><xm:sqref>F2</xm:sqref>"))
        #expect(!xml.contains("F5"))
    }

    // MARK: - Drawing

    private let frame = CGRect(x: 0, y: 0, width: 104, height: 24)

    @Test("A line breaks at a gap, and marks every point plus the high and low in their colours")
    func drawsLine() throws {
        let sheet = try XLSXReader.workbook(from: try workbookFile()).sheets[0]
        let shapes = sheet.sparklineShapes(at: CellAddress(row: 0, column: 5), in: frame, zoom: 1)
        let lines = shapes.compactMap { shape -> [CGPoint]? in
            if case .polyline(let points, let width, _) = shape { #expect(width == 1.5); return points }
            return nil
        }
        #expect(lines.map(\.count) == [2, 2])
        let markers = shapes.compactMap { shape -> (CGPoint, String)? in
            if case .marker(let center, _, let hex) = shape { return (center, hex) }
            return nil
        }
        #expect(markers.count == 4)
        // The high (5) is at the top of the inset box, the low (1) at its bottom.
        #expect(markers.contains { $0.1 == "FF0000FF" && abs($0.0.y - 2) < 0.001 })
        #expect(markers.contains { $0.1 == "FFFFC000" && abs($0.0.y - 22) < 0.001 })
        #expect(markers.filter { $0.1 == "FF00B050" }.count == 2)
    }

    @Test("Columns hang from a zero axis, negatives in their own colour")
    func drawsColumns() throws {
        let sheet = try XLSXReader.workbook(from: try workbookFile()).sheets[0]
        let shapes = sheet.sparklineShapes(at: CellAddress(row: 2, column: 5), in: frame, zoom: 1)
        var axisY: Double?
        var bars: [(CGRect, String)] = []
        for shape in shapes {
            switch shape {
            case .axis(let from, _, _, _): axisY = from.y
            case .bar(let rect, let hex): bars.append((rect, hex))
            default: break
            }
        }
        let zero = try #require(axisY)
        #expect(bars.count == 5)
        for (rect, hex) in bars {
            if hex == "FFD00000" { #expect(abs(rect.minY - zero) < 0.001) } else { #expect(abs(rect.maxY - zero) < 0.001) }
        }
        #expect(bars.filter { $0.1 == "FFD00000" }.count == 2)
    }

    @Test("Win/loss bars are all one height, nothing drawn for zero")
    func drawsWinLoss() throws {
        let sheet = try XLSXReader.workbook(from: try workbookFile()).sheets[0]
        let bars = sheet.sparklineShapes(at: CellAddress(row: 3, column: 5), in: frame, zoom: 1).compactMap { shape -> CGRect? in
            if case .bar(let rect, _) = shape { return rect }
            return nil
        }
        #expect(bars.count == 4)
        #expect(Set(bars.map { ($0.height * 1000).rounded() }).count == 1)
    }

    @Test("Changing a value in the data changes the drawing")
    func followsData() throws {
        var sheet = try XLSXReader.workbook(from: try workbookFile()).sheets[0]
        let address = CellAddress(row: 0, column: 5)
        let before = sheet.sparklineShapes(at: address, in: frame, zoom: 1)
        var cell = Cell()
        cell.value = .number(10)
        sheet[CellAddress(row: 0, column: 2)] = cell
        let after = sheet.sparklineShapes(at: address, in: frame, zoom: 1)
        #expect(before != after)
        // The gap is filled now: one unbroken line.
        #expect(after.filter { if case .polyline = $0 { return true }; return false }.count == 1)
    }

    @Test("Data on another sheet is found by name")
    func readsOtherSheets() throws {
        var data = Worksheet(name: "My data")
        for column in 0..<3 {
            var cell = Cell()
            cell.value = .number(Double(column))
            data[CellAddress(row: 0, column: column)] = cell
        }
        var sheet = Worksheet(name: "Summary")
        var group = SparklineGroup()
        group.sparklines = [Sparkline(formula: "'My data'!A1:C1", location: CellAddress(row: 0, column: 0))]
        sheet.sparklineGroups = [group]
        #expect(sheet.sparklineValues(group.sparklines[0], group: group).isEmpty)
        #expect(sheet.sparklineValues(group.sparklines[0], group: group, sheets: { $0 == "My data" ? data : nil }) == [0, 1, 2])
    }
}
