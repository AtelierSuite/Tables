import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

private func makeSheetWorkbook(_ entries: [String: String]) -> Workbook {
    var sheet = Worksheet(name: "Sheet1")
    for (reference, input) in entries {
        guard let address = CellAddress(a1: reference) else { continue }
        sheet[address] = CellInputParser.cell(from: input, inheriting: .default)
    }
    var workbook = Workbook(sheets: [sheet])
    workbook.recalculate()
    return workbook
}

private func cell(_ workbook: Workbook, _ reference: String) -> Cell {
    workbook.sheets[0][CellAddress(a1: reference)!]
}

@Suite("Spilling")
struct SpillTests {
    private let column = ["A1": "1", "A2": "2", "A3": "3"]

    @Test("An array result fills the cells below and beside its formula")
    func spills() {
        let workbook = makeSheetWorkbook(column.merging(["B1": "=A1:A3*2"]) { $1 })
        #expect(cell(workbook, "B1").value == .number(2))
        #expect(cell(workbook, "B2").value == .number(4))
        #expect(cell(workbook, "B3").value == .number(6))
        #expect(cell(workbook, "B2").isSpilled)
        #expect(cell(workbook, "B2").formula == nil)
        #expect(workbook.sheets[0].spills[CellAddress(a1: "B1")!] == CellRange(start: CellAddress(a1: "B1")!,
                                                                              end: CellAddress(a1: "B3")!))
    }

    @Test("Formulas reading spilled cells see them, and # names the whole spill")
    func readingSpills() {
        let workbook = makeSheetWorkbook(column.merging([
            "B1": "=A1:A3*2", "C1": "=B3+1", "D1": "=SUM(B1#)", "E1": "=COUNT(B1#)",
        ]) { $1 })
        #expect(cell(workbook, "C1").value == .number(7))
        #expect(cell(workbook, "D1").value == .number(12))
        #expect(cell(workbook, "E1").value == .number(3))
    }

    @Test("Something in the way gives #SPILL! and leaves the range alone")
    func blocked() {
        let workbook = makeSheetWorkbook(column.merging(["B1": "=A1:A3*2", "B2": "x"]) { $1 })
        #expect(cell(workbook, "B1").value == .error(.spill))
        #expect(cell(workbook, "B2").value == .text("x"))
        #expect(cell(workbook, "B3").value == .empty)
        #expect(workbook.sheets[0].spills.isEmpty)
    }

    @Test("A shrinking spill clears the cells it no longer reaches")
    func shrinking() {
        var workbook = makeSheetWorkbook(column.merging(["B1": "=A1:A3*2"]) { $1 })
        workbook.sheets[0][CellAddress(a1: "B1")!] = CellInputParser.cell(from: "={1;2}", inheriting: .default)
        workbook.recalculate()
        #expect(cell(workbook, "B2").value == .number(2))
        #expect(cell(workbook, "B3").value == .empty)
        #expect(!cell(workbook, "B3").isSpilled)
    }

    @Test("Typing into a spilled cell blocks the spill; clearing it lets the spill back")
    func typingOver() {
        var workbook = makeSheetWorkbook(column.merging(["B1": "=A1:A3*2"]) { $1 })
        workbook.sheets[0][CellAddress(a1: "B2")!] = CellInputParser.cell(from: "9", inheriting: .default)
        workbook.recalculate()
        #expect(cell(workbook, "B1").value == .error(.spill))
        workbook.sheets[0][CellAddress(a1: "B2")!] = Cell()
        workbook.recalculate()
        #expect(cell(workbook, "B2").value == .number(4))
    }

    @Test("@ picks the value in line with the formula")
    func implicitIntersection() {
        let workbook = makeSheetWorkbook(column.merging(["B2": "=@A1:A3*2", "B5": "=@A1:A3"]) { $1 })
        #expect(cell(workbook, "B2").value == .number(4))
        #expect(cell(workbook, "B5").value == .error(.valueError))
    }

    @Test("A legacy array formula fills its fixed block, padding with #N/A")
    func legacyArray() {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(a1: "A1")!] = Cell(formula: "{1;2}", arrayExtent: ArrayExtent(rows: 3, columns: 1))
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        #expect(cell(workbook, "A1").value == .number(1))
        #expect(cell(workbook, "A2").value == .number(2))
        #expect(cell(workbook, "A3").value == .error(.notAvailable))
    }
}

@Suite("Formulas from before dynamic arrays")
struct LegacyFormulaTests {
    @Test("@ goes where Excel's old rules intersected a range")
    func insertion() {
        #expect(FormulaDialect.legacyToDynamic("A1:A3*2") == "@A1:A3*2")
        #expect(FormulaDialect.legacyToDynamic("SUM(A1:A3)") == "SUM(A1:A3)")
        #expect(FormulaDialect.legacyToDynamic("SUM(A1:A3*2)") == "SUM(@A1:A3*2)")
        #expect(FormulaDialect.legacyToDynamic("SUMPRODUCT(A1:A3*B1:B3)") == "SUMPRODUCT(A1:A3*B1:B3)")
        #expect(FormulaDialect.legacyToDynamic("IF(A1:A3>1,1,0)") == "IF(@A1:A3>1,1,0)")
        #expect(FormulaDialect.legacyToDynamic("VLOOKUP(A1,B:C,2,0)") == "VLOOKUP(A1,B:C,2,0)")
        #expect(FormulaDialect.legacyToDynamic("LEN(A:A)") == "LEN(@A:A)")
        #expect(FormulaDialect.legacyToDynamic("Sales", isRangeName: { $0 == "Sales" }) == "@Sales")
        #expect(FormulaDialect.legacyToDynamic("INDIRECT(\"A1\")") == "@INDIRECT(\"A1\")")
        #expect(FormulaDialect.legacyToDynamic("A1+1") == "A1+1")
    }

    @Test("A formula whose @ only restates the old rules is stored the old way")
    func legacyForm() {
        #expect(FormulaDialect.legacyForm("@A1:A3*2") == "A1:A3*2")
        #expect(FormulaDialect.legacyForm("SUM(A1:A3)") == "SUM(A1:A3)")
        #expect(FormulaDialect.legacyForm("A1:A3*2") == nil)
        #expect(FormulaDialect.legacyForm("SUM(A1:A3*2)") == nil)
    }
}

@Suite("Dynamic arrays in files")
struct DynamicArrayFileTests {
    @Test("A spilling formula is stored as a dynamic array and read back as one")
    func roundTrip() throws {
        let workbook = makeSheetWorkbook(["A1": "1", "A2": "2", "A3": "3", "B1": "=A1:A3*2", "C1": "=SUM(A1:A3)"])
        let data = try XLSXWriter.data(from: workbook)
        let entries = try ZipArchive.entries(in: data)
        let sheetXML = String(decoding: entries["xl/worksheets/sheet1.xml"] ?? Data(), as: UTF8.self)
        #expect(sheetXML.contains("<c r=\"B1\" cm=\"1\"><f t=\"array\" ref=\"B1:B3\">A1:A3*2</f>"))
        #expect(sheetXML.contains("<f>SUM(A1:A3)</f>"))
        #expect(entries["xl/metadata.xml"] != nil)
        let types = String(decoding: entries["[Content_Types].xml"] ?? Data(), as: UTF8.self)
        #expect(types.contains("/xl/metadata.xml"))
        let relationships = String(decoding: entries["xl/_rels/workbook.xml.rels"] ?? Data(), as: UTF8.self)
        #expect(relationships.contains("sheetMetadata"))

        let reloaded = try XLSXReader.workbook(from: data)
        #expect(cell(reloaded, "B1").formula == "A1:A3*2")
        #expect(cell(reloaded, "B3").value == .number(6))
        #expect(cell(reloaded, "B3").isSpilled)
        #expect(cell(reloaded, "C1").formula == "SUM(A1:A3)")
    }

    @Test("A workbook without arrays carries no array metadata")
    func noMetadata() throws {
        let workbook = makeSheetWorkbook(["A1": "1", "B1": "=A1*2"])
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: workbook))
        #expect(entries["xl/metadata.xml"] == nil)
        let sheetXML = String(decoding: entries["xl/worksheets/sheet1.xml"] ?? Data(), as: UTF8.self)
        #expect(sheetXML.contains("<f>A1*2</f>"))
    }

    @Test("A legacy array formula keeps its fixed block through a save")
    func legacyArrayRoundTrip() throws {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(a1: "A1")!] = Cell(formula: "{1;2}", arrayExtent: ArrayExtent(rows: 2, columns: 1))
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        let data = try XLSXWriter.data(from: workbook)
        let sheetXML = String(decoding: try ZipArchive.entries(in: data)["xl/worksheets/sheet1.xml"] ?? Data(),
                              as: UTF8.self)
        #expect(sheetXML.contains("<c r=\"A1\"><f t=\"array\" ref=\"A1:A2\">{1;2}</f>"))
        let reloaded = try XLSXReader.workbook(from: data)
        #expect(cell(reloaded, "A1").arrayExtent == ArrayExtent(rows: 2, columns: 1))
        #expect(cell(reloaded, "A2").value == .number(2))
    }
}

@Suite("Functions Tables cannot calculate")
struct SavedResultTests {
    @Test("A formula calling an unknown function keeps the value it was saved with")
    func keepsSavedValue() {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .number(42), formula: "WEBSERVICE(\"https://example.com\")")
        sheet[CellAddress(a1: "A2")!] = Cell(formula: "A1+1")
        sheet[CellAddress(a1: "A3")!] = Cell(formula: "NOSUCHTHING(1)")
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        #expect(cell(workbook, "A1").value == .number(42))
        #expect(cell(workbook, "A2").value == .number(43))
        #expect(cell(workbook, "A3").value == .error(.nameError))
    }

    @Test("A saved spill stays where it was")
    func keepsSavedSpill() {
        var sheet = Worksheet(name: "Sheet1")
        sheet[CellAddress(a1: "A1")!] = Cell(value: .text("Date"), formula: "STOCKHISTORY(\"MSFT\",1)")
        sheet[CellAddress(a1: "A2")!] = Cell(value: .number(45000), isSpilled: true)
        sheet.spills[CellAddress(a1: "A1")!] = CellRange(start: CellAddress(a1: "A1")!, end: CellAddress(a1: "A2")!)
        sheet[CellAddress(a1: "B1")!] = Cell(formula: "COUNT(A1#)")
        var workbook = Workbook(sheets: [sheet])
        workbook.recalculate()
        #expect(cell(workbook, "A2").value == .number(45000))
        #expect(cell(workbook, "B1").value == .number(1))
    }
}
