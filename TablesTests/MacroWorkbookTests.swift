import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// What a workbook with macros needs from a save beyond its cells: the names
/// that bind its modules to its sheets.
@Suite("Macro workbooks")
struct MacroWorkbookTests {
    @Test("Code names survive a save, and a duplicated sheet does not inherit one")
    func codeNames() throws {
        var sheet = Worksheet(name: "Data")
        sheet.codeName = "shtData"
        var workbook = Workbook(sheets: [sheet])
        workbook.codeName = "ThisWorkbook"

        let reloaded = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        #expect(reloaded.codeName == "ThisWorkbook")
        #expect(reloaded.sheets[0].codeName == "shtData")

        var copied = reloaded
        let duplicated = copied.duplicateSheet(copied.sheets[0].id)
        let copyID = try #require(duplicated)
        #expect(copied.sheets[copied.index(of: copyID)!].codeName == nil)
    }

    // MARK: - The macro project

    /// Stand-in bytes: nothing here parses the project, only carries it.
    private static let projectBytes = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 1, 2, 3])
    private static let signatureBytes = Data([0x30, 0x82, 4, 5, 6])

    /// A minimal `.xlsm` the way Excel lays one out: the project typed by the
    /// `bin` default, its signature by an override and reached through the
    /// project's own `_rels`.
    private func macroPackage() throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="bin" ContentType="application/vnd.ms-office.vbaProject"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.ms-excel.sheet.macroEnabled.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/vbaProjectSignature.bin" ContentType="application/vnd.ms-office.vbaProjectSignature"/>\
        </Types>
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
        <workbookPr codeName="ThisWorkbook"/>\
        <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.microsoft.com/office/2006/relationships/vbaProject" \
        Target="vbaProject.bin"/></Relationships>
        """
        let projectRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.microsoft.com/office/2006/relationships/vbaProjectSignature" \
        Target="vbaProjectSignature.bin"/></Relationships>
        """
        let sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetPr codeName="Sheet1"/><sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData></worksheet>
        """
        return try ZipArchive.archive(entries: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheet.utf8)),
            ("xl/vbaProject.bin", Self.projectBytes),
            ("xl/_rels/vbaProject.bin.rels", Data(projectRels.utf8)),
            ("xl/vbaProjectSignature.bin", Self.signatureBytes),
        ])
    }

    @Test("Opening an .xlsm finds its macros and reports them as kept")
    func readsMacros() throws {
        let workbook = try XLSXReader.workbook(from: macroPackage())
        #expect(workbook.hasMacros)
        #expect(workbook.macroProject == Self.projectBytes)
        #expect(workbook.unsupportedFeatures.preserved.contains(.macros))
        #expect(!workbook.unsupportedFeatures.lost.contains(.macros))
    }

    @Test("Saving as .xlsm keeps the project, its signature and the macro-enabled type")
    func savesMacroEnabled() throws {
        let workbook = try XLSXReader.workbook(from: macroPackage())
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: workbook, macroEnabled: true))

        #expect(entries["xl/vbaProject.bin"] == Self.projectBytes)
        #expect(entries["xl/vbaProjectSignature.bin"] == Self.signatureBytes)
        let contentTypes = String(decoding: try #require(entries["[Content_Types].xml"]), as: UTF8.self)
        #expect(contentTypes.contains("application/vnd.ms-excel.sheet.macroEnabled.main+xml"))
        #expect(contentTypes.contains("application/vnd.ms-office.vbaProjectSignature"))
        let relationships = String(decoding: try #require(entries["xl/_rels/workbook.xml.rels"]), as: UTF8.self)
        #expect(relationships.contains("relationships/vbaProject\" Target=\"vbaProject.bin\""))

        let reopened = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook, macroEnabled: true))
        #expect(reopened.macroProject == Self.projectBytes)
        #expect(reopened.codeName == "ThisWorkbook")
        #expect(reopened.sheets[0].codeName == "Sheet1")
    }

    @Test("Saving as .xlsx leaves the macros out entirely")
    func savesPlain() throws {
        let workbook = try XLSXReader.workbook(from: macroPackage())
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))

        #expect(!entries.keys.contains { $0.contains("vbaProject") })
        let contentTypes = String(decoding: try #require(entries["[Content_Types].xml"]), as: UTF8.self)
        #expect(!contentTypes.contains("macroEnabled"))
        #expect(!contentTypes.contains("vbaProjectSignature"))
        let relationships = String(decoding: try #require(entries["xl/_rels/workbook.xml.rels"]), as: UTF8.self)
        #expect(!relationships.contains("vbaProject"))
    }

    @Test("A workbook without macros still saves as a valid .xlsm")
    func emptyMacroEnabled() throws {
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: Workbook(), macroEnabled: true))
        let contentTypes = String(decoding: try #require(entries["[Content_Types].xml"]), as: UTF8.self)
        #expect(contentTypes.contains("application/vnd.ms-excel.sheet.macroEnabled.main+xml"))
    }
}
