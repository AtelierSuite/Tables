import Foundation

/// Finds the cell references in a formula as it is being typed, so each can be
/// drawn on the grid and coloured in the text the way a spreadsheet does.
///
/// Works from the lexer's tokens rather than the parser's tree: a formula
/// half-way through being typed rarely parses, but its references still
/// deserve to be shown.
public enum FormulaReferenceScanner {
    public struct Reference: Hashable, Sendable {
        /// Character offsets into the text, the `=` included.
        public var range: Range<Int>
        /// The sheet the reference names, or nil when it points at its own.
        public var sheetName: String?
        public var cells: CellRange
        /// Shared by every mention of the same cells, in order of first
        /// appearance, so a colour can be picked by it.
        public var colorIndex: Int
    }

    public static func references(in text: String) -> [Reference] {
        guard text.hasPrefix("=") else { return [] }
        // A string still waiting for its closing quote fails to lex; whatever
        // came before it is still worth showing.
        guard let tokens = lexedPrefix(of: String(text.dropFirst())) else { return [] }

        var references: [Reference] = []
        var colorIndices: [String: Int] = [:]
        var index = 0
        while index < tokens.count {
            var start = index
            var sheetName: String?
            // `Sheet1!` or `'Q1 Sales'!` in front of the cells.
            if index + 1 < tokens.count, tokens[index + 1].token == .bang {
                switch tokens[index].token {
                case .identifier(let name), .quotedName(let name):
                    sheetName = name
                    index += 2
                default:
                    break
                }
            }
            guard let (cells, end) = cellRange(in: tokens, at: index) else {
                index = start + 1
                continue
            }
            // `A1(` is a function name, not a cell.
            if end < tokens.count, tokens[end].token == .leftParenthesis {
                index = end
                continue
            }
            if sheetName == nil { start = index }
            let key = "\(sheetName?.lowercased() ?? "")!\(cells.normalized.a1)"
            let colorIndex = colorIndices[key] ?? colorIndices.count
            colorIndices[key] = colorIndex
            references.append(
                Reference(
                    // Shifted past the `=` the lexer never saw.
                    range: (tokens[start].range.lowerBound + 1)..<(tokens[end - 1].range.upperBound + 1),
                    sheetName: sheetName,
                    cells: cells.normalized,
                    colorIndex: colorIndex
                )
            )
            index = end
        }
        return references
    }

    /// `A1` or `A1:B2` starting at `index`, and the index just past it.
    private static func cellRange(
        in tokens: [(token: FormulaToken, range: Range<Int>)], at index: Int
    ) -> (CellRange, Int)? {
        guard index < tokens.count, let start = address(tokens[index].token) else { return nil }
        if index + 2 < tokens.count, tokens[index + 1].token == .colon,
           let end = address(tokens[index + 2].token) {
            return (CellRange(start: start, end: end), index + 3)
        }
        return (CellRange(start), index + 1)
    }

    private static func address(_ token: FormulaToken) -> CellAddress? {
        guard case .identifier(let word) = token else { return nil }
        return CellAddress(a1: word)
    }

    /// Tokens for as much of the text as lexes, dropping an unfinished tail.
    private static func lexedPrefix(of body: String) -> [(token: FormulaToken, range: Range<Int>)]? {
        if let tokens = try? FormulaLexer.tokenizeWithOffsets(body) { return tokens }
        // The tail that fails is an open string or quoted name; cut at its
        // opening quote and try what is left.
        guard let quote = body.lastIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        return try? FormulaLexer.tokenizeWithOffsets(String(body[..<quote]))
    }
}
