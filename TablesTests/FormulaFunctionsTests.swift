import Foundation
import Testing
@testable import Tables
@testable import TablesEngine
@testable import TablesMacros

/// Builds a one-sheet workbook from an A1-keyed table of raw entries.
private func makeFunctionWorkbook(_ entries: [String: String], name: String = "Sheet 1") -> Workbook {
    var sheet = Worksheet(name: name)
    for (reference, input) in entries {
        guard let address = CellAddress(a1: reference) else { continue }
        sheet.rowCount = max(sheet.rowCount, address.row + 1)
        sheet.columnCount = max(sheet.columnCount, address.column + 1)
        sheet[address] = CellInputParser.cell(from: input, inheriting: .default)
    }
    var workbook = Workbook(sheets: [sheet])
    workbook.recalculate()
    return workbook
}

private func functionValue(_ workbook: Workbook, _ reference: String) -> CellValue {
    workbook.sheets[0][CellAddress(a1: reference)!].value
}

private func functionNumber(_ workbook: Workbook, _ reference: String) -> Double? {
    functionValue(workbook, reference).numericValue
}

/// The sample table every criteria and lookup suite below works against.
private let sampleTable: [String: String] = [
    "A1": "apple", "A2": "banana", "A3": "apple", "A4": "cherry", "A5": "banana",
    "B1": "10", "B2": "20", "B3": "30", "B4": "40", "B5": "50",
    "C1": "x", "C2": "y", "C3": "x", "C4": "y", "C5": "x",
]

private func makeSampleWorkbook(_ formulas: [String: String]) -> Workbook {
    makeFunctionWorkbook(sampleTable.merging(formulas) { _, formula in formula })
}

@Suite("Multi-criteria aggregates")
struct MultiCriteriaAggregateTests {
    @Test("SUMIFS totals the leading range where every criterion matches")
    func sumifs() {
        let workbook = makeSampleWorkbook([
            "E1": "=SUMIFS(B1:B5,A1:A5,\"apple\")",
            "E2": "=SUMIFS(B1:B5,A1:A5,\"apple\",C1:C5,\"x\")",
            "E3": "=SUMIFS(B1:B5,B1:B5,\">20\",C1:C5,\"x\")",
            "E4": "=SUMIFS(B1:B5,A1:A5,\"durian\")",
            "E5": "=SUMIFS(B1:B5,A1:A5,\"<>apple\")",
        ])
        #expect(functionNumber(workbook, "E1") == 40)
        #expect(functionNumber(workbook, "E2") == 40)
        #expect(functionNumber(workbook, "E3") == 80)
        #expect(functionNumber(workbook, "E4") == 0)
        #expect(functionNumber(workbook, "E5") == 110)
    }

    @Test("COUNTIFS counts rows satisfying all criteria")
    func countifs() {
        let workbook = makeSampleWorkbook([
            "E1": "=COUNTIFS(A1:A5,\"banana\")",
            "E2": "=COUNTIFS(A1:A5,\"<>apple\")",
            "E3": "=COUNTIFS(B1:B5,\">=30\",C1:C5,\"y\")",
            "E4": "=COUNTIFS(B1:B5,\">10\",B1:B5,\"<50\")",
            "E5": "=COUNTIFS(A1:A5,\"APPLE\")",
        ])
        #expect(functionNumber(workbook, "E1") == 2)
        #expect(functionNumber(workbook, "E2") == 3)
        #expect(functionNumber(workbook, "E3") == 1)
        #expect(functionNumber(workbook, "E4") == 3)
        #expect(functionNumber(workbook, "E5") == 2)  // criteria ignore case
    }

    @Test("AVERAGEIFS averages only the matching rows")
    func averageifs() {
        let workbook = makeSampleWorkbook([
            "E1": "=AVERAGEIFS(B1:B5,A1:A5,\"apple\")",
            "E2": "=AVERAGEIFS(B1:B5,C1:C5,\"x\",B1:B5,\">10\")",
            "E3": "=AVERAGEIFS(B1:B5,A1:A5,\"durian\")",
        ])
        #expect(functionNumber(workbook, "E1") == 20)
        #expect(functionNumber(workbook, "E2") == 40)
        #expect(functionValue(workbook, "E3").errorValue == .divideByZero)
    }

    @Test("Mismatched shapes and dangling criteria are rejected")
    func argumentErrors() {
        let workbook = makeSampleWorkbook([
            "E1": "=SUMIFS(B1:B5,A1:A3,\"apple\")",
            "E2": "=SUMIFS(B1:B5,A1:A5)",
            "E3": "=COUNTIFS(A1:A5)",
            "E4": "=COUNTIFS(A1:A5,\"apple\",C1:C3,\"x\")",
            "E5": "=AVERAGEIFS(B1:B5)",
        ])
        for reference in ["E1", "E2", "E3", "E4", "E5"] {
            #expect(functionValue(workbook, reference).errorValue == .valueError)
        }
    }
}

@Suite("XLOOKUP")
struct CrossLookupTests {
    @Test("Exact matches return the parallel entry")
    func exactMatches() {
        let workbook = makeSampleWorkbook([
            "E1": "=XLOOKUP(\"banana\",A1:A5,B1:B5)",
            "E2": "=XLOOKUP(\"APPLE\",A1:A5,B1:B5)",
            "E3": "=XLOOKUP(30,B1:B5,A1:A5)",
            "E4": "=XLOOKUP(\"cherry\",A1:A5,C1:C5,\"none\",0)",
        ])
        #expect(functionNumber(workbook, "E1") == 20)  // first match wins
        #expect(functionNumber(workbook, "E2") == 10)
        #expect(functionValue(workbook, "E3") == .text("apple"))
        #expect(functionValue(workbook, "E4") == .text("y"))
    }

    @Test("Missing values fall back or report #N/A")
    func missingValues() {
        let workbook = makeSampleWorkbook([
            "E1": "=XLOOKUP(\"durian\",A1:A5,B1:B5)",
            "E2": "=XLOOKUP(\"durian\",A1:A5,B1:B5,\"none\")",
            "E3": "=XLOOKUP(\"durian\",A1:A5,B1:B5,0)",
        ])
        #expect(functionValue(workbook, "E1").errorValue == .notAvailable)
        #expect(functionValue(workbook, "E2") == .text("none"))
        #expect(functionNumber(workbook, "E3") == 0)
    }

    @Test("Bad arity, mismatched arrays and unknown modes give #VALUE!")
    func lookupErrors() {
        let workbook = makeSampleWorkbook([
            "E1": "=XLOOKUP(\"apple\",A1:A5)",
            "E2": "=XLOOKUP(\"apple\",A1:A5,B1:B4)",
            "E3": "=XLOOKUP(\"apple\",A1:A5,B1:B5,\"none\",5)",
        ])
        for reference in ["E1", "E2", "E3"] {
            #expect(functionValue(workbook, reference).errorValue == .valueError)
        }
    }

    @Test("Wildcard and nearest-value match modes")
    func matchModes() {
        let workbook = makeSampleWorkbook([
            "E1": "=XLOOKUP(\"ch*\",A1:A5,B1:B5,\"none\",2)",
            "E2": "=XLOOKUP(25,B1:B5,A1:A5,,-1)",
            "E3": "=XLOOKUP(25,B1:B5,A1:A5,,1)",
            "E4": "=XLOOKUP(\"apple\",A1:A5,B1:B5,,0,-1)",
        ])
        #expect(functionNumber(workbook, "E1") == 40)
        #expect(functionValue(workbook, "E2") == .text("banana"))
        #expect(functionValue(workbook, "E3") == .text("apple"))
        #expect(functionNumber(workbook, "E4") == 30)
    }
}

@Suite("TEXTJOIN")
struct TextJoinTests {
    @Test("Ranges expand and the delimiter separates every piece")
    func joining() {
        let workbook = makeSampleWorkbook([
            "E1": "=TEXTJOIN(\"-\",TRUE,A1:A3)",
            "E2": "=TEXTJOIN(\", \",TRUE,\"x\",B1)",
            "E3": "=TEXTJOIN(\"\",TRUE,A1:A2)",
        ])
        #expect(functionValue(workbook, "E1") == .text("apple-banana-apple"))
        #expect(functionValue(workbook, "E2") == .text("x, 10"))
        #expect(functionValue(workbook, "E3") == .text("applebanana"))
    }

    @Test("ignore_empty decides whether blanks leave gaps")
    func blanks() {
        let workbook = makeFunctionWorkbook([
            "D1": "a", "D3": "c",
            "E1": "=TEXTJOIN(\",\",TRUE,D1:D3)",
            "E2": "=TEXTJOIN(\",\",FALSE,D1:D3)",
        ])
        #expect(functionValue(workbook, "E1") == .text("a,c"))
        #expect(functionValue(workbook, "E2") == .text("a,,c"))
    }

    @Test("A missing text argument list yields an empty string, a missing flag an error")
    func edgeCases() {
        let workbook = makeFunctionWorkbook([
            "E1": "=TEXTJOIN(\",\",TRUE)",
            "E2": "=TEXTJOIN(\",\")",
            "E3": "=TEXTJOIN(\",\",TRUE,1/0)",
        ])
        #expect(functionValue(workbook, "E1") == .text(""))
        #expect(functionValue(workbook, "E2").errorValue == .valueError)
        #expect(functionValue(workbook, "E3").errorValue == .divideByZero)
    }
}

@Suite("SWITCH")
struct SwitchTests {
    @Test("The first matching value selects its result")
    func matching() {
        let workbook = makeSampleWorkbook([
            "E1": "=SWITCH(2,1,\"one\",2,\"two\",3,\"three\")",
            "E2": "=SWITCH(A1,\"apple\",\"fruit\",\"carrot\",\"vegetable\")",
            "E3": "=SWITCH(B2/10,1,\"low\",2,\"medium\",3,\"high\")",
        ])
        #expect(functionValue(workbook, "E1") == .text("two"))
        #expect(functionValue(workbook, "E2") == .text("fruit"))
        #expect(functionValue(workbook, "E3") == .text("medium"))
    }

    @Test("A trailing argument acts as the default, otherwise #N/A")
    func defaults() {
        let workbook = makeSampleWorkbook([
            "E1": "=SWITCH(9,1,\"one\",2,\"two\",\"other\")",
            "E2": "=SWITCH(9,1,\"one\",2,\"two\")",
            "E3": "=SWITCH(\"APPLE\",\"apple\",\"fruit\",\"other\")",
            "E4": "=SWITCH(1,1)",
        ])
        #expect(functionValue(workbook, "E1") == .text("other"))
        #expect(functionValue(workbook, "E2").errorValue == .notAvailable)
        #expect(functionValue(workbook, "E3") == .text("fruit"))
        #expect(functionValue(workbook, "E4").errorValue == .valueError)
    }

    @Test("An erroring expression propagates instead of falling to the default")
    func errorPropagation() {
        let workbook = makeFunctionWorkbook(["E1": "=SWITCH(1/0,1,\"one\",\"other\")"])
        #expect(functionValue(workbook, "E1").errorValue == .divideByZero)
    }
}

/// A stand-in workbook context that reports a fixed extent and no stored values,
/// so `ROW()`/`COLUMN()` can be exercised without a full calculation pass.
private final class StubFormulaContext: FormulaContext {
    let currentSheetName = "Sheet 1"

    func value(at address: CellAddress, sheetName: String?) -> CellValue { .empty }

    func bounds(forSheetNamed name: String?) -> (rows: Int, columns: Int)? { (rows: 100, columns: 26) }
}

@Suite("ROW and COLUMN")
struct PositionFunctionTests {
    @Test("A reference argument reports that cell's position")
    func withReference() {
        let workbook = makeFunctionWorkbook([
            "E1": "=ROW(B3)", "E2": "=COLUMN(B3)", "E3": "=ROW(1+1)", "E4": "=COLUMN(\"x\")",
        ])
        #expect(functionNumber(workbook, "E1") == 3)
        #expect(functionNumber(workbook, "E2") == 2)
        #expect(functionValue(workbook, "E3").errorValue == .valueError)
        #expect(functionValue(workbook, "E4").errorValue == .valueError)
    }

    @Test("Without arguments the evaluator's own address answers")
    func withoutArguments() throws {
        let context = StubFormulaContext()
        let evaluator = FormulaEvaluator(context: context, currentAddress: CellAddress(a1: "C7")!)
        #expect(evaluator.evaluate(try FormulaParser.parse("ROW()")) == .number(7))
        #expect(evaluator.evaluate(try FormulaParser.parse("COLUMN()")) == .number(3))
        #expect(evaluator.evaluate(try FormulaParser.parse("ROW()+COLUMN()")) == .number(10))
    }

    @Test("Without a known address the bare forms report #VALUE!")
    func withoutAddress() throws {
        let evaluator = FormulaEvaluator(context: StubFormulaContext())
        #expect(evaluator.evaluate(try FormulaParser.parse("ROW()")) == .failure(.valueError))
        #expect(evaluator.evaluate(try FormulaParser.parse("COLUMN()")) == .failure(.valueError))
    }
}
