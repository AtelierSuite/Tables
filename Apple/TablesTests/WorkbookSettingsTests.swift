import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Covers what `xl/workbook.xml` holds beside the sheet list: calculation
/// settings, workbook protection, the windows' active tab, the rest of
/// `<workbookPr>`, and very hidden sheets.
@Suite("Workbook settings")
struct WorkbookSettingsTests {

    // MARK: - Fixtures

    private static let workbookPart = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:xr2="http://schemas.microsoft.com/office/spreadsheetml/2015/revision2">\
    <workbookPr codeName="ThisWorkbook" filterPrivacy="1" defaultThemeVersion="166925" backupFile="1"/>\
    <workbookProtection lockStructure="1" lockWindows="1" workbookAlgorithmName="SHA-512" \
    workbookHashValue="aGFzaA==" workbookSaltValue="c2FsdA==" workbookSpinCount="100000"/>\
    <bookViews><workbookView xWindow="240" yWindow="120" windowWidth="28800" windowHeight="17000" \
    tabRatio="600" firstSheet="1" activeTab="2" xr2:uid="{00000000-0000-0000-0000-000000000000}"/></bookViews>\
    <sheets>\
    <sheet name="Inputs" sheetId="1" r:id="rId1"/>\
    <sheet name="Notes" sheetId="2" state="hidden" r:id="rId2"/>\
    <sheet name="Summary" sheetId="3" r:id="rId3"/>\
    <sheet name="Lookup" sheetId="4" state="veryHidden" r:id="rId4"/>\
    </sheets>\
    <calcPr calcId="191029" calcMode="manual" iterate="1" iterateCount="250" iterateDelta="0.0001" \
    fullPrecision="0" calcOnSave="0"/>\
    </workbook>
    """

    private func package(workbook: String = Self.workbookPart, sheetCount: Int = 4,
                         cells: String = "") throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/></Types>
        """
        let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="xl/workbook.xml"/></Relationships>
        """
        var relationships = ""
        var parts: [(path: String, data: Data)] = []
        for number in 1...sheetCount {
            relationships += """
            <Relationship Id="rId\(number)" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
            Target="worksheets/sheet\(number).xml"/>
            """
            let sheet = """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <sheetData>\(number == 1 ? cells : "")</sheetData></worksheet>
            """
            parts.append(("xl/worksheets/sheet\(number).xml", Data(sheet.utf8)))
        }
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(relationships)</Relationships>
        """
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
        ] + parts)
    }

    private func workbookXML(_ workbook: Workbook) throws -> String {
        let entries = try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))
        return String(decoding: try #require(entries["xl/workbook.xml"]), as: UTF8.self)
    }

    private func element(_ name: String, in xml: String) throws -> XMLElement {
        try #require(try XMLLite.parse(Data(xml.utf8)).firstChild(named: name))
    }

    // MARK: - Reading

    @Test("The workbook part's settings are read")
    func readsSettings() throws {
        let workbook = try XLSXReader.workbook(from: try package())
        let settings = workbook.settings

        #expect(settings.isManualCalculation)
        #expect(settings.iteration == WorkbookSettings.Iteration(maximumCount: 250, maximumChange: 0.0001))
        #expect(settings.calculation["fullPrecision"] == "0")
        #expect(settings.protection?["lockStructure"] == "1")
        #expect(settings.protection?["workbookHashValue"] == "aGFzaA==")
        #expect(settings.properties == ["filterPrivacy": "1", "defaultThemeVersion": "166925", "backupFile": "1"])
        #expect(workbook.codeName == "ThisWorkbook")
        #expect(settings.activeSheetID == workbook.sheets[2].id)
        #expect(settings.views.first?.firstSheetID == workbook.sheets[1].id)
        // An attribute in another namespace has lost its prefix, so it is not kept.
        #expect(settings.views.first?.attributes["uid"] == nil)
    }

    @Test("The workbook opens on its active tab")
    func opensOnActiveTab() throws {
        let workbook = try XLSXReader.workbook(from: try package())
        #expect(workbook.openingSheetID == workbook.sheets[2].id)
    }

    @Test("An active tab that is hidden gives way to the first visible sheet")
    func hiddenActiveTabFallsBack() throws {
        let xml = Self.workbookPart.replacingOccurrences(of: "activeTab=\"2\"", with: "activeTab=\"1\"")
        let workbook = try XLSXReader.workbook(from: try package(workbook: xml))
        #expect(workbook.openingSheetID == workbook.sheets[0].id)
    }

    @Test("A very hidden sheet is hidden, and not offered to unhide")
    func veryHiddenSheet() throws {
        let workbook = try XLSXReader.workbook(from: try package())
        #expect(workbook.sheets.map(\.isHidden) == [false, true, false, true])
        #expect(workbook.sheets.map(\.isVeryHidden) == [false, false, false, true])
        #expect(workbook.unhidableSheets.map(\.name) == ["Notes"])
    }

    // MARK: - Writing

    @Test("Settings survive a save")
    func settingsRoundTrip() throws {
        let workbook = try XLSXReader.workbook(from: try package())
        let xml = try workbookXML(workbook)

        let properties = try element("workbookPr", in: xml)
        #expect(properties.attribute("codeName") == "ThisWorkbook")
        #expect(properties.attribute("filterPrivacy") == "1")
        #expect(properties.attribute("defaultThemeVersion") == "166925")
        #expect(properties.attribute("backupFile") == "1")

        let protection = try element("workbookProtection", in: xml)
        #expect(protection.attributes == [
            "lockStructure": "1", "lockWindows": "1", "workbookAlgorithmName": "SHA-512",
            "workbookHashValue": "aGFzaA==", "workbookSaltValue": "c2FsdA==", "workbookSpinCount": "100000",
        ])

        let view = try #require(try element("bookViews", in: xml).firstChild(named: "workbookView"))
        #expect(view.attributes == [
            "xWindow": "240", "yWindow": "120", "windowWidth": "28800", "windowHeight": "17000",
            "tabRatio": "600", "firstSheet": "1", "activeTab": "2",
        ])

        let calculation = try element("calcPr", in: xml)
        #expect(calculation.attribute("calcMode") == "manual")
        #expect(calculation.attribute("iterate") == "1")
        #expect(calculation.attribute("iterateCount") == "250")
        #expect(calculation.attribute("iterateDelta") == "0.0001")
        #expect(calculation.attribute("fullPrecision") == "0")
        #expect(calculation.attribute("calcOnSave") == "0")
        #expect(calculation.attribute("fullCalcOnLoad") == "1")

        #expect(xml.contains("<sheet name=\"Lookup\" sheetId=\"4\" state=\"veryHidden\""))
        #expect(xml.contains("<sheet name=\"Notes\" sheetId=\"2\" state=\"hidden\""))

        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: workbook))
        #expect(reopened.settings.calculation == workbook.settings.calculation)
        #expect(reopened.settings.protection == workbook.settings.protection)
        #expect(reopened.settings.properties == workbook.settings.properties)
        #expect(reopened.sheets.map(\.isVeryHidden) == [false, false, false, true])
        #expect(reopened.openingSheetID == reopened.sheets[2].id)
    }

    @Test("The workbook part's children are written in schema order")
    func schemaOrder() throws {
        let xml = try workbookXML(try XLSXReader.workbook(from: try package()))
        let order = ["<workbookPr", "<workbookProtection", "<bookViews", "<sheets", "<calcPr"]
        let positions = try order.map { try #require(xml.range(of: $0)).lowerBound }
        #expect(positions == positions.sorted())
    }

    @Test("The active tab follows its sheet when sheets move")
    func activeTabFollowsSheet() throws {
        var workbook = try XLSXReader.workbook(from: try package())
        let summary = workbook.sheets[2].id
        workbook.moveSheet(summary, to: 0)
        let view = try #require(try element("bookViews", in: try workbookXML(workbook)).firstChild(named: "workbookView"))
        #expect(view.attribute("activeTab") == nil)  // 0, the default
        #expect(view.attribute("firstSheet") == "2")

        workbook.removeSheet(summary)
        let after = try #require(try element("bookViews", in: try workbookXML(workbook)).firstChild(named: "workbookView"))
        #expect(after.attribute("activeTab") == nil)
        #expect(after.attribute("firstSheet") == "1")
    }

    @Test("A workbook made in Tables writes only the calculation settings")
    func freshWorkbook() throws {
        let xml = try workbookXML(Workbook())
        #expect(!xml.contains("<workbookPr"))
        #expect(!xml.contains("<workbookProtection"))
        #expect(!xml.contains("<bookViews"))
        #expect(xml.contains("<calcPr calcId=\"0\" fullCalcOnLoad=\"1\"/>"))
    }

    @Test("Showing a very hidden sheet makes it an ordinary one")
    func showingVeryHiddenSheet() throws {
        var workbook = try XLSXReader.workbook(from: try package())
        let lookup = workbook.sheets[3].id
        let changed1 = workbook.setSheet(lookup, hidden: false)
        #expect(changed1)
        #expect(workbook[lookup]?.isVeryHidden == false)
        let changed2 = workbook.setSheet(lookup, hidden: true)
        #expect(changed2)
        #expect(workbook[lookup]?.isVeryHidden == false)
        #expect(workbook.unhidableSheets.map(\.name) == ["Notes", "Lookup"])
        let changed3 = workbook.setSheet(lookup, hidden: true, veryHidden: true)
        #expect(changed3)
        #expect(workbook.unhidableSheets.map(\.name) == ["Notes"])
    }

    // MARK: - Iterative calculation

    private func circularWorkbook(iterate: Bool, count: Int = 100, delta: Double = 0.001) -> Workbook {
        var sheet = Worksheet(name: "Sheet1")
        // A1 halves its way toward 10: A1 = (A1 + 10) / 2.
        sheet[CellAddress(a1: "A1")!] = Cell(value: .empty, formula: "(A1+10)/2", style: .default)
        sheet[CellAddress(a1: "B1")!] = Cell(value: .empty, formula: "A1*2", style: .default)
        var workbook = Workbook(sheets: [sheet])
        if iterate {
            workbook.settings.calculation = [
                "iterate": "1", "iterateCount": String(count), "iterateDelta": String(delta),
            ]
        }
        return workbook
    }

    @Test("Without iterative calculation a circular reference is an error")
    func circularReferenceError() {
        var workbook = circularWorkbook(iterate: false)
        workbook.recalculate()
        #expect(workbook.sheets[0][CellAddress(a1: "A1")!].value == .error(.circularReference))
    }

    @Test("With iterative calculation a circular reference settles")
    func circularReferenceIterates() throws {
        var workbook = circularWorkbook(iterate: true)
        workbook.recalculate()
        guard case .number(let a1) = workbook.sheets[0][CellAddress(a1: "A1")!].value else {
            Issue.record("A1 is not a number")
            return
        }
        #expect(abs(a1 - 10) < 0.01)
        guard case .number(let b1) = workbook.sheets[0][CellAddress(a1: "B1")!].value else {
            Issue.record("B1 is not a number")
            return
        }
        #expect(abs(b1 - 20) < 0.02)
    }

    @Test("Iteration stops at the file's maximum count")
    func iterationCount() throws {
        var workbook = circularWorkbook(iterate: true, count: 3, delta: 0)
        workbook.recalculate()
        // 0 → 5 → 7.5 → 8.75
        #expect(workbook.sheets[0][CellAddress(a1: "A1")!].value == .number(8.75))
    }

    @Test("Iteration settings are read from the file and used")
    func iterationFromFile() throws {
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>\
        <calcPr calcId="191029" iterate="1" iterateCount="2" iterateDelta="0"/></workbook>
        """
        var opened = try XLSXReader.workbook(
            from: try package(workbook: workbook, sheetCount: 1,
                              cells: "<row r=\"1\"><c r=\"A1\"><f>(A1+10)/2</f><v>0</v></c></row>"))
        // Opening recalculates: 0 → 5 → 7.5.
        #expect(opened.sheets[0][CellAddress(a1: "A1")!].value == .number(7.5))
        // Each recalculation carries on from where the last one stopped.
        opened.recalculate()
        #expect(opened.sheets[0][CellAddress(a1: "A1")!].value == .number(9.375))
    }
}
