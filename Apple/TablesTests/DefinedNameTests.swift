import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Covers workbook-level defined names: reading them, resolving them inside
/// formulas, and writing them back where Excel expects to find them.
@Suite("Defined names")
struct DefinedNameTests {

    // MARK: - Fixtures

    /// Builds a minimal package whose workbook part carries `<definedNames>`.
    /// The entries arrive as `(name, definition, localSheetId)` triples so a
    /// test can spell the XML the way Excel does.
    private func packageWithNames(
        _ names: [(name: String, formula: String, localSheetId: Int?)],
        sheets: [(name: String, xml: String)]
    ) throws -> Data {
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
        let sheetElements = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(sheet.name)\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        let nameElements = names.map { entry in
            let scope = entry.localSheetId.map { " localSheetId=\"\($0)\"" } ?? ""
            return "<definedName name=\"\(entry.name)\"\(scope)>\(entry.formula)</definedName>"
        }.joined()
        let workbook = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(sheetElements)</sheets>\
        \(nameElements.isEmpty ? "" : "<definedNames>\(nameElements)</definedNames>")</workbook>
        """
        let sheetRelationships = sheets.indices.map { index in
            "<Relationship Id=\"rId\(index + 1)\" " +
            "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" " +
            "Target=\"worksheets/sheet\(index + 1).xml\"/>"
        }.joined()
        let workbookRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(sheetRelationships)</Relationships>
        """
        var entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships.utf8)),
        ]
        for (index, sheet) in sheets.enumerated() {
            entries.append(("xl/worksheets/sheet\(index + 1).xml", Data(sheet.xml.utf8)))
        }
        return try ZipArchive.archive(entries: entries)
    }

    /// A sheet holding 1, 2, 3 in A1:A3 plus whatever formulas a test needs.
    private func dataSheet(formulas: [String: String] = [:]) -> String {
        var rows = ""
        for row in 1...3 {
            var cells = "<c r=\"A\(row)\"><v>\(row)</v></c>"
            if let formula = formulas["B\(row)"] {
                cells += "<c r=\"B\(row)\"><f>\(formula)</f></c>"
            }
            rows += "<row r=\"\(row)\">\(cells)</row>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetData>\(rows)</sheetData></worksheet>
        """
    }

    private func value(_ workbook: Workbook, _ address: String, sheet: Int = 0) -> CellValue {
        workbook.sheets[sheet][CellAddress(a1: address)!].value
    }

    // MARK: - Resolution

    @Test("A name standing for one cell reads that cell")
    func singleCellName() throws {
        let data = try packageWithNames(
            [(name: "Rate", formula: "S!$A$2", localSheetId: nil)],
            sheets: [(name: "S", xml: dataSheet(formulas: ["B1": "Rate*10"]))]
        )
        #expect(value(try XLSXReader.workbook(from: data), "B1") == .number(20))
    }

    @Test("A name standing for a range works as a range argument")
    func rangeName() throws {
        let data = try packageWithNames(
            [(name: "SalesData", formula: "S!$A$1:$A$3", localSheetId: nil)],
            sheets: [(name: "S", xml: dataSheet(formulas: ["B1": "SUM(SalesData)", "B2": "SUM(S!$A$1:$A$3)"]))]
        )
        let workbook = try XLSXReader.workbook(from: data)
        #expect(value(workbook, "B1") == .number(6))
        #expect(value(workbook, "B1") == value(workbook, "B2"))
    }

    @Test("A name may be defined in terms of another name")
    func chainedNames() throws {
        let data = try packageWithNames(
            [
                (name: "Base", formula: "S!$A$3", localSheetId: nil),
                (name: "Doubled", formula: "Base*2", localSheetId: nil),
            ],
            sheets: [(name: "S", xml: dataSheet(formulas: ["B1": "Doubled+1"]))]
        )
        #expect(value(try XLSXReader.workbook(from: data), "B1") == .number(7))
    }

    @Test("Lookup ignores case, the way Excel matches names")
    func caseInsensitiveLookup() throws {
        let data = try packageWithNames(
            [(name: "TaxRate", formula: "0.25", localSheetId: nil)],
            sheets: [(name: "S", xml: dataSheet(formulas: ["B1": "taxrate*4", "B2": "TAXRATE*8"]))]
        )
        let workbook = try XLSXReader.workbook(from: data)
        #expect(value(workbook, "B1") == .number(1))
        #expect(value(workbook, "B2") == .number(2))
    }

    @Test("A name nobody declared is still #NAME?")
    func unknownName() throws {
        let data = try packageWithNames(
            [(name: "Known", formula: "1", localSheetId: nil)],
            sheets: [(name: "S", xml: dataSheet(formulas: ["B1": "Missing+1", "B2": "SUM(Missing)"]))]
        )
        let workbook = try XLSXReader.workbook(from: data)
        #expect(value(workbook, "B1").errorValue == .nameError)
        #expect(value(workbook, "B2").errorValue == .nameError)
    }

    @Test("A self-referential name reports an error instead of hanging")
    func selfReference() throws {
        let data = try packageWithNames(
            [
                (name: "Loop", formula: "Loop+1", localSheetId: nil),
                (name: "Ping", formula: "Pong", localSheetId: nil),
                (name: "Pong", formula: "Ping", localSheetId: nil),
            ],
            sheets: [(name: "S", xml: dataSheet(formulas: ["B1": "Loop", "B2": "Ping"]))]
        )
        let workbook = try XLSXReader.workbook(from: data)
        #expect(value(workbook, "B1").errorValue == .circularReference)
        #expect(value(workbook, "B2").errorValue == .circularReference)
    }

    @Test("A name whose definition is not a formula degrades to #NAME?")
    func malformedDefinition() throws {
        let data = try packageWithNames(
            [(name: "Broken", formula: "SUM(", localSheetId: nil)],
            sheets: [(name: "S", xml: dataSheet(formulas: ["B1": "Broken"]))]
        )
        #expect(value(try XLSXReader.workbook(from: data), "B1").errorValue == .nameError)
    }

    // MARK: - Scoping

    @Test("A sheet-scoped name answers only on its own sheet")
    func sheetScoping() throws {
        let data = try packageWithNames(
            [
                (name: "Rate", formula: "2", localSheetId: nil),
                (name: "Rate", formula: "100", localSheetId: 1),
                (name: "Private", formula: "7", localSheetId: 1),
            ],
            sheets: [
                (name: "S", xml: dataSheet(formulas: ["B1": "Rate", "B2": "Private"])),
                (name: "T", xml: dataSheet(formulas: ["B1": "Rate"])),
            ]
        )
        let workbook = try XLSXReader.workbook(from: data)
        // The workbook-scoped definition on the first sheet, the sheet-scoped
        // one on the second — and the second sheet's private name is invisible
        // from the first.
        #expect(value(workbook, "B1", sheet: 0) == .number(2))
        #expect(value(workbook, "B1", sheet: 1) == .number(100))
        #expect(value(workbook, "B2", sheet: 0).errorValue == .nameError)
    }

    @Test("Scope survives sheets being reordered or deleted")
    func scopeFollowsItsSheet() throws {
        let data = try packageWithNames(
            [(name: "Rate", formula: "100", localSheetId: 1)],
            sheets: [
                (name: "S", xml: dataSheet()),
                (name: "T", xml: dataSheet(formulas: ["B1": "Rate"])),
            ]
        )
        var workbook = try XLSXReader.workbook(from: data)
        let second = workbook.sheets[1].id
        workbook.moveSheet(second, to: 0)
        workbook.recalculate()
        #expect(workbook.sheets[0][CellAddress(a1: "B1")!].value == .number(100))

        workbook.removeSheet(second)
        let written = String(decoding: try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))["xl/workbook.xml"]!,
                             as: UTF8.self)
        #expect(!written.contains("definedName"))
    }

    // MARK: - Reading and writing

    @Test("Excel's own entries are filtered, not resolved")
    func builtInEntries() throws {
        let data = try packageWithNames(
            [
                (name: "_xlnm.Print_Area", formula: "S!$A$1:$B$3", localSheetId: 0),
                (name: "_xlnm._FilterDatabase", formula: "S!$A$1:$A$3", localSheetId: 0),
                (name: "Rate", formula: "3", localSheetId: nil),
            ],
            sheets: [(name: "S", xml: dataSheet(formulas: ["B1": "Rate"]))]
        )
        let workbook = try XLSXReader.workbook(from: data)

        // The print area is kept so saving does not throw away page setup; the
        // filter range is not, because we write no autofilter for it to describe.
        #expect(workbook.definedNames.map(\.name) == ["_xlnm.Print_Area", "Rate"])
        #expect(workbook.definedNames.first?.isBuiltIn == true)
        #expect(value(workbook, "B1") == .number(3))

        let written = String(decoding: try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))["xl/workbook.xml"]!,
                             as: UTF8.self)
        #expect(written.contains("<definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">S!$A$1:$B$3</definedName>"))
        #expect(!written.contains("_FilterDatabase"))
    }

    @Test("Defined names are written after the sheets, where the schema wants them")
    func elementOrder() throws {
        var sheet = Worksheet(name: "S")
        sheet[CellAddress(a1: "A1")!] = CellInputParser.cell(from: "=Rate", inheriting: .default)
        let workbook = Workbook(sheets: [sheet], definedNames: [DefinedName(name: "Rate", formula: "5", scope: nil)])

        let xml = String(decoding: try ZipArchive.entries(in: try XLSXWriter.data(from: workbook))["xl/workbook.xml"]!,
                         as: UTF8.self)
        let sheets = try #require(xml.range(of: "</sheets>"))
        let names = try #require(xml.range(of: "<definedNames>"))
        let calculation = try #require(xml.range(of: "<calcPr"))
        #expect(sheets.upperBound <= names.lowerBound)
        #expect(names.upperBound <= calculation.lowerBound)
    }

    @Test("Names and the formulas using them survive a save and reopen")
    func roundTrip() throws {
        let source = try packageWithNames(
            [
                (name: "SalesData", formula: "S!$A$1:$A$3", localSheetId: nil),
                (name: "Rate", formula: "S!$A$2", localSheetId: nil),
            ],
            sheets: [(name: "S", xml: dataSheet(formulas: ["B1": "SUM(SalesData)*Rate"]))]
        )
        let original = try XLSXReader.workbook(from: source)
        #expect(value(original, "B1") == .number(12))

        let reopened = try XLSXReader.workbook(from: try XLSXWriter.data(from: original))
        #expect(reopened.definedNames == original.definedNames)
        #expect(reopened.sheets[0][CellAddress(a1: "B1")!].formula == "SUM(SalesData)*Rate")
        #expect(value(reopened, "B1") == .number(12))
    }
}
