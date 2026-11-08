import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Keeps the function reference in step with the engine: every function it
/// runs is written up, and nothing that it doesn't.
@Suite("Function reference")
struct FunctionReferenceTests {

    @Test("Every function the engine runs has an entry, and every entry a function")
    func coversTheLibrary() {
        let documented = Set(FunctionReference.all.map(\.name))
        let library = Set(FormulaFunctions.names)
        #expect(library.subtracting(documented).sorted() == [])
        #expect(documented.subtracting(library).sorted() == [])
    }

    @Test("Each entry is written with its own name and has a summary")
    func entriesAreComplete() {
        for entry in FunctionReference.all {
            #expect(entry.syntax.hasPrefix(entry.name + "("), "\(entry.name)")
            #expect(entry.example.hasPrefix("="), "\(entry.name)")
            #expect(entry.summary != entry.name, "\(entry.name) has no summary")
        }
    }

    @Test("Searching finds a function by name first, then by what it does")
    func search() {
        let results = FunctionReference.entries(in: nil, matching: "sum")
        #expect(results.first?.name == "SUM")
        #expect(FunctionReference.entries(in: .text, matching: "").allSatisfy { $0.category == .text })
    }
}
