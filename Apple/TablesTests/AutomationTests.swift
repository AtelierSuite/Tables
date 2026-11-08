import AppIntents
#if canImport(UIKit)
import UIKit
#endif
import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

@Suite("Workbook automation")
struct WorkbookAutomationTests {
    private func sample() throws -> Workbook {
        var workbook = Workbook(sheets: [Worksheet(name: "Sales"), Worksheet(name: "Notes")])
        let rows = [["Item", "Qty", "Price"], ["Pen", "10", "2"], ["Ink", "3", "5"], ["Pad", "7", "4"]]
        for (row, line) in rows.enumerated() {
            for (column, text) in line.enumerated() {
                try WorkbookAutomation.setCell(text, at: CellAddress(row: row, column: column), sheet: 0, in: &workbook)
            }
        }
        return workbook
    }

    @Test("Addresses, ranges, columns and sheets are checked before anything changes")
    func validation() throws {
        let workbook = try sample()
        #expect(try WorkbookAutomation.sheetIndex("notes", in: workbook) == 1)
        #expect(try WorkbookAutomation.sheetIndex(nil, in: workbook) == 0)
        #expect(throws: WorkbookAutomation.Failure.sheetNotFound("Q3")) {
            try WorkbookAutomation.sheetIndex("Q3", in: workbook)
        }
        #expect(throws: WorkbookAutomation.Failure.invalidCell("B0")) { try WorkbookAutomation.address("B0") }
        #expect(throws: WorkbookAutomation.Failure.invalidRange("A1:")) {
            try WorkbookAutomation.range("A1:", in: workbook.sheets[0])
        }
        #expect(try WorkbookAutomation.column("C") == 2)
        #expect(try WorkbookAutomation.column("3") == 2)
        let whole = try WorkbookAutomation.range("B:B", in: workbook.sheets[0])
        #expect(whole.end.row == workbook.sheets[0].rowCount - 1)
        #expect(WorkbookAutomation.Failure.sheetNotFound("Q3").errorDescription?.contains("Q3") == true)
    }

    @Test("Cells are set as if typed, formulas included, and rows append below the data")
    func changing() throws {
        var workbook = try sample()
        try WorkbookAutomation.setCell("=B2*C2", at: CellAddress(a1: "D2")!, sheet: 0, in: &workbook)
        #expect(workbook.sheets[0][CellAddress(a1: "D2")!].value == .number(20))
        let row = try WorkbookAutomation.appendRow(["Cap", "1", "9"], sheet: 0, in: &workbook)
        #expect(row == 5)
        #expect(workbook.sheets[0][CellAddress(a1: "A5")!].value == .text("Cap"))
        #expect(workbook.sheets[0][CellAddress(a1: "B5")!].value == .number(1))
        try WorkbookAutomation.setCell("x", at: CellAddress(a1: "Z200")!, sheet: 1, in: &workbook)
        #expect(workbook.sheets[1].rowCount >= 200)
        WorkbookAutomation.clear(try WorkbookAutomation.range("A2:C2", in: workbook.sheets[0]), sheet: 0, in: &workbook)
        #expect(workbook.sheets[0][CellAddress(a1: "A2")!].value == .empty)
        #expect(workbook.sheets[0][CellAddress(a1: "D2")!].value == .number(0))
    }

    @Test("Sorting keeps the header and moves whole rows")
    func sorting() throws {
        var workbook = try sample()
        try WorkbookAutomation.sort(try WorkbookAutomation.range("A1:C4", in: workbook.sheets[0]), by: 1,
                                    ascending: false, hasHeader: true, sheet: 0, in: &workbook)
        let rows = WorkbookAutomation.rows(try WorkbookAutomation.range("A1:C4", in: workbook.sheets[0]),
                                           sheet: 0, in: workbook)
        #expect(rows.map(\.first) == ["Item", "Pen", "Pad", "Ink"])
        #expect(rows[3] == ["Ink", "3", "5"])
    }

    @Test("Finding rows and evaluating formulas")
    func reading() throws {
        let workbook = try sample()
        #expect(WorkbookAutomation.findRows(where: 1, matches: ">5", sheet: 0, in: workbook).map(\.first)
                == ["Pen", "Pad"])
        #expect(WorkbookAutomation.findRows(where: 0, matches: "P*", sheet: 0, in: workbook).count == 2)
        #expect(WorkbookAutomation.evaluate("=SUMPRODUCT(B2:B4,C2:C4)", sheet: 0, in: workbook) == .number(63))
        #expect(WorkbookAutomation.evaluate("SUM(1,2)", sheet: 0, in: workbook) == .number(3))
    }

    @Test("Sheets are added, renamed and deleted, but the last one stays")
    func sheets() throws {
        var workbook = try sample()
        #expect(WorkbookAutomation.addSheet(named: "Sales", in: &workbook) == "Sales 2")
        #expect(WorkbookAutomation.renameSheet(1, to: "Memo", in: &workbook) == "Memo")
        try WorkbookAutomation.deleteSheet(2, in: &workbook)
        try WorkbookAutomation.deleteSheet(1, in: &workbook)
        #expect(throws: WorkbookAutomation.Failure.lastSheet) { try WorkbookAutomation.deleteSheet(0, in: &workbook) }
    }

    @Test("Workbooks read from and write to Excel and delimited text")
    func files() throws {
        let workbook = try sample()
        let xlsx = try WorkbookAutomation.write(workbook, as: .xlsx)
        #expect(try WorkbookAutomation.read(xlsx, filename: "Book.xlsx").sheets.map(\.name) == ["Sales", "Notes"])
        let csv = try WorkbookAutomation.write(workbook, as: .csv, sheet: "sales")
        #expect(String(decoding: csv, as: UTF8.self).hasPrefix("Item,Qty,Price"))
        let fromCSV = try WorkbookAutomation.read(csv, filename: "Orders.csv")
        #expect(fromCSV.sheets[0].name == "Orders")
        #expect(throws: WorkbookAutomation.Failure.unreadable) {
            try WorkbookAutomation.read(Data([0x50, 0x4B, 1, 2]), filename: "Broken.xlsx")
        }
    }
}

@Suite("Shortcuts actions")
struct ShortcutsActionTests {
    @Test("Actions chain: open, set, append, read back and export")
    func chaining() async throws {
        var open = GetWorkbookIntent()
        let csv = Data("Item,Qty\nPen,10\n".utf8)
        open.file = IntentFile(data: csv, filename: "Orders.csv", type: .commaSeparatedText)
        let opened = try await open.perform().value

        var set = SetCellIntent()
        set.workbook = try #require(opened)
        set.cell = "C2"
        set.value = "=B2*2"
        let changed = try await set.perform().value

        var append = AppendRowIntent()
        append.workbook = try #require(changed)
        append.values = ["Ink", "3"]
        let appended = try #require(try await append.perform().value)
        #expect(appended.name == "Orders")
        #expect(appended.sheetNames == ["Orders"])

        var get = GetCellIntent()
        get.workbook = appended
        get.cell = "C2"
        get.part = .value
        #expect(try await get.perform().value == "20")
        get.part = .formula
        #expect(try await get.perform().value == "=B2*2")

        var range = GetRangeIntent()
        range.workbook = appended
        range.range = "A1:B3"
        range.layout = .rows
        #expect(try await range.perform().value == ["Item\tQty", "Pen\t10", "Ink\t3"])

        var export = ExportWorkbookIntent()
        export.workbook = appended
        export.format = .csv
        let file = try #require(try await export.perform().value)
        #expect(file.filename == "Orders.csv")
        #expect(String(decoding: file.data, as: UTF8.self).contains("Ink,3"))
    }

    @Test("A bad argument stops the action with a message naming it")
    func errors() async throws {
        var create = CreateWorkbookIntent()
        create.name = "Plan"
        let workbook = try #require(try await create.perform().value)
        var set = SetCellIntent()
        set.workbook = workbook
        set.cell = "Nowhere"
        set.value = "1"
        await #expect(throws: WorkbookAutomation.Failure.invalidCell("Nowhere")) { _ = try await set.perform() }
        set.cell = "A1"
        set.sheet = "Missing"
        await #expect(throws: WorkbookAutomation.Failure.sheetNotFound("Missing")) { _ = try await set.perform() }
    }

    @Test("Formulas evaluate with or without a workbook")
    func evaluation() async throws {
        var evaluate = EvaluateFormulaIntent()
        evaluate.formula = "=TEXTJOIN(\"-\",,SEQUENCE(3))"
        #expect(try await evaluate.perform().value == "1-2-3")
    }
}

@Suite("Saving and opening from Shortcuts")
struct SaveAndOpenTests {
    private func temporaryFile(_ name: String, _ contents: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("Save Workbook writes changes back to the file the workbook came from")
    func savesInPlace() async throws {
        let url = try temporaryFile("Orders.csv", "Item,Qty\nPen,10\n")
        var get = GetWorkbookIntent()
        get.file = IntentFile(fileURL: url, filename: "Orders.csv", type: .commaSeparatedText)
        let opened = try #require(try await get.perform().value)
        #expect(opened.source != nil)

        var append = AppendRowIntent()
        append.workbook = opened
        append.values = ["Ink", "3"]
        let changed = try #require(try await append.perform().value)
        #expect(changed.source == opened.source)

        var save = SaveWorkbookIntent()
        save.workbook = changed
        _ = try await save.perform()
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Ink,3"))
    }

    @Test("A macro workbook keeps its macros through Shortcuts and saves back as an .xlsm")
    func savesMacroWorkbookInPlace() async throws {
        var original = Workbook(sheets: [Worksheet(name: "Data")])
        try original.createMacroProject()
        let url = try temporaryFile("Tools.xlsm", "")
        try XLSXWriter.data(from: original, macroEnabled: true).write(to: url)

        var get = GetWorkbookIntent()
        get.file = IntentFile(fileURL: url, filename: "Tools.xlsm", type: .macroEnabledWorkbook)
        let opened = try #require(try await get.perform().value)
        var append = AppendRowIntent()
        append.workbook = opened
        append.values = ["kept"]
        let changed = try #require(try await append.perform().value)
        #expect(changed.file.filename.hasSuffix(".xlsm"))

        var save = SaveWorkbookIntent()
        save.workbook = changed
        _ = try await save.perform()
        let entries = try ZipArchive.entries(in: Data(contentsOf: url))
        let types = String(decoding: try #require(entries["[Content_Types].xml"]), as: UTF8.self)
        #expect(types.contains("application/vnd.ms-excel.sheet.macroEnabled.main+xml"))
        let reopened = try XLSXReader.workbook(from: Data(contentsOf: url))
        #expect(reopened.hasMacros)
        #expect(reopened.sheets[0][CellAddress(a1: "A1")!].value == .text("kept"))
    }

    @Test("Save Workbook can write to a chosen file, and asks for one when there is none")
    func savesElsewhere() async throws {
        var create = CreateWorkbookIntent()
        create.name = "Plan"
        let workbook = try #require(try await create.perform().value)
        var save = SaveWorkbookIntent()
        save.workbook = workbook
        await #expect(throws: WorkbookAutomation.Failure.noSaveLocation) { _ = try await save.perform() }

        let target = try temporaryFile("Plan.xlsx", "")
        save.destination = IntentFile(fileURL: target, filename: "Plan.xlsx", type: .openXMLWorkbook)
        _ = try await save.perform()
        let written = try Data(contentsOf: target)
        #expect(try WorkbookAutomation.read(written, filename: "Plan.xlsx").sheets.count == 1)
    }

    #if canImport(UIKit)
    @Test("Open in Tables shows the workbook in the editor")
    @MainActor
    func opensInEditor() async throws {
        var create = CreateWorkbookIntent()
        create.name = "From Shortcuts"
        var open = OpenInTablesIntent()
        open.workbook = try #require(try await create.perform().value)
        _ = try await open.perform()
        try await Task.sleep(for: .seconds(2))
        let opened = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap { ($0.rootViewController as? UINavigationController)?.viewControllers.first as? UIDocumentViewController }
            .first?.document?.fileURL
        #expect(opened?.lastPathComponent.hasPrefix("From Shortcuts") == true)
        if let opened { try? FileManager.default.removeItem(at: opened) }
    }
    #endif
}

@Suite("Filling ranges from Shortcuts")
struct FillRangeTests {
    private func cell(_ a1: String, in workbook: Workbook) -> Cell {
        workbook.sheets[0][CellAddress(a1: a1)!]
    }

    private func range(_ text: String, in workbook: Workbook) throws -> CellRange {
        try WorkbookAutomation.range(text, in: workbook.sheets[0])
    }

    @Test("A value is entered into every cell as if typed, each keeping its formatting")
    func fillsValue() throws {
        var workbook = Workbook(sheets: [Worksheet(name: "Data")])
        var bold = CellStyle()
        bold.isBold = true
        workbook.sheets[0][CellAddress(a1: "B3")!] = Cell(value: .text("old"), style: bold)
        try WorkbookAutomation.fill(try range("B2:C4", in: workbook), with: "42", sheet: 0, in: &workbook)
        for a1 in ["B2", "C2", "B3", "C4"] { #expect(cell(a1, in: workbook).value == .number(42)) }
        #expect(cell("B3", in: workbook).style.isBold)
        #expect(!cell("B2", in: workbook).style.isBold)
        #expect(cell("A2", in: workbook).value == .empty)

        try WorkbookAutomation.fill(try range("A1:A2", in: workbook), with: "hello", sheet: 0, in: &workbook)
        #expect(cell("A2", in: workbook).value == .text("hello"))
        try WorkbookAutomation.fill(try range("D1:D2", in: workbook), with: "15%", sheet: 0, in: &workbook)
        #expect(cell("D2", in: workbook).value == .number(0.15))
        #expect(cell("D2", in: workbook).style.numberFormat == NumberFormatPreset.percent.code)
    }

    @Test("A formula value is written in the first cell and moves along the range")
    func fillsFormulaValue() throws {
        var workbook = Workbook(sheets: [Worksheet(name: "Data")])
        for row in 1...4 { try WorkbookAutomation.setCell("\(row)", at: CellAddress(row: row, column: 0), sheet: 0, in: &workbook) }
        try WorkbookAutomation.fill(try range("B2:B5", in: workbook), with: "=A2*$A$2", sheet: 0, in: &workbook)
        #expect(cell("B2", in: workbook).formula == "A2*$A$2")
        #expect(cell("B5", in: workbook).formula == "A5*$A$2")
        #expect(cell("B5", in: workbook).value == .number(4))
    }

    @Test("A source cell is copied with relative, absolute and mixed references moving as a fill moves them")
    func fillsFromCell() throws {
        var workbook = Workbook(sheets: [Worksheet(name: "Data")])
        for (a1, text) in [("A1", "1"), ("A2", "2"), ("A3", "3"), ("B1", "10"), ("B2", "20"), ("B3", "30")] {
            try WorkbookAutomation.setCell(text, at: CellAddress(a1: a1)!, sheet: 0, in: &workbook)
        }
        var style = CellStyle()
        style.isItalic = true
        style.fillColorHex = "#FFCC00"
        style.numberFormat = "0.00"
        workbook.sheets[0][CellAddress(a1: "C1")!] = Cell(value: .empty, formula: "A1+$A$1+A$1+$A1", style: style)
        workbook.recalculate()
        try WorkbookAutomation.fill(try range("C2:D3", in: workbook), from: CellAddress(a1: "C1")!, sheet: 0, in: &workbook)

        #expect(cell("C1", in: workbook).formula == "A1+$A$1+A$1+$A1")
        #expect(cell("C3", in: workbook).formula == "A3+$A$1+A$1+$A3")
        #expect(cell("D2", in: workbook).formula == "B2+$A$1+B$1+$A2")
        #expect(cell("C3", in: workbook).value == .number(3 + 1 + 1 + 3))
        #expect(cell("D3", in: workbook).value == .number(30 + 1 + 10 + 3))
        #expect(cell("D3", in: workbook).style == style)

        try WorkbookAutomation.fill(try range("E1:E3", in: workbook), from: CellAddress(a1: "A1")!, sheet: 0, in: &workbook)
        #expect((1...3).allSatisfy { cell("E\($0)", in: workbook).value == .number(1) })
    }

    @Test("Bad ranges and cells are refused before anything changes, and the sheet grows to fit")
    func validation() throws {
        var workbook = Workbook(sheets: [Worksheet(name: "Data")])
        #expect(throws: WorkbookAutomation.Failure.invalidRange("B2:")) { try range("B2:", in: workbook) }
        #expect(throws: WorkbookAutomation.Failure.invalidRange("SUM(A1)")) { try range("SUM(A1)", in: workbook) }
        let tooFar = try range("A99999:A100001", in: workbook)
        #expect(throws: WorkbookAutomation.Failure.outsideSheet("A100001")) {
            try WorkbookAutomation.fill(tooFar, with: "1", sheet: 0, in: &workbook)
        }
        #expect(workbook.sheets[0].cells.isEmpty)
        try WorkbookAutomation.fill(try range("Z500:Z501", in: workbook), with: "x", sheet: 0, in: &workbook)
        #expect(workbook.sheets[0].rowCount >= 501)
        #expect(workbook.sheets[0].columnCount >= 26)
    }

    @Test("Filling 2,000 rows from a formula stays quick")
    func largeRange() throws {
        var workbook = Workbook(sheets: [Worksheet(name: "Data")])
        workbook.sheets[0].rowCount = max(workbook.sheets[0].rowCount, 2_000)
        for row in 0..<2_000 { workbook.sheets[0][CellAddress(row: row, column: 0)] = Cell(value: .number(Double(row + 1))) }
        try WorkbookAutomation.setCell("=A1*2", at: CellAddress(a1: "B1")!, sheet: 0, in: &workbook)
        let started = ContinuousClock.now
        try WorkbookAutomation.fill(try range("B2:B2000", in: workbook), from: CellAddress(a1: "B1")!, sheet: 0, in: &workbook)
        try WorkbookAutomation.fill(try range("C1:C2000", in: workbook), with: "=B1+1", sheet: 0, in: &workbook)
        let elapsed = ContinuousClock.now - started
        #expect(cell("B2000", in: workbook).formula == "A2000*2")
        #expect(cell("B2000", in: workbook).value == .number(4_000))
        #expect(cell("C2000", in: workbook).value == .number(4_001))
        #expect(elapsed < .seconds(2), "Filling 2,000 rows took \(elapsed)")
    }

    @Test("The action fills from a value or a cell and hands on the changed workbook")
    func action() async throws {
        var open = GetWorkbookIntent()
        open.file = IntentFile(data: Data("Item,Qty\nPen,10\nInk,3\nPad,7\n".utf8), filename: "Orders.csv",
                               type: .commaSeparatedText)
        var set = SetCellIntent()
        set.workbook = try #require(try await open.perform().value)
        set.cell = "C2"
        set.value = "=B2*2"

        var fill = FillRangeIntent()
        fill.workbook = try #require(try await set.perform().value)
        fill.range = "C3:C4"
        fill.content = .cell
        fill.sourceCell = "C2"
        let copied = try #require(try await fill.perform().value)
        let book = try copied.load()
        #expect(book.sheets[0][CellAddress(a1: "C4")!].formula == "B4*2")
        #expect(book.sheets[0][CellAddress(a1: "C4")!].value == .number(14))

        fill.workbook = copied
        fill.range = "D2:D4"
        fill.content = .value
        fill.value = "done"
        let filled = try #require(try await fill.perform().value)
        #expect(try filled.load().sheets[0][CellAddress(a1: "D4")!].value == .text("done"))

        fill.range = "D2:"
        await #expect(throws: WorkbookAutomation.Failure.invalidRange("D2:")) { _ = try await fill.perform() }
        fill.range = "D2:D4"
        fill.content = .cell
        fill.sourceCell = "Here"
        await #expect(throws: WorkbookAutomation.Failure.invalidCell("Here")) { _ = try await fill.perform() }
    }
}
