import Foundation

/// Numbers' formulas, read into Tables formulas and written back from them.
///
/// Numbers keeps a formula as its tree of operators, functions and
/// references laid out in postfix order, a `TSCE.ASTNodeArrayArchive`.
/// References count from the cell holding the formula unless they are
/// absolute, and name another table by its UUID.
///
/// Only what both apps mean the same way is translated. A formula with
/// anything else — a function Tables doesn't have, a header name, a
/// duration — isn't read as a formula at all: the cell keeps the result
/// Numbers calculated, and is left as Numbers wrote it.
///
/// A whole column, `B` in Numbers, is `B:B` here, and a whole row `3:3`.
/// Numbers means by one its table's body alone, leaving out the header and
/// footer rows or the header columns; so does Tables on a sheet read from
/// Numbers, which knows its table's edges. The reference stays whole as rows
/// come and go, reaching every row of the body as Numbers' does.
enum NumbersFormula {
    /// The tables a formula can refer to, by the UUID Numbers knows each by,
    /// and the one it is in.
    struct Context {
        var host: CellAddress
        var hostTable: MergeOwners.UUID?
        /// The name each table's worksheet goes by.
        var sheetNames: [MergeOwners.UUID: String]

        func table(named name: String) -> MergeOwners.UUID? {
            sheetNames.first { $0.value.caseInsensitiveCompare(name) == .orderedSame }?.key
        }
    }

    /// The node types translated, a `TSCE.ASTNodeArrayArchive.ASTNodeType`.
    enum NodeType {
        static let addition = 1
        static let subtraction = 2
        static let multiplication = 3
        static let division = 4
        static let power = 5
        static let concatenation = 6
        static let greaterThan = 7
        static let greaterThanOrEqual = 8
        static let lessThan = 9
        static let lessThanOrEqual = 10
        static let equal = 11
        static let notEqual = 12
        static let negation = 13
        static let plusSign = 14
        static let percent = 15
        static let function = 16
        static let number = 17
        static let boolean = 18
        static let string = 19
        static let date = 20
        static let emptyArgument = 22
        static let token = 23
        static let array = 24
        static let list = 25
        static let colon = 29
        /// A colon between two ends as `colon` is, written where a formula
        /// also keeps its references by row and column UUIDs.
        static let colonWithUIDs = 45
        static let referenceError = 30
        static let appendWhitespace = 32
        static let prependWhitespace = 33
        static let beginThunk = 34
        static let endThunk = 35
        static let cellReference = 36
        static let referenceErrorWithUIDs = 46
        static let colonTract = 67
    }

    /// The fields of a `TSCE.ASTNodeArrayArchive.ASTNodeArchive`.
    private enum Field {
        static let type = 1
        static let functionIndex = 2
        static let argumentCount = 3
        static let number = 4
        static let boolean = 5
        static let string = 6
        static let date = 7
        static let token = 10
        static let arrayColumns = 11
        static let arrayRows = 12
        static let listCount = 13
        static let column = 26
        static let row = 27
        static let crossTable = 28
        static let stickyBits = 33
        static let colonTract = 40
        static let decimalLow = 42
        static let decimalHigh = 43
    }

    /// Ends of a range Numbers writes past the last row or column, for a
    /// range of whole rows or columns.
    private static let wholeColumn = 0x7FFF
    private static let wholeRow = 0x7FFF_FFFF

    /// Functions Numbers works out only the arguments it needs of, each with
    /// the first argument it holds back that way; it holds back every one
    /// after it, wrapping each in a thunk.
    private static let lazyArguments: [String: Int] = ["IF": 1, "IFS": 1, "CHOOSE": 1]

    /// Functions Numbers names as Excel does but means something else by:
    /// Numbers' `DURATION` makes a length of time, Excel's works out a
    /// bond's.
    private static let differentFunctions: Set<String> = ["DURATION"]

    /// Numbers' functions Tables knows by another name, as the name Numbers
    /// gives them is taken by a different Excel function.
    private static let renamedFunctions: [String: String] = ["DURATION": "DURATION.TIME"]

    /// Functions that look up exchange rates and prices on the internet,
    /// which Tables doesn't: their formulas are read and written back all the
    /// same, and show the result Numbers last fetched, never working it out
    /// again, as a formula calling a function Tables lacks does.
    private static let fetchingFunctions: Set<String> = ["CURRENCY", "CURRENCYH", "CURRENCYCONVERT", "STOCK", "STOCKH"]

    /// Whether a function means the same in both apps.
    private static func isShared(_ name: String) -> Bool {
        FormulaFunctions.isKnown(name) && !differentFunctions.contains(name) || fetchingFunctions.contains(name)
    }

    /// The name Tables knows a Numbers function by.
    private static func tablesName(_ numbersName: String) -> String {
        renamedFunctions[numbersName] ?? numbersName
    }

    /// The index Numbers calls a Tables function by.
    private static func numbersIndex(_ tablesName: String) -> Int? {
        let numbersName = renamedFunctions.first { $0.value == tablesName }?.key ?? tablesName
        return NumbersFunctionIndex.indices[numbersName]
    }

    // MARK: - Reading

    /// A formula as Tables writes it, from the nodes of a Numbers formula, or
    /// nil when it holds anything Tables can't take on.
    static func formula(from nodes: [ProtobufMessage], context: Context) -> String? {
        var reader = Reader(context: context)
        for node in nodes {
            guard reader.read(node) else { return nil }
        }
        guard reader.stack.count == 1 else { return nil }
        return reader.stack[0].text
    }

    private struct Reader {
        /// An operand: its text, and how tightly it binds, to know when it
        /// needs parentheses.
        struct Operand {
            var text: String
            var precedence: Int
            /// The reference it is, for joining two into a range: a cell, or
            /// a whole column or row by its letters or number alone.
            var reference: (table: MergeOwners.UUID?, cell: String, line: Line?)?
        }

        /// What a reference with only a column or only a row names.
        enum Line {
            case column, row
        }

        let context: Context
        var stack: [Operand] = []

        static let atom = 9
        static let postfix = 8
        static let prefix = 7

        mutating func read(_ node: ProtobufMessage) -> Bool {
            switch node.int(Field.type) ?? 0 {
            case NodeType.addition: return binary("+", 3)
            case NodeType.subtraction: return binary("-", 3)
            case NodeType.multiplication: return binary("*", 4)
            case NodeType.division: return binary("/", 4)
            case NodeType.power: return binary("^", 5)
            case NodeType.concatenation: return binary("&", 2)
            case NodeType.greaterThan: return binary(">", 1)
            case NodeType.greaterThanOrEqual: return binary(">=", 1)
            case NodeType.lessThan: return binary("<", 1)
            case NodeType.lessThanOrEqual: return binary("<=", 1)
            case NodeType.equal: return binary("=", 1)
            case NodeType.notEqual: return binary("<>", 1)
            case NodeType.negation: return prefix("-")
            case NodeType.plusSign: return prefix("+")
            case NodeType.percent:
                guard let operand = stack.popLast() else { return false }
                push(parenthesized(operand, below: Self.postfix) + "%", Self.postfix)
            case NodeType.number:
                guard let number = NumbersFormula.number(of: node), number.isFinite else { return false }
                // Every digit, as it was typed: written back, it has to be the
                // same number.
                let text = number == number.rounded() && abs(number) < 1e15
                    ? String(Int64(number)) : "\(number)".uppercased()
                push(text, Self.atom)
            case NodeType.boolean:
                push(node.bool(Field.boolean) ? "TRUE" : "FALSE", Self.atom)
            case NodeType.token:
                push(node.bool(Field.token) ? "TRUE" : "FALSE", Self.atom)
            case NodeType.string:
                let text = node.string(Field.string) ?? ""
                push("\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"", Self.atom)
            case NodeType.date:
                guard let seconds = node.double(Field.date),
                      seconds.truncatingRemainder(dividingBy: NumbersCellStorage.secondsPerDay) == 0 else { return false }
                let serial = NumbersCellStorage.epochSerial + seconds / NumbersCellStorage.secondsPerDay
                guard let date = Optional(FormulaDates.components(fromSerial: serial)) else { return false }
                push("DATE(\(date.year),\(date.month),\(date.day))", Self.atom)
            case NodeType.emptyArgument:
                push("", Self.atom)
            case NodeType.function:
                return function(node)
            case NodeType.array:
                let columns = node.int(Field.arrayColumns) ?? 0, rows = node.int(Field.arrayRows) ?? 0
                guard columns > 0, rows > 0, stack.count >= columns * rows else { return false }
                let items = stack.suffix(columns * rows).map(\.text)
                stack.removeLast(columns * rows)
                let text = (0..<rows).map { items[($0 * columns)..<(($0 + 1) * columns)].joined(separator: ",") }
                push("{" + text.joined(separator: ";") + "}", Self.atom)
            case NodeType.list:
                let count = node.int(Field.listCount) ?? 0
                guard count > 0, stack.count >= count else { return false }
                let items = stack.suffix(count).map(\.text)
                stack.removeLast(count)
                push("(" + items.joined(separator: ",") + ")", Self.atom)
            case NodeType.cellReference:
                return cellReference(node)
            case NodeType.colon, NodeType.colonWithUIDs:
                return colon()
            case NodeType.colonTract:
                return colonTract(node)
            case NodeType.referenceError, NodeType.referenceErrorWithUIDs:
                push(CellError.referenceError.rawValue, Self.atom)
            case NodeType.appendWhitespace, NodeType.prependWhitespace, NodeType.beginThunk, NodeType.endThunk:
                break
            default:
                return false
            }
            return true
        }

        private mutating func push(_ text: String, _ precedence: Int) {
            stack.append(Operand(text: text, precedence: precedence))
        }

        private func parenthesized(_ operand: Operand, below precedence: Int) -> String {
            operand.precedence < precedence ? "(" + operand.text + ")" : operand.text
        }

        private mutating func binary(_ symbol: String, _ precedence: Int) -> Bool {
            guard let right = stack.popLast(), let left = stack.popLast() else { return false }
            // Operators group from the left but for `^`, from the right, so the
            // operand on the other side as loose as the operator itself needs
            // parentheses to keep its place.
            let rightGrouping = symbol == "^"
            let text = parenthesized(left, below: rightGrouping ? precedence + 1 : precedence) + symbol
                + parenthesized(right, below: rightGrouping ? precedence : precedence + 1)
            push(text, precedence)
            return true
        }

        private mutating func prefix(_ symbol: String) -> Bool {
            guard let operand = stack.popLast() else { return false }
            push(symbol + parenthesized(operand, below: Self.prefix), Self.prefix)
            return true
        }

        private mutating func function(_ node: ProtobufMessage) -> Bool {
            let count = node.int(Field.argumentCount) ?? 0
            guard let index = node.int(Field.functionIndex),
                  let name = NumbersFunctionIndex.names[index].map(NumbersFormula.tablesName),
                  NumbersFormula.isShared(name), stack.count >= count else { return false }
            let arguments = stack.suffix(count).map(\.text)
            stack.removeLast(count)
            push(name + "(" + arguments.joined(separator: ",") + ")", Self.atom)
            return true
        }

        // MARK: References

        private mutating func cellReference(_ node: ProtobufMessage) -> Bool {
            let table = MergeOwners.UUID(words: node.message(Field.crossTable)?.message(1))
            // A reference with only a column or a row names all of it, which
            // Numbers takes to mean its body rows or columns alone, as Tables
            // does on a table read from Numbers.
            let column = node.message(Field.column), row = node.message(Field.row)
            if let column, row == nil {
                let absolute = column.bool(2)
                let index = absolute ? zigzag(column.uint(1)) : context.host.column + zigzag(column.uint(1))
                guard index >= 0, index <= SheetLimits.maxColumn else { return false }
                return pushReference((absolute ? "$" : "") + CellAddress.columnName(index), table: table, line: .column)
            }
            if let row, column == nil {
                let absolute = row.bool(2)
                let index = absolute ? zigzag(row.uint(1)) : context.host.row + zigzag(row.uint(1))
                guard index >= 0, index <= SheetLimits.maxRow else { return false }
                return pushReference((absolute ? "$" : "") + String(index + 1), table: table, line: .row)
            }
            guard let column, let row else { return false }
            let columnAbsolute = column.bool(2), rowAbsolute = row.bool(2)
            let address = CellAddress(
                row: rowAbsolute ? zigzag(row.uint(1)) : context.host.row + zigzag(row.uint(1)),
                column: columnAbsolute ? zigzag(column.uint(1)) : context.host.column + zigzag(column.uint(1))
            )
            guard address.row >= 0, address.column >= 0 else { return false }
            let cell = NumbersFormula.a1(address, rowAbsolute: rowAbsolute, columnAbsolute: columnAbsolute)
            return pushReference(cell, table: table)
        }

        /// Pushes a reference: a cell or range, or a whole column or row,
        /// written as the range of it alone.
        private mutating func pushReference(_ cell: String, table: MergeOwners.UUID?, line: Line? = nil) -> Bool {
            guard let prefix = sheetPrefix(table) else { return false }
            let text = line == nil ? cell : cell + ":" + cell
            stack.append(Operand(text: prefix + text, precedence: Self.atom, reference: (table, cell, line)))
            return true
        }

        /// What goes before a reference into `table`: nothing for the table the
        /// formula is in, otherwise its worksheet's name.
        private func sheetPrefix(_ table: MergeOwners.UUID?) -> String? {
            guard let table, table != context.hostTable else { return "" }
            guard let name = context.sheetNames[table] else { return nil }
            return ChartReference.quotedSheetName(name) + "!"
        }

        private mutating func colon() -> Bool {
            guard let right = stack.popLast(), let left = stack.popLast() else { return false }
            if let start = left.reference, let end = right.reference, start.table == end.table, start.line == end.line {
                return pushReference(start.cell + ":" + end.cell, table: start.table)
            }
            // A whole column or row joined to anything but another of its
            // kind has no way to be written.
            if left.reference?.line != nil || right.reference?.line != nil { return false }
            push(parenthesized(left, below: Self.atom) + ":" + parenthesized(right, below: Self.atom), Self.atom)
            return true
        }

        /// A range as recent versions of Numbers write one: each end's row and
        /// column, absolute ones in one list and relative ones in another.
        private mutating func colonTract(_ node: ProtobufMessage) -> Bool {
            guard let tract = node.message(Field.colonTract) else { return false }
            let sticky = node.message(Field.stickyBits)
            let beginRowAbsolute = sticky?.bool(1) ?? false, beginColumnAbsolute = sticky?.bool(2) ?? false
            let endRowAbsolute = sticky?.bool(3) ?? false, endColumnAbsolute = sticky?.bool(4) ?? false

            // Each list's first value is the start, if the start is of its
            // kind; its second, or its first when there's one, is the end.
            func ends(relative: Int, absolute: Int, host: Int, beginAbsolute: Bool, endAbsolute: Bool, whole: Int) -> (Int, Int)? {
                func values(_ field: Int, signed: Bool) -> (begin: Int, end: Int)? {
                    guard let range = tract.messages(field).first, let begin = range.uint(1) else { return nil }
                    let convert = { (value: UInt64) in signed ? Int(Int32(truncatingIfNeeded: value)) : Int(value) }
                    return (convert(begin), convert(range.uint(2) ?? begin))
                }
                let relatives = values(relative, signed: true), absolutes = values(absolute, signed: false)
                guard absolutes?.begin != whole, absolutes?.end != whole else { return nil }
                guard let begin = beginAbsolute ? absolutes?.begin : relatives.map({ $0.begin + host }),
                      let end = endAbsolute ? absolutes?.end : relatives.map({ $0.end + host }) else { return nil }
                return (begin, end)
            }

            guard let rows = ends(relative: 2, absolute: 4, host: context.host.row,
                                  beginAbsolute: beginRowAbsolute, endAbsolute: endRowAbsolute, whole: wholeRow),
                  let columns = ends(relative: 1, absolute: 3, host: context.host.column,
                                     beginAbsolute: beginColumnAbsolute, endAbsolute: endColumnAbsolute, whole: wholeColumn),
                  rows.0 >= 0, rows.1 >= 0, columns.0 >= 0, columns.1 >= 0 else { return false }
            let start = NumbersFormula.a1(CellAddress(row: rows.0, column: columns.0),
                                          rowAbsolute: beginRowAbsolute, columnAbsolute: beginColumnAbsolute)
            let end = NumbersFormula.a1(CellAddress(row: rows.1, column: columns.1),
                                        rowAbsolute: endRowAbsolute, columnAbsolute: endColumnAbsolute)
            let table = MergeOwners.UUID(words: node.message(Field.crossTable)?.message(1))
            return pushReference(start + ":" + end, table: table)
        }

        private func zigzag(_ value: UInt64?) -> Int {
            let value = value ?? 0
            return Int(Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1))
        }
    }

    private static func a1(_ address: CellAddress, rowAbsolute: Bool, columnAbsolute: Bool) -> String {
        (columnAbsolute ? "$" : "") + CellAddress.columnName(address.column) + (rowAbsolute ? "$" : "") + String(address.row + 1)
    }

    private static func number(of node: ProtobufMessage) -> Double? {
        if let low = node.uint(Field.decimalLow), let high = node.uint(Field.decimalHigh) {
            let bytes = withUnsafeBytes(of: low.littleEndian, Array.init) + withUnsafeBytes(of: high.littleEndian, Array.init)
            return NumbersCellStorage.decimal128(bytes)
        }
        return node.double(Field.number)
    }

    // MARK: - Writing

    private struct Unwritable: Error {}

    /// The nodes of a Numbers formula for a Tables formula, or nil when it
    /// uses anything Numbers can't be given.
    static func nodes(for formula: String, context: Context) -> [ProtobufMessage]? {
        guard let syntax = try? FormulaParser.parseSyntax(formula) else { return nil }
        var writer = Writer(source: Array(formula), context: context)
        do {
            try writer.write(syntax)
        } catch {
            return nil
        }
        return writer.nodes
    }

    private struct Writer {
        let source: [Character]
        let context: Context
        var nodes: [ProtobufMessage] = []

        mutating func write(_ syntax: FormulaSyntax) throws {
            if syntax.isGroup, let inner = syntax.children.first {
                // Parentheses a person typed, which Numbers keeps as a list
                // of one so they show as typed.
                try write(inner)
                append(NodeType.list) { $0.set(Field.listCount, uint: 1) }
                return
            }
            switch syntax.node {
            case .number(let number):
                try writeNumber(number)
            case .text(let text):
                append(NodeType.string) { $0.set(Field.string, bytes: Array(text.utf8)) }
            case .boolean(let flag):
                append(NodeType.boolean) { $0.set(Field.boolean, bool: flag) }
            case .reference(let sheet, let address):
                let anchors = self.anchors(in: syntax.range)
                try writeCell(address, rowAbsolute: anchors.first?.row ?? false,
                              columnAbsolute: anchors.first?.column ?? false, sheet: sheet)
            case .range(let sheet, let start, let end):
                try writeRange(start, end, anchors: anchors(in: syntax.range), sheet: sheet)
            case .unary(let symbol, _):
                try write(child(syntax, 0))
                append(symbol == "-" ? NodeType.negation : NodeType.plusSign)
            case .postfixPercent:
                try write(child(syntax, 0))
                append(NodeType.percent)
            case .binary(let symbol, _, _):
                guard let type = Self.binaryTypes[symbol] else { throw Unwritable() }
                try write(child(syntax, 0))
                try write(child(syntax, 1))
                append(type)
            case .call(let name, let arguments):
                try writeCall(name, arguments: arguments.indices.map { try child(syntax, $0) })
            case .missing:
                append(NodeType.emptyArgument)
            case .array(let rows):
                guard let columns = rows.first?.count, rows.allSatisfy({ $0.count == columns }) else { throw Unwritable() }
                for item in syntax.children { try write(item) }
                append(NodeType.array) {
                    $0.set(Field.arrayColumns, uint: UInt64(columns))
                    $0.set(Field.arrayRows, uint: UInt64(rows.count))
                }
            case .union(let parts):
                for index in parts.indices { try write(child(syntax, index)) }
                append(NodeType.list) { $0.set(Field.listCount, uint: UInt64(parts.count)) }
            case .errorLiteral, .sheetSpan, .invoke, .definedName, .intersect, .spill, .structured:
                throw Unwritable()
            }
        }

        private static let binaryTypes: [String: Int] = [
            "+": NodeType.addition, "-": NodeType.subtraction, "*": NodeType.multiplication,
            "/": NodeType.division, "^": NodeType.power, "&": NodeType.concatenation,
            ">": NodeType.greaterThan, ">=": NodeType.greaterThanOrEqual, "<": NodeType.lessThan,
            "<=": NodeType.lessThanOrEqual, "=": NodeType.equal, "<>": NodeType.notEqual, ":": NodeType.colon,
        ]

        private func child(_ syntax: FormulaSyntax, _ index: Int) throws -> FormulaSyntax {
            guard index < syntax.children.count else { throw Unwritable() }
            return syntax.children[index]
        }

        private mutating func append(_ type: Int, _ configure: (inout ProtobufMessage) -> Void = { _ in }) {
            var node = ProtobufMessage()
            node.set(Field.type, uint: UInt64(type))
            configure(&node)
            nodes.append(node)
        }

        private mutating func writeNumber(_ number: Double) throws {
            guard number.isFinite else { throw Unwritable() }
            if number < 0 {
                try writeNumber(-number)
                append(NodeType.negation)
                return
            }
            let bytes = NumbersCellStorage.decimal128(number)
            let low = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[$1]) << (8 * $1) }
            let high = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[8 + $1]) << (8 * $1) }
            append(NodeType.number) {
                $0.set(Field.number, [.fixed64(number.bitPattern)])
                $0.set(Field.decimalLow, uint: low)
                $0.set(Field.decimalHigh, uint: high)
            }
        }

        private mutating func writeCall(_ name: String, arguments: [FormulaSyntax]) throws {
            let name = name.uppercased()
            guard let index = numbersIndex(name), isShared(name), !["LET", "LAMBDA"].contains(name) else {
                throw Unwritable()
            }
            let firstLazy = lazyArguments[name] ?? Int.max
            for (position, argument) in arguments.enumerated() {
                let lazy = position >= firstLazy
                if lazy { append(NodeType.beginThunk) }
                try write(argument)
                if lazy { append(NodeType.endThunk) }
            }
            append(NodeType.function) {
                $0.set(Field.functionIndex, uint: UInt64(index))
                $0.set(Field.argumentCount, uint: UInt64(arguments.count))
            }
        }

        // MARK: References

        /// The `$` anchors of each cell in a reference's text: one for a cell,
        /// two for a range.
        private func anchors(in range: Range<Int>) -> [(column: Bool, row: Bool)] {
            var text = String(source[range.clamped(to: 0..<source.count)])
            // A sheet name goes before the last "!" outside quotes.
            if let bang = text.lastIndex(of: "!") { text = String(text[text.index(after: bang)...]) }
            return text.split(separator: ":").map { cell in
                let columnAbsolute = cell.hasPrefix("$")
                let body = cell.drop { $0 == "$" }
                let rowAbsolute = body.drop { $0.isLetter }.hasPrefix("$")
                return (columnAbsolute, rowAbsolute)
            }
        }

        private func table(for sheet: String?) throws -> MergeOwners.UUID? {
            guard let sheet else { return nil }
            guard let table = context.table(named: sheet) else { throw Unwritable() }
            return table == context.hostTable ? nil : table
        }

        private func crossTable(_ table: MergeOwners.UUID) -> ProtobufMessage {
            var words = ProtobufMessage()
            words.set(2, uint: table.lower & 0xFFFF_FFFF)
            words.set(3, uint: table.lower >> 32)
            words.set(4, uint: table.upper & 0xFFFF_FFFF)
            words.set(5, uint: table.upper >> 32)
            var info = ProtobufMessage()
            info.set(1, message: words)
            return info
        }

        private mutating func writeCell(
            _ address: CellAddress, rowAbsolute: Bool, columnAbsolute: Bool, sheet: String?
        ) throws {
            try writeReference(column: address.column, columnAbsolute: columnAbsolute,
                               row: address.row, rowAbsolute: rowAbsolute, sheet: sheet)
        }

        /// A reference to a cell, or with only a column or a row, to all of
        /// it.
        private mutating func writeReference(
            column: Int?, columnAbsolute: Bool, row: Int?, rowAbsolute: Bool, sheet: String?
        ) throws {
            let table = try table(for: sheet)
            func coordinate(_ value: Int, absolute: Bool) -> ProtobufMessage {
                var coordinate = ProtobufMessage()
                let value = Int64(value)
                coordinate.set(1, uint: UInt64(bitPattern: (value << 1) ^ (value >> 63)))
                coordinate.set(2, bool: absolute)
                return coordinate
            }
            let columnCoordinate = column.map {
                coordinate(columnAbsolute ? $0 : $0 - context.host.column, absolute: columnAbsolute)
            }
            let rowCoordinate = row.map { coordinate(rowAbsolute ? $0 : $0 - context.host.row, absolute: rowAbsolute) }
            let crossTable = table.map(crossTable)
            append(NodeType.cellReference) {
                if let columnCoordinate { $0.set(Field.column, message: columnCoordinate) }
                if let rowCoordinate { $0.set(Field.row, message: rowCoordinate) }
                if let crossTable { $0.set(Field.crossTable, message: crossTable) }
            }
        }

        /// Whole columns or rows, each end a reference with only its column
        /// or row, joined into a range when there are several. Numbers takes
        /// them to mean its table's body alone, as Tables does on a sheet
        /// read from Numbers.
        private mutating func writeLines(
            _ start: CellAddress, _ end: CellAddress, anchors: [(column: Bool, row: Bool)], sheet: String?
        ) throws {
            let columns = start.row == 0 && end.row == SheetLimits.maxRow
            let rows = start.column == 0 && end.column == SheetLimits.maxColumn
            guard columns != rows else { throw Unwritable() }
            // The `$` before a row number is the row's.
            let first = anchors.first?.column ?? false
            let last = anchors.count > 1 ? anchors[1].column : first
            let ends = columns ? [start.column, end.column] : [start.row, end.row]
            let single = ends[0] == ends[1]
            for (index, absolute) in zip(single ? [ends[0]] : ends, [first, last]) {
                try writeReference(column: columns ? index : nil, columnAbsolute: columns && absolute,
                                   row: rows ? index : nil, rowAbsolute: rows && absolute, sheet: sheet)
            }
            if !single { append(NodeType.colon) }
        }

        private mutating func writeRange(
            _ start: CellAddress, _ end: CellAddress, anchors: [(column: Bool, row: Bool)], sheet: String?
        ) throws {
            if end.row >= SheetLimits.maxRow || end.column >= SheetLimits.maxColumn {
                return try writeLines(start, end, anchors: anchors, sheet: sheet)
            }
            let table = try table(for: sheet)
            let begin = anchors.first ?? (false, false)
            let finish = anchors.count > 1 ? anchors[1] : begin

            // Read back as `colonTract` reads them: a list's first value is
            // the start if the start is of its kind, its second the end; an
            // end alone goes first, and a start alone needs no second.
            func ends(_ first: Int, _ last: Int, firstAbsolute: Bool, lastAbsolute: Bool, host: Int) -> (relative: ProtobufMessage?, absolute: ProtobufMessage?) {
                func range(_ values: [Int]) -> ProtobufMessage {
                    var range = ProtobufMessage()
                    for (number, value) in zip([1, 2], values) {
                        range.set(number, uint: UInt64(bitPattern: Int64(value)))
                    }
                    return range
                }
                func list(firstOfKind: Bool, lastOfKind: Bool, _ first: Int, _ last: Int) -> ProtobufMessage? {
                    switch (firstOfKind, lastOfKind) {
                    case (true, true): return range([first, last])
                    case (true, false): return range([first])
                    case (false, true): return range([last])
                    case (false, false): return nil
                    }
                }
                let relative = list(firstOfKind: !firstAbsolute, lastOfKind: !lastAbsolute, first - host, last - host)
                let absolute = list(firstOfKind: firstAbsolute, lastOfKind: lastAbsolute, first, last)
                return (relative, absolute)
            }

            let columns = ends(start.column, end.column, firstAbsolute: begin.column, lastAbsolute: finish.column, host: context.host.column)
            let rows = ends(start.row, end.row, firstAbsolute: begin.row, lastAbsolute: finish.row, host: context.host.row)
            var tract = ProtobufMessage()
            if let range = columns.relative { tract.set(1, message: range) }
            if let range = rows.relative { tract.set(2, message: range) }
            if let range = columns.absolute { tract.set(3, message: range) }
            if let range = rows.absolute { tract.set(4, message: range) }
            tract.set(5, bool: true)

            var sticky = ProtobufMessage()
            sticky.set(1, bool: begin.row)
            sticky.set(2, bool: begin.column)
            sticky.set(3, bool: finish.row)
            sticky.set(4, bool: finish.column)

            let crossTable = table.map(crossTable)
            append(NodeType.colonTract) {
                if let crossTable { $0.set(Field.crossTable, message: crossTable) }
                $0.set(Field.stickyBits, message: sticky)
                $0.set(Field.colonTract, message: tract)
            }
        }
    }
}
