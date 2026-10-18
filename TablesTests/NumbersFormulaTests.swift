import Foundation
import Testing
@testable import Tables
@testable import TablesEngine

/// Nodes laid out as Numbers writes them, for formulas to be read from.
enum NumbersNodes {
    static func node(_ type: Int, _ configure: (inout ProtobufMessage) -> Void = { _ in }) -> ProtobufMessage {
        var node = ProtobufMessage()
        node.set(1, uint: UInt64(type))
        configure(&node)
        return node
    }

    static func number(_ value: Double) -> ProtobufMessage {
        node(NumbersFormula.NodeType.number) { $0.set(4, [.fixed64(value.bitPattern)]) }
    }

    /// A cell `columns` and `rows` away from the formula's own, or at them
    /// when absolute.
    static func cell(
        column: Int, row: Int, columnAbsolute: Bool = false, rowAbsolute: Bool = false,
        table: MergeOwners.UUID? = nil
    ) -> ProtobufMessage {
        func coordinate(_ value: Int, _ absolute: Bool) -> ProtobufMessage {
            var coordinate = ProtobufMessage()
            coordinate.set(1, uint: UInt64(bitPattern: Int64(value) << 1 ^ Int64(value) >> 63))
            coordinate.set(2, bool: absolute)
            return coordinate
        }
        return node(NumbersFormula.NodeType.cellReference) {
            $0.set(26, message: coordinate(column, columnAbsolute))
            $0.set(27, message: coordinate(row, rowAbsolute))
            if let table { $0.set(28, message: crossTable(table)) }
        }
    }

    /// A whole column `column` away from the formula's own, or at it when
    /// absolute, as Numbers writes `B` or `Table 1::B`: a reference with a
    /// column and no row.
    static func wholeColumn(_ column: Int, absolute: Bool = false, table: MergeOwners.UUID? = nil) -> ProtobufMessage {
        line(26, column, absolute: absolute, table: table)
    }

    /// A whole row, a reference with a row and no column.
    static func wholeRow(_ row: Int, absolute: Bool = false, table: MergeOwners.UUID? = nil) -> ProtobufMessage {
        line(27, row, absolute: absolute, table: table)
    }

    private static func line(_ field: Int, _ value: Int, absolute: Bool, table: MergeOwners.UUID?) -> ProtobufMessage {
        var coordinate = ProtobufMessage()
        coordinate.set(1, uint: UInt64(bitPattern: Int64(value) << 1 ^ Int64(value) >> 63))
        coordinate.set(2, bool: absolute)
        return node(NumbersFormula.NodeType.cellReference) {
            $0.set(field, message: coordinate)
            if let table { $0.set(28, message: crossTable(table)) }
        }
    }

    static func crossTable(_ table: MergeOwners.UUID) -> ProtobufMessage {
        var words = ProtobufMessage()
        words.set(2, uint: table.lower & 0xFFFF_FFFF)
        words.set(3, uint: table.lower >> 32)
        words.set(4, uint: table.upper & 0xFFFF_FFFF)
        words.set(5, uint: table.upper >> 32)
        var info = ProtobufMessage()
        info.set(1, message: words)
        return info
    }

    /// A range of rows and columns counted from the formula's cell, as recent
    /// versions of Numbers write one.
    static func relativeRange(columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> ProtobufMessage {
        func range(_ bounds: ClosedRange<Int>) -> ProtobufMessage {
            var range = ProtobufMessage()
            range.set(1, uint: UInt64(bitPattern: Int64(bounds.lowerBound)))
            range.set(2, uint: UInt64(bitPattern: Int64(bounds.upperBound)))
            return range
        }
        var tract = ProtobufMessage()
        tract.set(1, message: range(columns))
        tract.set(2, message: range(rows))
        tract.set(5, bool: true)
        var sticky = ProtobufMessage()
        for field in 1...4 { sticky.set(field, bool: false) }
        return node(NumbersFormula.NodeType.colonTract) {
            $0.set(33, message: sticky)
            $0.set(40, message: tract)
        }
    }

    static func function(_ name: String, arguments: Int) -> ProtobufMessage {
        node(NumbersFormula.NodeType.function) {
            $0.set(2, uint: UInt64(NumbersFunctionIndex.indices[name]!))
            $0.set(3, uint: UInt64(arguments))
        }
    }
}

@Suite("Numbers formulas")
struct NumbersFormulaTests {
    private let otherTable = MergeOwners.UUID(lower: 0x1234_5678_9ABC_DEF0, upper: 0x0FED_CBA9_8765_4321)

    private func context(_ host: String) -> NumbersFormula.Context {
        NumbersFormula.Context(host: CellAddress(a1: host)!, hostTable: nil, sheetNames: [otherTable: "Rates – Table 1"])
    }

    @Test("References count from the formula's cell unless they are absolute")
    func references() {
        let nodes = [
            NumbersNodes.cell(column: 0, row: -1),
            NumbersNodes.cell(column: -2, row: 0),
            NumbersNodes.node(NumbersFormula.NodeType.addition),
            NumbersNodes.cell(column: 1, row: 0, columnAbsolute: true, rowAbsolute: true),
            NumbersNodes.node(NumbersFormula.NodeType.subtraction),
        ]
        #expect(NumbersFormula.formula(from: nodes, context: context("E3")) == "E2+C3-$B$1")
    }

    @Test("Operators the tree groups looser than their parent are put in parentheses")
    func parentheses() {
        let nodes = [
            NumbersNodes.number(1), NumbersNodes.number(2),
            NumbersNodes.node(NumbersFormula.NodeType.addition),
            NumbersNodes.number(3), NumbersNodes.number(4),
            NumbersNodes.node(NumbersFormula.NodeType.subtraction),
            NumbersNodes.node(NumbersFormula.NodeType.subtraction),
            NumbersNodes.node(NumbersFormula.NodeType.negation),
            NumbersNodes.number(2),
            NumbersNodes.node(NumbersFormula.NodeType.multiplication),
        ]
        #expect(NumbersFormula.formula(from: nodes, context: context("A1")) == "-(1+2-(3-4))*2")
    }

    @Test("A range of relative rows and columns reads as the cells it covers")
    func colonTract() {
        // Numbers' own `SUM(C3:K6)`, in C7.
        let nodes = [
            NumbersNodes.relativeRange(columns: 0...8, rows: -4 ... -1),
            NumbersNodes.function("SUM", arguments: 1),
        ]
        #expect(NumbersFormula.formula(from: nodes, context: context("C7")) == "SUM(C3:K6)")
    }

    @Test("A range anchored at one end reads its other end from the list of its kind")
    func mixedRange() {
        // Numbers' own `SUM($H$1:H4)`, in H5: the relative list keeps an
        // unused start alongside the end.
        func range(_ values: [Int]) -> ProtobufMessage {
            var range = ProtobufMessage()
            for (field, value) in zip([1, 2], values) { range.set(field, uint: UInt64(bitPattern: Int64(value))) }
            return range
        }
        var tract = ProtobufMessage()
        tract.set(1, message: range([0]))
        tract.set(2, message: range([-3, -1]))
        tract.set(3, message: range([7]))
        tract.set(4, message: range([0]))
        var sticky = ProtobufMessage()
        for (field, value) in zip(1...4, [true, true, false, false]) { sticky.set(field, bool: value) }
        let nodes = [
            NumbersNodes.node(NumbersFormula.NodeType.colonTract) {
                $0.set(33, message: sticky)
                $0.set(40, message: tract)
            },
            NumbersNodes.function("SUM", arguments: 1),
        ]
        #expect(NumbersFormula.formula(from: nodes, context: context("H5")) == "SUM($H$1:H4)")
    }

    @Test("A colon kept with UUIDs joins its two ends as a colon does")
    func colonWithUIDs() {
        let nodes = [
            NumbersNodes.cell(column: -1, row: 0), NumbersNodes.cell(column: -1, row: 2),
            NumbersNodes.node(NumbersFormula.NodeType.colonWithUIDs), NumbersNodes.function("SUM", arguments: 1),
        ]
        #expect(NumbersFormula.formula(from: nodes, context: context("B1")) == "SUM(A1:A3)")
    }

    @Test("Thunks around IF's branches are passed over")
    func thunks() {
        let nodes = [
            NumbersNodes.cell(column: -1, row: 0),
            NumbersNodes.number(0),
            NumbersNodes.node(NumbersFormula.NodeType.greaterThan),
            NumbersNodes.node(NumbersFormula.NodeType.beginThunk),
            NumbersNodes.node(NumbersFormula.NodeType.string) { $0.set(6, bytes: Array("up \"a\"".utf8)) },
            NumbersNodes.node(NumbersFormula.NodeType.endThunk),
            NumbersNodes.node(NumbersFormula.NodeType.beginThunk),
            NumbersNodes.node(NumbersFormula.NodeType.boolean) { $0.set(5, bool: false) },
            NumbersNodes.node(NumbersFormula.NodeType.endThunk),
            NumbersNodes.function("IF", arguments: 3),
        ]
        #expect(NumbersFormula.formula(from: nodes, context: context("B1")) == "IF(A1>0,\"up \"\"a\"\"\",FALSE)")
    }

    @Test("Another table is named by its worksheet")
    func crossTable() {
        let nodes = [NumbersNodes.cell(column: 0, row: 1, columnAbsolute: true, rowAbsolute: true, table: otherTable)]
        #expect(NumbersFormula.formula(from: nodes, context: context("A1")) == "'Rates – Table 1'!$A$2")
    }

    @Test("A reference with only a column or a row reads as all of it, and is written back node for node")
    func wholeLines() throws {
        // Numbers' own `SUM(B)` in B9, `SUM($C)` and `SUM(Rates::B)`, and a
        // whole row, `SUM(3)`.
        let cases: [(nodes: [ProtobufMessage], formula: String)] = [
            ([NumbersNodes.wholeColumn(0)], "SUM(B:B)"),
            ([NumbersNodes.wholeColumn(2, absolute: true)], "SUM($C:$C)"),
            ([NumbersNodes.wholeColumn(0, table: otherTable)], "SUM('Rates – Table 1'!B:B)"),
            ([NumbersNodes.wholeRow(-6)], "SUM(3:3)"),
            ([NumbersNodes.wholeColumn(-1), NumbersNodes.wholeColumn(1), NumbersNodes.node(NumbersFormula.NodeType.colon)],
             "SUM(A:C)"),
        ]
        for (references, formula) in cases {
            let nodes = references + [NumbersNodes.function("SUM", arguments: 1)]
            #expect(NumbersFormula.formula(from: nodes, context: context("B9")) == formula)
            let written = try #require(NumbersFormula.nodes(for: formula, context: context("B9")))
            #expect(written.map { $0.encoded() } == nodes.map { $0.encoded() }, "\(formula)")
        }
    }

    @Test("A whole column joined to a single cell isn't read")
    func wholeColumnToCell() {
        let nodes = [
            NumbersNodes.wholeColumn(0), NumbersNodes.cell(column: 0, row: 0),
            NumbersNodes.node(NumbersFormula.NodeType.colon), NumbersNodes.function("SUM", arguments: 1),
        ]
        #expect(NumbersFormula.formula(from: nodes, context: context("B9")) == nil)
    }

    @Test("Formulas with anything Tables can't take on aren't read")
    func unreadable() {
        let nowhere = NumbersNodes.node(NumbersFormula.NodeType.cellReference)
        #expect(NumbersFormula.formula(from: [nowhere, NumbersNodes.function("SUM", arguments: 1)], context: context("B1")) == nil)
        let unknownFunction = NumbersNodes.function("DUR2WEEKS", arguments: 1)
        #expect(NumbersFormula.formula(from: [NumbersNodes.number(1), unknownFunction], context: context("B1")) == nil)
        let unknownTable = NumbersNodes.cell(column: 0, row: 0, table: MergeOwners.UUID(lower: 1, upper: 2))
        #expect(NumbersFormula.formula(from: [unknownTable], context: context("B1")) == nil)
    }

    @Test("Numbers' DURATION reads as DURATION.TIME, and is written back as Numbers' DURATION")
    func duration() throws {
        let nodes = [NumbersNodes.number(0), NumbersNodes.number(8), NumbersNodes.function("DURATION", arguments: 2)]
        #expect(NumbersFormula.formula(from: nodes, context: context("B1")) == "DURATION.TIME(0,8)")
        let written = try #require(NumbersFormula.nodes(for: "DURATION.TIME(0,8)", context: context("B1")))
        #expect(written.last?.int(2) == NumbersFunctionIndex.indices["DURATION"])
    }

    @Test("Formulas come back the same after being written and read again", arguments: [
        "A1+B1*2", "(A1+B1)*2", "-A1^2", "2^3^2", "(2^3)^2", "SUM($A$1:B$3,10%)", "IF(A1>=1,\"yes\",IFERROR(1/0,0))",
        "'Rates – Table 1'!B2*2", "SUM('Rates – Table 1'!A1:A9)", "AVERAGE({1,2;3,4})", "IFS(A1,1,TRUE,2)",
        "CHOOSE(2,A1,B1,C1)", "1.234E-09*A1", "0.1+1E+16", "SUM($A$1:B3)", "SUM(A1:$B$3)", "SUM($A1:B$3)", "SUM(A$1:$B3)", "A1&\" \"&B1", "A1<>B1", "COUNT(,1)", "SUM(A2:INDEX(A1:A9,3))", "DAYNAME(A1)",
        "SUM(B:B)", "SUM($B:$B)", "SUM($B:D)", "SUM(2:4)", "SUM($7:$7)", "COUNTA('Rates – Table 1'!A:A)", "B:B*2",
    ])
    func roundTrip(_ formula: String) throws {
        let nodes = try #require(NumbersFormula.nodes(for: formula, context: context("D5")))
        #expect(NumbersFormula.formula(from: nodes, context: context("D5")) == formula)
    }

    @Test("IF, IFS and CHOOSE hold back the arguments Numbers works out lazily")
    func writesThunks() throws {
        let nodes = try #require(NumbersFormula.nodes(for: "IF(A1,1,2)", context: context("B1")))
        let types = nodes.map { $0.int(1) ?? 0 }
        let begin = NumbersFormula.NodeType.beginThunk, end = NumbersFormula.NodeType.endThunk
        #expect(types == [
            NumbersFormula.NodeType.cellReference, begin, NumbersFormula.NodeType.number, end,
            begin, NumbersFormula.NodeType.number, end, NumbersFormula.NodeType.function,
        ])
    }

    @Test("Formulas Numbers can't be given are turned away", arguments: [
        "SUM(A5:A1048576)", "SUM(B1:XFD1)", "SUM(A:A 1:1)", "LET(x,1,x)", "DURATION(A1,B1,0.08,0.09,2)", "Missing!A1", "#N/A", "Sales[Amount]", "A1#",
    ])
    func unwritable(_ formula: String) {
        #expect(NumbersFormula.nodes(for: formula, context: context("B1")) == nil)
    }
}

@Suite("Numbers formula saving")
struct NumbersFormulaSavingTests {
    private let rates = MergeOwners.UUID(lower: 0xABCD, upper: 0xEF01)

    /// A table whose C1 is Numbers' own `A1+B1`, beside a table of rates.
    private func document() throws -> Data {
        let sum = [
            NumbersNodes.cell(column: -2, row: 0), NumbersNodes.cell(column: -1, row: 0),
            NumbersNodes.node(NumbersFormula.NodeType.addition),
        ]
        var document = NumbersDocumentBuilder()
        var rates = NumbersDocumentBuilder.Table(name: "Rates", rows: [[.number(3, exponent: 0)]])
        rates.uuid = self.rates
        document.addSheet("Sums", tables: [.init(name: "Table 1", rows: [
            [.number(1, exponent: 0), .number(2, exponent: 0), .formulaNodes(3, sum)],
            [.number(5, exponent: 0), .empty, .formula(9)],
        ])])
        document.addSheet("Rates", tables: [rates])
        return try document.singleFile()
    }

    private func save(_ workbook: Workbook, _ source: NumbersSource) throws -> Data {
        try #require(NumbersWriter.fileWrapper(for: workbook, source: source, existing: nil).regularFileContents)
    }

    @Test("Numbers formulas Tables can read come in as formulas, and work out again")
    func readsFormulas() throws {
        var (workbook, source) = try NumbersReader.document(from: document())
        let c1 = CellAddress(a1: "C1")!
        #expect(workbook.sheets[0][c1].formula == "A1+B1")
        #expect(workbook.sheets[0][c1].value == .number(3))
        #expect(workbook.sheets[0][CellAddress(a1: "C2")!].formula == nil, "a formula Tables can't read")
        #expect(source.tables[workbook.sheets[0].id]?.protectedCells == [CellAddress(a1: "C2")!])

        workbook.sheets[0][CellAddress(a1: "A1")!] = Cell(value: .number(10))
        workbook.recalculate()
        #expect(workbook.sheets[0][c1].value == .number(12))
    }

    @Test("A formula Tables works out differently keeps Numbers' result, and is left as Numbers wrote it")
    func keepsNumbersResults() throws {
        // Numbers' result for `A1+B1` is 3; this one says 4, as if Numbers
        // read something differently.
        let sum = [
            NumbersNodes.cell(column: -2, row: 0), NumbersNodes.cell(column: -1, row: 0),
            NumbersNodes.node(NumbersFormula.NodeType.addition),
        ]
        var builder = NumbersDocumentBuilder()
        builder.addSheet("Sums", tables: [.init(name: "Table 1", rows: [
            [.number(1, exponent: 0), .number(2, exponent: 0), .formulaNodes(4, sum),
             .formulaNodes(8, [NumbersNodes.cell(column: -1, row: 0), NumbersNodes.number(2),
                               NumbersNodes.node(NumbersFormula.NodeType.multiplication)])],
        ])])
        let (workbook, source) = try NumbersReader.document(from: builder.singleFile())
        let sheet = workbook.sheets[0]
        #expect(sheet[CellAddress(a1: "C1")!].formula == nil)
        #expect(sheet[CellAddress(a1: "C1")!].value == .number(4))
        #expect(source.tables[sheet.id]?.protectedCells.contains(CellAddress(a1: "C1")!) == true)
        // D1 doubles C1, so agrees once C1 is Numbers' 4 again.
        #expect(sheet[CellAddress(a1: "D1")!].formula == "C1*2")
        #expect(sheet[CellAddress(a1: "D1")!].value == .number(8))
    }

    @Test("A formula fetching exchange rates is read, and keeps the result Numbers fetched")
    func keepsFetchedResults() throws {
        let usd = NumbersNodes.node(NumbersFormula.NodeType.string) { $0.set(6, bytes: Array("USD".utf8)) }
        let convert = [NumbersNodes.cell(column: -1, row: 0), usd, NumbersNodes.function("CURRENCYCONVERT", arguments: 2)]
        var builder = NumbersDocumentBuilder()
        builder.addSheet("Money", tables: [.init(name: "Table 1", rows: [
            [.number(1000, exponent: 0), .formulaNodes(7, convert)],
        ])])
        let (read, source) = try NumbersReader.document(from: builder.singleFile())
        var workbook = read
        let b1 = CellAddress(a1: "B1")!
        #expect(workbook.sheets[0][b1].formula == "CURRENCYCONVERT(A1,\"USD\")")
        #expect(workbook.sheets[0][b1].value == .number(7))
        #expect(source.tables[workbook.sheets[0].id]?.protectedCells.isEmpty == true)

        workbook.sheets[0][CellAddress(a1: "A1")!] = Cell(value: .number(2000))
        workbook.recalculate()
        #expect(workbook.sheets[0][b1].value == .number(7), "never worked out again")
    }

    @Test("A new formula is saved with its result, and read back as a formula")
    func writesFormula() throws {
        let original = try document()
        var (workbook, source) = try NumbersReader.document(from: original)
        var cell = Cell()
        cell.formula = "A1*Rates!A1"
        workbook.sheets[0][CellAddress(a1: "B2")!] = cell
        workbook.sheets[0][CellAddress(a1: "D1")!] = { var cell = Cell(); cell.formula = "C1*2"; return cell }()
        workbook.sheets[0].addColumns(1)
        workbook.recalculate()
        #expect(NumbersEditPolicy.violation(in: workbook, source: source) == nil)
        let saved = try save(workbook, source)

        let (reread, rereadSource) = try NumbersReader.document(from: saved)
        let sheet = reread.sheets[0]
        #expect(sheet[CellAddress(a1: "B2")!].formula == "A1*Rates!A1")
        #expect(sheet[CellAddress(a1: "B2")!].value == .number(3))
        #expect(sheet[CellAddress(a1: "D1")!].formula == "C1*2")
        #expect(sheet[CellAddress(a1: "C1")!].formula == "A1+B1")

        let table = try #require(rereadSource.tables[sheet.id])
        let storage = try #require(table.storage[CellAddress(a1: "B2")!].flatMap(NumbersCellStorage.init))
        #expect(storage.hasFormula)
        #expect(storage.type == NumbersCellStorage.CellType.number)
        #expect(storage.field(NumbersCellStorage.Field.decimal) == NumbersCellStorage.decimal128(3))

        // The engine counts the two new formulas, and is asked to work
        // every table out again.
        let archive = rereadSource.archive
        let engine = try #require(archive[3]?.message)
        #expect(engine.message(2)?.uint(5) == 4)
        let stale = try #require(archive[NumbersDocumentBuilder.staleOwnerListIdentifier]?.message)
        #expect(!(stale.message(1)?.messages(1).isEmpty ?? true))
    }

    @Test("A formula's result changing saves the result beside the formula it had")
    func keepsFormulaKey() throws {
        var (workbook, source) = try NumbersReader.document(from: document())
        let before = try #require(source.tables[workbook.sheets[0].id]?.storage[CellAddress(a1: "C1")!])
        workbook.sheets[0][CellAddress(a1: "A1")!] = Cell(value: .number(10))
        workbook.recalculate()
        let (_, saved) = try NumbersReader.document(from: save(workbook, source))
        let after = try #require(saved.tables.values.first { $0.rowCount == 2 }?.storage[CellAddress(a1: "C1")!])
        let old = try #require(NumbersCellStorage(before)), new = try #require(NumbersCellStorage(after))
        #expect(new.formulaKey == old.formulaKey)
        #expect(new.field(NumbersCellStorage.Field.decimal) == NumbersCellStorage.decimal128(12))
    }

    @Test("Formulas that read the same share one entry in the table's formulas")
    func sharesFormulas() throws {
        var (workbook, source) = try NumbersReader.document(from: document())
        workbook.sheets[0].addRows(2)
        for row in [2, 3] {
            var cell = Cell()
            cell.formula = "A\(row + 1)+B\(row + 1)"
            workbook.sheets[0][CellAddress(row: row, column: 2)] = cell
        }
        workbook.recalculate()
        let (_, saved) = try NumbersReader.document(from: save(workbook, source))
        let table = try #require(saved.tables.values.first { $0.rowCount == 4 })
        let keys = [CellAddress(a1: "C1")!, CellAddress(a1: "C3")!, CellAddress(a1: "C4")!].map {
            table.storage[$0].flatMap(NumbersCellStorage.init)?.formulaKey
        }
        #expect(keys[0] != nil && keys.allSatisfy { $0 == keys[0] })
    }

    @Test("A formula Numbers can't be given is taken back; one it can is kept")
    func policy() throws {
        let (workbook, source) = try NumbersReader.document(from: document())
        var edited = workbook
        edited.sheets[0][CellAddress(a1: "B2")!] = { var cell = Cell(); cell.formula = "LET(x,1,x)"; return cell }()
        edited.sheets[0][CellAddress(a1: "C1")!] = { var cell = Cell(); cell.formula = "A1-B1"; return cell }()
        let (result, violation) = NumbersEditPolicy.reconcile(edited, from: workbook, source: source)
        #expect(violation == .formula)
        #expect(result.sheets[0][CellAddress(a1: "B2")!].formula == nil)
        #expect(result.sheets[0][CellAddress(a1: "C1")!].formula == "A1-B1")

        var protected = workbook
        protected.sheets[0][CellAddress(a1: "C2")!] = Cell(value: .number(1))
        #expect(NumbersEditPolicy.reconcile(protected, from: workbook, source: source).violation == .protectedCell)
    }
}

@Suite("Numbers whole columns and rows")
struct NumbersWholeLineTests {
    private let budgetTable = MergeOwners.UUID(lower: 0x5151, upper: 0x7272)

    /// A budget under a header row holding a year, totalled in its footer row
    /// by Numbers' own `SUM(B)`, and a summary on another sheet reading
    /// `SUM(Table 1::$B)`. Numbers leaves the header and the footer out of
    /// both: each comes to 1,500.
    private func document() throws -> Data {
        let sum = NumbersNodes.function("SUM", arguments: 1)
        var budget = NumbersDocumentBuilder.Table(name: "Table 1", rows: [
            [.text("Item"), .number(2_024, exponent: 0)],
            [.text("Rent"), .number(1_200, exponent: 0)],
            [.text("Food"), .number(300, exponent: 0)],
            [.text("Total"), .formulaNodes(1_500, [NumbersNodes.wholeColumn(0), sum])],
        ])
        budget.headerRows = 1
        budget.footerRows = 1
        budget.hasIdentifiers = true
        budget.uuid = budgetTable
        var document = NumbersDocumentBuilder()
        document.addSheet("Budget", tables: [budget])
        document.addSheet("Summary", tables: [.init(name: "Table 1", rows: [
            [.formulaNodes(1_500, [NumbersNodes.wholeColumn(1, absolute: true, table: budgetTable), sum])],
        ])])
        return try document.singleFile()
    }

    private func save(_ workbook: Workbook, _ source: NumbersSource) throws -> Data {
        try #require(NumbersWriter.fileWrapper(for: workbook, source: source, existing: nil).regularFileContents)
    }

    /// The nodes Numbers keeps for a cell's formula.
    private func nodes(at address: CellAddress, of sheet: Worksheet, in source: NumbersSource) throws -> [[UInt8]] {
        let table = try #require(source.tables[sheet.id])
        let key = try #require(table.storage[address].flatMap(NumbersCellStorage.init)?.formulaKey)
        let model = try #require(source.archive[table.modelIdentifier]?.message)
        let list = try #require(source.archive[model.message(4)?.message(6)]?.message)
        let entry = try #require(list.messages(3).first { $0.uint(1) == UInt64(key) })
        return (entry.message(5)?.message(1)?.messages(1) ?? []).map { $0.encoded() }
    }

    @Test("A whole column reads as one and covers the body alone, here as in Numbers")
    func reads() throws {
        let (workbook, source) = try NumbersReader.document(from: document())
        let budget = workbook.sheets[0], summary = workbook.sheets[1]
        let total = CellAddress(a1: "B4")!
        #expect(budget.tableEdges == TableEdges(headerRows: 1, footerRows: 1, headerColumns: 0))
        #expect(budget[total].formula == "SUM(B:B)")
        #expect(budget[total].value == .number(1_500), "neither the year in the header nor the total itself")
        #expect(summary[CellAddress(a1: "A1")!].formula == "SUM(Budget!$B:$B)")
        #expect(summary[CellAddress(a1: "A1")!].value == .number(1_500))
        #expect(source.tables.values.allSatisfy { $0.protectedCells.isEmpty })
    }

    @Test("A row inserted at the end of the body is counted, and the whole column is saved as Numbers wrote it")
    func survivesInsertion() throws {
        let (opened, openedSource) = try NumbersReader.document(from: document())
        let before = try nodes(at: CellAddress(a1: "B4")!, of: opened.sheets[0], in: openedSource)
        let summaryBefore = try nodes(at: CellAddress(a1: "A1")!, of: opened.sheets[1], in: openedSource)

        var workbook = opened
        // Just above the footer: past the end of any range written out.
        workbook.sheets[0].insertRows(1, at: 3)
        workbook.sheets[0][CellAddress(a1: "B4")!] = Cell(value: .number(50))
        workbook.recalculate()
        #expect(workbook.sheets[0][CellAddress(a1: "B5")!].formula == "SUM(B:B)")
        #expect(workbook.sheets[0][CellAddress(a1: "B5")!].value == .number(1_550))
        #expect(workbook.sheets[1][CellAddress(a1: "A1")!].value == .number(1_550))
        #expect(NumbersEditPolicy.violation(in: workbook, source: openedSource) == nil)

        let (reread, rereadSource) = try NumbersReader.document(from: save(workbook, openedSource))
        #expect(reread.sheets[0].rowCount == 5)
        #expect(reread.sheets[0][CellAddress(a1: "B5")!].formula == "SUM(B:B)")
        #expect(reread.sheets[0][CellAddress(a1: "B5")!].value == .number(1_550))
        #expect(reread.sheets[1][CellAddress(a1: "A1")!].value == .number(1_550))
        #expect(try nodes(at: CellAddress(a1: "B5")!, of: reread.sheets[0], in: rereadSource) == before)
        #expect(try nodes(at: CellAddress(a1: "A1")!, of: reread.sheets[1], in: rereadSource) == summaryBefore)
    }

    @Test("A whole column typed into a Numbers table is saved as one")
    func writesNew() throws {
        let (opened, source) = try NumbersReader.document(from: document())
        var workbook = opened
        workbook.sheets[0][CellAddress(a1: "A4")!] = Cell(formula: "COUNT(B:B)")
        workbook.recalculate()
        #expect(workbook.sheets[0][CellAddress(a1: "A4")!].value == .number(2))
        #expect(NumbersEditPolicy.violation(in: workbook, source: source) == nil)
        let reread = try NumbersReader.workbook(from: save(workbook, source))
        #expect(reread.sheets[0][CellAddress(a1: "A4")!].formula == "COUNT(B:B)")
        #expect(reread.sheets[0][CellAddress(a1: "A4")!].value == .number(2))
    }

    @Test("Saved as an Excel workbook, a whole column is written out as the body it covers")
    func exportsBodies() throws {
        let (workbook, _) = try NumbersReader.document(from: document())
        let budget = workbook.sheets[0], summary = workbook.sheets[1]
        #expect(FormulaPlan.writingOutTableBodies("SUM(B:B)", on: budget, in: workbook) == "SUM(B$2:B$3)")
        #expect(FormulaPlan.writingOutTableBodies("SUM(2:3)*2", on: budget, in: workbook) == "SUM($A2:$B3)*2")
        #expect(FormulaPlan.writingOutTableBodies("SUM(Budget!$B:$B)+(A:A)", on: summary, in: workbook)
            == "SUM(Budget!$B$2:$B$3)+(A$1:A$1)")
        #expect(FormulaPlan.writingOutTableBodies("SUM(B2:B3)", on: budget, in: workbook) == "SUM(B2:B3)")

        let copy = try XLSXReader.workbook(from: XLSXWriter.data(from: workbook))
        #expect(copy.sheets[0][CellAddress(a1: "B4")!].formula == "SUM(B$2:B$3)")
        #expect(copy.sheets[0][CellAddress(a1: "B4")!].value == .number(1_500))
        #expect(copy.sheets[1][CellAddress(a1: "A1")!].value == .number(1_500))
    }

    @Test("On a sheet with a table's edges, whole columns and rows leave out its headers and footers")
    func evaluates() {
        var workbook = Workbook()
        var sheet = Worksheet(name: "Table")
        sheet.rowCount = 4
        sheet.columnCount = 3
        for row in 0..<4 {
            for column in 0..<3 {
                sheet[CellAddress(row: row, column: column)] = Cell(value: .number(Double(row * 10 + column)))
            }
        }
        sheet.tableEdges = TableEdges(headerRows: 1, footerRows: 1, headerColumns: 1)
        workbook.sheets = [sheet]
        let value = { (formula: String) in CalculationEngine.preview(formula: formula, in: workbook, sheetIndex: 0) }
        #expect(value("SUM(B:B)") == .number(11 + 21))
        #expect(value("ROWS(B:B)") == .number(2))
        #expect(value("SUM(2:2)") == .number(11 + 12))
        #expect(value("INDEX(C:C,1)") == .number(12))
        #expect(value("SUM(B1:B4)") == .number(1 + 11 + 21 + 31), "a range written out is as written")
    }
}
