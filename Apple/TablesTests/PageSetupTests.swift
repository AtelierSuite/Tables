import CoreGraphics
import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// A sheet's page setup: read from the fragments the file keeps, edited
/// without disturbing the rest of them, saved, and followed when the sheet
/// is cut into pages.
@Suite("Page setup")
struct PageSetupTests {

    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    /// A range written as in a formula, which the tests know to be valid.
    private func range(_ a1: String) -> CellRange { CellRange(a1Range: a1)! }

    private func sheet(_ elements: [(String, String)] = []) -> Worksheet {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(row: 0, column: 0)] = Cell(value: .text("x"))
        // As read from a file: in the worksheet's namespace.
        sheet.preservedElements = elements.map { name, xml in
            PreservedElement(name: name, xml: xml.replacingOccurrences(
                of: "<\(name)", with: "<\(name) xmlns=\"\(Self.main)\"", options: [], range: xml.range(of: "<\(name)")))
        }
        return sheet
    }

    private func savedAndReopened(_ workbook: Workbook) throws -> (workbook: Workbook, sheetXML: String, workbookXML: String) {
        let data = try XLSXWriter.data(from: workbook)
        let entries = try ZipArchive.entries(in: data)
        let sheet = String(decoding: try #require(entries["xl/worksheets/sheet1.xml"]), as: UTF8.self)
        let book = String(decoding: try #require(entries["xl/workbook.xml"]), as: UTF8.self)
        return (try XLSXReader.workbook(from: data), sheet, book)
    }

    // MARK: - Reading

    @Test("A sheet with no print elements has Excel's defaults")
    func defaults() {
        let setup = sheet().pageSetup
        #expect(setup == PageSetup())
        #expect(setup.orientation == .portrait)
        #expect(setup.paperSize == nil)
        #expect(setup.scale == 100)
        #expect(!setup.fitsToPages)
        #expect(setup.margins.left == 0.7 && setup.margins.top == 0.75 && setup.margins.header == 0.3)
    }

    @Test("Orientation, paper, scale, options, margins and text are read from the kept elements")
    func reads() {
        let setup = sheet([
            ("pageSetup", "<pageSetup paperSize=\"9\" scale=\"85\" fitToWidth=\"2\" fitToHeight=\"0\" orientation=\"landscape\"/>"),
            ("printOptions", "<printOptions gridLines=\"1\" horizontalCentered=\"1\"/>"),
            ("pageMargins", "<pageMargins left=\"0.25\" right=\"0.5\" top=\"1\" bottom=\"1.25\" header=\"0.2\" footer=\"0.4\"/>"),
            ("headerFooter", "<headerFooter><oddHeader>&amp;LLeft&amp;C&amp;\"Arial,Bold\"Title&amp;R&amp;D</oddHeader>"
                + "<oddFooter>Page &amp;P of &amp;N</oddFooter></headerFooter>"),
        ]).pageSetup
        #expect(setup.orientation == .landscape)
        #expect(setup.paperSize == 9)
        #expect(setup.scale == 85)
        #expect(setup.fitWide == 2 && setup.fitTall == 0)
        #expect(setup.printsGridlines && setup.centersHorizontally && !setup.centersVertically)
        #expect(setup.margins.left == 0.25 && setup.margins.right == 0.5 && setup.margins.top == 1)
        #expect(setup.margins.bottom == 1.25 && setup.margins.header == 0.2 && setup.margins.footer == 0.4)
        #expect(setup.header == HeaderFooterText(left: "Left", center: "&\"Arial,Bold\"Title", right: "&D"))
        // Text before any mark is the middle's.
        #expect(setup.footer == HeaderFooterText(center: "Page &P of &N"))
    }

    // MARK: - Header and footer text

    @Test("Header text splits at its marks and joins back the same")
    func headerSections() {
        let text = HeaderFooterText(code: "&LA && B&C&\"Courier,Regular\"&12Mid&RPage &P")
        #expect(text.left == "A && B")
        // The font name's letters are not marks.
        #expect(text.center == "&\"Courier,Regular\"&12Mid")
        #expect(text.right == "Page &P")
        #expect(text.code == "&LA && B&C&\"Courier,Regular\"&12Mid&RPage &P")
        #expect(HeaderFooterText(code: "").isEmpty)
        #expect(HeaderFooterText(left: "", center: "", right: "x").code == "&Rx")
    }

    @Test("The codes are filled in and the formatting ones dropped when printed")
    func printedText() {
        let fields = HeaderFooterText.Fields(
            page: 2, pageCount: 5, date: "2026/11/13", time: "9:30", fileName: "Budget.xlsx", sheetName: "Q1")
        #expect(HeaderFooterText.printed("Page &P of &N", fields: fields) == "Page 2 of 5")
        #expect(HeaderFooterText.printed("&F - &A, &D &T", fields: fields) == "Budget.xlsx - Q1, 2026/11/13 9:30")
        #expect(HeaderFooterText.printed("Profit && Loss", fields: fields) == "Profit & Loss")
        #expect(HeaderFooterText.printed("&\"Arial,Bold\"&14&KFF0000&BTitle&B", fields: fields) == "Title")
        #expect(HeaderFooterText.printed("&8Small &P", fields: fields) == "Small 2")
    }

    // MARK: - Editing

    @Test("Changing one setting leaves the rest of the fragment as the file had it")
    func editKeepsOtherAttributes() {
        var sheet = sheet([
            ("pageSetup", "<pageSetup paperSize=\"9\" orientation=\"portrait\" horizontalDpi=\"300\" useFirstPageNumber=\"1\"/>"),
            ("headerFooter", "<headerFooter differentFirst=\"1\"><oddHeader>Old</oddHeader><firstHeader>First</firstHeader></headerFooter>"),
        ])
        var setup = sheet.pageSetup
        setup.orientation = .landscape
        setup.header.center = "New &P"
        setup.footer.right = "&D"
        sheet.pageSetup = setup

        let page = sheet.preservedElements.first { $0.name == "pageSetup" }?.xml ?? ""
        #expect(page.contains("orientation=\"landscape\""))
        #expect(page.contains("paperSize=\"9\"") && page.contains("horizontalDpi=\"300\"") && page.contains("useFirstPageNumber=\"1\""))
        let headerFooter = sheet.preservedElements.first { $0.name == "headerFooter" }?.xml ?? ""
        #expect(headerFooter.contains("differentFirst=\"1\""))
        // The odd header and footer come first, in that order.
        #expect(headerFooter.contains(
            "<oddHeader>&amp;CNew &amp;P</oddHeader><oddFooter>&amp;R&amp;D</oddFooter><firstHeader>First</firstHeader>"))
        // Nothing else was asked for, so nothing else was added.
        #expect(!sheet.preservedElements.contains { $0.name == "printOptions" || $0.name == "pageMargins" })
        #expect(sheet.pageSetup == setup)
    }

    @Test("Setting the same setup changes nothing")
    func unchangedSetupIsNoEdit() {
        var sheet = sheet([("pageSetup", "<pageSetup orientation=\"default\" scale=\"100\"/>")])
        let before = sheet
        sheet.pageSetup = sheet.pageSetup
        #expect(sheet == before)
    }

    @Test("Every setting survives a save and reopening")
    func roundTrip() throws {
        var setup = PageSetup()
        setup.orientation = .landscape
        setup.paperSize = 9
        setup.fitsToPages = true
        setup.fitWide = 1
        setup.fitTall = 0
        setup.margins.left = 0.5
        setup.margins.footer = 0.25
        setup.printsGridlines = true
        setup.centersVertically = true
        setup.header = HeaderFooterText(left: "&F", center: "Report & more", right: "&A")
        setup.footer = HeaderFooterText(center: "Page &P of &N")
        var first = sheet()
        first.pageSetup = setup
        let saved = try savedAndReopened(Workbook(sheets: [first]))

        #expect(saved.workbook.sheets[0].pageSetup == setup)
        #expect(saved.sheetXML.contains("<sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr>"))
        #expect(saved.sheetXML.contains("fitToHeight=\"0\"") && saved.sheetXML.contains("orientation=\"landscape\""))
        #expect(saved.sheetXML.contains("<printOptions xmlns=\"\(Self.main)\" gridLines=\"1\" verticalCentered=\"1\"/>"))
        #expect(saved.sheetXML.contains("<pageMargins xmlns=\"\(Self.main)\" "
            + "bottom=\"0.75\" footer=\"0.25\" header=\"0.3\" left=\"0.5\" right=\"0.7\" top=\"0.75\"/>"))
        // Every new fragment, and the header and footer inside one, stays in
        // the worksheet's namespace.
        #expect(!saved.sheetXML.contains("xmlns=\"\""))
        #expect(saved.sheetXML.contains("<oddHeader>&amp;L&amp;F&amp;CReport &amp; more&amp;R&amp;A</oddHeader>"))
        // In the order the schema fixes.
        let order = ["<sheetPr", "<sheetData", "<printOptions", "<pageMargins", "<pageSetup", "<headerFooter"]
            .map { saved.sheetXML.range(of: $0)?.lowerBound }
        #expect(order.allSatisfy { $0 != nil })
        #expect(order == order.sorted { ($0 ?? saved.sheetXML.startIndex) < ($1 ?? saved.sheetXML.startIndex) })

        // Back to a scale, the fit goes from the sheet's properties too.
        var second = saved.workbook
        var plain = setup
        plain.fitsToPages = false
        plain.scale = 70
        second.sheets[0].pageSetup = plain
        let again = try savedAndReopened(second)
        #expect(again.workbook.sheets[0].pageSetup == plain)
        #expect(!again.sheetXML.contains("pageSetUpPr"))
        #expect(again.sheetXML.contains("scale=\"70\""))
    }

    @Test("Page setup and header text no longer count as print settings Tables cannot edit")
    func noticeLeavesOutEditableSettings() throws {
        var first = sheet([
            ("pageSetup", "<pageSetup orientation=\"landscape\"/>"),
            ("headerFooter", "<headerFooter><oddFooter>&amp;P</oddFooter></headerFooter>"),
        ])
        first.pageSetup.printsGridlines = true
        let saved = try savedAndReopened(Workbook(sheets: [first]))
        #expect(!saved.workbook.unsupportedFeatures.preserved.contains(.printSetup))
        #expect(saved.workbook.unsupportedFeatures.lost.isEmpty)
    }

    // MARK: - Print area and titles

    @Test("The print area and titles are read from the sheet's built-in names")
    func readsNames() {
        var book = Workbook(sheets: [sheet(), Worksheet(name: "My Sheet")])
        let first = book.sheets[0].id, second = book.sheets[1].id
        book.definedNames = [
            DefinedName(name: "_xlnm.Print_Area", formula: "Sheet1!$B$2:$D$20", scope: first),
            DefinedName(name: "_xlnm.Print_Titles", formula: "Sheet1!$A:$B,Sheet1!$1:$2", scope: first),
            DefinedName(name: "_xlnm.Print_Area", formula: "'My Sheet'!$A$1:$C$5,'My Sheet'!$E$1:$F$5", scope: second),
            DefinedName(name: "_xlnm.Print_Titles", formula: "'My Sheet'!$3:$3", scope: second),
        ]
        #expect(book.printAreas(of: first) == [range("B2:D20")])
        #expect(book.printTitles(of: first) == PrintTitles(rows: 0...1, columns: 0...1))
        #expect(book.printAreas(of: second) == [range("A1:C5"), range("E1:F5")])
        #expect(book.printTitles(of: second) == PrintTitles(rows: 2...2, columns: nil))
        #expect(book.printSetup(of: first).areas == [range("B2:D20")])
    }

    @Test("Setting and clearing the print area and titles writes the built-in names")
    func writesNames() throws {
        var book = Workbook(sheets: [sheet(), Worksheet(name: "My Sheet")])
        let first = book.sheets[0].id, second = book.sheets[1].id
        book.definedNames = [DefinedName(name: "Total", formula: "Sheet1!$A$1", scope: nil)]

        var setup = book.printSetup(of: first)
        setup.areas = [range("A1:D20")]
        setup.titles = PrintTitles(rows: 0...1, columns: 0...0)
        book.setPrintSetup(setup, of: first)
        book.setPrintAreas([range("B2:C3")], of: second)

        #expect(book.definedNames.contains(DefinedName(name: "_xlnm.Print_Area", formula: "Sheet1!$A$1:$D$20", scope: first)))
        #expect(book.definedNames.contains(DefinedName(name: "_xlnm.Print_Titles", formula: "Sheet1!$A:$A,Sheet1!$1:$2", scope: first)))
        #expect(book.definedNames.contains(DefinedName(name: "_xlnm.Print_Area", formula: "'My Sheet'!$B$2:$C$3", scope: second)))
        // A name that only looks like a cell past Excel's last column stays bare;
        // one that is a cell is quoted.
        book.sheets[1].name = "AB12"
        book.setPrintAreas([range("B2:C3")], of: second)
        #expect(book.definedNames.contains(DefinedName(name: "_xlnm.Print_Area", formula: "'AB12'!$B$2:$C$3", scope: second)))
        book.sheets[1].name = "My Sheet"
        book.setPrintAreas([range("B2:C3")], of: second)

        let saved = try savedAndReopened(book)
        #expect(saved.workbookXML.contains("<definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">Sheet1!$A$1:$D$20</definedName>"))
        #expect(saved.workbookXML.contains("<definedName name=\"_xlnm.Print_Titles\" localSheetId=\"0\">Sheet1!$A:$A,Sheet1!$1:$2</definedName>"))
        let reopened = saved.workbook
        #expect(reopened.printSetup(of: reopened.sheets[0].id).areas == setup.areas)
        #expect(reopened.printTitles(of: reopened.sheets[0].id) == setup.titles)

        // Cleared, the names go; the user's own name stays.
        book.setPrintSetup(PrintSetup(), of: first)
        #expect(book.printAreas(of: first).isEmpty)
        #expect(book.printTitles(of: first) == PrintTitles())
        #expect(book.definedNames.map(\.name) == ["Total", "_xlnm.Print_Area"])
        #expect(book.printAreas(of: second) == [range("B2:C3")])
    }

    @Test("Typed ranges are read, and anything else refused")
    func typedRanges() {
        #expect(PrintSetup.areas(fromText: "") == [])
        #expect(PrintSetup.areas(fromText: " a1:d20 ") == [range("A1:D20")])
        #expect(PrintSetup.areas(fromText: "$A$1:$B$2,D4") == [range("A1:B2"), range("D4")])
        #expect(PrintSetup.areas(fromText: "hello world") == nil)
        #expect(PrintSetup.areasText([range("A1:D20"), range("F1")]) == "A1:D20,F1")

        #expect(PrintTitles.rows(fromText: "1:2") == .some(0...1))
        #expect(PrintTitles.rows(fromText: "$3") == .some(2...2))
        #expect(PrintTitles.rows(fromText: "") == .some(nil))
        #expect(PrintTitles.rows(fromText: "A:B") == nil)
        #expect(PrintTitles.rows(fromText: "0:2") == nil)
        #expect(PrintTitles.columns(fromText: "a:c") == .some(0...2))
        #expect(PrintTitles.columns(fromText: "$B") == .some(1...1))
        #expect(PrintTitles.columns(fromText: "1:2") == nil)
        #expect(PrintTitles(rows: 0...1, columns: 1...3).rowsText == "1:2")
        #expect(PrintTitles(rows: 0...1, columns: 1...3).columnsText == "B:D")
    }

    // MARK: - Pages

    /// Twelve rows of 20 and four columns.
    private func grid() -> (metrics: SheetMetrics, range: CellRange, columnWidth: Double) {
        var sheet = Worksheet(name: "Sheet1")
        sheet.standardRowHeight = 20
        let metrics = SheetMetrics(sheet: sheet)
        let range = CellRange(start: CellAddress(row: 0, column: 0), end: CellAddress(row: 11, column: 3))
        return (metrics, range, metrics.width(ofColumn: 0))
    }

    @Test("Title rows and columns take room on, and are named by, the pages past them")
    func titlesRepeat() {
        let (metrics, range, width) = grid()
        // Five rows and two and a half columns a page.
        let size = CGSize(width: width * 2.5, height: 100)
        let pagination = PrintPagination(
            areas: [range], metrics: metrics, pageSize: size, titles: PrintTitles(rows: 0...0, columns: 0...0))

        // The first page holds the titles themselves; the rest give a line up to them.
        #expect(pagination.rowBands == [0..<5, 5..<9, 9..<12])
        #expect(pagination.columnBands == [0..<2, 2..<3, 3..<4])
        #expect(pagination.pages.count == 9)
        #expect(pagination.pages[0].titleRows == nil && pagination.pages[0].titleColumns == nil)
        #expect(pagination.pages[1].titleRows == 0..<1 && pagination.pages[1].titleColumns == nil)
        #expect(pagination.pages[3].titleRows == nil && pagination.pages[3].titleColumns == 0..<1)
        #expect(pagination.pages[4].titleRows == 0..<1 && pagination.pages[4].titleColumns == 0..<1)
        for page in pagination.pages {
            let titles = page.titleRows == nil ? 0.0 : 20
            #expect(Double(page.frame.height) + titles <= 100)
        }
    }

    @Test("Without titles or breaks the areas paginate as a plain range does")
    func plainAreaMatchesRange() {
        let (metrics, range, width) = grid()
        let size = CGSize(width: width * 2.5, height: 100)
        let plain = PrintPagination(range: range, metrics: metrics, pageSize: size)
        let areas = PrintPagination(areas: [range], metrics: metrics, pageSize: size)
        #expect(areas == plain)
    }

    @Test("Each print area starts on a page of its own, and only its cells print")
    func severalAreas() {
        let (metrics, _, width) = grid()
        let size = CGSize(width: width * 10, height: 100)
        let first = CellRange(start: CellAddress(row: 2, column: 1), end: CellAddress(row: 3, column: 2))
        let second = CellRange(start: CellAddress(row: 6, column: 0), end: CellAddress(row: 12, column: 0))
        let pagination = PrintPagination(areas: [first, second], metrics: metrics, pageSize: size)
        #expect(pagination.pages.map(\.rows) == [2..<4, 6..<11, 11..<13])
        #expect(pagination.pages.map(\.columns) == [1..<3, 0..<1, 0..<1])
        #expect(pagination.range == first)
    }

    @Test("A manual break starts a new page at its line")
    func manualBreaks() {
        let (metrics, range, width) = grid()
        let size = CGSize(width: width * 10, height: 100)
        let pagination = PrintPagination(
            areas: [range], metrics: metrics, pageSize: size, rowBreaks: [3], columnBreaks: [2])
        #expect(pagination.rowBands == [0..<3, 3..<8, 8..<12])
        #expect(pagination.columnBands == [0..<2, 2..<4])

        let sheet = sheet([
            ("rowBreaks", "<rowBreaks count=\"1\" manualBreakCount=\"1\"><brk id=\"3\" max=\"16383\" man=\"1\"/></rowBreaks>"),
            ("colBreaks", "<colBreaks count=\"1\" manualBreakCount=\"1\"><brk id=\"2\" max=\"1048575\" man=\"1\"/></colBreaks>"),
        ])
        #expect(sheet.manualPageBreaks.rows == [3])
        #expect(sheet.manualPageBreaks.columns == [2])
    }

    @Test("Fitting to pages finds the largest scale that takes no more pages than asked")
    func fittedScale() {
        let (metrics, range, width) = grid()
        // Full size needs 240 down and four columns across.
        let size = CGSize(width: width * 2, height: 120)

        // One page wide, as tall as it takes: half size, for four columns in the room of two.
        let wide = PrintPagination.fittedScale(areas: [range], metrics: metrics, pageSize: size, wide: 1, tall: 0)
        #expect(wide == 0.5)
        // One page each way: the same, as 240 down already fits at half size.
        #expect(PrintPagination.fittedScale(areas: [range], metrics: metrics, pageSize: size, wide: 1, tall: 1) == 0.5)
        // Two pages each way fit as they are; nothing is ever enlarged.
        #expect(PrintPagination.fittedScale(areas: [range], metrics: metrics, pageSize: size, wide: 2, tall: 2) == 1)
        // Whole rows have to fit: 12 rows of 20 on pages of 130 go 6 and 6, but 7 rows of 20 on 130 do not.
        let tall = PrintPagination.fittedScale(
            areas: [range], metrics: metrics, pageSize: CGSize(width: width * 10, height: 50), wide: 0, tall: 2)
        let pages = PrintPagination(
            areas: [range], metrics: metrics, pageSize: CGSize(width: width * 10 / tall, height: 50 / tall))
        #expect(pages.rowBands.count == 2)
        let larger = PrintPagination(
            areas: [range], metrics: metrics,
            pageSize: CGSize(width: width * 10 / (tall + 0.01), height: 50 / (tall + 0.01)))
        #expect(larger.rowBands.count > 2)
        // Never below Excel's floor.
        let tiny = PrintPagination.fittedScale(
            areas: [range], metrics: metrics, pageSize: CGSize(width: 1, height: 1), wide: 1, tall: 1)
        #expect(tiny == 0.1)
    }
}
