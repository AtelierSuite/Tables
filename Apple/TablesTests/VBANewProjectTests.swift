import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

@Suite("New VBA projects")
struct VBANewProjectTests {
    @Test("Protection fields decrypt as Office writes them")
    func decryptsOfficeFields() throws {
        // From a project Excel saved: unprotected, no password, visible.
        let projectID = "{8D807122-0657-42C8-BC6F-4B5FD08031C9}"
        let fields = ["DBD966ECE4F0E4F0E4F0E4F0": [UInt8](repeating: 0, count: 4),
                      "5557E86E18E919E919E9": [0], "CFCD72F0961011111111EE": [0xFF]]
        for (hex, expected) in fields {
            let decrypted = try #require(VBAProjectEncryption.decrypt(VBAProjectEncryption.bytes(fromHex: hex)))
            #expect(decrypted.data == expected)
            #expect(decrypted.projectKey == VBAProjectEncryption.key(for: projectID))
        }
    }

    @Test("Encryption round-trips for every seed")
    func roundTrips() {
        for seed in UInt8.min...UInt8.max {
            let encrypted = VBAProjectEncryption.encrypt([0, 0, 0, 0], projectID: "{ABC}", seed: seed)
            #expect(VBAProjectEncryption.decrypt(encrypted)?.data == [0, 0, 0, 0])
        }
    }

    @Test("A workbook without macros gets a project with a module per sheet and code names to match")
    func createsProject() throws {
        var chart = Worksheet(name: "Chart")
        chart.kind = .chart
        var named = Worksheet(name: "Named")
        named.codeName = "Sheet1"
        var workbook = Workbook(sheets: [Worksheet(name: "First"), named, chart])
        try workbook.createMacroProject()

        #expect(workbook.hasMacros)
        #expect(workbook.codeName == "ThisWorkbook")
        #expect(workbook.sheets.map(\.codeName) == ["Sheet2", "Sheet1", nil])
        let project = try VBAProject(data: try #require(workbook.macroProject))
        #expect(project.modules.map(\.name) == ["ThisWorkbook", "Sheet2", "Sheet1", "Module1"])
        #expect(project.modules.map(\.kind) == [.document, .document, .document, .standard])
        #expect(project.module(named: "Sheet2")?.attributes.contains(VBAProject.worksheetClassID) == true)

        let file = try CompoundFile(data: try #require(workbook.macroProject))
        let text = String(decoding: try #require(file.root.stream(named: "PROJECT")), as: UTF8.self)
        let projectID = try #require(text.components(separatedBy: "\r\n").first?.dropFirst(4).dropLast())
        for (field, expected) in [("CMG", [UInt8](repeating: 0, count: 4)), ("DPB", [0]), ("GC", [0xFF])] {
            let line = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix(field + "=") })
            let hex = String(line.dropFirst(field.count + 2).dropLast())
            let decrypted = try #require(VBAProjectEncryption.decrypt(VBAProjectEncryption.bytes(fromHex: hex)))
            #expect(decrypted.data == expected)
            #expect(decrypted.projectKey == VBAProjectEncryption.key(for: String(projectID)))
        }
    }

    @Test("A new project saves as .xlsm, reopens, and runs what is written in it")
    func savesAndRuns() throws {
        var workbook = Workbook()
        try workbook.createMacroProject()
        var project = try VBAProject(data: try #require(workbook.macroProject))
        project.setSource("Sub Fill()\n    Sheet1.Range(\"A1\").Value = 42\nEnd Sub", ofModule: "Module1")
        workbook.setMacroProject(try project.data())

        let saved = try XLSXWriter.data(from: workbook, macroEnabled: true)
        let entries = try ZipArchive.entries(in: saved)
        let types = String(decoding: try #require(entries["[Content_Types].xml"]), as: UTF8.self)
        #expect(types.contains("/xl/vbaProject.bin\" ContentType=\"application/vnd.ms-office.vbaProject"))
        let reopened = try XLSXReader.workbook(from: saved)
        #expect(reopened.hasMacros)
        #expect(reopened.sheets[0].codeName == "Sheet1")

        let host = VBAExcelHost(workbook: reopened, name: "Book.xlsm")
        let interpreter = try VBAInterpreter(project: VBAProject(data: try #require(reopened.macroProject)), host: host)
        _ = try interpreter.run("Fill")
        #expect(host.finishedWorkbook.sheets[0][CellAddress(a1: "A1")!].value == .number(42))
    }
}
