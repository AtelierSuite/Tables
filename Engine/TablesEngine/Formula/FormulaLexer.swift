import Foundation

public enum FormulaToken: Hashable, Sendable {
    case number(Double)
    case string(String)
    /// A bare word: a function name, a cell reference, a sheet name, or a constant.
    case identifier(String)
    /// A quoted sheet name, as in `'Q1 Sales'!A1`.
    case quotedName(String)
    /// An error literal such as `#N/A`, which may be written straight into a formula.
    case error(CellError)
    /// The inside of a `[…]` bracket, kept raw for structured references.
    case bracket(String)
    case op(String)
    case leftParenthesis
    case rightParenthesis
    case leftBrace
    case rightBrace
    case comma
    case semicolon
    case colon
    case bang
    case percent
    /// `@`, the implicit intersection operator.
    case at
    /// `#` after a reference, naming the whole range a formula spilled into.
    case hash
}

public struct FormulaLexError: Error, Sendable {
    public var message: String
}

/// Splits a formula body (everything after the leading `=`) into tokens.
public struct FormulaLexer: Sendable {
    private let characters: [Character]
    private var index = 0

    public init(_ source: String) {
        characters = Array(source)
    }

    public static func tokenize(_ source: String) throws -> [FormulaToken] {
        try tokenizeWithOffsets(source).map(\.token)
    }

    /// Tokens with the character offset each one starts and ends at, for the
    /// rewrites that splice text into a formula rather than reprint it.
    public static func tokenizeWithOffsets(_ source: String) throws -> [(token: FormulaToken, range: Range<Int>)] {
        var lexer = FormulaLexer(source)
        var tokens: [(FormulaToken, Range<Int>)] = []
        while true {
            lexer.skipWhitespace()
            let start = lexer.index
            guard let token = try lexer.next() else { break }
            tokens.append((token, start..<lexer.index))
        }
        return tokens
    }

    private var current: Character? { index < characters.count ? characters[index] : nil }

    private mutating func skipWhitespace() {
        while let character = current, character.isWhitespace { index += 1 }
    }

    private mutating func next() throws -> FormulaToken? {
        skipWhitespace()
        guard let character = current else { return nil }

        if character.isNumber || (character == "." && peekIsNumber(at: index + 1)) {
            return readNumber()
        }
        if character == "\"" { return try readString() }
        if character == "'" { return try readQuotedName() }
        if character == "[" { return try readBracket() }
        if character == "#" {
            if let error = readErrorLiteral() { return .error(error) }
            index += 1
            return .hash
        }
        if character.isLetter || character == "_" || character == "$" || character == "\\" {
            return readIdentifier()
        }

        index += 1
        switch character {
        case "(": return .leftParenthesis
        case ")": return .rightParenthesis
        case "{": return .leftBrace
        case "}": return .rightBrace
        case ",": return .comma
        case ";": return .semicolon
        case ":": return .colon
        case "!": return .bang
        case "%": return .percent
        case "@": return .at
        case "+", "-", "*", "/", "^", "&", "=": return .op(String(character))
        case "<":
            if current == "=" { index += 1; return .op("<=") }
            if current == ">" { index += 1; return .op("<>") }
            return .op("<")
        case ">":
            if current == "=" { index += 1; return .op(">=") }
            return .op(">")
        default:
            throw FormulaLexError(message: "Unexpected character “\(character)”")
        }
    }

    private func peekIsNumber(at position: Int) -> Bool {
        position < characters.count && characters[position].isNumber
    }

    /// The longest error literal starting here, matched without regard to case.
    private mutating func readErrorLiteral() -> CellError? {
        let rest = String(characters[index..<min(characters.count, index + 16)]).uppercased()
        let candidates = CellError.allCases.filter { rest.hasPrefix($0.rawValue) }
        guard let error = candidates.max(by: { $0.rawValue.count < $1.rawValue.count }) else { return nil }
        index += error.rawValue.count
        return error
    }

    private mutating func readNumber() -> FormulaToken {
        var text = ""
        while let character = current, character.isNumber || character == "." {
            text.append(character)
            index += 1
        }
        // Scientific notation, e.g. 1.2E-3.
        if let character = current, character == "e" || character == "E" {
            let save = index
            var candidate = String(character)
            index += 1
            if let sign = current, sign == "+" || sign == "-" {
                candidate.append(sign)
                index += 1
            }
            if let digit = current, digit.isNumber {
                while let digit = current, digit.isNumber {
                    candidate.append(digit)
                    index += 1
                }
                text += candidate
            } else {
                index = save
            }
        }
        return .number(Double(text) ?? 0)
    }

    private mutating func readString() throws -> FormulaToken {
        index += 1  // opening quote
        var text = ""
        while let character = current {
            index += 1
            if character == "\"" {
                if current == "\"" {  // escaped quote
                    text.append("\"")
                    index += 1
                    continue
                }
                return .string(text)
            }
            text.append(character)
        }
        throw FormulaLexError(message: "Unterminated text literal")
    }

    private mutating func readQuotedName() throws -> FormulaToken {
        index += 1
        var text = ""
        while let character = current {
            index += 1
            if character == "'" {
                if current == "'" {
                    text.append("'")
                    index += 1
                    continue
                }
                return .quotedName(text)
            }
            text.append(character)
        }
        throw FormulaLexError(message: "Unterminated sheet name")
    }

    /// Reads a bracketed specifier, nested brackets and all. Inside one a `'`
    /// escapes the next character, which is how a column named `a[1]` is written.
    private mutating func readBracket() throws -> FormulaToken {
        index += 1
        var depth = 1
        var text = ""
        while let character = current {
            index += 1
            if character == "'", let escaped = current {
                text.append(character)
                text.append(escaped)
                index += 1
                continue
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { return .bracket(text) }
            }
            text.append(character)
        }
        throw FormulaLexError(message: "Unterminated “[”")
    }

    private mutating func readIdentifier() -> FormulaToken {
        var text = ""
        while let character = current,
              character.isLetter || character.isNumber || character == "_" || character == "."
                || character == "$" || character == "\\" || character == "?" {
            text.append(character)
            index += 1
        }
        return .identifier(text)
    }
}
