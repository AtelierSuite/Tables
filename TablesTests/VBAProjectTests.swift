import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

@Suite("VBA projects")
struct VBAProjectTests {
    /// One dir-stream record: id, size, payload.
    private func record(_ id: UInt16, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(payload.count)
        return [UInt8(id & 0xFF), UInt8(id >> 8),
                UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)] + payload
    }

    private func utf16(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    /// A project laid out the way Office writes one, down to the version
    /// record whose size field undercounts and the Unicode name records.
    private func project(modules: [(name: String, source: String, procedural: Bool)], projectStream: String) throws -> Data {
        var dir: [UInt8] = []
        dir += record(0x0001, [1, 0, 0, 0])
        dir += record(0x0002, [0x09, 0x04, 0, 0])
        dir += record(0x0003, [0xE4, 0x04])
        dir += record(0x0004, Array("VBAProject".utf8))
        dir += [0x09, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00]
        dir += record(0x000F, [UInt8(modules.count), 0])
        dir += record(0x0013, [0xFF, 0xFF])

        var vba = CompoundFile.Storage(name: "VBA")
        for module in modules {
            dir += record(0x0019, Array(module.name.utf8))
            dir += record(0x0047, utf16(module.name))
            dir += record(0x001A, Array(module.name.utf8))
            dir += record(0x0032, utf16(module.name))
            dir += record(0x0031, [0x10, 0, 0, 0])
            dir += record(module.procedural ? 0x0021 : 0x0022, [])
            dir += record(0x002B, [])
            // Sixteen bytes standing in for the p-code cache ahead of the source.
            let text = "Attribute VB_Name = \"\(module.name)\"\r\n" + module.source
            let encoded = text.data(using: .windowsCP1252)!
            vba.streams.append(.init(name: module.name, data: Data(count: 16) + VBACompression.compress(encoded)))
        }
        dir += record(0x0010, [])
        vba.streams.append(.init(name: "dir", data: VBACompression.compress(Data(dir))))

        var root = CompoundFile.Storage(name: "Root Entry")
        root.streams = [.init(name: "PROJECT", data: Data(projectStream.utf8))]
        root.storages = [vba]
        return try CompoundFile(root: root).data()
    }

    @Test("Modules come out with their source, kind and attributes")
    func readsModules() throws {
        let data = try project(
            modules: [
                ("Module1", "Sub Hello()\r\n    MsgBox \"Café\"\r\nEnd Sub\r\n", true),
                ("Sheet1", "", false),
                ("Counter", "Public Count As Long\r\n", false),
            ],
            projectStream: "ID=\"{0}\"\r\nDocument=Sheet1/&H00000000\r\nModule=Module1\r\nClass=Counter\r\nName=\"VBAProject\"\r\n"
        )
        let project = try VBAProject(data: data)
        #expect(project.name == "VBAProject")
        #expect(project.codePage == 1252)
        #expect(project.modules.map(\.name) == ["Module1", "Sheet1", "Counter"])
        #expect(project.modules.map(\.kind) == [.standard, .document, .classModule])

        let module = try #require(project.module(named: "module1"))
        #expect(module.source == "Sub Hello()\n    MsgBox \"Café\"\nEnd Sub\n")
        #expect(module.attributes == "Attribute VB_Name = \"Module1\"\r\n")
    }

    @Test("Without a PROJECT stream, the dir stream still tells standard from class")
    func kindsWithoutProjectStream() throws {
        let data = try project(modules: [("A", "", true), ("B", "", false)], projectStream: "")
        #expect(try VBAProject(data: data).modules.map(\.kind) == [.standard, .classModule])
    }
}
