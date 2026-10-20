import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

@Suite("Compound files")
struct CompoundFileTests {
    @Test("A tree of storages and streams, small and large, survives a write and read")
    func roundTrip() throws {
        var vba = CompoundFile.Storage(name: "VBA")
        vba.streams = [
            .init(name: "dir", data: Data(repeating: 7, count: 100)),
            .init(name: "Module1", data: Data((0..<5000).map { UInt8($0 % 251) })),
            .init(name: "Empty", data: Data()),
        ]
        var root = CompoundFile.Storage(name: "Root Entry")
        root.streams = [.init(name: "PROJECT", data: Data("ID=\"{}\"".utf8))]
        root.storages = [vba]
        // Enough siblings that the tree has real depth.
        for index in 0..<20 {
            root.streams.append(.init(name: "S\(index)", data: Data(repeating: UInt8(index), count: index * 300)))
        }
        let file = CompoundFile(root: root)
        let reread = try CompoundFile(data: file.data())

        #expect(reread.stream(at: ["VBA", "Module1"]) == vba.streams[1].data)
        #expect(reread.stream(at: ["vba", "DIR"]) == vba.streams[0].data)
        #expect(reread.stream(at: ["VBA", "Empty"]) == Data())
        for index in 0..<20 {
            #expect(reread.root.stream(named: "S\(index)")?.count == index * 300)
        }
    }

    @Test("Things that are not compound files are refused")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) { try CompoundFile(data: Data("PK".utf8)) }
        var truncated = [UInt8](repeating: 0, count: 512)
        truncated.replaceSubrange(0..<8, with: CompoundFile.signature)
        #expect(throws: (any Error).self) { try CompoundFile(data: Data(truncated)) }
    }
}
