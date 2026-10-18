import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

@Suite("Editing VBA projects")
struct VBAProjectWriterTests {
    private func record(_ id: UInt16, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(payload.count)
        return [UInt8(id & 0xFF), UInt8(id >> 8),
                UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)] + payload
    }

    private func utf16(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    /// A project laid out as Office writes one: each module's source behind
    /// sixteen bytes of stand-in p-code, a performance cache, and the
    /// workspace section the editor keeps in `PROJECT`.
    private func project() throws -> Data {
        let modules: [(String, String, Bool)] = [
            ("ThisWorkbook", "", false),
            ("Module1", "Sub Hello()\r\n    MsgBox \"hi\"\r\nEnd Sub\r\n", true),
            ("Old", "Sub Gone()\r\nEnd Sub\r\n", true),
        ]
        var dir: [UInt8] = []
        dir += record(0x0001, [1, 0, 0, 0])
        dir += record(0x0003, [0xE4, 0x04])
        dir += record(0x0004, Array("VBAProject".utf8))
        dir += [0x09, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00]
        dir += record(0x000F, [UInt8(modules.count), 0])
        dir += record(0x0013, [0xFF, 0xFF])
        var vba = CompoundFile.Storage(name: "VBA")
        for (name, source, procedural) in modules {
            dir += record(0x0019, Array(name.utf8))
            dir += record(0x0047, utf16(name))
            dir += record(0x001A, Array(name.utf8))
            dir += record(0x0032, utf16(name))
            dir += record(0x0031, [0x10, 0, 0, 0])
            dir += record(procedural ? 0x0021 : 0x0022, [])
            dir += record(0x002B, [])
            let text = "Attribute VB_Name = \"\(name)\"\r\n" + source
            vba.streams.append(.init(name: name, data: Data(count: 16) + VBACompression.compress(Data(text.utf8))))
        }
        dir += record(0x0010, [])
        vba.streams.append(.init(name: "dir", data: VBACompression.compress(Data(dir))))
        vba.streams.append(.init(name: "_VBA_PROJECT", data: Data([0xCC, 0x61, 0xB5, 0x00, 0x00, 0x01, 0x00, 9, 9, 9])))
        vba.streams.append(.init(name: "__SRP_0", data: Data([1, 2, 3])))
        var root = CompoundFile.Storage(name: "Root Entry")
        root.streams = [.init(name: "PROJECT", data: Data("""
        ID="{0}"\r\nDocument=ThisWorkbook/&H00000000\r\nModule=Module1\r\nModule=Old\r\nName="VBAProject"\r\n\r\n\
        [Workspace]\r\nThisWorkbook=0, 0, 0, 0, C\r\nModule1=1, 2, 3, 4, \r\nOld=1, 2, 3, 4, \r\n
        """.utf8))]
        root.storages = [vba]
        return try CompoundFile(root: root).data()
    }

    @Test("An edited module reads back with its new source, its attributes intact")
    func editsSource() throws {
        var project = try VBAProject(data: project())
        project.setSource("Sub Hello()\n    MsgBox \"edited\"\nEnd Sub", ofModule: "module1")
        let reread = try VBAProject(data: project.data())
        let module = try #require(reread.module(named: "Module1"))
        #expect(module.source == "Sub Hello()\n    MsgBox \"edited\"\nEnd Sub\n")
        #expect(module.attributes == "Attribute VB_Name = \"Module1\"\r\n")
        #expect(reread.modules.map(\.name) == ["ThisWorkbook", "Module1", "Old"])
    }

    @Test("The compiled caches are dropped and the project marked for recompiling")
    func dropsCompiledCode() throws {
        var project = try VBAProject(data: project())
        project.setSource("Sub A()\nEnd Sub", ofModule: "Module1")
        let file = try CompoundFile(data: project.data())
        let vba = try #require(file.root.storage(named: "VBA"))
        #expect(vba.stream(named: "_VBA_PROJECT") == Data([0xCC, 0x61, 0xFF, 0xFF, 0x00, 0x00, 0x00]))
        #expect(vba.stream(named: "__SRP_0") == nil)
        // With the p-code gone, the source starts the stream.
        let module = try #require(vba.stream(named: "Module1"))
        #expect(module.first == 0x01)
    }

    @Test("Modules can be added and removed, and the project's lists follow")
    func addsAndRemoves() throws {
        var project = try VBAProject(data: project())
        try project.addModule(named: project.nextModuleName())
        project.removeModule(named: "Old")
        project.removeModule(named: "ThisWorkbook")
        let data = try project.data()
        let reread = try VBAProject(data: data)
        #expect(reread.modules.map(\.name) == ["ThisWorkbook", "Module1", "Module2"])
        #expect(reread.module(named: "Module2")?.kind == .standard)
        #expect(reread.module(named: "Module2")?.source == "Option Explicit\n")

        let file = try CompoundFile(data: data)
        let text = String(decoding: try #require(file.root.stream(named: "PROJECT")), as: UTF8.self)
        #expect(text.contains("Module=Module2"))
        #expect(!text.contains("Module=Old"))
        #expect(!text.contains("Old=1, 2, 3, 4"))
        #expect(file.stream(at: ["VBA", "Old"]) == nil)

        // And the result runs.
        var edited = reread
        edited.setSource("Function Twice(x)\nTwice = x * 2\nEnd Function", ofModule: "Module2")
        let interpreter = try VBAInterpreter(project: try VBAProject(data: edited.data()), host: nil)
        #expect(try interpreter.run("Twice", arguments: [.integer(21)]).asInteger() == 42)
    }

    @Test("A renamed module keeps its code, under its new name everywhere the project lists it")
    func renames() throws {
        var project = try VBAProject(data: project())
        try project.renameModule("Module1", to: "Reports")
        #expect(throws: VBAProject.EditError.self) { try project.renameModule("Reports", to: "Old") }
        try project.renameModule("ThisWorkbook", to: "Book")   // a document module: left alone
        let data = try project.data()
        let reread = try VBAProject(data: data)
        #expect(reread.modules.map(\.name) == ["ThisWorkbook", "Reports", "Old"])
        let reports = try #require(reread.module(named: "Reports"))
        #expect(reports.source.contains("Sub Hello()"))
        #expect(reports.attributes == "Attribute VB_Name = \"Reports\"\r\n")

        let file = try CompoundFile(data: data)
        #expect(file.stream(at: ["VBA", "Module1"]) == nil)
        #expect(file.stream(at: ["VBA", "Reports"]) != nil)
        let text = String(decoding: try #require(file.root.stream(named: "PROJECT")), as: UTF8.self)
        #expect(text.contains("Module=Reports"))
        #expect(text.contains("Reports=1, 2, 3, 4"))
        #expect(!text.contains("Module1"))

        // Renaming twice, and back again, before saving.
        var twice = reread
        try twice.renameModule("Reports", to: "Interim")
        try twice.renameModule("Interim", to: "reports")
        #expect(try VBAProject(data: twice.data()).modules.map(\.name) == ["ThisWorkbook", "reports", "Old"])
    }

    @Test("Class modules can be added, and instantiated once saved")
    func addsClasses() throws {
        var project = try VBAProject(data: project())
        try project.addModule(named: "Counter", kind: .classModule)
        project.setSource("Public Count As Long\nPublic Sub Bump()\nCount = Count + 1\nEnd Sub", ofModule: "Counter")
        project.setSource("Function Run()\nDim c As New Counter\nc.Bump: c.Bump\nRun = c.Count\nEnd Function", ofModule: "Module1")
        let data = try project.data()
        let reread = try VBAProject(data: data)
        #expect(reread.module(named: "Counter")?.kind == .classModule)
        let text = String(decoding: try #require(try CompoundFile(data: data).root.stream(named: "PROJECT")), as: UTF8.self)
        #expect(text.contains("Class=Counter"))
        let interpreter = try VBAInterpreter(project: reread, host: nil)
        #expect(try interpreter.run("Run").asInteger() == 2)
    }

    @Test("Module names follow VBA's rules", arguments: [
        ("Report", true), ("Report_2", true), ("2Report", false), ("My Module", false), ("Module1", false),
        ("module1", false), ("VBAProject", false), (String(repeating: "a", count: 32), false), ("Données", false),
    ])
    func moduleNames(_ name: String, _ isValid: Bool) throws {
        let project = try VBAProject(data: project())
        #expect((project.problem(withModuleName: name) == nil) == isValid)
    }

    @Test("Text the project's code page cannot hold is refused rather than mangled")
    func unencodable() throws {
        var project = try VBAProject(data: project())
        project.setSource("Sub A()\nMsgBox \"日本語\"\nEnd Sub", ofModule: "Module1")
        #expect(throws: VBAProject.EditError.self) { try project.data() }
    }

    @Test("Saving an edit into a workbook drops the now-invalid signature")
    func dropsSignature() throws {
        var workbook = Workbook()
        workbook.preservedPackage.parts["xl/vbaProject.bin"] = try project()
        workbook.preservedPackage.parts["xl/vbaProjectSignature.bin"] = Data([1])
        workbook.preservedPackage.parts["xl/_rels/vbaProject.bin.rels"] = Data([2])
        workbook.preservedPackage.contentTypeOverrides["/xl/vbaProjectSignature.bin"] = "sig"
        workbook.preservedPackage.workbookRelationships.append(PreservedRelationship(
            type: PreservedPackage.macroProjectRelationshipType, target: "vbaProject.bin", targetMode: nil
        ))
        var project = try VBAProject(data: try #require(workbook.macroProject))
        project.setSource("Sub A()\nEnd Sub", ofModule: "Module1")
        workbook.setMacroProject(try project.data())

        #expect(try VBAProject(data: try #require(workbook.macroProject)).module(named: "Module1")?.source == "Sub A()\nEnd Sub\n")
        #expect(workbook.preservedPackage.parts["xl/vbaProjectSignature.bin"] == nil)
        #expect(workbook.preservedPackage.parts["xl/_rels/vbaProject.bin.rels"] == nil)
        #expect(workbook.preservedPackage.contentTypeOverrides["/xl/vbaProjectSignature.bin"] == nil)
        let entries = try ZipArchive.entries(in: XLSXWriter.data(from: workbook, macroEnabled: true))
        #expect(entries["xl/vbaProject.bin"] != nil)
        #expect(!entries.keys.contains { $0.contains("Signature") })
    }
}
