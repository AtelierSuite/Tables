import Testing
@testable import Tables
@testable import TablesEngine

@Suite("Formula reference scanner")
struct FormulaReferenceScannerTests {
    private func spans(_ text: String) -> [String] {
        let characters = Array(text)
        return FormulaReferenceScanner.references(in: text).map { String(characters[$0.range]) }
    }

    @Test func findsCellsAndRanges() {
        #expect(spans("=SUM(A1:B2)+$C$3*d4") == ["A1:B2", "$C$3", "d4"])
    }

    @Test func includesTheSheetItNames() {
        let references = FormulaReferenceScanner.references(in: "=Data!A1+'Q1 Sales'!B2:B9")
        #expect(spans("=Data!A1+'Q1 Sales'!B2:B9") == ["Data!A1", "'Q1 Sales'!B2:B9"])
        #expect(references.map(\.sheetName) == ["Data", "Q1 Sales"])
    }

    @Test func skipsFunctionNamesAndText() {
        #expect(spans("=LOG10(A1)&\"B2\"") == ["A1"])
    }

    @Test func sharesAColourBetweenMentionsOfTheSameCells() {
        let references = FormulaReferenceScanner.references(in: "=A1+B2+$A$1+B2:A1")
        #expect(references.map(\.colorIndex) == [0, 1, 0, 2])
    }

    @Test func keepsWhatPrecedesAnUnfinishedString() {
        #expect(spans("=A1&\"unfinished") == ["A1"])
    }

    @Test func ignoresPlainText() {
        #expect(spans("A1+B2").isEmpty)
    }
}
