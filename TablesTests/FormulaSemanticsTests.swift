import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Builds a one-sheet workbook from an A1-keyed table of raw entries and
/// returns a reader for its calculated values.
func evaluateSheet(_ entries: [String: String]) -> (String) -> CellValue {
    var sheet = Worksheet(name: "Sheet 1")
    for (reference, input) in entries {
        guard let address = CellAddress(a1: reference) else { continue }
        sheet.rowCount = max(sheet.rowCount, address.row + 1)
        sheet.columnCount = max(sheet.columnCount, address.column + 1)
        sheet[address] = CellInputParser.cell(from: input, inheriting: .default)
    }
    var workbook = Workbook(sheets: [sheet])
    workbook.recalculate()
    return { workbook.sheets[0][CellAddress(a1: $0)!].value }
}

/// Evaluates one formula against an optional table of cells.
func evaluate(_ formula: String, with entries: [String: String] = [:]) -> CellValue {
    evaluateSheet(entries.merging(["Z99": formula]) { _, new in new })("Z99")
}

@Suite("Excel's argument rules")
struct ArgumentRuleTests {
    @Test("Text typed into SUM is converted; text in a referenced cell is skipped")
    func directVersusReferenced() {
        #expect(evaluate("=SUM(\"3\",1)") == .number(4))
        #expect(evaluate("=SUM(A1,1)", with: ["A1": "=\"3\""]) == .number(1))
        #expect(evaluate("=SUM(\"x\",1)") == .error(.valueError))
        #expect(evaluate("=SUM(TRUE,1)") == .number(2))
        #expect(evaluate("=COUNT(1,\"2\",\"x\",TRUE)") == .number(3))
        #expect(evaluate("=AVERAGEA(A1:A3)", with: ["A1": "2", "A2": "x", "A3": "TRUE"]) == .number(1))
    }

    @Test("Errors in a range carry through aggregates")
    func errorsPropagate() {
        #expect(evaluate("=SUM(A1:A2)", with: ["A1": "1", "A2": "=1/0"]) == .error(.divideByZero))
        #expect(evaluate("=LEN(1/0)") == .error(.divideByZero))
        #expect(evaluate("=COUNT(A1:A2)", with: ["A1": "1", "A2": "=1/0"]) == .number(1))
    }

    @Test("Text that reads as a number, date or percentage works in arithmetic")
    func textCoercion() {
        #expect(evaluate("=\"1,000\"+1") == .number(1001))
        #expect(evaluate("=\"50%\"*2") == .number(1))
        #expect(evaluate("=\"$12\"+0") == .number(12))
        #expect(evaluate("=\"2024-01-15\"+0") == .number(45306))
        #expect(evaluate("=\"12:00\"*2") == .number(1))
        #expect(evaluate("=\"abc\"+1") == .error(.valueError))
    }

    @Test("Numbers become text with fifteen significant digits")
    func numberText() {
        #expect(evaluate("=1/3&\"\"") == .text("0.333333333333333"))
        #expect(evaluate("=2/3&\"\"") == .text("0.666666666666667"))
        #expect(evaluate("=10^15&\"\"") == .text("1E+15"))
        #expect(evaluate("=123456789012345&\"\"") == .text("123456789012345"))
        #expect(evaluate("=1.5E-10&\"\"") == .text("1.5E-10"))
        #expect(evaluate("=TRUE&\"\"") == .text("TRUE"))
    }

    @Test("Comparisons order numbers before text before booleans and ignore binary dust")
    func comparisons() {
        #expect(evaluate("=0.1+0.2=0.3") == .boolean(true))
        #expect(evaluate("=\"a\"=\"A\"") == .boolean(true))
        #expect(evaluate("=1<\"a\"") == .boolean(true))
        #expect(evaluate("=\"z\"<TRUE") == .boolean(true))
        #expect(evaluate("=A1=0", with: [:]) == .boolean(true))
        #expect(evaluate("=A1=\"\"", with: [:]) == .boolean(true))
    }

    @Test("Rounding works in decimal, as Excel's does")
    func rounding() {
        #expect(evaluate("=ROUND(2.675,2)") == .number(2.68))
        #expect(evaluate("=ROUND(-2.5,0)") == .number(-3))
        #expect(evaluate("=ROUNDUP(0.1+0.2,1)") == .number(0.3))
        #expect(evaluate("=ROUND(1234,-2)") == .number(1200))
        #expect(evaluate("=MOD(-3,2)") == .number(1))
        #expect(evaluate("=CEILING(-2.5,2)") == .number(-2))
        #expect(evaluate("=FLOOR(-2.5,2)") == .number(-4))
        #expect(evaluate("=0^0") == .error(.numberError))
    }

    @Test("Dates follow Excel's serials, phantom leap day included")
    func dates() {
        #expect(evaluate("=DATE(1900,2,28)") == .number(59))
        #expect(evaluate("=DATE(1900,3,1)") == .number(61))
        #expect(evaluate("=DATE(2024,14,1)") == .number(45689))
        #expect(evaluate("=DATE(24,1,1)") == .number(8767))
        #expect(evaluate("=DAY(60)") == .number(29))
        #expect(evaluate("=WEEKDAY(1)") == .number(1))
        #expect(evaluate("=WEEKDAY(45292,2)") == .number(1))
        #expect(evaluate("=HOUR(0.75)") == .number(18))
        #expect(evaluate("=YEAR(\"2023-06-30\")") == .number(2023))
    }
}

@Suite("Arrays and references")
struct ArrayAndReferenceTests {
    @Test("Operators work element by element, broadcasting single rows and columns")
    func broadcasting() {
        #expect(evaluate("=SUM(A1:A3*B1:B3)", with: ["A1": "1", "A2": "2", "A3": "3", "B1": "4", "B2": "5", "B3": "6"])
                == .number(32))
        #expect(evaluate("=SUMPRODUCT((A1:A3>1)*B1:B3)", with: ["A1": "1", "A2": "2", "A3": "3", "B1": "4", "B2": "5", "B3": "6"])
                == .number(11))
        #expect(evaluate("=SUM({1,2,3}*{1;2})") == .number(18))
        #expect(evaluate("=COUNTIF(IF({1,2,3}>1,{1,2},0),\"#N/A\")") == .number(1))
    }

    @Test("Functions taking single values spread over arrays")
    func lifting() {
        #expect(evaluate("=SUM(LEN({\"a\",\"bb\",\"ccc\"}))") == .number(6))
        #expect(evaluate("=SUM(COUNTIF(A1:A4,{\"x\",\"y\"}))", with: ["A1": "x", "A2": "y", "A3": "x", "A4": "z"])
                == .number(3))
        #expect(evaluate("=SUM(IFERROR(1/{1,0,2},0))") == .number(1.5))
    }

    @Test("INDEX and CHOOSE answer with references the range operator can join")
    func referenceFunctions() {
        let cells = ["A1": "1", "A2": "2", "A3": "3", "A4": "4"]
        #expect(evaluate("=SUM(A1:INDEX(A1:A4,3))", with: cells) == .number(6))
        #expect(evaluate("=SUM(INDEX(A1:B4,0,1))", with: cells) == .number(10))
        #expect(evaluate("=ROW(INDEX(A1:A4,3))", with: cells) == .number(3))
        #expect(evaluate("=SUM(CHOOSE(2,A1,A2:A3))", with: cells) == .number(5))
        #expect(evaluate("=SUM(A2:XLOOKUP(3,A1:A4,A1:A4))", with: cells) == .number(5))
    }

    @Test("Criteria understand operators, wildcards and numbers written as text")
    func criteria() {
        let cells = ["A1": "apple", "A2": "apricot", "A3": "banana", "A4": "5", "A5": "=\"5\"", "A6": ""]
        #expect(evaluate("=COUNTIF(A1:A6,\"ap*\")", with: cells) == .number(2))
        #expect(evaluate("=COUNTIF(A1:A6,\"?????\")", with: cells) == .number(1))
        #expect(evaluate("=COUNTIF(A1:A6,5)", with: cells) == .number(2))
        #expect(evaluate("=COUNTIF(A1:A6,\">4\")", with: cells) == .number(1))
        #expect(evaluate("=COUNTIF(A1:A6,\"<>apple\")", with: cells) == .number(5))
        #expect(evaluate("=COUNTIF(A1:A6,\"\")", with: cells) == .number(1))
        #expect(evaluate("=COUNTIF(A1:A6,\"<c\")", with: cells) == .number(4))
    }

    @Test("Lookups match exactly by kind and binary-search sorted data")
    func lookups() {
        let cells = ["A1": "10", "A2": "20", "A3": "30", "B1": "a", "B2": "b", "B3": "c"]
        #expect(evaluate("=VLOOKUP(25,A1:B3,2)", with: cells) == .text("b"))
        #expect(evaluate("=VLOOKUP(5,A1:B3,2)", with: cells) == .error(.notAvailable))
        #expect(evaluate("=VLOOKUP(\"20\",A1:B3,2,FALSE)", with: cells) == .error(.notAvailable))
        #expect(evaluate("=MATCH(\"B*\",B1:B3,0)", with: cells) == .number(2))
        #expect(evaluate("=INDEX(B1:B3,MATCH(30,A1:A3,0))", with: cells) == .text("c"))
        #expect(evaluate("=HLOOKUP(2,{1,2,3;\"x\",\"y\",\"z\"},2,FALSE)") == .text("y"))
    }

    @Test("PROPER capitalises after any non-letter")
    func proper() {
        #expect(evaluate("=PROPER(\"o'neil 2nd-place\")") == .text("O'Neil 2Nd-Place"))
        #expect(evaluate("=SEARCH(\"n?n\",\"banana\")") == .number(3))
        #expect(evaluate("=FIND(\"N\",\"banana\")") == .error(.valueError))
        #expect(evaluate("=LEN(\"😀\")") == .number(2))
    }
}

@Suite("LET and LAMBDA")
struct LambdaTests {
    @Test("LET names values for the rest of the formula, in order")
    func letBindings() {
        #expect(evaluate("=LET(x,2,y,x*3,x+y)") == .number(8))
        #expect(evaluate("=LET(r,A1:A3,ROW(r)+0)", with: ["A1": "1"]) == .number(1))
        #expect(evaluate("=LET(r,A1:A3,SUM(r))", with: ["A1": "1", "A2": "2", "A3": "3"]) == .number(6))
        #expect(evaluate("=LET(X,1,x+1)") == .number(2))
        #expect(evaluate("=LET(x,1,2)") == .number(2))
    }

    @Test("A LAMBDA can be called straight away, held in LET, or named in the workbook")
    func calling() {
        #expect(evaluate("=LAMBDA(x,x*x)(4)") == .number(16))
        #expect(evaluate("=LET(sq,LAMBDA(x,x*x),sq(5))") == .number(25))
        #expect(evaluate("=LAMBDA(x,x)") == .error(.calc))
        #expect(evaluate("=LAMBDA(x,y,ISOMITTED(y))(1)") == .boolean(true))
        #expect(evaluate("=LAMBDA(x,x)(1,2)") == .error(.valueError))

        var sheet = Worksheet(name: "Sheet 1")
        sheet[CellAddress(a1: "A1")!] = Cell(formula: "Fact(5)")
        var workbook = Workbook(sheets: [sheet], definedNames: [
            DefinedName(name: "Fact", formula: "LAMBDA(n,IF(n<=1,1,n*Fact(n-1)))", scope: nil),
        ])
        workbook.recalculate()
        #expect(workbook.sheets[0][CellAddress(a1: "A1")!].value == .number(120))
    }

    @Test("A LAMBDA sees the LET names around where it was written")
    func closures() {
        #expect(evaluate("=LET(k,10,f,LAMBDA(x,x+k),f(1))") == .number(11))
    }

    @Test("MAP, REDUCE, SCAN, BYROW, BYCOL and MAKEARRAY")
    func helpers() {
        #expect(evaluate("=SUM(MAP({1,2,3},LAMBDA(v,v*10)))") == .number(60))
        #expect(evaluate("=SUM(MAP({1,2},{3,4},LAMBDA(a,b,a*b)))") == .number(11))
        #expect(evaluate("=REDUCE(0,{1,2,3},LAMBDA(a,v,a+v))") == .number(6))
        #expect(evaluate("=REDUCE(,{1,2,3},LAMBDA(a,v,a+v))") == .number(6))
        #expect(evaluate("=INDEX(SCAN(0,{1,2,3},LAMBDA(a,v,a+v)),1,3)") == .number(6))
        #expect(evaluate("=SUM(BYROW({1,2;3,4},LAMBDA(r,SUM(r))))") == .number(10))
        #expect(evaluate("=INDEX(BYCOL({1,2;3,4},LAMBDA(c,SUM(c))),1,2)") == .number(6))
        #expect(evaluate("=SUM(MAKEARRAY(2,3,LAMBDA(r,c,r*c)))") == .number(18))
        #expect(evaluate("=INDEX(MAKEARRAY(2,3,LAMBDA(r,c,r*c)),2,3)") == .number(6))
    }

    @Test("Runaway recursion stops rather than crashing")
    func recursionLimit() {
        var sheet = Worksheet(name: "Sheet 1")
        sheet[CellAddress(a1: "A1")!] = Cell(formula: "Forever(1)")
        var workbook = Workbook(sheets: [sheet], definedNames: [
            DefinedName(name: "Forever", formula: "LAMBDA(n,Forever(n+1))", scope: nil),
        ])
        workbook.recalculate()
        #expect(workbook.sheets[0][CellAddress(a1: "A1")!].value == .error(.numberError))
    }
}

@Suite("Union and intersection")
struct ReferenceOperatorTests {
    private let grid = ["A1": "1", "A2": "2", "A3": "3", "B1": "10", "B2": "20", "B3": "30", "C1": "100", "C2": "200"]

    @Test("A comma in parentheses joins references; a space intersects them")
    func parsing() throws {
        let a1a2 = FormulaNode.range(sheet: nil, start: CellAddress(a1: "A1")!, end: CellAddress(a1: "A2")!)
        let c1 = FormulaNode.reference(sheet: nil, address: CellAddress(a1: "C1")!)
        #expect(try FormulaParser.parse("SUM((A1:A2,C1))") == .call("SUM", [.union([a1a2, c1])]))
        #expect(try FormulaParser.parse("SUM(A1:A2,C1)") == .call("SUM", [a1a2, c1]))
        #expect(try FormulaParser.parse("A1:A2 C1") == .binary(" ", a1a2, c1))
        #expect(try FormulaParser.parse("A1 + C1") == .binary("+", .reference(sheet: nil, address: CellAddress(a1: "A1")!), c1))
    }

    @Test("Unions feed aggregates, AREAS, INDEX and SUBTOTAL")
    func unions() {
        #expect(evaluate("=SUM((A1:A3,C1:C2))", with: grid) == .number(306))
        #expect(evaluate("=AREAS((A1:A3,C1:C2,B1))", with: grid) == .number(3))
        #expect(evaluate("=INDEX((A1:A3,C1:C2),2,1,2)", with: grid) == .number(200))
        #expect(evaluate("=SUBTOTAL(9,(A1,B1))", with: grid) == .number(11))
        #expect(evaluate("=MAX((A1:A3,B1:B3))", with: grid) == .number(30))
        #expect(evaluate("=ROWS((A1:A3,C1:C2))", with: grid) == .error(.referenceError))
    }

    @Test("Intersections pick the shared cells, or #NULL! when there are none")
    func intersections() {
        #expect(evaluate("=A1:C3 B2:B3", with: grid) == .number(20))
        #expect(evaluate("=SUM(A1:C2 B1:C3)", with: grid) == .number(330))
        #expect(evaluate("=A1:A3 C1:C3", with: grid) == .error(.nullError))
        #expect(evaluate("=SUM(A:A 2:3)", with: grid) == .number(5))
        #expect(FormulaDialect.legacyToDynamic("A:A 2:2") == "A:A 2:2")
    }
}
