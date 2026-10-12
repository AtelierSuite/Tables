import Foundation
import Testing
@testable import Tables

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

    @Test("Formulas with anything Tables can't take on aren't read")
    func unreadable() {
        let wholeColumn = NumbersNodes.node(NumbersFormula.NodeType.cellReference) {
            var column = ProtobufMessage()
            column.set(1, uint: 0)
            $0.set(26, message: column)
        }
        #expect(NumbersFormula.formula(from: [wholeColumn, NumbersNodes.function("SUM", arguments: 1)], context: context("B1")) == nil)
        let unknownFunction = NumbersNodes.function("DUR2WEEKS", arguments: 1)
        #expect(NumbersFormula.formula(from: [NumbersNodes.number(1), unknownFunction], context: context("B1")) == nil)
        let unknownTable = NumbersNodes.cell(column: 0, row: 0, table: MergeOwners.UUID(lower: 1, upper: 2))
        #expect(NumbersFormula.formula(from: [unknownTable], context: context("B1")) == nil)
    }

    @Test("Formulas come back the same after being written and read again", arguments: [
        "A1+B1*2", "(A1+B1)*2", "-A1^2", "2^3^2", "(2^3)^2", "SUM($A$1:B$3,10%)", "IF(A1>=1,\"yes\",IFERROR(1/0,0))",
        "'Rates – Table 1'!B2*2", "SUM('Rates – Table 1'!A1:A9)", "AVERAGE({1,2;3,4})", "IFS(A1,1,TRUE,2)",
        "CHOOSE(2,A1,B1,C1)", "SUM($A$1:B3)", "SUM(A1:$B$3)", "SUM($A1:B$3)", "SUM(A$1:$B3)", "A1&\" \"&B1", "A1<>B1", "COUNT(,1)", "SUM(A2:INDEX(A1:A9,3))",
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
        "SUM(A:A)", "SUM(1:1)", "LET(x,1,x)", "DURATION(A1,B1,0.08,0.09,2)", "Missing!A1", "#N/A", "Sales[Amount]", "A1#",
    ])
    func unwritable(_ formula: String) {
        #expect(NumbersFormula.nodes(for: formula, context: context("B1")) == nil)
    }
}
