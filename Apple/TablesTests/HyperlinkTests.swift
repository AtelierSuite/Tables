import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Links on cells: read from a file, kept through a save, moved with the
/// cells they are on, and followed to where they lead.
@Suite("Hyperlinks")
struct HyperlinkTests {

    // MARK: - Package construction

    private static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// A two-sheet package, "Sheet1" with `body` after its cells and the
    /// sheet relationships given, and an empty "Data Sheet".
    private func package(body: String, sheetRelationships: String = "", definedNames: String = "") throws -> Data {
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
        <Relationship Id="rId1" Type="\(Self.relationships)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\(Self.relationships)">\
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/><sheet name="Data Sheet" sheetId="2" r:id="rId2"/></sheets>\
        \(definedNames)</workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(Self.relationships)/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="\(Self.relationships)/worksheet" Target="worksheets/sheet2.xml"/></Relationships>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="1"><font><sz val="11"/></font></fonts>\
        <fills count="1"><fill><patternFill patternType="none"/></fill></fills>\
        <borders count="1"><border/></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
        """
        func sheet(_ body: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="\(Self.relationships)">\
            <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Site</t></is></c></row></sheetData>\(body)</worksheet>
            """
        }
        var entries: [(path: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/styles.xml", Data(styles.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet(body).utf8)),
            ("xl/worksheets/sheet2.xml", Data(sheet("").utf8)),
        ]
        if !sheetRelationships.isEmpty {
            let payload = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            \(sheetRelationships)</Relationships>
            """
            entries.append(("xl/worksheets/_rels/sheet1.xml.rels", Data(payload.utf8)))
        }
        return try ZipArchive.archive(entries: entries)
    }

    private func external(_ id: String, _ target: String) -> String {
        "<Relationship Id=\"\(id)\" Type=\"\(Self.relationships)/hyperlink\" Target=\"\(target)\" TargetMode=\"External\"/>"
    }

    private func text(_ entries: [String: Data], _ path: String) throws -> String {
        String(decoding: try #require(entries[path], "\(path) is missing"), as: UTF8.self)
    }

    private func a1(_ reference: String) -> CellAddress { CellAddress(a1: reference)! }

    /// Excel's way of writing each kind of link.
    private func excelStyleWorkbook() throws -> Workbook {
        let body = """
        <hyperlinks>\
        <hyperlink ref="A1" r:id="rId1" tooltip="Open the site" display="Site"/>\
        <hyperlink ref="A2" r:id="rId2"/>\
        <hyperlink ref="A3" location="'Data Sheet'!B4" display="Go"/>\
        <hyperlink ref="B1:C2" r:id="rId3" location="Summary"/>\
        </hyperlinks>
        """
        let relationships = external("rId1", "https://example.com/a?b=1&amp;c=2")
            + external("rId2", "mailto:someone@example.com")
            + external("rId3", "other.xlsx")
        return try XLSXReader.workbook(from: try package(body: body, sheetRelationships: relationships))
    }

    // MARK: - Reading

    @Test("Outside addresses, email, places in the workbook, display text and tooltips are read")
    func readsEveryKindOfLink() throws {
        let workbook = try excelStyleWorkbook()
        let links = workbook.sheets[0].hyperlinks

        #expect(links[a1("A1")] == CellHyperlink(
            address: "https://example.com/a?b=1&c=2", display: "Site", tooltip: "Open the site"))
        #expect(links[a1("A2")] == CellHyperlink(address: "mailto:someone@example.com"))
        #expect(links[a1("A3")] == CellHyperlink(location: "'Data Sheet'!B4", display: "Go"))
        // A link on a range is on each of its cells.
        for reference in ["B1", "C1", "B2", "C2"] {
            #expect(links[a1(reference)] == CellHyperlink(address: "other.xlsx", location: "Summary"))
        }
        #expect(links.count == 7)
        #expect(links[a1("B1")]?.target == "other.xlsx#Summary")
        // They are modelled now, not kept as something Tables can't edit.
        #expect(!workbook.unsupportedFeatures.preserved.contains(.hyperlinks))
        #expect(!workbook.unsupportedFeatures.lost.contains(.hyperlinks))
        #expect(!workbook.sheets[0].preservedElements.contains { $0.name == "hyperlinks" })
    }

    @Test("A link whose relationship is missing goes nowhere and is dropped")
    func danglingRelationshipIsDropped() throws {
        let body = """
        <hyperlinks><hyperlink ref="A1" r:id="rId9"/><hyperlink ref="A2" location="A5"/></hyperlinks>
        """
        let workbook = try XLSXReader.workbook(from: try package(body: body))
        #expect(workbook.sheets[0].hyperlinks == [a1("A2"): CellHyperlink(location: "A5")])

        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        let sheet = try text(entries, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("<hyperlinks><hyperlink ref=\"A2\" location=\"A5\"/></hyperlinks>"), "\(sheet)")
        #expect(!sheet.contains("rId9"))
    }

    // MARK: - Saving

    @Test("Links survive a save, each outside address with a relationship of its own")
    func roundTrip() throws {
        let workbook = try excelStyleWorkbook()
        let saved = try XLSXWriter.data(from: workbook)
        let entries = try ZipArchive.entries(in: saved)

        let sheet = try text(entries, "xl/worksheets/sheet1.xml")
        let relationships = try text(entries, "xl/worksheets/_rels/sheet1.xml.rels")
        let root = try XMLLite.parse(Data(relationships.utf8))
        let targets = Dictionary(uniqueKeysWithValues: root.children(named: "Relationship").map {
            ($0.attribute("Id") ?? "", $0)
        })
        let list = try #require(try XMLLite.parse(Data(sheet.utf8)).firstChild(named: "hyperlinks"))
        let written = list.children(named: "hyperlink")
        #expect(written.count == 7)
        for link in written where link.attribute("id") != nil {
            let relationship = try #require(targets[link.attribute("id")!])
            #expect(relationship.attribute("Type") == "\(Self.relationships)/hyperlink")
            #expect(relationship.attribute("TargetMode") == "External")
        }
        // Each relationship the file had is written once, not again beside ours.
        #expect(relationships.components(separatedBy: "mailto:someone@example.com").count == 2)
        #expect(relationships.contains("https://example.com/a?b=1&amp;c=2"))
        // The list sits in its schema slot: after the cells, before the margins.
        let hyperlinks = try #require(sheet.range(of: "<hyperlinks>"))
        let cells = try #require(sheet.range(of: "</sheetData>"))
        #expect(cells.upperBound <= hyperlinks.lowerBound)

        let reopened = try XLSXReader.workbook(from: saved)
        #expect(reopened.sheets[0].hyperlinks == workbook.sheets[0].hyperlinks)
    }

    @Test("A link added to a new workbook is saved with the sheet relationships it needs")
    func newLinkIsSaved() throws {
        var workbook = Workbook(sheets: [Worksheet(name: "Sheet1")])
        workbook.sheets[0][a1("B2")] = Cell(value: .text("Docs"))
        workbook.sheets[0].hyperlinks[a1("B2")] = CellHyperlink(address: "https://example.com/docs", tooltip: "Read")
        workbook.sheets[0].hyperlinks[a1("B3")] = CellHyperlink(location: "Sheet1!A1")

        let saved = try XLSXWriter.data(from: workbook)
        let entries = try ZipArchive.entries(in: saved)
        let sheet = try text(entries, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("<hyperlink ref=\"B2\" r:id=\"rId1\" tooltip=\"Read\"/>"), "\(sheet)")
        #expect(sheet.contains("<hyperlink ref=\"B3\" location=\"Sheet1!A1\"/>"))
        let relationships = try text(entries, "xl/worksheets/_rels/sheet1.xml.rels")
        #expect(relationships.contains("Id=\"rId1\""))
        #expect(relationships.contains("Target=\"https://example.com/docs\" TargetMode=\"External\""))

        #expect(try XLSXReader.workbook(from: saved).sheets[0].hyperlinks == workbook.sheets[0].hyperlinks)
    }

    // MARK: - Rows and columns

    @Test("Links move with their cells when rows and columns come and go")
    func linksFollowStructuralEdits() {
        var sheet = Worksheet(name: "Sheet1")
        let link = CellHyperlink(address: "https://example.com")
        sheet.hyperlinks[a1("B2")] = link
        sheet.hyperlinks[a1("C5")] = CellHyperlink(location: "A1")

        sheet.insertRows(2, at: 0)
        #expect(sheet.hyperlinks[a1("B4")] == link)
        #expect(sheet.hyperlinks[a1("C7")] != nil)
        sheet.insertColumns(1, at: 1)
        #expect(sheet.hyperlinks[a1("C4")] == link)
        sheet.removeRows(3...3)
        #expect(sheet.hyperlinks[a1("C4")] == nil)
        #expect(sheet.hyperlinks.keys.sorted() == [a1("D6")])
        sheet.removeColumns(0...0)
        #expect(sheet.hyperlinks.keys.sorted() == [a1("C6")])
    }

    @Test("Moving cells carries their links; copying leaves them on the original too")
    func linksMoveWithCells() {
        var workbook = Workbook(sheets: [Worksheet(name: "Sheet1")])
        let id = workbook.sheets[0].id
        let link = CellHyperlink(address: "https://example.com")
        workbook.sheets[0][a1("A1")] = Cell(value: .text("Site"))
        workbook.sheets[0].hyperlinks[a1("A1")] = link

        let moved = workbook.moveCells(CellRange(a1("A1")), on: id, to: a1("C3"), copying: false)
        #expect(moved)
        #expect(workbook.sheets[0].hyperlinks == [a1("C3"): link])
        let copied = workbook.moveCells(CellRange(a1("C3")), on: id, to: a1("D4"), copying: true)
        #expect(copied)
        #expect(workbook.sheets[0].hyperlinks == [a1("C3"): link, a1("D4"): link])
    }

    // MARK: - Following

    @Test("A place in the workbook leads to its sheet and range")
    func placesResolve() throws {
        let body = "<hyperlinks><hyperlink ref=\"A1\" location=\"Totals\"/></hyperlinks>"
        let names = "<definedNames><definedName name=\"Totals\">'Data Sheet'!$B$2:$C$3</definedName></definedNames>"
        let workbook = try XLSXReader.workbook(from: try package(body: body, definedNames: names))
        let first = workbook.sheets[0].id, data = workbook.sheets[1].id

        #expect(workbook.destination(ofLocation: "B7", from: first)! == (first, CellRange(a1("B7"))))
        #expect(workbook.destination(ofLocation: "'Data Sheet'!C4:D5", from: first)!
            == (data, CellRange(start: a1("C4"), end: a1("D5"))))
        #expect(workbook.destination(ofLocation: "Sheet1!$A$2", from: data)! == (first, CellRange(a1("A2"))))
        #expect(workbook.destination(ofLocation: "Totals", from: first)!
            == (data, CellRange(start: a1("B2"), end: a1("C3"))))
        #expect(workbook.destination(ofLocation: "Missing!A1", from: first) == nil)
        #expect(workbook.destination(ofLocation: "NoSuchName", from: first) == nil)

        let link = try #require(workbook.sheets[0].hyperlinks[a1("A1")])
        #expect(workbook.destination(of: link, from: first)
            == .cells(sheet: data, range: CellRange(start: a1("B2"), end: a1("C3"))))
        #expect(workbook.destination(of: CellHyperlink(address: "https://example.com"), from: first)
            == .external("https://example.com"))
    }

    @Test("What a person types becomes a web page, an email or a place in the workbook")
    func typedLinksAreUnderstood() throws {
        let workbook = try XLSXReader.workbook(from: try package(body: ""))
        let sheet = workbook.sheets[0].id
        func parse(_ text: String) -> CellHyperlink? { CellHyperlink.parse(text, in: workbook, from: sheet) }

        #expect(parse("https://example.com/x") == CellHyperlink(address: "https://example.com/x"))
        #expect(parse("example.com") == CellHyperlink(address: "https://example.com"))
        #expect(parse("www.example.co.jp/path") == CellHyperlink(address: "https://www.example.co.jp/path"))
        #expect(parse("someone@example.com") == CellHyperlink(address: "mailto:someone@example.com"))
        #expect(parse("mailto:a@b.com") == CellHyperlink(address: "mailto:a@b.com"))
        #expect(parse("  'Data Sheet'!B2 ") == CellHyperlink(location: "'Data Sheet'!B2"))
        #expect(parse("C9") == CellHyperlink(location: "C9"))
        #expect(parse("#Anywhere") == CellHyperlink(location: "Anywhere"))
        #expect(parse("report.pdf") == CellHyperlink(address: "report.pdf"))
        #expect(parse("   ") == nil)
    }

    @Test("A HYPERLINK formula is a link to the address it names")
    func hyperlinkFunctionIsALink() {
        var workbook = Workbook(sheets: [Worksheet(name: "Sheet1"), Worksheet(name: "Sheet2")])
        let id = workbook.sheets[0].id
        workbook.sheets[0][a1("A1")] = Cell(formula: "HYPERLINK(\"https://example.com/a,b\",\"Example\")")
        workbook.sheets[0][a1("A2")] = Cell(value: .text("example.org"))
        workbook.sheets[0][a1("A3")] = Cell(formula: "HYPERLINK(\"https://\"&A2)")
        workbook.sheets[0][a1("A4")] = Cell(formula: "HYPERLINK(\"#Sheet2!B3\",\"Jump\")")
        workbook.sheets[0][a1("A5")] = Cell(formula: "UPPER(\"x\")")
        workbook.sheets[0][a1("A6")] = Cell(formula: "HYPERLINK(\"https://a.example\")&\"!\"")
        workbook.recalculate()

        #expect(workbook.hyperlink(at: a1("A1"), onSheet: id) == CellHyperlink(address: "https://example.com/a,b"))
        #expect(workbook.hyperlink(at: a1("A3"), onSheet: id) == CellHyperlink(address: "https://example.org"))
        let jump = workbook.hyperlink(at: a1("A4"), onSheet: id)
        #expect(jump == CellHyperlink(location: "Sheet2!B3"))
        #expect(workbook.destination(of: jump!, from: id)
            == .cells(sheet: workbook.sheets[1].id, range: CellRange(a1("B3"))))
        #expect(workbook.hyperlink(at: a1("A5"), onSheet: id) == nil)
        #expect(workbook.hyperlink(at: a1("A6"), onSheet: id) == nil)
        // A link set on the cell wins over its formula's.
        workbook.sheets[0].hyperlinks[a1("A1")] = CellHyperlink(location: "A9")
        #expect(workbook.hyperlink(at: a1("A1"), onSheet: id) == CellHyperlink(location: "A9"))
    }

    // MARK: - Editing

    @Test("Adding a link sets what the cell shows and gives it the link look; removing takes both away")
    @MainActor
    func addEditAndRemove() {
        var workbook = Workbook(sheets: [Worksheet(name: "Sheet1"), Worksheet(name: "Sheet2")])
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id

        // A blank cell with no text given shows the link itself.
        #expect(state.setHyperlink("example.com", display: "", at: a1("A1"), in: &workbook))
        #expect(workbook.sheets[0].hyperlinks[a1("A1")] == CellHyperlink(address: "https://example.com"))
        #expect(workbook.sheets[0][a1("A1")].value == .text("https://example.com"))
        #expect(workbook.sheets[0][a1("A1")].style.isUnderlined)
        #expect(workbook.sheets[0][a1("A1")].style.textColorHex == CellHyperlink.textColorHex)

        // Editing: a place in the workbook, with text of its own.
        #expect(state.setHyperlink("Sheet2!B2", display: "Totals", at: a1("A1"), in: &workbook))
        #expect(workbook.sheets[0].hyperlinks[a1("A1")] == CellHyperlink(location: "Sheet2!B2", display: "Totals"))
        #expect(workbook.sheets[0][a1("A1")].value == .text("Totals"))
        #expect(state.hyperlinkDestination(at: a1("A1"), in: workbook)
            == .cells(sheet: workbook.sheets[1].id, range: CellRange(a1("B2"))))

        // Following it brings the cell up, once its sheet is.
        state.selectSheet(workbook.sheets[1].id, in: workbook)
        state.reveal(CellRange(a1("B2")), in: workbook)
        #expect(state.selection.normalized == CellRange(a1("B2")))
        #expect(state.scrollTarget == a1("B2"))
        state.selectSheet(workbook.sheets[0].id, in: workbook)

        // Nothing typed is no link.
        #expect(!state.setHyperlink("  ", display: "x", at: a1("A2"), in: &workbook))
        #expect(workbook.sheets[0].hyperlinks[a1("A2")] == nil)

        state.select(a1("A1"))
        #expect(state.selectionHasHyperlinks(in: workbook))
        state.removeHyperlinks(in: &workbook)
        #expect(workbook.sheets[0].hyperlinks.isEmpty)
        #expect(!workbook.sheets[0][a1("A1")].style.isUnderlined)
        #expect(workbook.sheets[0][a1("A1")].style.textColorHex == nil)
        #expect(workbook.sheets[0][a1("A1")].value == .text("Totals"))
    }

    @Test("Removing a link read from a file takes away the file's link look too")
    @MainActor
    func removingAFileLinkResetsItsLook() {
        var workbook = Workbook(sheets: [Worksheet(name: "Sheet1")])
        var style = CellStyle.default
        style.textColorHex = "FF0563C1"
        style.isUnderlined = true
        workbook.sheets[0][a1("B2")] = Cell(value: .text("Site"), style: style)
        workbook.sheets[0].hyperlinks[a1("B2")] = CellHyperlink(address: "https://example.com")
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        state.select(a1("B2"))
        state.removeHyperlinks(in: &workbook)
        #expect(workbook.sheets[0].hyperlinks.isEmpty)
        #expect(workbook.sheets[0][a1("B2")].style.textColorHex == nil)
        #expect(!workbook.sheets[0][a1("B2")].style.isUnderlined)
    }

    @Test("A formula's cell keeps its formula when a link is set on it")
    @MainActor
    func linkOnAFormulaKeepsTheFormula() {
        var workbook = Workbook(sheets: [Worksheet(name: "Sheet1")])
        workbook.sheets[0][a1("A1")] = Cell(formula: "1+1")
        workbook.recalculate()
        let state = EditorState()
        state.activeSheetID = workbook.sheets[0].id
        #expect(state.setHyperlink("https://example.com", display: "Ignored", at: a1("A1"), in: &workbook))
        #expect(workbook.sheets[0][a1("A1")].formula == "1+1")
        #expect(workbook.sheets[0].hyperlinks[a1("A1")]?.display == nil)
    }

    @Test("Only an address with a scheme is opened by the system")
    @MainActor
    func urlsNeedASchemeToOpen() {
        #expect(EditorState.url(forHyperlinkAddress: "https://example.com/a b")?.host == "example.com")
        #expect(EditorState.url(forHyperlinkAddress: "mailto:a@b.com")?.scheme == "mailto")
        #expect(EditorState.url(forHyperlinkAddress: "report.pdf") == nil)
    }
}
