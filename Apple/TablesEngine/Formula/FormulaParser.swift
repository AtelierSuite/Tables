import Foundation

public indirect enum FormulaNode: Hashable, Sendable {
    case number(Double)
    case text(String)
    case boolean(Bool)
    case errorLiteral(CellError)
    case reference(sheet: String?, address: CellAddress)
    case range(sheet: String?, start: CellAddress, end: CellAddress)
    /// A 3-D reference such as `Jan:Mar!B2`, spanning every sheet from
    /// `first` to `last` in tab order.
    case sheetSpan(first: String, last: String, start: CellAddress, end: CellAddress)
    case unary(String, FormulaNode)
    /// An infix operator. `:` joins two references into the range they span,
    /// for the forms the reference grammar cannot read alone, like `A1:INDEX(…)`.
    case binary(String, FormulaNode, FormulaNode)
    case postfixPercent(FormulaNode)
    case call(String, [FormulaNode])
    /// Calling whatever an expression evaluates to, as in `LAMBDA(x, x+1)(2)`.
    case invoke(FormulaNode, [FormulaNode])
    case array([[FormulaNode]])
    /// A defined name. Only the workbook knows what it stands for, so the
    /// definition is left to the evaluator to look up and evaluate.
    case definedName(sheet: String?, name: String)
    /// An argument left empty, as the middle one in `IF(A1,,2)`.
    case missing
    /// `@`: one value out of a range, picked by the formula's own row or column.
    case intersect(FormulaNode)
    /// `A1#`: the whole range the formula in `A1` spilled into.
    case spill(FormulaNode)
    /// A structured reference into a table: `Sales[Amount]`, or `[@Price]`
    /// inside the table itself. The specifier is the text between the outer
    /// brackets, escapes and all.
    case structured(table: String?, specifier: String)
    /// `(A1:A3,C1:C3)`: several references taken together, as `SUM` and
    /// `AREAS` read them.
    case union([FormulaNode])
}

public struct FormulaParseError: Error, Sendable {
    public var message: String
}

/// A parsed node with the span of source text it came from, for rewrites that
/// need to edit a formula's text rather than reprint it.
public struct FormulaSyntax: Sendable {
    public var node: FormulaNode
    /// Character offsets into the formula body.
    public var range: Range<Int>
    /// The syntax of each operand or argument, in source order.
    public var children: [FormulaSyntax]
    /// A parenthesised expression: the parentheses' span around the one child
    /// that is the expression itself, carrying that child's node.
    public var isGroup = false
}

/// Excel's grid limits, which whole-column and whole-row references reach to.
public enum SheetLimits {
    public static let maxRow = 1_048_575
    public static let maxColumn = 16_383
}

/// A precedence-climbing parser for the spreadsheet expression grammar.
public struct FormulaParser: Sendable {
    private let tokens: [FormulaToken]
    private let offsets: [Range<Int>]
    private var index = 0

    private init(tokens: [(token: FormulaToken, range: Range<Int>)]) {
        self.tokens = tokens.map(\.token)
        self.offsets = tokens.map(\.range)
    }

    public static func parse(_ formulaBody: String) throws -> FormulaNode {
        try parseSyntax(formulaBody).node
    }

    public static func parseSyntax(_ formulaBody: String) throws -> FormulaSyntax {
        let tokens = try FormulaLexer.tokenizeWithOffsets(formulaBody)
        guard !tokens.isEmpty else { throw FormulaParseError(message: "Empty formula") }
        var parser = FormulaParser(tokens: tokens)
        let syntax = try parser.parseExpression(minimumPrecedence: 0)
        guard parser.index == tokens.count else {
            throw FormulaParseError(message: "Unexpected trailing input")
        }
        return syntax
    }

    /// The prefixes Excel writes in front of functions newer than the 2007
    /// file format, and in front of LAMBDA parameters. None of them is part of
    /// the name a person types.
    public static func strippingFilePrefixes(_ name: String) -> String {
        var result = name
        for prefix in ["_xlfn.", "_xlws.", "_xlpm.", "_xleta.", "_xlfn.", "_xlws."]
        where result.count > prefix.count && result.lowercased().hasPrefix(prefix) {
            result.removeFirst(prefix.count)
        }
        return result
    }

    // MARK: - Token helpers

    private var current: FormulaToken? { index < tokens.count ? tokens[index] : nil }

    private func peek(_ offset: Int) -> FormulaToken? {
        index + offset < tokens.count ? tokens[index + offset] : nil
    }

    private mutating func advance() -> FormulaToken? {
        defer { index += 1 }
        return current
    }

    private mutating func expect(_ token: FormulaToken, _ description: String) throws {
        guard current == token else { throw FormulaParseError(message: "Expected \(description)") }
        index += 1
    }

    /// Where the token at `position` begins, or the end of the text past the last one.
    private func start(of position: Int) -> Int {
        position < offsets.count ? offsets[position].lowerBound : (offsets.last?.upperBound ?? 0)
    }

    /// The span from the token at `first` to the last one consumed.
    private func span(from first: Int) -> Range<Int> {
        let lower = start(of: first)
        let upper = index > 0 ? offsets[min(index, offsets.count) - 1].upperBound : lower
        return lower..<max(lower, upper)
    }

    private static let precedences: [String: Int] = [
        "<": 1, ">": 1, "=": 1, "<=": 1, ">=": 1, "<>": 1,
        "&": 2,
        "+": 3, "-": 3,
        "*": 4, "/": 4,
        "^": 5,
    ]

    // MARK: - Expressions

    private mutating func parseExpression(minimumPrecedence: Int) throws -> FormulaSyntax {
        let first = index
        var left = try parseUnary()
        while case .op(let symbol)? = current,
              let precedence = Self.precedences[symbol], precedence >= minimumPrecedence {
            index += 1
            // `^` is right-associative; everything else is left-associative.
            let nextMinimum = symbol == "^" ? precedence : precedence + 1
            let right = try parseExpression(minimumPrecedence: nextMinimum)
            left = FormulaSyntax(node: .binary(symbol, left.node, right.node), range: span(from: first),
                                 children: [left, right])
        }
        return left
    }

    private mutating func parseUnary() throws -> FormulaSyntax {
        let first = index
        if case .op(let symbol)? = current, symbol == "-" || symbol == "+" {
            index += 1
            let operand = try parseUnary()
            guard symbol == "-" else { return operand }
            return FormulaSyntax(node: .unary("-", operand.node), range: span(from: first), children: [operand])
        }
        return try parsePostfix()
    }

    private mutating func parsePostfix() throws -> FormulaSyntax {
        let first = index
        var syntax = try parseRangeOperand()
        while current == .percent {
            index += 1
            syntax = FormulaSyntax(node: .postfixPercent(syntax.node), range: span(from: first), children: [syntax])
        }
        return syntax
    }

    /// A reference-level operand, joined to the next by `:` where the reference
    /// grammar has not already taken the colon itself.
    private mutating func parseRangeOperand() throws -> FormulaSyntax {
        let first = index
        var syntax = try parseColonChain()
        // A space between two references is the intersection operator.
        while startsIntersection(after: syntax.node) {
            let right = try parseColonChain()
            syntax = FormulaSyntax(node: .binary(" ", syntax.node, right.node), range: span(from: first),
                                   children: [syntax, right])
        }
        return syntax
    }

    private mutating func parseColonChain() throws -> FormulaSyntax {
        let first = index
        var syntax = try parseSuffixed()
        while current == .colon {
            index += 1
            let right = try parseSuffixed()
            syntax = FormulaSyntax(node: .binary(":", syntax.node, right.node), range: span(from: first),
                                   children: [syntax, right])
        }
        return syntax
    }

    /// Whether whitespace and then another reference follow a reference. In
    /// any other position two operands side by side are a syntax error, so
    /// reading them as an intersection cannot change a formula that parsed.
    private func startsIntersection(after node: FormulaNode) -> Bool {
        guard index > 0, index < tokens.count, offsets[index - 1].upperBound < offsets[index].lowerBound else {
            return false
        }
        switch node {
        case .reference, .range, .definedName, .structured, .union, .spill, .intersect, .binary(":", _, _),
             .binary(" ", _, _), .call:
            break
        default:
            return false
        }
        switch tokens[index] {
        case .identifier, .quotedName, .bracket: return true
        // A whole-row reference such as `2:3`.
        case .number: return peek(1) == .colon
        case .leftParenthesis:
            if case .call = node { return false }
            return true
        default: return false
        }
    }

    /// A primary followed by any number of `#` spill markers or call parentheses.
    private mutating func parseSuffixed() throws -> FormulaSyntax {
        let first = index
        var syntax = try parsePrimary()
        while true {
            if current == .hash {
                index += 1
                syntax = FormulaSyntax(node: .spill(syntax.node), range: span(from: first), children: [syntax])
            } else if current == .leftParenthesis, Self.isCallable(syntax.node) {
                index += 1
                let arguments = try parseArguments(closing: "a call")
                syntax = FormulaSyntax(node: .invoke(syntax.node, arguments.map(\.node)), range: span(from: first),
                                       children: [syntax] + arguments)
            } else {
                return syntax
            }
        }
    }

    /// Only a call or a parenthesised expression can produce a LAMBDA to call;
    /// anything else followed by `(` is a syntax error, not an invocation.
    private static func isCallable(_ node: FormulaNode) -> Bool {
        switch node {
        case .call, .invoke: return true
        default: return false
        }
    }

    private mutating func parsePrimary() throws -> FormulaSyntax {
        let first = index
        guard let token = advance() else { throw FormulaParseError(message: "Unexpected end of formula") }
        switch token {
        case .number(let value):
            // `1:3` is a whole-row reference, not arithmetic.
            if current == .colon, case .number(let end)? = peek(1),
               let range = Self.rowRange(Self.rowWord(value), Self.rowWord(end)) {
                index += 2
                return leaf(.range(sheet: nil, start: range.start, end: range.end), from: first)
            }
            return leaf(.number(value), from: first)
        case .string(let value):
            return leaf(.text(value), from: first)
        case .error(let error):
            return leaf(.errorLiteral(error), from: first)
        case .bracket(let specifier):
            return leaf(.structured(table: nil, specifier: specifier), from: first)
        case .leftParenthesis:
            let inner = try parseExpression(minimumPrecedence: 0)
            // A comma inside plain parentheses joins references into a union.
            if current == .comma {
                var parts = [inner]
                while current == .comma {
                    index += 1
                    parts.append(try parseExpression(minimumPrecedence: 0))
                }
                try expect(.rightParenthesis, "“)”")
                return FormulaSyntax(node: .union(parts.map(\.node)), range: span(from: first), children: parts)
            }
            try expect(.rightParenthesis, "“)”")
            return FormulaSyntax(node: inner.node, range: span(from: first), children: [inner], isGroup: true)
        case .leftBrace:
            return try parseArrayLiteral(from: first)
        case .quotedName(let sheetName):
            try expect(.bang, "“!” after a sheet name")
            return try parseReference(sheet: sheetName, from: first)
        case .identifier(let word):
            return try parseIdentifier(word, from: first)
        case .at:
            let operand = try parseSuffixed()
            return FormulaSyntax(node: .intersect(operand.node), range: span(from: first), children: [operand])
        case .op(let symbol) where symbol == "-":
            let operand = try parseUnary()
            return FormulaSyntax(node: .unary("-", operand.node), range: span(from: first), children: [operand])
        default:
            throw FormulaParseError(message: "Unexpected token in formula")
        }
    }

    private func leaf(_ node: FormulaNode, from first: Int) -> FormulaSyntax {
        FormulaSyntax(node: node, range: span(from: first), children: [])
    }

    private mutating func parseArrayLiteral(from first: Int) throws -> FormulaSyntax {
        var rows: [[FormulaSyntax]] = []
        var row: [FormulaSyntax] = []
        while current != .rightBrace {
            row.append(try parseExpression(minimumPrecedence: 0))
            if current == .comma {
                index += 1
            } else if current == .semicolon {
                index += 1
                rows.append(row)
                row = []
            } else {
                break
            }
        }
        try expect(.rightBrace, "“}”")
        if !row.isEmpty { rows.append(row) }
        return FormulaSyntax(node: .array(rows.map { $0.map(\.node) }), range: span(from: first),
                             children: rows.flatMap { $0 })
    }

    /// The arguments of a call once its `(` has been consumed. An empty slot
    /// between separators is an omitted argument, not an error.
    private mutating func parseArguments(closing description: String) throws -> [FormulaSyntax] {
        var arguments: [FormulaSyntax] = []
        if current == .rightParenthesis {
            index += 1
            return arguments
        }
        while true {
            if current == .comma || current == .semicolon || current == .rightParenthesis {
                arguments.append(FormulaSyntax(node: .missing, range: start(of: index)..<start(of: index),
                                               children: []))
            } else {
                arguments.append(try parseExpression(minimumPrecedence: 0))
            }
            if current == .comma || current == .semicolon {
                index += 1
                continue
            }
            break
        }
        try expect(.rightParenthesis, "“)” closing \(description)")
        return arguments
    }

    private mutating func parseIdentifier(_ word: String, from first: Int) throws -> FormulaSyntax {
        // A structured reference: Sales[Amount]
        if case .bracket(let specifier)? = current {
            index += 1
            return leaf(.structured(table: word, specifier: specifier), from: first)
        }
        // A sheet-qualified reference: Sheet1!A1
        if current == .bang {
            index += 1
            return try parseReference(sheet: word, from: first)
        }
        // A 3-D reference: Jan:Mar!A1
        if current == .colon, case .identifier(let last)? = peek(1), peek(2) == .bang {
            index += 3
            return try parseSheetSpan(first: word, last: last, from: first)
        }
        // A function call.
        if current == .leftParenthesis {
            index += 1
            let name = Self.strippingFilePrefixes(word).uppercased()
            let arguments = try parseArguments(closing: name)
            let node: FormulaNode
            // Excel writes `@` and `#` into files as these two functions.
            if name == "SINGLE", arguments.count == 1 {
                node = .intersect(arguments[0].node)
            } else if name == "ANCHORARRAY", arguments.count == 1 {
                node = .spill(arguments[0].node)
            } else {
                node = .call(name, arguments.map(\.node))
            }
            return FormulaSyntax(node: node, range: span(from: first), children: arguments)
        }
        return try makeValueOrReference(word, sheet: nil, from: first)
    }

    /// Parses the address portion of a reference once the sheet name is known.
    private mutating func parseReference(sheet: String, from first: Int) throws -> FormulaSyntax {
        // `'Jan:Mar'!A1` quotes a 3-D span in one name.
        if let colon = sheet.firstIndex(of: ":") {
            return try parseSheetSpan(first: String(sheet[..<colon]),
                                      last: String(sheet[sheet.index(after: colon)...]), from: first)
        }
        switch advance() {
        case .identifier(let word):
            return try makeValueOrReference(word, sheet: sheet, from: first)
        case .number(let value):
            // A whole-row reference on another sheet: Sheet1!1:3
            guard current == .colon, case .number(let end)? = peek(1),
                  let range = Self.rowRange(Self.rowWord(value), Self.rowWord(end)) else {
                throw FormulaParseError(message: "Expected a cell reference after “!”")
            }
            index += 2
            return leaf(.range(sheet: sheet, start: range.start, end: range.end), from: first)
        case .error(.referenceError):
            return leaf(.errorLiteral(.referenceError), from: first)
        default:
            throw FormulaParseError(message: "Expected a cell reference after “!”")
        }
    }

    private mutating func parseSheetSpan(first firstSheet: String, last: String, from first: Int) throws -> FormulaSyntax {
        guard case .identifier(let word)? = advance() else {
            throw FormulaParseError(message: "Expected a cell reference after “!”")
        }
        let reference = try makeValueOrReference(word, sheet: firstSheet, from: first)
        switch reference.node {
        case .reference(_, let address):
            return leaf(.sheetSpan(first: firstSheet, last: last, start: address, end: address), from: first)
        case .range(_, let start, let end):
            return leaf(.sheetSpan(first: firstSheet, last: last, start: start, end: end), from: first)
        default:
            throw FormulaParseError(message: "Expected a cell reference after “!”")
        }
    }

    private mutating func makeValueOrReference(_ word: String, sheet: String?, from first: Int) throws -> FormulaSyntax {
        let upper = word.uppercased()
        if sheet == nil {
            switch upper {
            case "TRUE": return leaf(.boolean(true), from: first)
            case "FALSE": return leaf(.boolean(false), from: first)
            default: break
            }
        }

        // Whole columns, `A:C`, and whole rows written with anchors, `$1:$3`.
        if current == .colon, case .identifier(let endWord)? = peek(1),
           let range = Self.columnRange(word, endWord) ?? Self.rowRange(word, endWord) {
            index += 2
            return leaf(.range(sheet: sheet, start: range.start, end: range.end), from: first)
        }

        // Anything that is not an address is a defined name. Whether one exists
        // is a workbook question, not a grammar one, so an unknown name has to
        // reach the evaluator to become `#NAME?` rather than failing the parse.
        guard let start = CellAddress(a1: word) else {
            return leaf(.definedName(sheet: sheet, name: Self.strippingFilePrefixes(word)), from: first)
        }
        // `A1:B2` is read here; `A1:INDEX(…)` is left to the range operator.
        if current == .colon, case .identifier(let endWord)? = peek(1), peek(2) != .leftParenthesis,
           let end = CellAddress(a1: endWord) {
            index += 2
            return leaf(.range(sheet: sheet, start: start, end: end), from: first)
        }
        return leaf(.reference(sheet: sheet, address: start), from: first)
    }

    /// `A:C` as a range reaching every row, or nil when either side is not
    /// purely column letters.
    private static func columnRange(_ startWord: String, _ endWord: String) -> CellRange? {
        func column(_ word: String) -> Int? {
            let letters = word.replacingOccurrences(of: "$", with: "")
            guard !letters.isEmpty, letters.count <= 3, letters.allSatisfy(\.isLetter),
                  word.hasPrefix("$") || word.first?.isLetter == true,
                  let index = CellAddress.columnIndex(letters), index <= SheetLimits.maxColumn else { return nil }
            return index
        }
        guard let first = column(startWord), let last = column(endWord) else { return nil }
        return CellRange(start: CellAddress(row: 0, column: first),
                         end: CellAddress(row: SheetLimits.maxRow, column: last))
    }

    /// A number token as row digits, or an empty word when it cannot be a row.
    private static func rowWord(_ value: Double) -> String {
        guard value >= 1, value <= Double(SheetLimits.maxRow + 1), value == value.rounded() else { return "" }
        return String(Int(value))
    }

    /// `1:3` as a range reaching every column, or nil when either side is not a row number.
    private static func rowRange(_ startWord: String, _ endWord: String) -> CellRange? {
        func row(_ word: String) -> Int? {
            let digits = word.hasPrefix("$") ? String(word.dropFirst()) : word
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits),
                  number >= 1, number - 1 <= SheetLimits.maxRow else { return nil }
            return number - 1
        }
        guard let first = row(startWord), let last = row(endWord) else { return nil }
        return CellRange(start: CellAddress(row: first, column: 0),
                         end: CellAddress(row: last, column: SheetLimits.maxColumn))
    }
}
