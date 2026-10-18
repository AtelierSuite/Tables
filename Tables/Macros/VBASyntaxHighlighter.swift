import Foundation
import TablesEngine

/// Finds what to colour in VBA source: keywords, comments, strings and
/// numbers. Deliberately forgiving — it runs on every keystroke, over code
/// that is usually half-typed, so it never fails, it only colours less.
enum VBASyntaxHighlighter {
    enum Kind: Hashable, Sendable {
        case keyword, comment, string, number
    }

    struct Span: Hashable, Sendable {
        var range: NSRange
        var kind: Kind
    }

    static let keywords: Set<String> = [
        "and", "as", "boolean", "byref", "byte", "byval", "call", "case", "const", "currency", "date", "declare",
        "dim", "do", "double", "each", "else", "elseif", "empty", "end", "enum", "eqv", "erase", "error", "event",
        "exit", "explicit", "false", "for", "friend", "function", "get", "global", "gosub", "goto", "if", "imp",
        "implements", "in", "integer", "is", "let", "like", "long", "longlong", "longptr", "loop", "me", "mod",
        "new", "next", "not", "nothing", "null", "object", "on", "option", "optional", "or", "paramarray",
        "preserve", "private", "property", "ptrsafe", "public", "redim", "resume", "select", "set", "single",
        "static", "step", "stop", "string", "sub", "then", "to", "true", "type", "typeof", "until", "variant",
        "wend", "while", "with", "withevents", "xor", "compare",
    ]

    static func spans(in text: String) -> [Span] {
        let units = Array(text.utf16)
        var spans: [Span] = []
        var index = 0
        var atLineStart = true

        func isIdentifierUnit(_ unit: UInt16) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return unit > 0x7F }
            return CharacterSet.alphanumerics.contains(scalar) || unit == 0x5F
        }

        while index < units.count {
            let unit = units[index]
            switch unit {
            case 0x0A, 0x0D:
                atLineStart = true
                index += 1
            case 0x20, 0x09:
                index += 1
            case 0x27: // ' starts a comment running to the end of the line
                let start = index
                while index < units.count, units[index] != 0x0A, units[index] != 0x0D { index += 1 }
                spans.append(Span(range: NSRange(location: start, length: index - start), kind: .comment))
            case 0x22: // "…", with "" for a quote inside
                let start = index
                index += 1
                while index < units.count, units[index] != 0x0A, units[index] != 0x0D {
                    if units[index] == 0x22 {
                        if index + 1 < units.count, units[index + 1] == 0x22 {
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    index += 1
                }
                spans.append(Span(range: NSRange(location: start, length: index - start), kind: .string))
                atLineStart = false
            case 0x30...0x39:
                let start = index
                while index < units.count, (0x30...0x39).contains(units[index]) || units[index] == 0x2E { index += 1 }
                // A number that runs into letters is part of a name, like a line label's tail.
                if index < units.count, isIdentifierUnit(units[index]) {
                    while index < units.count, isIdentifierUnit(units[index]) { index += 1 }
                } else {
                    spans.append(Span(range: NSRange(location: start, length: index - start), kind: .number))
                }
                atLineStart = false
            default:
                guard isIdentifierUnit(unit) else {
                    index += 1
                    atLineStart = false
                    continue
                }
                let start = index
                while index < units.count, isIdentifierUnit(units[index]) { index += 1 }
                let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start).lowercased()
                // `Rem` is a comment keyword when it opens a statement.
                if word == "rem", atLineStart {
                    while index < units.count, units[index] != 0x0A, units[index] != 0x0D { index += 1 }
                    spans.append(Span(range: NSRange(location: start, length: index - start), kind: .comment))
                } else if keywords.contains(word), start == 0 || units[start - 1] != 0x2E {
                    // After a dot it is a member name, however keyword-like: `.End`, `.Select`.
                    spans.append(Span(range: NSRange(location: start, length: index - start), kind: .keyword))
                }
                atLineStart = false
            }
        }
        return spans
    }
}
