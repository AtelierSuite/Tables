import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// A sheet's filter: read from a file, applied, changed and written back.
@Suite("Filtering")
struct SortFilterTests {

    // MARK: - Fixtures

    /// Name, city and amount under a header row, with a total under them.
    private static let entries: [String: String] = [
        "A1": "Name", "B1": "City", "C1": "Amount",
        "A2": "Mori", "B2": "Osaka", "C2": "30",
        "A3": "abe", "B3": "Tokyo", "C3": "10",
        "A4": "Sato", "B4": "Osaka", "C4": "20",
        "A5": "Endo", "B5": "Tokyo", "C5": "40",
        "A6": "Kato", "B6": "Kyoto",
    ]

    private func workbook(_ entries: [String: String] = SortFilterTests.entries) -> Workbook {
        var sheet = Worksheet(name: "Sheet1")
        for (reference, input) in entries {
            guard let address = CellAddress(a1: reference) else { continue }
            sheet[address] = CellInputParser.cell(from: input, inheriting: .default)
        }
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        return workbook
    }

    private func column(_ letter: String, rows: ClosedRange<Int>, in sheet: Worksheet) -> [String] {
        rows.map { CellFormatter.displayText(for: sheet[CellAddress(a1: "\(letter)\($0)")!]) }
    }

    private func range(_ reference: String) -> CellRange { CellRange(a1Range: reference)! }

    private func package(sheetData: String, sheetBody: String) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" \
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
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet1.xml"/></Relationships>
        """
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetData>\(sheetData)</sheetData>\(sheetBody)</worksheet>
        """
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
        ])
    }

    /// City in A and amount in B under a header, rows 2 to 6; `hidden` names
    /// the rows the file itself marks hidden.
    private func cityPackage(_ body: String, hidden: Set<Int> = []) throws -> Data {
        let cities = ["Osaka", "Tokyo", "Osaka", "Kyoto", "Tokyo"]
        var rows = "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>City</t></is></c>"
            + "<c r=\"B1\" t=\"inlineStr\"><is><t>Amount</t></is></c></row>"
        for (offset, city) in cities.enumerated() {
            let row = offset + 2
            rows += "<row r=\"\(row)\"\(hidden.contains(row) ? " hidden=\"1\"" : "")>"
                + "<c r=\"A\(row)\" t=\"inlineStr\"><is><t>\(city)</t></is></c>"
                + "<c r=\"B\(row)\"><v>\(row * 10)</v></c></row>"
        }
        return try package(sheetData: rows, sheetBody: body)
    }

    private func savedSheet(_ workbook: Workbook) throws -> String {
        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        return String(decoding: try #require(entries["xl/worksheets/sheet1.xml"]), as: UTF8.self)
    }

    // MARK: - Filtering

    @Test("A value list hides the rows whose value is not in it")
    func filtersByValues() {
        var book = workbook()
        book.sheets[0].setAutoFilter(on: range("A1:C6"))
        book.sheets[0].setFilter(.values(["osaka", "Kyoto"], includesBlanks: false), forColumn: 1)
        #expect(book.sheets[0].hiddenRows == [2, 4])
        #expect(book.sheets[0].autoFilter?.filteredRows == [2, 4])
    }

    @Test("Blanks are shown only when the list includes them")
    func filtersBlanks() {
        var book = workbook()
        book.sheets[0].setAutoFilter(on: range("A1:C6"))
        book.sheets[0].setFilter(.values(["10"], includesBlanks: true), forColumn: 2)
        #expect(book.sheets[0].hiddenRows == [1, 3, 4])
        book.sheets[0].setFilter(.values(["10"], includesBlanks: false), forColumn: 2)
        #expect(book.sheets[0].hiddenRows == [1, 3, 4, 5])
    }

    @Test("Two filtered columns show only the rows both let through")
    func filtersByTwoColumns() {
        var book = workbook()
        book.sheets[0].setAutoFilter(on: range("A1:C6"))
        book.sheets[0].setFilter(.values(["Tokyo"], includesBlanks: false), forColumn: 1)
        book.sheets[0].setFilter(.conditions(.init(.greaterThan, "20")), forColumn: 2)
        #expect(book.sheets[0].hiddenRows == [1, 2, 3, 5])
        // The other column's list offers only what is still showing.
        #expect(book.sheets[0].filterValues(forColumn: 1).values == ["Osaka", "Tokyo"])
    }

    @Test("Conditions compare numbers, and two of them join with and or or")
    func filtersByNumberConditions() {
        var book = workbook()
        book.sheets[0].setAutoFilter(on: range("A1:C6"))
        book.sheets[0].setFilter(
            .conditions(.init(.greaterThanOrEqual, "20"), .init(.lessThan, "40"), matchesBoth: true), forColumn: 2)
        #expect(book.sheets[0].hiddenRows == [2, 4, 5])
        book.sheets[0].setFilter(
            .conditions(.init(.equal, "10"), .init(.equal, "40"), matchesBoth: false), forColumn: 2)
        #expect(book.sheets[0].hiddenRows == [1, 3, 5])
        book.sheets[0].setFilter(.conditions(.init(.notEqual, "10")), forColumn: 2)
        #expect(book.sheets[0].hiddenRows == [2])
    }

    @Test("Text conditions take wildcards, which is how contains and begins with are written")
    func filtersByTextConditions() {
        var book = workbook()
        book.sheets[0].setAutoFilter(on: range("A1:C6"))
        book.sheets[0].setFilter(.conditions(.init(.equal, "*o*")), forColumn: 0)
        #expect(book.sheets[0].hiddenRows == [2])
        book.sheets[0].setFilter(.conditions(.init(.equal, "s*")), forColumn: 0)
        #expect(book.sheets[0].hiddenRows == [1, 2, 4, 5])
        book.sheets[0].setFilter(.conditions(.init(.notEqual, "*o")), forColumn: 0)
        #expect(book.sheets[0].hiddenRows == [3, 4, 5])
        // A single space stands for a blank cell.
        book.sheets[0].setFilter(nil, forColumn: 0)
        book.sheets[0].setFilter(.conditions(.init(.notEqual, " ")), forColumn: 2)
        #expect(book.sheets[0].hiddenRows == [5])
    }

    @Test("Top and bottom items keep the largest or smallest numbers")
    func filtersTopItems() {
        var book = workbook()
        book.sheets[0].setAutoFilter(on: range("A1:C6"))
        book.sheets[0].setFilter(.top(count: 2), forColumn: 2)
        #expect(book.sheets[0].hiddenRows == [2, 3, 5])
        book.sheets[0].setFilter(.top(count: 1, isBottom: true), forColumn: 2)
        #expect(book.sheets[0].hiddenRows == [1, 3, 4, 5])
        book.sheets[0].setFilter(.top(count: 50, isPercent: true), forColumn: 2)
        #expect(book.sheets[0].hiddenRows == [2, 3, 5])
    }

    @Test("Rows hidden by hand stay hidden when the filter is cleared or removed")
    func filterKeepsManuallyHiddenRows() {
        var book = workbook()
        book.sheets[0].setRows(4...4, hidden: true)
        book.sheets[0].setAutoFilter(on: range("A1:C6"))
        book.sheets[0].setFilter(.values(["Osaka"], includesBlanks: false), forColumn: 1)
        #expect(book.sheets[0].hiddenRows == [2, 4, 5])
        #expect(book.sheets[0].autoFilter?.filteredRows == [2, 4, 5])
        book.sheets[0].clearFilterCriteria()
        #expect(book.sheets[0].hiddenRows == [4])
        #expect(book.sheets[0].autoFilter != nil)

        book.sheets[0].setFilter(.values(["Osaka"], includesBlanks: false), forColumn: 1)
        book.sheets[0].setRows(7...7, hidden: true)
        book.sheets[0].setAutoFilter(on: nil)
        #expect(book.sheets[0].hiddenRows == [4, 7])
        #expect(book.sheets[0].autoFilter == nil)
    }

    @Test("SUBTOTAL passes over filtered rows but counts rows hidden by hand")
    func subtotalSkipsFilteredRows() {
        var entries = Self.entries
        entries["E1"] = "=SUBTOTAL(9,C2:C6)"
        entries["E2"] = "=SUBTOTAL(109,C2:C6)"
        entries["E3"] = "=SUM(C2:C6)"
        entries["E4"] = "=AGGREGATE(9,5,C2:C6)"
        var book = workbook(entries)
        book.sheets[0].setRows(2...2, hidden: true)
        book.recalculate()
        func value(_ reference: String) -> CellValue { book.sheets[0][CellAddress(a1: reference)!].value }
        #expect(value("E1") == .number(100))
        #expect(value("E2") == .number(90))

        book.sheets[0].setAutoFilter(on: range("A1:C6"))
        book.sheets[0].setFilter(.values(["Osaka"], includesBlanks: false), forColumn: 1)
        book.recalculate()
        // Osaka is rows 2 and 4 (30 and 20); row 3 is hidden by hand and by the filter.
        #expect(value("E1") == .number(50))
        #expect(value("E2") == .number(50))
        #expect(value("E3") == .number(100))
        #expect(value("E4") == .number(50))
    }

    @Test("The filter follows rows and columns inserted and removed")
    func filterFollowsStructureEdits() {
        var book = workbook()
        book.sheets[0].setAutoFilter(on: range("A1:C6"))
        book.sheets[0].setFilter(.values(["Tokyo"], includesBlanks: false), forColumn: 1)
        book.sheets[0].insertRows(2, at: 0)
        #expect(book.sheets[0].autoFilter?.range == range("A3:C8"))
        #expect(book.sheets[0].autoFilter?.filteredRows == [3, 5, 7])
        #expect(book.sheets[0].hiddenRows == [3, 5, 7])

        book.sheets[0].insertColumns(1, at: 1)
        #expect(book.sheets[0].autoFilter?.range == range("A3:D8"))
        #expect(book.sheets[0].autoFilter?.columns.keys.sorted() == [2])
        book.sheets[0].removeColumns(2...2)
        #expect(book.sheets[0].autoFilter?.range == range("A3:C8"))
        #expect(book.sheets[0].autoFilter?.columns.isEmpty == true)

        // Removing the header row takes the filter with it.
        book.sheets[0].removeRows(2...2)
        #expect(book.sheets[0].autoFilter == nil)
        #expect(book.sheets[0].hiddenRows.isEmpty)
    }

    // MARK: - Files

    @Test("A file's filter is read with its value list and applied")
    func readsAndAppliesValueFilter() throws {
        let body = "<autoFilter ref=\"A1:B6\"><filterColumn colId=\"0\"><filters>"
            + "<filter val=\"Osaka\"/><filter val=\"Kyoto\"/></filters></filterColumn></autoFilter>"
        // The file hides row 3 only; the filter also turns away row 6.
        let book = try XLSXReader.workbook(from: try cityPackage(body, hidden: [3]))
        let sheet = book.sheets[0]
        #expect(sheet.autoFilter?.range == range("A1:B6"))
        #expect(sheet.autoFilter?.columns == [0: .values(["Osaka", "Kyoto"], includesBlanks: false)])
        #expect(sheet.hiddenRows == [2, 5])
        #expect(sheet.autoFilter?.filteredRows == [2, 5])
        #expect(sheet.hasFilterButton(at: CellAddress(a1: "B1")!))
        #expect(!sheet.hasFilterButton(at: CellAddress(a1: "B2")!))
        #expect(!book.unsupportedFeatures.preserved.contains(.autoFilter))
        #expect(!book.unsupportedFeatures.lost.contains(.autoFilter))
    }

    @Test("Conditions, top items and hidden buttons are read and written back")
    func roundTripsCriteria() throws {
        let body = "<autoFilter ref=\"A1:B6\">"
            + "<filterColumn colId=\"0\" hiddenButton=\"1\"><customFilters and=\"1\">"
            + "<customFilter operator=\"notEqual\" val=\"*yo*\"/><customFilter val=\"O*\"/></customFilters></filterColumn>"
            + "<filterColumn colId=\"1\"><top10 top=\"0\" val=\"3\"/></filterColumn></autoFilter>"
        let book = try XLSXReader.workbook(from: try cityPackage(body))
        let filter = try #require(book.sheets[0].autoFilter)
        #expect(filter.columns[0] == .conditions(.init(.notEqual, "*yo*"), .init(.equal, "O*"), matchesBoth: true))
        #expect(filter.columns[1] == .top(count: 3, isBottom: true))
        #expect(filter.hiddenButtons == [0])
        #expect(book.sheets[0].hiddenRows == [2, 4, 5])

        let xml = try savedSheet(book)
        #expect(xml.contains(body))
        for row in [3, 5, 6] { #expect(xml.contains("<row r=\"\(row)\" hidden=\"1\"")) }
        #expect(!xml.contains("<row r=\"2\" hidden"))
        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: book))
        #expect(reopened.sheets[0].autoFilter == filter)
        #expect(reopened.sheets[0].hiddenRows == [2, 4, 5])
    }

    @Test("A date group in a value list shows the dates under it")
    func readsDateGroups() throws {
        let rows = "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Day</t></is></c></row>"
            + "<row r=\"2\"><c r=\"A2\"><v>45292</v></c></row>"   // 2024-01-01
            + "<row r=\"3\"><c r=\"A3\"><v>45323</v></c></row>"   // 2024-02-01
            + "<row r=\"4\"><c r=\"A4\"><v>45658</v></c></row>"   // 2025-01-01
        let body = "<autoFilter ref=\"A1:A4\"><filterColumn colId=\"0\"><filters>"
            + "<dateGroupItem year=\"2024\" month=\"2\" dateTimeGrouping=\"month\"/>"
            + "<dateGroupItem year=\"2025\" dateTimeGrouping=\"year\"/></filters></filterColumn></autoFilter>"
        let book = try XLSXReader.workbook(from: try package(sheetData: rows, sheetBody: body))
        #expect(book.sheets[0].hiddenRows == [1])
        #expect(try savedSheet(book).contains(body))
    }

    @Test("A filter set in the app is written in its schema slot and read back")
    func writesNewFilter() throws {
        var book = workbook()
        book.sheets[0].setAutoFilter(on: range("A1:C6"))
        book.sheets[0].merge(range("D8:E8"))
        book.sheets[0].setFilter(.values(["Tokyo", "A&B"], includesBlanks: true), forColumn: 1)
        let xml = try savedSheet(book)
        #expect(xml.contains(
            "<autoFilter ref=\"A1:C6\"><filterColumn colId=\"1\"><filters blank=\"1\">"
                + "<filter val=\"A&amp;B\"/><filter val=\"Tokyo\"/></filters></filterColumn></autoFilter>"))
        let data = try #require(xml.range(of: "</sheetData>")), filter = try #require(xml.range(of: "<autoFilter"))
        let merges = try #require(xml.range(of: "<mergeCells"))
        #expect(data.lowerBound < filter.lowerBound && filter.lowerBound < merges.lowerBound)

        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: book))
        #expect(reopened.sheets[0].autoFilter?.columns == book.sheets[0].autoFilter?.columns)
        #expect(reopened.sheets[0].hiddenRows == [1, 3, 5])

        // Taking the filter away takes it out of the file too.
        book.sheets[0].setAutoFilter(on: nil)
        #expect(!(try savedSheet(book).contains("<autoFilter")))
    }
}
